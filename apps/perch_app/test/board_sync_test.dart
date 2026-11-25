// The app's board sync with machines (Task 16): an offline edit reaches the machine when it
// connects; edits from one machine reach another through the phone; the phone makes the
// board key once and gives it to every machine; a rotated key from one machine reaches the
// other; an older host (no board sync) still gets task saves and runs the old way.
import 'package:flutter_test/flutter_test.dart';
import 'package:perch_app/src/connection/account_store.dart';
import 'package:perch_app/src/connection/board_file.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'fakes.dart';

void main() {
  late FakeChannels channels;
  late BoardFile file;
  final conns = <HostConnection>[];
  final hosts = <FakeBoardHost>[];

  setUp(() async {
    channels = FakeChannels();
    file = BoardFile(dir: null, writer: 'phone', keyBox: MemorySecretBox());
    await file.load();
  });
  tearDown(() {
    for (final h in hosts) {
      h.stop();
    }
    hosts.clear();
    for (final c in conns) {
      c.dispose();
    }
    conns.clear();
  });

  /// Connects to machine [id] and returns its fake board host (online, serving).
  Future<(HostConnection, FakeBoardHost)> machine(String id,
      {Welcome hello = boardWelcome, void Function(FakeBoardHost h)? before}) async {
    final c = HostConnection(testMachine(id: id, lan: ['10.0.0.${conns.length + 1}:8787']),
        channelFactory: channels.factory, deviceId: 'phone', boardFile: file);
    conns.add(c);
    final before0 = channels.hosts.length;
    c.connect();
    await eventually(() => channels.hosts.length > before0 && channels.last.frames.isNotEmpty);
    final h = FakeBoardHost(channels.last, writer: 'host-$id');
    hosts.add(h);
    before?.call(h);
    h.start();
    h.side.send(hello);
    // A host with board sync sends its summary with the snapshot.
    if (hello.boardSync) h.side.send(BoardSummaryFromHost(summary: h.board.summary()));
    await eventually(() => c.link.value == LinkState.online);
    return (c, h);
  }

  test('an_offline_edit_reaches_the_machine_when_it_connects', () async {
    file.edit(RecordKinds.project, 'p1', {
      'content': {'name': 'Perch'}
    });
    file.edit(RecordKinds.task, 'idea', {
      'content': {'title': 'Written offline', 'projectId': 'p1'}
    });
    expect(file.unsynced, isTrue);
    final (_, h) = await machine('m1', before: (h) {
      h.board.put(RecordKinds.task, 'on-host', {
        'content': {'title': 'Already there', 'projectId': 'p1'}
      }, h.clock);
    });
    await eventually(() => h.board.get(RecordKinds.task, 'idea') != null);
    expect(taskOf(h.board.get(RecordKinds.task, 'idea')!)!.title, 'Written offline');
    await eventually(() => file.board.get(RecordKinds.task, 'on-host') != null);
    expect(file.unsynced, isFalse);
    // Later edits go at once.
    file.edit(RecordKinds.task, 'idea', {
      'column': {'column': 'ready'}
    });
    await eventually(() => h.board.get(RecordKinds.task, 'idea')!.groups['column']?.value['column'] == 'ready');
  });

  test('edits_from_machine_a_reach_machine_b_through_the_phone', () async {
    final (_, a) = await machine('m1');
    final (_, b) = await machine('m2');
    a.edit(RecordKinds.task, 'from-a', {
      'content': {'title': 'Made on A', 'projectId': 'p1'}
    });
    await eventually(() => b.board.get(RecordKinds.task, 'from-a') != null);
    expect(file.board.get(RecordKinds.task, 'from-a'), isNotNull);
  });

  test('the_phone_creates_the_board_key_once_and_gives_it_to_every_machine', () async {
    final (_, a) = await machine('m1');
    await eventually(() => a.key != null);
    final made = file.boardKey!;
    expect(a.key!.boardId, made.boardId);
    final (_, b) = await machine('m2');
    await eventually(() => b.key != null);
    expect(b.key!.boardId, made.boardId);
    expect(file.boardKey!.boardId, made.boardId, reason: 'made once');
    // A machine that already has a newer key gives it to the phone, and so to the others.
    final newer = newBoardKey();
    final (_, c) = await machine('m3', before: (h) {
      h.key = (
        boardId: newer.boardId,
        key: base64UrlNoPad(newer.key),
        keyVersion: Hlc(DateTime.now().millisecondsSinceEpoch + 60000, 0, 'pc').encode()
      );
    });
    await eventually(() => file.boardKey!.boardId == newer.boardId);
    await eventually(() => a.key!.boardId == newer.boardId && b.key!.boardId == newer.boardId);
    expect(c.key!.boardId, newer.boardId);
  });

  test('a_rotated_key_from_one_machine_reaches_the_other', () async {
    final (_, a) = await machine('m1');
    final (_, b) = await machine('m2');
    await eventually(() => a.key != null && b.key != null);
    final rotated = newBoardKey();
    final v = Hlc(Hlc.parse(file.boardKey!.keyVersion)!.ms + 1000, 0, 'host_m1').encode();
    a.key = (boardId: rotated.boardId, key: base64UrlNoPad(rotated.key), keyVersion: v);
    a.side.send(BoardKeyFromHost(boardId: rotated.boardId, key: base64UrlNoPad(rotated.key), keyVersion: v));
    await eventually(() => b.key!.boardId == rotated.boardId);
    expect(file.boardKey!.boardId, rotated.boardId);
  });

  test('a_watch_only_machine_shares_its_board_but_gets_nothing_written', () async {
    final (_, h) = await machine('m1',
        hello: const Welcome(
            machineName: 'devbox', os: 'windows', hostVersion: '0.4.0', boardSync: true, permission: DevicePermissions.watch),
        before: (h) {
      h.board.put(RecordKinds.task, 'seen', {
        'content': {'title': 'Visible', 'projectId': 'p'}
      }, h.clock);
    });
    await eventually(() => file.board.get(RecordKinds.task, 'seen') != null);
    file.edit(RecordKinds.task, 'mine', {
      'content': {'title': 'x', 'projectId': 'p'}
    });
    await pump(100);
    expect(h.side.messages.whereType<BoardRecordsFromApp>(), isEmpty);
    expect(h.side.messages.whereType<BoardKeyFromApp>(), isEmpty);
    expect(file.unsynced, isTrue, reason: 'a watch-only machine does not take edits');
  });

  test('an_older_host_still_gets_task_saves_and_runs', () async {
    final (c, h) = await machine('m1', hello: welcome);
    h.side.send(const TasksMessage(tasks: [
      BoardTask(id: 'old-1', title: 'On an old host', cwd: r'D:\proj', projectId: 'p1', updatedAtMs: 100),
    ]));
    // Its tasks join the board, assigned to that machine.
    await eventually(() => file.board.get(RecordKinds.task, 'old-1') != null);
    expect(taskOf(file.board.get(RecordKinds.task, 'old-1')!)!.machineId, 'm1');
    await pump(50);
    expect(h.side.messages.whereType<BoardSummaryFromApp>(), isEmpty, reason: 'no board sync with an older host');
    file.edit(RecordKinds.task, 'phone-only', {
      'content': {'title': 'x', 'projectId': 'p1'}
    });
    await pump(50);
    expect(h.side.messages.whereType<BoardRecordsFromApp>(), isEmpty);
    // The old messages still work.
    final saving = c.saveTask(const BoardTask(id: 'old-2', title: 'Saved the old way', cwd: r'D:\proj', projectId: 'p1'));
    await eventually(() => h.side.messages.whereType<SaveTask>().isNotEmpty);
    h.side.send(const TasksMessage(tasks: [
      BoardTask(id: 'old-1', title: 'On an old host', cwd: r'D:\proj', projectId: 'p1', updatedAtMs: 100),
      BoardTask(id: 'old-2', title: 'Saved the old way', cwd: r'D:\proj', projectId: 'p1', updatedAtMs: 200),
    ]));
    await saving;
    final running = c.runTask('old-2');
    await eventually(() => h.side.messages.whereType<RunTask>().isNotEmpty);
    h.side.send(const TasksMessage(tasks: [
      BoardTask(
          id: 'old-2',
          title: 'Saved the old way',
          cwd: r'D:\proj',
          projectId: 'p1',
          column: TaskColumn.inProgress,
          sentAtMs: 5,
          updatedAtMs: 300),
    ]));
    await running;
    // A task gone from the old host leaves the board.
    await eventually(() => file.board.get(RecordKinds.task, 'old-1')!.deleted);
    expect(taskOf(file.board.get(RecordKinds.task, 'old-2')!)!.column, TaskColumn.inProgress);
  });
}
