// The task board in the app, projects first (2026-11-24): the device's own board (every
// project and task, assigned to a machine or to none) that works with every machine
// offline; the phone layout (column chips with counts, one column at a time, press and hold
// for the menu, quick add in a project with no machine), the wide layout of the board page
// (five columns, drag between them), a task in Review (report, to-dos, files, notes back,
// Done), the projects screen, the model table and Model… in the session menu. Machines here
// run an older Perch unless a test says otherwise: their tasks join the board and edits to
// them still go through the task messages.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/account_store.dart';
import 'package:perch_app/src/connection/board_file.dart';
import 'package:perch_app/src/connection/board_store.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/state/session_prefs.dart';
import 'package:perch_app/src/ui/board_logic.dart';
import 'package:perch_app/src/ui/board_screen.dart';
import 'package:perch_app/src/ui/glass/dots.dart';
import 'package:perch_app/src/ui/home_screen.dart' show boardEntryLabel;
import 'package:perch_app/src/ui/glass/settings.dart';
import 'package:perch_app/src/ui/model_table_screen.dart';
import 'package:perch_app/src/ui/projects_screen.dart';
import 'package:perch_app/src/ui/sessions_screen.dart';
import 'package:perch_app/src/ui/task_detail.dart';
import 'package:perch_app/src/web_board.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'fakes.dart';
import 'glass_harness.dart';

BoardTask task(String id, String title,
        {TaskColumn column = TaskColumn.backlog,
        TaskPriority priority = TaskPriority.normal,
        String cwd = r'D:\projects\perch',
        String? type,
        String? sessionId,
        TaskReport? report,
        String? gitRemote,
        String? projectId,
        int created = 1,
        int updated = 1}) =>
    BoardTask(
        id: id,
        title: title,
        description: 'Do $title',
        cwd: cwd,
        projectId: projectId,
        column: column,
        priority: priority,
        taskType: type,
        sessionId: sessionId,
        sessionName: sessionId == null ? null : 'Session $sessionId',
        sentAtMs: sessionId == null ? null : 5,
        report: report,
        gitRemote: gitRemote,
        createdAtMs: created,
        updatedAtMs: updated);

/// A board store backed by a fresh in-memory board.
Future<BoardStore> boardStore() async {
  final file = BoardFile(dir: null, writer: 'phone', keyBox: MemorySecretBox());
  await file.load();
  return BoardStore(persist: false)..attach(file);
}

void main() {
  late FakeChannels channels;
  late BoardStore store;
  final conns = <HostConnection>[];

  setUp(() async {
    channels = FakeChannels();
    store = await boardStore();
  });
  tearDown(() {
    for (final c in conns) {
      c.dispose();
    }
    conns.clear();
  });

  Future<(HostConnection, FakeHostSide)> online(WidgetTester tester, List<BoardTask> tasks,
      {String id = 'm1', List<SessionSummary> sessions = const [], ModelTable? models}) async {
    final c = HostConnection(testMachine(id: id, label: id, lan: ['10.0.0.${conns.length + 1}:8787']),
        channelFactory: channels.factory, modelSource: store, boardFile: store.file)
      ..actionTimeout = const Duration(seconds: 5);
    conns.add(c);
    c.connect();
    final host = channels.last;
    host.send(welcome);
    host.send(Sessions(sessions: sessions));
    host.send(TasksMessage(tasks: tasks));
    host.send(ModelTableMessage(table: models ?? ModelTable.starting));
    host.send(ProjectsMessage(projects: store.projects));
    await tester.runAsync(() => eventually(() => c.link.value == LinkState.online && c.tasks.value != null));
    return (c, host);
  }

  Future<T> sentBy<T extends ClientMessage>(WidgetTester tester, FakeHostSide h, {bool Function(T m)? where}) async {
    await tester.runAsync(() => eventually(() => h.messages.whereType<T>().any((m) => where == null || where(m))));
    return h.messages.whereType<T>().lastWhere((m) => where == null || where(m));
  }

  /// The host answers with its tasks now.
  Future<void> answer(WidgetTester tester, FakeHostSide h, List<BoardTask> tasks) async {
    h.send(TasksMessage(tasks: tasks));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
  }

  BoardTask? onBoard(String id) {
    final r = store.file!.board.get(RecordKinds.task, id);
    return r == null || r.deleted ? null : taskOf(r);
  }

  group('connection', () {
    test('a save completes when the machine has the task; a refusal says why', () async {
      // Outside the widget test's fake clock: the host's answers arrive while the app waits.
      final c = HostConnection(testMachine(), channelFactory: channels.factory)..actionTimeout = const Duration(seconds: 5);
      conns.add(c);
      c.connect();
      final host = channels.last;
      host.send(welcome);
      host.send(const TasksMessage(tasks: []));
      await eventually(() => c.link.value == LinkState.online && c.tasks.value != null);
      final t = task('t1', 'Add footer');
      await Future.sync(() async {
        final f = c.saveTask(t);
        await eventually(() => host.messages.whereType<SaveTask>().isNotEmpty);
        host.send(TasksMessage(tasks: [t.copyWith(updatedAtMs: 9)]));
        await f;
        final g = c.deleteTask('t1');
        await eventually(() => host.messages.whereType<DeleteTask>().isNotEmpty);
        host.send(const ErrorMessage(code: ErrorCodes.badRequest, message: 'This task no longer exists.'));
        await expectLater(g, throwsA(isA<SessionActionFailed>().having((e) => e.message, 'm', contains('no longer'))));
        final h = c.runTask('t1');
        await eventually(() => host.messages.whereType<RunTask>().isNotEmpty);
        host.send(const ErrorMessage(code: ErrorCodes.badRequest, message: unknownMessageText));
        await expectLater(h, throwsA(isA<SessionActionFailed>().having((e) => e.message, 'm', olderHostTasksMessage)));
      });
    });

    testWidgets('the newer model table wins on either side', (tester) async {
      // The phone's is newer: an older machine is given it.
      await store.setTable(ModelTable.starting.withRow(ModelTable.starting.row('chores')!.copyWith(model: 'haiku'), atMs: 50));
      final (_, host) = await online(tester, const []);
      final synced = await sentBy<SyncModelTable>(tester, host);
      expect(synced.table.modelFor('chores'), 'haiku');
      // Another machine has a newer one: the phone takes it.
      final later = DateTime.now().millisecondsSinceEpoch + 60000;
      final newer = ModelTable.starting.withRow(ModelTable.starting.row('review')!.copyWith(model: 'opus'), atMs: later);
      await online(tester, const [], id: 'm2', models: newer);
      expect(store.table.updatedAtMs, later);
      expect(store.table.modelFor('review'), 'opus');
    });

    test('the board page learns its machine from the host', () {
      final m = localMachineFromPairing(
          {'machineId': 'mid', 'name': 'Desk', 'secret': base64UrlNoPad(testSecret), 'port': 8790}, Uri.parse('http://localhost:8790/'));
      expect(m.id, 'mid');
      expect(m.label, 'Desk');
      expect(m.lan, ['localhost:8790']);
      expect(m.needsPairing, isFalse);
      expect(() => localMachineFromPairing({'name': 'x'}, Uri.parse('http://localhost:1/')), throwsFormatException);
    });
  });

  group('projects first, offline', () {
    Future<void> show(WidgetTester tester, List<HostConnection> c) async {
      tallPhone(tester, height: 2400);
      await tester.pumpWidget(glassApp(BoardView(connections: c, store: store)));
      await tester.pumpAndSettle();
    }

    testWidgets('with_every_machine_offline_the_board_shows_and_a_task_can_be_added', (tester) async {
      await store.setProjects(const ProjectList().withProject(const Project(id: 'p1', name: 'Perch'), atMs: 1));
      store.file!.edit(RecordKinds.task, 'old', {
        'content': taskContent(task('old', 'Written yesterday', projectId: 'p1', cwd: '')),
        'column': {'column': 'backlog'}
      });
      store.file!.markSynced();
      // One machine, offline (never reached).
      final c = HostConnection(testMachine(id: 'm1', label: 'Desk'), channelFactory: channels.factory, boardFile: store.file);
      conns.add(c);
      expect(c.link.value, LinkState.offline);
      await show(tester, [c]);
      expect(find.text('Written yesterday'), findsOneWidget);
      expect(find.byKey(const ValueKey('board-offline-note')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('board-add')));
      await tester.pumpAndSettle();
      expect(find.text('MACHINE'), findsNothing, reason: 'no machine is chosen for a new task');
      await tester.enterText(field('Title'), 'An idea on the train');
      await tester.tap(button('Add').last);
      await tester.pumpAndSettle();
      expect(find.text('An idea on the train'), findsOneWidget);
      final t = store.file!.board.liveTasks.firstWhere((t) => t.title == 'An idea on the train');
      expect(t.projectId, 'p1');
      expect(t.machineId, isNull);
      expect(t.column, TaskColumn.backlog);
      expect(find.text(savedOnPhoneNote), findsOneWidget);
    });

    testWidgets('new_project_and_new_task_need_no_machine', (tester) async {
      await show(tester, const []);
      // No project yet: New task starts with the project.
      await tester.tap(find.byKey(const ValueKey('board-add')));
      await tester.pumpAndSettle();
      expect(find.text('New project'), findsWidgets);
      await tester.enterText(field('Name'), 'Garden app');
      await tester.enterText(field('Description (optional)'), 'An idea for the allotment');
      await tester.ensureVisible(find.byKey(const ValueKey('project-save')));
      await tester.tap(find.byKey(const ValueKey('project-save')));
      await tester.pumpAndSettle();
      final p = store.projects.projects.single;
      expect(p.name, 'Garden app');
      expect(p.description, 'An idea for the allotment');
      expect(p.folders, isEmpty);
      // Then the task, in that project.
      expect(tester.widget<GlassChip>(find.byKey(ValueKey('task-project-${p.id}'))).selected, isTrue);
      await tester.enterText(field('Title'), 'Plan the beds');
      await tester.tap(button('Add').last);
      await tester.pumpAndSettle();
      expect(onBoard(store.file!.board.liveTasks.single.id)!.projectId, p.id);
      expect(store.lastProject, p.id);
      // A second project from the picker row.
      await tester.ensureVisible(find.byKey(const ValueKey('project-new')));
      await tester.tap(find.byKey(const ValueKey('project-new')));
      await tester.pumpAndSettle();
      await tester.enterText(field('Name'), 'Second');
      await tester.ensureVisible(find.byKey(const ValueKey('project-save')));
      await tester.tap(find.byKey(const ValueKey('project-save')));
      await tester.pumpAndSettle();
      expect(store.projects.projects.map((p) => p.name).toSet(), {'Garden app', 'Second'});
      expect(store.projectFilter, store.projects.projects.firstWhere((p) => p.name == 'Second').id);
    });

    testWidgets('cards_say_not_assigned_or_the_machine', (tester) async {
      final (c, _) = await online(tester, [task('on-m1', 'On the desk', projectId: 'p1')]);
      store.file!.edit(RecordKinds.task, 'idea', {
        'content': taskContent(task('idea', 'Just an idea', projectId: 'p1', cwd: '')),
      });
      await show(tester, [c]);
      expect(tester.widget<Text>(find.byKey(const ValueKey('card-machine-idea'))).data, notAssignedLabel);
      expect(tester.widget<Text>(find.byKey(const ValueKey('card-machine-on-m1'))).data, 'devbox');
    });

    testWidgets('the_offline_note_shows_until_something_synced', (tester) async {
      store.file!.edit(RecordKinds.task, 'idea', {
        'content': taskContent(task('idea', 'Just an idea', projectId: 'p1', cwd: '')),
      });
      await show(tester, const []);
      expect(find.text(savedOnPhoneNote), findsOneWidget);
      store.file!.markSynced();
      await tester.pumpAndSettle();
      expect(find.text(savedOnPhoneNote), findsNothing);
    });

    testWidgets('a_machine_with_board_sync_gets_a_new_task_as_a_record', (tester) async {
      await store.setProjects(const ProjectList().withProject(const Project(id: 'p1', name: 'Perch'), atMs: 1));
      final c = HostConnection(testMachine(id: 'm1', label: 'Desk'), channelFactory: channels.factory, boardFile: store.file);
      conns.add(c);
      c.connect();
      final host = channels.last;
      host.send(boardWelcome);
      host.send(const BoardSummaryFromHost(summary: {}));
      await tester.runAsync(() => eventually(() => c.link.value == LinkState.online));
      await show(tester, [c]);
      await tester.tap(find.byKey(const ValueKey('board-add')));
      await tester.pumpAndSettle();
      await tester.enterText(field('Title'), 'Synced idea');
      await tester.tap(button('Add').last);
      await tester.pumpAndSettle();
      final sent = await sentBy<BoardRecordsFromApp>(tester, host, where: (m) => m.records.any((r) => taskOf(r)?.title == 'Synced idea'));
      expect(taskOf(sent.records.firstWhere((r) => r.kind == RecordKinds.task))!.machineId, isNull);
      expect(host.messages.whereType<SaveTask>(), isEmpty);
      expect(find.text(savedOnPhoneNote), findsNothing, reason: 'a machine has it');
    });
  });

  group('phone layout', () {
    Future<void> show(WidgetTester tester, List<HostConnection> c) async {
      tallPhone(tester, height: 2400);
      await tester.pumpWidget(glassApp(BoardView(connections: c, store: store)));
      await tester.pumpAndSettle();
    }

    testWidgets('chips count each column; one column at a time; swipe to the next', (tester) async {
      final (c, _) = await online(tester, [
        task('a', 'Write the tests', priority: TaskPriority.high, type: 'tests'),
        task('b', 'Tidy imports', type: 'chores', created: 2),
        task('c', 'Ship it', column: TaskColumn.ready),
      ]);
      await show(tester, [c]);
      expect(find.byKey(const ValueKey('chip-backlog')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-models')), findsNothing, reason: 'Models moved to the menu on the first screen');
      expect(tester.widget<ColumnChip>(find.byKey(const ValueKey('chip-backlog'))).count, 2);
      expect(tester.widget<ColumnChip>(find.byKey(const ValueKey('chip-ready'))).count, 1);
      expect(find.text('Write the tests'), findsOneWidget);
      expect(find.text('Ship it'), findsNothing);
      // High first; the type and priority show.
      expect(tester.getTopLeft(find.text('Write the tests')).dy, lessThan(tester.getTopLeft(find.text('Tidy imports')).dy));
      expect(find.text('Tests and documentation'), findsOneWidget);
      expect(find.text('High'), findsOneWidget);
      await tester.drag(find.byKey(const ValueKey('board-pages')), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(find.text('Ship it'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chip-backlog')));
      await tester.pumpAndSettle();
      expect(find.text('Tidy imports'), findsOneWidget);
    });

    testWidgets('an in-progress card shows the working wave and the last activity', (tester) async {
      final (c, _) = await online(tester, [
        task('a', 'Busy one', column: TaskColumn.inProgress, sessionId: 's1').copyWith(
            activity: 'Edit notes.txt', activityAtMs: DateTime.now().millisecondsSinceEpoch),
      ], sessions: [summary('s1', state: SessionState.working)]);
      await show(tester, [c]);
      await tester.tap(find.byKey(const ValueKey('chip-inProgress')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Edit notes.txt · just now'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('card-a')), matching: find.byType(WorkingWave)), findsOneWidget);
    });

    testWidgets('press and hold opens the menu; Move to a column moves it', (tester) async {
      final (c, host) = await online(tester, [task('a', 'Move me')]);
      await show(tester, [c]);
      await tester.longPress(find.text('Move me'));
      await tester.pumpAndSettle();
      for (final l in ['Open', 'Run on…', 'Move to a column…', 'Edit…', 'Share', 'Duplicate', 'Delete…']) {
        expect(find.text(l), findsOneWidget, reason: l);
      }
      expect(find.text('Copy to…'), findsNothing, reason: 'Run on… replaces Copy to… and Move to…');
      await tester.tap(find.text('Move to a column…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ready').last);
      await tester.pump();
      final m = await sentBy<MoveTask>(tester, host);
      expect(m.column, TaskColumn.ready);
      await answer(tester, host, [task('a', 'Move me', column: TaskColumn.ready)]);
    });

    testWidgets('quick add puts the task in the project used last, with no machine', (tester) async {
      final (c, host) = await online(tester, const []);
      await store.setProjects(const ProjectList()
          .withProject(const Project(id: 'p-site', name: 'Site', folders: {'m1': r'D:\projects\site'}), atMs: 2)
          .withProject(const Project(id: 'p-api', name: 'Api', folders: {'m1': r'D:\projects\api'}), atMs: 2));
      await store.rememberProject('p-site');
      await show(tester, [c]);
      await tester.tap(find.byKey(const ValueKey('board-add')));
      await tester.pumpAndSettle();
      expect(tester.widget<GlassChip>(find.byKey(const ValueKey('task-project-p-site'))).selected, isTrue);
      await tester.tap(find.byKey(const ValueKey('task-project-p-api')));
      await tester.pumpAndSettle();
      await tester.enterText(field('Title'), 'Fix the footer');
      await tester.enterText(field('One line (optional)'), 'It overlaps on small screens');
      await tester.tap(button('Add').last);
      await tester.pumpAndSettle();
      expect(find.text('New task'), findsNothing, reason: 'the sheet closed');
      final t = store.file!.board.liveTasks.single;
      expect(t.title, 'Fix the footer');
      expect(t.description, 'It overlaps on small screens');
      expect(t.projectId, 'p-api');
      expect(t.machineId, isNull);
      expect(t.cwd, '');
      expect(host.messages.whereType<SaveTask>(), isEmpty, reason: 'not on a machine until Run on…');
      expect(find.text('Fix the footer'), findsOneWidget);
      expect(store.lastProject, 'p-api');
      expect(tester.widget<Text>(find.byKey(ValueKey('card-project-${t.id}'))).data, 'Api', reason: 'the card shows its project');
    });

    testWidgets('the full editor writes acceptance criteria', (tester) async {
      await store.setProjects(
          const ProjectList().withProject(const Project(id: 'p', name: 'Perch', folders: {'m1': r'D:\projects\perch'}), atMs: 2));
      await show(tester, const []);
      await tester.tap(find.byKey(const ValueKey('board-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('task-more')));
      await tester.pumpAndSettle();
      await tester.enterText(field('Title'), 'Add a footer');
      for (final (i, text) in ['It shows the version', 'Tests pass', 'drop me'].indexed) {
        await tester.ensureVisible(find.byKey(const ValueKey('criterion-add')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('criterion-add')));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.descendant(of: find.byKey(ValueKey('criterion-$i')), matching: find.byType(TextField)), text);
      }
      await tester.tap(find.byKey(const ValueKey('criterion-remove-2')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(button('Add').last);
      await tester.pumpAndSettle();
      await tester.tap(button('Add').last);
      await tester.pumpAndSettle();
      expect(store.file!.board.liveTasks.single.acceptance, ['It shows the version', 'Tests pass']);
    });

    testWidgets('older tasks are grouped into projects by folder and git remote; the picker filters', (tester) async {
      final (win, _) = await online(tester, [
        task('a', 'On Windows', cwd: r'D:\projects\perch', gitRemote: 'git@github.com:o/perch.git'),
        task('b', 'Also there', cwd: r'D:\projects\perch', gitRemote: 'git@github.com:o/perch.git'),
        task('c', 'Notes task', cwd: r'D:\notes'),
      ]);
      final (mac, _) = await online(tester, [task('d', 'On the Mac', cwd: '/Users/o/perch', gitRemote: 'https://github.com/o/perch')],
          id: 'm2');
      await show(tester, [win, mac]);
      await tester.pumpAndSettle();
      final ps = store.projects.projects;
      expect(ps.map((p) => p.name).toSet(), {'perch', 'notes'});
      final perch = ps.firstWhere((p) => p.name == 'perch');
      expect(perch.folders, {'m1': r'D:\projects\perch', 'm2': '/Users/o/perch'}, reason: 'one project on both machines');
      expect(perch.auto, isTrue);
      expect(find.byKey(ValueKey('project-${perch.id}')), findsOneWidget);
      expect(find.text('On Windows'), findsOneWidget);
      expect(find.text('Notes task'), findsOneWidget);
      await tester.ensureVisible(find.byKey(ValueKey('project-${perch.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('project-${perch.id}')));
      await tester.pumpAndSettle();
      expect(store.projectFilter, perch.id);
      expect(find.text('On Windows'), findsOneWidget);
      expect(find.text('On the Mac'), findsOneWidget);
      expect(find.text('Notes task'), findsNothing);
      expect(find.byKey(const ValueKey('card-machine-d')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('project-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project-all')));
      await tester.pumpAndSettle();
      expect(find.text('Notes task'), findsOneWidget);
    });

    testWidgets('the chip row follows the column shown (swipe and tap)', (tester) async {
      final (c, _) = await online(tester, [task('d', 'Shipped', column: TaskColumn.done)]);
      await show(tester, [c]);
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      bool whole(String col) {
        final r = tester.getRect(find.byKey(ValueKey('chip-$col')));
        return r.left >= 0 && r.right <= width;
      }

      expect(whole('done'), isFalse, reason: 'Done starts off screen on a phone');
      for (var i = 0; i < 4; i++) {
        await tester.drag(find.byKey(const ValueKey('board-pages')), const Offset(-300, 0));
        await tester.pumpAndSettle();
      }
      expect(find.text('Shipped'), findsOneWidget);
      expect(whole('done'), isTrue, reason: 'swiping to Done brought its chip into view');
      for (var i = 0; i < 4; i++) {
        await tester.drag(find.byKey(const ValueKey('board-pages')), const Offset(300, 0));
        await tester.pumpAndSettle();
      }
      expect(whole('backlog'), isTrue, reason: 'and back again');
      // A tap on a chip half off screen brings it into view too.
      await tester.drag(find.byKey(const ValueKey('chip-row')), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(whole('backlog'), isFalse);
      await tester.tap(find.byKey(const ValueKey('chip-review')));
      await tester.pumpAndSettle();
      expect(whole('review'), isTrue);
    });

    testWidgets('watch-only on every machine: the board can be read, not changed', (tester) async {
      final c = HostConnection(testMachine(id: 'm1', label: 'Desk'), channelFactory: channels.factory, boardFile: store.file);
      conns.add(c);
      c.connect();
      channels.last.send(const Welcome(
          machineName: 'devbox', os: 'windows', hostVersion: '0.4.0', boardSync: true, permission: DevicePermissions.watch));
      await tester.runAsync(() => eventually(() => c.link.value == LinkState.online));
      await show(tester, [c]);
      await tester.tap(find.byKey(const ValueKey('board-add')));
      await tester.pumpAndSettle();
      expect(find.text('New task'), findsNothing);
      expect(find.text(watchOnlyMessage), findsOneWidget);
    });
  });

  group('run on', () {
    Future<void> show(WidgetTester tester, List<HostConnection> c) async {
      tallPhone(tester, height: 2400);
      await tester.pumpWidget(glassApp(BoardView(connections: c, store: store)));
      await tester.pumpAndSettle();
    }

    /// A machine with board sync, online; its fake host answers nothing by itself.
    Future<(HostConnection, FakeHostSide)> syncing(WidgetTester tester, {String id = 'm1', List<SessionSummary> sessions = const []}) async {
      final c = HostConnection(testMachine(id: id, label: id, lan: ['10.0.0.${conns.length + 1}:8787']),
          channelFactory: channels.factory, boardFile: store.file)
        ..actionTimeout = const Duration(seconds: 5);
      conns.add(c);
      c.connect();
      final host = channels.last;
      host.send(boardWelcome);
      host.send(Sessions(sessions: sessions));
      host.send(const TasksMessage(tasks: []));
      host.send(const BoardSummaryFromHost(summary: {}));
      await tester.runAsync(() => eventually(() => c.link.value == LinkState.online && c.tasks.value != null));
      return (c, host);
    }

    void idea(String id, String title, {String project = 'p1'}) => store.file!.edit(RecordKinds.task, id, {
          'content': taskContent(task(id, title, projectId: project, cwd: '')),
          'column': {'column': 'ready'}
        });

    Future<void> runOnFromMenu(WidgetTester tester, String title) async {
      await tester.tap(find.byKey(const ValueKey('chip-ready')));
      await tester.pumpAndSettle();
      await tester.longPress(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run on…'));
      await tester.pumpAndSettle();
    }

    testWidgets('run_on_assigns_then_runs_on_that_machine', (tester) async {
      await store.setProjects(
          const ProjectList().withProject(const Project(id: 'p1', name: 'Perch', folders: {'m1': r'D:\projects\perch'}), atMs: 1));
      idea('t1', 'Run me');
      final (c, host) = await syncing(tester, sessions: [summary('s9', name: 'Old chat')]);
      await show(tester, [c]);
      await runOnFromMenu(tester, 'Run me');
      expect(find.text('Run on'), findsOneWidget, reason: 'the sheet title');
      await tester.tap(find.byKey(const ValueKey('run-on-m1')));
      await tester.pumpAndSettle();
      expect(find.text('Old chat'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('run-new')));
      await tester.pump();
      // The assignment reaches the machine as a record first...
      final sent = await sentBy<BoardRecordsFromApp>(tester, host,
          where: (m) => m.records.any((r) => r.id == 't1' && r.groups['content']?.value['machineId'] == 'm1'));
      expect(taskOf(sent.records.firstWhere((r) => r.id == 't1'))!.cwd, r'D:\projects\perch');
      expect(host.messages.whereType<RunTask>(), isEmpty, reason: 'not before the machine has it');
      // ...the machine has it (its task list says so), then it runs.
      final assigned = onBoard('t1')!;
      host.send(TasksMessage(tasks: [assigned]));
      final r = await sentBy<RunTask>(tester, host);
      expect(r.taskId, 't1');
      expect(r.sessionId, isNull);
      await answer(tester, host, [assigned.copyWith(column: TaskColumn.inProgress, sentAtMs: 9)]);
      expect(onBoard('t1')!.machineId, 'm1');
    });

    testWidgets('a_project_without_a_folder_there_asks_for_one_and_saves_it', (tester) async {
      await store.setProjects(const ProjectList()
          .withProject(const Project(id: 'p1', name: 'Perch', gitRemote: 'https://github.com/o/perch'), atMs: 1));
      idea('t1', 'Port it');
      final (c, host) = await syncing(tester);
      await show(tester, [c]);
      await runOnFromMenu(tester, 'Port it');
      await tester.tap(find.byKey(const ValueKey('run-on-m1')));
      await tester.pump();
      await sentBy<ListGitRemotes>(tester, host);
      host.send(const GitRemotesMessage(folders: [GitFolder(path: '/Users/me/perch', remote: 'git@github.com:o/perch.git')]));
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      expect(find.text('/Users/me/perch'), findsOneWidget);
      await tester.tap(button('Use this folder').last);
      await tester.pumpAndSettle();
      expect(store.projects.byId('p1')!.folderOn('m1'), '/Users/me/perch', reason: 'saved into the project');
      expect(find.byKey(const ValueKey('run-new')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('run-new')));
      await tester.pump();
      await sentBy<BoardRecordsFromApp>(tester, host, where: (m) => m.records.any((r) => r.id == 't1' && r.groups['content']?.value['cwd'] == '/Users/me/perch'));
      host.send(TasksMessage(tasks: [onBoard('t1')!]));
      await sentBy<RunTask>(tester, host);
      await answer(tester, host, [onBoard('t1')!.copyWith(column: TaskColumn.inProgress, sentAtMs: 9)]);
    });

    testWidgets('an_offline_machine_keeps_the_assignment_and_says_so', (tester) async {
      await store.setProjects(
          const ProjectList().withProject(const Project(id: 'p1', name: 'Perch', folders: {'m1': r'D:\projects\perch'}), atMs: 1));
      idea('t1', 'Later');
      final c = HostConnection(testMachine(id: 'm1', label: 'Desk'), channelFactory: channels.factory, boardFile: store.file);
      conns.add(c);
      await show(tester, [c]);
      await runOnFromMenu(tester, 'Later');
      await tester.tap(find.byKey(const ValueKey('run-on-m1')));
      await tester.pumpAndSettle();
      expect(find.text('Desk is offline: run it when it is back'), findsOneWidget);
      expect(onBoard('t1')!.machineId, 'm1');
      expect(onBoard('t1')!.cwd, r'D:\projects\perch');
      expect(tester.widget<Text>(find.byKey(const ValueKey('card-machine-t1'))).data, 'Desk');
    });

    testWidgets('duplicate_makes_an_unassigned_copy', (tester) async {
      final (c, _) = await online(tester, [
        task('a', 'Copy me', column: TaskColumn.review, sessionId: 's1', projectId: 'p1', report: const TaskReport(text: 'r', atMs: 1))
            .copyWith(acceptance: ['It works'], taskType: 'feature')
      ]);
      await show(tester, [c]);
      await tester.ensureVisible(find.byKey(const ValueKey('chip-review')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chip-review')));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Copy me'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();
      final copy = store.file!.board.liveTasks.firstWhere((t) => t.id != 'a');
      expect(copy.title, 'Copy me');
      expect(copy.machineId, isNull);
      expect(copy.cwd, '');
      expect(copy.sessionId, isNull);
      expect(copy.report, isNull);
      expect(copy.column, TaskColumn.ready);
      expect(copy.acceptance, ['It works']);
      expect(copy.taskType, 'feature');
      expect(copy.projectId, 'p1');
    });
  });

  group('wide layout (the board page)', () {
    testWidgets('a column label and its count keep clear of the rounded frame', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (c, _) = await online(tester, [task('a', 'Drag me')]);
      await tester.pumpWidget(glassApp(BoardView(connections: [c], store: store, root: true)));
      await tester.pumpAndSettle();
      final frame = tester.getRect(find.byKey(const ValueKey('drop-backlog')));
      final label = tester.getRect(find.text('BACKLOG'));
      final count = tester.getRect(find.descendant(of: find.byKey(const ValueKey('drop-backlog')), matching: find.byType(DotMatrix)).first);
      expect(label.left - frame.left, greaterThanOrEqualTo(20));
      expect(label.top - frame.top, greaterThanOrEqualTo(16));
      expect(frame.right - count.right, greaterThanOrEqualTo(20));
    });

    testWidgets('five columns side by side; dragging a card moves it', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (c, host) = await online(tester, [
        task('a', 'Drag me'),
        task('b', 'Waiting', column: TaskColumn.review, report: const TaskReport(text: 'ok', atMs: 1)),
      ]);
      await tester.pumpWidget(glassApp(BoardView(connections: [c], store: store, root: true)));
      await tester.pumpAndSettle();
      for (final col in TaskColumn.values) {
        expect(find.byKey(ValueKey('drop-${col.name}')), findsOneWidget);
        expect(find.text(columnLabel(col).toUpperCase()), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('board-add-wide')), findsOneWidget);
      expect(find.text('Drag me'), findsOneWidget);
      expect(find.text('Waiting'), findsOneWidget);
      final from = tester.getCenter(find.text('Drag me'));
      final to = tester.getCenter(find.byKey(const ValueKey('drop-done')));
      final g = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 50));
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(Offset.lerp(from, to, i / 10)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump();
      final m = await sentBy<MoveTask>(tester, host);
      expect(m.taskId, 'a');
      expect(m.column, TaskColumn.done);
      await answer(tester, host, [task('a', 'Drag me', column: TaskColumn.done)]);
    });
  });

  group('a task in review', () {
    final report = TaskReport(
      text: '## Report\n- Created notes.txt\n- Tested by reading it',
      todos: const [TodoItem('Create notes.txt', done: true), TodoItem('Check it')],
      files: const [r'D:\p\notes.txt'],
      changes: const [' new file: notes.txt'],
      atMs: 1,
    );

    testWidgets('shows the report, to-dos with ticks, files and changes; notes back and Done', (tester) async {
      final t = task('a', 'Make notes', column: TaskColumn.review, sessionId: 's1', report: report);
      final (c, host) = await online(tester, [t], sessions: [summary('s1', name: 'Make notes')]);
      tallPhone(tester);
      await tester.pumpWidget(glassApp(TaskDetailScreen(taskId: 'a', all: [c], store: store)));
      await tester.pumpAndSettle();
      expect(find.text('Make notes'), findsWidgets);
      expect(find.textContaining('Created notes.txt'), findsWidgets);
      expect(find.text('Create notes.txt'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('todo-0')), matching: find.byIcon(Icons.check_box_rounded)), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('todo-1')), matching: find.byIcon(Icons.check_box_outline_blank_rounded)),
          findsOneWidget);
      expect(find.text(r'D:\p\notes.txt'), findsOneWidget);
      expect(find.text(' new file: notes.txt'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('detail-notes')));
      await tester.pumpAndSettle();
      await tester.enterText(field('Notes'), 'Add a second line');
      await tester.tap(button('Send').last);
      await tester.pump();
      final n = await sentBy<TaskNotes>(tester, host);
      expect(n.notes, 'Add a second line');
      await answer(tester, host, [t.copyWith(column: TaskColumn.inProgress, sentAtMs: 99, clearReport: true, updatedAtMs: 2)]);
      expect(find.byKey(const ValueKey('detail-done')), findsNothing);

      await answer(tester, host, [t.copyWith(sentAtMs: 99, updatedAtMs: 3)]);
      await tester.tap(find.byKey(const ValueKey('detail-done')));
      await tester.pump();
      final d = await sentBy<MoveTask>(tester, host);
      expect(d.column, TaskColumn.done);
      await answer(tester, host, [t.copyWith(column: TaskColumn.done, updatedAtMs: 4)]);
    });

    testWidgets('sections in order: Description, Acceptance criteria (ticked), Completion report', (tester) async {
      final t = task('a', 'Add a footer', column: TaskColumn.review, sessionId: 's1').copyWith(
          projectId: 'p',
          acceptance: ['It shows the version', 'Tests pass', 'Docs updated'],
          report: const TaskReport(text: '## Report\n- [x] It shows the version\n- [ ] Tests pass', atMs: 9, criteria: [
            CriterionCheck('It shows the version', met: true),
            CriterionCheck('Tests pass', met: false),
            CriterionCheck('Docs updated'),
          ]));
      await store.setProjects(const ProjectList().withProject(const Project(id: 'p', name: 'Perch'), atMs: 1));
      final (c, _) = await online(tester, [t], sessions: [summary('s1', name: 'Add a footer')]);
      tallPhone(tester);
      await tester.pumpWidget(glassApp(TaskDetailScreen(taskId: 'a', all: [c], store: store)));
      await tester.pumpAndSettle();
      double y(String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy;
      expect(y('detail-description'), lessThan(y('detail-criteria')));
      expect(y('detail-criteria'), lessThan(y('detail-completion')));
      expect(find.text('Perch'), findsOneWidget, reason: 'the project, as information');
      expect(find.byKey(const ValueKey('criterion-0-met')), findsOneWidget);
      expect(find.byKey(const ValueKey('criterion-1-not met')), findsOneWidget);
      expect(find.byKey(const ValueKey('criterion-2-not reported')), findsOneWidget);
      expect(find.text('1/3 met'), findsOneWidget);
    });

    testWidgets('an unassigned task says so and offers Run on…', (tester) async {
      store.file!.edit(RecordKinds.task, 'idea', {
        'content': taskContent(task('idea', 'Just an idea', projectId: 'p1', cwd: '')),
      });
      tallPhone(tester);
      await tester.pumpWidget(glassApp(TaskDetailScreen(taskId: 'idea', all: const [], store: store)));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(const ValueKey('detail-machine')), matching: find.text(notAssignedLabel)), findsOneWidget);
      expect(find.text('Run on…'), findsOneWidget);
      expect(find.text('Folder'), findsNothing);
    });

    testWidgets('Delete is confirmed by press and hold and says it goes to the bin', (tester) async {
      final (c, host) = await online(tester, [task('a', 'Doomed task')]);
      tallPhone(tester, height: 2400);
      await tester.pumpWidget(glassApp(BoardView(connections: [c], store: store)));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Doomed task'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();
      expect(find.textContaining('go to the bin'), findsOneWidget);
      await tester.tap(find.widgetWithText(HoldButton, 'Delete task'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => pump(50));
      expect(host.messages.whereType<DeleteTask>(), isEmpty, reason: 'a tap is not enough');
      await holdToConfirm(tester, 'Delete task');
      final d = await sentBy<DeleteTask>(tester, host);
      expect(d.taskId, 'a');
      await answer(tester, host, const []);
    });
  });

  group('projects screen', () {
    testWidgets('a project finds its folder on another machine by git remote; Save keeps it', (tester) async {
      final (win, _) = await online(tester, const []);
      final (mac, macHost) = await online(tester, const [], id: 'm2');
      await store.setProjects(const ProjectList().withProject(
          const Project(id: 'p', name: 'Perch', gitRemote: 'git@github.com:o/perch.git', folders: {'m1': r'D:\projects\perch'}),
          atMs: 1));
      store.onProjectsChanged = () {
        win.syncProjects();
        mac.syncProjects();
      };
      tallPhone(tester, height: 2400);
      await tester.pumpWidget(glassApp(ProjectsView(connections: [win, mac], store: store)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('project-row-p')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('project-row-p')), matching: find.byType(ValuePill)), findsOneWidget,
          reason: 'an editable row shows its verb pill');
      await tester.tap(find.byKey(const ValueKey('project-row-p')));
      await tester.pumpAndSettle();
      await sentBy<ListGitRemotes>(tester, macHost);
      macHost.send(const GitRemotesMessage(folders: [GitFolder(path: '/Users/o/perch', remote: 'https://github.com/o/perch')]));
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      expect(find.text('/Users/o/perch'), findsOneWidget);
      expect(find.text('Found by its git remote'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('project-save')));
      await tester.tap(find.byKey(const ValueKey('project-save')));
      await tester.pumpAndSettle();
      expect(store.projects.byId('p')!.folderOn('m2'), '/Users/o/perch');
      expect(store.projects.byId('p')!.folderOn('m1'), r'D:\projects\perch');
      final sync = await sentBy<SyncProjects>(tester, macHost, where: (m) => m.projects.byId('p')?.folderOn('m2') != null);
      expect(sync.projects.byId('p')!.name, 'Perch');
    });
  });

  group('models', () {
    testWidgets('the table starts on the default with hints; a change reaches every machine', (tester) async {
      final (c, host) = await online(tester, const []);
      final sync = c.syncModelTable;
      store.onTableChanged = sync;
      tallPhone(tester);
      await tester.pumpWidget(glassApp(ModelTableScreen(store: store)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('models-hint')), findsOneWidget);
      expect(find.text('Default'), findsNWidgets(7));
      expect(find.text('Your default'), findsNothing);
      // The value sits in a rounded rectangle on one line, not a two-line oval.
      final pill = find.byKey(const ValueKey('model-of-chores'));
      final box = tester.widget<Container>(find.descendant(of: pill, matching: find.byType(Container)).first);
      expect((box.decoration! as BoxDecoration).borderRadius, BorderRadius.circular(10));
      final label = find.descendant(of: pill, matching: find.text('Default'));
      expect(tester.getSize(label).height, lessThan(20), reason: 'one line');
      expect(tester.getSize(pill).width, lessThan(tester.getSize(find.byKey(const ValueKey('model-row-chores'))).width / 3));
      expect(find.text('Strongest model'), findsNWidgets(3));
      await tester.tap(find.byKey(const ValueKey('model-row-chores')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('haiku'));
      await tester.pumpAndSettle();
      expect(store.table.modelFor('chores'), 'haiku');
      expect(find.text('haiku'), findsOneWidget);
      final s = await sentBy<SyncModelTable>(tester, host, where: (m) => m.table.modelFor('chores') == 'haiku');
      expect(s.table.updatedAtMs, greaterThan(0));
    });

    testWidgets('session menu: Model… switches a running session', (tester) async {
      final (c, host) = await online(tester, const [], sessions: [summary('s1', name: 'Chat')]);
      tallPhone(tester);
      await tester.pumpWidget(glassApp(SessionsScreen(connection: c, prefs: SessionPrefs(persist: false))));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Model…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('sonnet'));
      await tester.pump();
      final m = await sentBy<SetSessionModel>(tester, host);
      expect(m.model, 'sonnet');
      host.send(const SessionActionDone(action: SessionActions.model, sessionId: 's1', message: 'Model: sonnet'));
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      expect(find.text('Model: sonnet'), findsOneWidget);
    });
  });
  group('older hosts and the first screen', () {
    testWidgets('an older host is named only after it had time to send its tasks', (tester) async {
      final c = HostConnection(testMachine(), channelFactory: channels.factory)..boardGrace = const Duration(milliseconds: 300);
      conns.add(c);
      c.connect();
      final host = channels.last;
      host.send(welcome);
      host.send(const Sessions(sessions: []));
      await tester.runAsync(() => eventually(() => c.link.value == LinkState.online));
      tallPhone(tester, height: 2400);
      await tester.pumpWidget(glassApp(BoardView(connections: [c], store: store)));
      await tester.pump();
      expect(find.text(olderHostTasksMessage), findsNothing, reason: 'its tasks may still be on the way');
      await tester.runAsync(() => pump(400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(olderHostTasksMessage), findsOneWidget);
      host.send(const TasksMessage(tasks: []));
      await tester.runAsync(() => pump(50));
      await tester.pump();
      expect(find.text(olderHostTasksMessage), findsNothing);
    });

    testWidgets('the Board entry counts tasks waiting in Review', (tester) async {
      final (c, _) = await online(tester, [
        task('a', 'One', column: TaskColumn.review),
        task('b', 'Two', column: TaskColumn.review),
        task('c', 'Three'),
      ]);
      expect(boardEntryLabel([c]), 'Board · 2 to review');
      final (d, _) = await online(tester, const [], id: 'm2');
      expect(boardEntryLabel([d]), 'Board');
    });
  });
  group('/perch in a session', () {
    test('the_board_shows_the_project_holding_the_session_folder_else_the_machine', () async {
      final store = BoardStore(persist: false);
      await store.setProjects(const ProjectList(updatedAtMs: 1, projects: [
        Project(id: 'p-perch', name: 'Perch', folders: {'m1': r'D:\projects\perch', 'm2': '/Users/x/perch'}),
        Project(id: 'p-host', name: 'Host only', folders: {'m1': r'D:\projects\perch\packages\perch_host'}),
        Project(id: 'p-site', name: 'Site', folders: {'m1': r'D:\projects\site'}),
      ]));
      expect(projectForFolder(store.projects, 'm1', r'd:/projects/perch/apps')?.id, 'p-perch');
      expect(projectForFolder(store.projects, 'm1', r'D:\projects\perch\packages\perch_host\lib')?.id, 'p-host',
          reason: 'the closest folder wins');
      expect(projectForFolder(store.projects, 'm2', '/Users/x/perch')?.id, 'p-perch');
      expect(projectForFolder(store.projects, 'm1', r'D:\projects\perch-scratch'), isNull);
      expect(projectForFolder(store.projects, 'm3', r'D:\projects\perch'), isNull);

      await store.setFilter('m2');
      final p = await focusBoardOn(store, machineId: 'm1', cwd: r'D:\projects\perch\apps');
      expect(p!.name, 'Perch');
      expect(store.projectFilter, 'p-perch');
      expect(store.machineFilter, isNull, reason: 'a project shows on every machine it is on');
      expect(await focusBoardOn(store, machineId: 'm1', cwd: r'C:\elsewhere'), isNull);
      expect(store.projectFilter, isNull);
      expect(store.machineFilter, 'm1');
    });
  });
}
