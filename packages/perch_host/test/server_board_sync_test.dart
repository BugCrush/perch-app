// Board sync over the wire (docs/superpowers/plans/2026-11-24-projects-first-board.md, Task 9):
// a new app gets the host's summary after the welcome, answers with its own and receives
// the records it lacks; records from one device reach the others; a watch-only device reads
// but cannot write; an older app keeps the task messages; a task assigned to this machine
// from the phone runs with RunTask.
import 'dart:async';
import 'dart:io';

import 'package:perch_host/src/host_board.dart';
import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/task_board.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'server_accounts_test.dart' show MemoryLink;

final sep = Platform.pathSeparator;

/// A device on an in-memory link, allowed with [permission].
class Device {
  final MemoryLink link = MemoryLink();
  final List<HostMessage> received = [];
  late SecureSession session;
  final _ready = Completer<void>();
  final String id;

  Device(PerchServer server, HostState state, {String permission = DevicePermissions.full})
      : id = 'dev-${_n++}' {
    final rec = state.approveDevice(id, name: 'Phone $id', permission: permission);
    final hs = ClientHandshake(secret: rec.keyBytes!, machineId: state.machineId, deviceId: id);
    link.onFromHost = (f) {
      if (!_ready.isCompleted) {
        session = hs.finish(f);
        _ready.complete();
        return;
      }
      final text = session.open(f);
      if (text == null) return;
      final m = decodeHost(text);
      if (m != null) received.add(m);
    };
    server.attach(link);
    link.push(hs.hello);
  }
  static var _n = 0;

  Future<void> hello() async {
    await _ready.future;
    send(const Hello(deviceName: 'Phone', pairing: 2));
    await next<Welcome>();
  }

  void send(ClientMessage m) {
    for (final f in session.seal(encodeClient(m))) {
      link.push(f);
    }
  }

  Future<T> next<T extends HostMessage>({bool Function(T)? where, int from = 0}) async {
    await waitUntil(() => received.skip(from).whereType<T>().any((m) => where == null || where(m)),
        timeout: const Duration(seconds: 15));
    return received.skip(from).whereType<T>().firstWhere((m) => where == null || where(m));
  }
}

void main() {
  late Directory tmp;
  late HostState state;
  late SessionManager manager;
  late HostBoard hostBoard;
  late TaskBoard board;
  late PerchServer server;
  final phoneClock = HlcClock('phone');

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_board_sync_');
    state = HostState.load('${tmp.path}${sep}state');
    manager = SessionManager(launcher: fakeLauncher(), external: FakeExternalSessions());
    hostBoard = HostBoard(stateDir: state.directory, machineId: state.machineId, remoteOf: (_) => null);
    board = TaskBoard(
        board: hostBoard,
        sessions: ManagerTaskSessions(manager),
        settle: const Duration(milliseconds: 100),
        poll: const Duration(milliseconds: 100))
      ..start();
    server = PerchServer(manager: manager, state: state, machineName: 'Desk', bindAddress: '127.0.0.1', port: 0, board: board);
    await server.start();
  });

  tearDown(() async {
    await server.close();
    await board.dispose();
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Device> device({String permission = DevicePermissions.full}) async {
    final d = Device(server, state, permission: permission);
    await d.hello();
    return d;
  }

  BoardRecord taskRecord(String id, String title, {String? machine, String? cwd}) {
    final v = phoneClock.tick();
    return BoardRecord(RecordKinds.task, id, {
      'content': BoardGroup(
          {'title': title, 'projectId': 'p1', 'machineId': ?machine, 'cwd': cwd ?? ''}, v),
      'column': BoardGroup({'column': 'ready'}, v),
    });
  }

  test('a_new_app_gets_a_summary_then_the_missing_records', () async {
    hostBoard.edit(RecordKinds.project, 'p1', {
      'content': {'name': 'Perch'}
    });
    hostBoard.edit(RecordKinds.task, 'on-host', {
      'content': {'title': 'Only on the host', 'projectId': 'p1'}
    });
    final d = await device();
    expect((await d.next<Welcome>()).boardSync, isTrue);
    final summary = await d.next<BoardSummaryFromHost>();
    expect(summary.summary.keys.toSet(), {'project/p1', 'task/on-host'});
    // The app has one of them already and one of its own.
    final mine = taskRecord('on-phone', 'Only on the phone');
    d.send(BoardSummaryFromApp(summary: {
      'project/p1': {for (final g in hostBoard.board.get(RecordKinds.project, 'p1')!.groups.entries) g.key: g.value.version.encode()},
      mine.key: {for (final g in mine.groups.entries) g.key: g.value.version.encode()},
    }));
    final got = await d.next<BoardRecordsFromHost>();
    expect(got.records.map((r) => r.key), ['task/on-host']);
    d.send(BoardRecordsFromApp(records: [mine]));
    await waitUntil(() => hostBoard.board.get(RecordKinds.task, 'on-phone') != null);
    expect(File('${state.directory}${sep}board.json').readAsStringSync(), contains('Only on the phone'));
  });

  test('records_from_one_device_reach_the_other_connected_device', () async {
    final a = await device();
    final b = await device();
    b.send(const BoardSummaryFromApp(summary: {}));
    await b.next<BoardRecordsFromHost>();
    a.send(const BoardSummaryFromApp(summary: {}));
    await a.next<BoardRecordsFromHost>();
    final fromA = a.received.length, fromB = b.received.length;
    a.send(BoardRecordsFromApp(records: [taskRecord('t1', 'Idea from A')]));
    final seen = await b.next<BoardRecordsFromHost>(where: (m) => m.records.isNotEmpty, from: fromB);
    expect(taskOf(seen.records.single)!.title, 'Idea from A');
    // Not echoed to the sender.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(a.received.skip(fromA).whereType<BoardRecordsFromHost>(), isEmpty);
    // A change made on the host (the board page, /perch, a run) reaches both.
    hostBoard.edit(RecordKinds.task, 't1', {
      'column': {'column': 'done'}
    });
    await a.next<BoardRecordsFromHost>(where: (m) => m.records.any((r) => r.id == 't1'), from: fromA);
    await b.next<BoardRecordsFromHost>(where: (m) => m.records.any((r) => r.groups['column']?.value['column'] == 'done'),
        from: fromB);
  });

  test('a_watch_only_device_may_read_but_not_write_the_board', () async {
    hostBoard.edit(RecordKinds.task, 'seen', {
      'content': {'title': 'Visible', 'projectId': 'p1'}
    });
    final w = await device(permission: DevicePermissions.watch);
    await w.next<BoardSummaryFromHost>();
    w.send(const BoardSummaryFromApp(summary: {}));
    expect((await w.next<BoardRecordsFromHost>()).records.single.id, 'seen');
    w.send(BoardRecordsFromApp(records: [taskRecord('sneaky', 'Not allowed')]));
    expect((await w.next<ErrorMessage>()).code, ErrorCodes.watchOnly);
    expect(hostBoard.board.get(RecordKinds.task, 'sneaky'), isNull);
  });

  test('an_older_app_still_lists_saves_and_runs_this_machines_tasks', () async {
    final old = await device();
    // An older app never sends a summary; it uses the task messages.
    old.send(const ListTasks());
    expect((await old.next<TasksMessage>()).tasks, isEmpty);
    old.send(SaveTask(task: BoardTask(id: 'old-1', title: 'From an old app', cwd: tmp.path, projectId: 'p1')));
    final saved = await old.next<TasksMessage>(where: (m) => m.tasks.isNotEmpty);
    expect(saved.tasks.single.machineId, state.machineId);
    expect(hostBoard.board.get(RecordKinds.task, 'old-1'), isNotNull, reason: 'kept in the board');
    old.send(const RunTask(taskId: 'old-1'));
    final done = await old.next<TasksMessage>(where: (m) => m.tasks.any((t) => t.column == TaskColumn.review));
    expect(done.tasks.single.report!.text, startsWith('echo: From an old app'));
    // An old app's project list and model table still sync (and reach the board).
    old.send(SyncProjects(
        projects: const ProjectList().withProject(const Project(id: 'p9', name: 'Old list'), atMs: DateTime.now().millisecondsSinceEpoch)));
    await waitUntil(() => hostBoard.board.get(RecordKinds.project, 'p9') != null);
    expect(projectOf(hostBoard.board.get(RecordKinds.project, 'p9')!)!.name, 'Old list');
  });

  test('a_task_assigned_to_this_machine_from_the_phone_then_RunTask_runs_it', () async {
    final d = await device();
    d.send(const BoardSummaryFromApp(summary: {}));
    await d.next<BoardRecordsFromHost>();
    final from = d.received.length;
    d.send(BoardRecordsFromApp(records: [taskRecord('assigned', 'Run me', machine: state.machineId, cwd: tmp.path)]));
    await waitUntil(() => board.tasks.any((t) => t.id == 'assigned'));
    d.send(const RunTask(taskId: 'assigned'));
    final review = await d.next<BoardRecordsFromHost>(
        where: (m) => m.records.any((r) => r.id == 'assigned' && r.groups['column']?.value['column'] == 'review'),
        from: from);
    final t = taskOf(review.records.firstWhere((r) => r.id == 'assigned'))!;
    expect(t.report!.text, startsWith('echo: Run me'));
    expect(t.title, 'Run me');
  });
}
