// `/perch` in a terminal session asks the host for its menu over loopback: the board grouped
// by project (the session's folder first) with tasks by column, starting a task in that
// session (the same link, report and Review as the phone's Run; the menu sends the message
// itself, the host types nothing), adding a task to the folder's project, moving a task,
// and finishing one into Review or Done with the session's report. The endpoints answer
// only the menu on this machine. Sessions are fakes; no real `claude`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/host_board.dart';
import 'package:perch_host/src/local_board.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/task_board.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final sep = Platform.pathSeparator;

/// One terminal session (`claude` typed by the owner), id `term-1`, Claude Code id `cc-1`.
class TerminalSessions implements TaskSessions {
  final String cwd;
  TerminalSessions(this.cwd);
  final typed = <String>[];
  final _updates = StreamController<SessionSummary>.broadcast();
  final _events = StreamController<({String sessionId, ConversationEvent event})>.broadcast();
  final List<ConversationEvent> log = [];
  SessionState state = SessionState.idle;
  var _seq = 0;

  SessionSummary get summary => SessionSummary(
      id: 'term-1', name: 'My terminal', cwd: cwd, origin: SessionOrigin.external, state: state, startedAtMs: 1);

  void setState(SessionState s) {
    state = s;
    _updates.add(summary);
  }

  void event(ConversationEvent e) {
    e
      ..seq = ++_seq
      ..atMs = DateTime.now().millisecondsSinceEpoch;
    log.add(e);
    _events.add((sessionId: 'term-1', event: e));
  }

  @override
  Future<SessionSummary> startSession({required String cwd, required String prompt, String? name, String? model}) =>
      throw UnimplementedError();
  @override
  Future<void> sendTo(String sessionId, String text) async => typed.add(text);
  @override
  SessionSummary? summaryOf(String sessionId) => sessionId == 'term-1' ? summary : null;
  @override
  List<ConversationEvent> eventsOf(String sessionId) => sessionId == 'term-1' ? List.of(log) : const [];
  @override
  Stream<SessionSummary> get sessionUpdates => _updates.stream;
  @override
  Stream<({String sessionId, ConversationEvent event})> get events => _events.stream;
  @override
  Future<List<String>> recentFolders() async => [cwd];
}

void main() {
  late Directory tmp;
  late Directory perch; // a project with a subfolder the terminal is in
  late Directory other;
  late TerminalSessions term;
  late TaskBoard board;
  late LocalBoard api;
  late Project projectPerch;
  const machine = 'm-1';
  var ids = 0;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_local_board_');
    perch = Directory('${tmp.path}${sep}perch')..createSync();
    Directory('${perch.path}${sep}packages${sep}host').createSync(recursive: true);
    other = Directory('${tmp.path}${sep}other')..createSync();
    term = TerminalSessions('${perch.path}${sep}packages${sep}host');
    board = TaskBoard(
        board: HostBoard(stateDir: '${tmp.path}${sep}state', machineId: machine, remoteOf: (_) => null),
        sessions: term,
        git: (args, cwd) async => ProcessResult(0, 1, '', 'not git'),
        settle: const Duration(milliseconds: 100),
        poll: const Duration(milliseconds: 50))
      ..start();
    projectPerch = Project(id: 'p-perch', name: 'Perch', folders: {machine: perch.path, 'm-2': '/Users/x/perch'});
    board.board.edit(RecordKinds.project, projectPerch.id, projectGroupValues(projectPerch));
    ids = 0;
    api = LocalBoard(
        board: board,
        sessionFor: (cid) async => cid == 'cc-1' ? term.summary : null,
        machineId: () => machine,
        machineName: () => 'Desk',
        newId: () => 'new-${++ids}');
  });

  tearDown(() async {
    await board.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<BoardTask> task(String title,
          {String? cwd, String? project, TaskColumn column = TaskColumn.ready, TaskPriority priority = TaskPriority.normal}) =>
      board.save(BoardTask(
          id: 'id-$title',
          title: title,
          description: 'About $title',
          cwd: cwd ?? perch.path,
          projectId: project,
          acceptance: const ['It works'],
          taskType: 'chores',
          priority: priority,
          column: column,
          createdAtMs: 1000 + title.length));


  group('menu', () {
    test('the_folder_project_comes_first_with_its_tasks_by_column_then_the_others_by_name', () async {
      await task('Low one', project: 'p-perch', priority: TaskPriority.low);
      await task('Urgent', project: 'p-perch', priority: TaskPriority.high);
      await task('Old style'); // no project id: matched by its folder
      await task('Elsewhere', cwd: other.path, column: TaskColumn.backlog);
      board.move('id-Old style', TaskColumn.review);
      final v = await api.view(claudeId: 'cc-1', cwd: term.cwd);
      expect(v['machine'], 'Desk');
      expect(v['session'], {'id': 'term-1', 'name': 'My terminal', 'state': 'idle', 'live': true});
      final ps = v['projects'] as List;
      expect([for (final p in ps) p['name']], ['Perch', 'other']);
      final here = ps.first as Map;
      expect(here['here'], isTrue);
      expect(here['folder'], perch.path);
      expect(here['count'], 3);
      final cols = here['columns'] as List;
      expect([for (final c in cols) c['label']], ['Backlog', 'Ready', 'In progress', 'Review', 'Done']);
      final ready = cols[1] as Map;
      expect([for (final t in ready['tasks'] as List) t['title']], ['Urgent', 'Low one'], reason: 'High first');
      expect([for (final t in (cols[3] as Map)['tasks'] as List) t['title']], ['Old style']);
      final urgent = (ready['tasks'] as List).first as Map;
      expect(urgent['columnLabel'], 'Ready');
      expect(urgent['priorityLabel'], 'High');
      expect(urgent['typeLabel'], 'Search and chores');
      expect(urgent['acceptance'], ['It works']);
      expect(urgent['machine'], 'Desk');
      expect(urgent['canStart'], isTrue);
      expect((ps[1] as Map)['here'], isFalse);
      expect([for (final t in v['taskTypes'] as List) t['id']], contains('feature'));
      expect([for (final p in v['priorities'] as List) p['label']], ['High', 'Normal', 'Low']);
    });

    test('a_folder_with_no_project_and_no_tasks_still_comes_first_empty', () async {
      await task('Elsewhere', cwd: other.path);
      final fresh = Directory('${tmp.path}${sep}fresh')..createSync();
      final v = await api.view(claudeId: 'nobody', cwd: fresh.path);
      expect(v['session'], isNull);
      final ps = v['projects'] as List;
      expect(ps.first['name'], 'fresh');
      expect(ps.first['here'], isTrue);
      expect(ps.first['count'], 0);
      expect(ps[1]['name'], 'other');
    });

    test('perch_lists_unassigned_and_other_machines_tasks', () async {
      await task('Mine', project: 'p-perch');
      board.board.edit(RecordKinds.task, 'idea', {
        'content': {'title': 'An idea', 'projectId': 'p-perch'},
        'column': {'column': 'backlog'}
      });
      board.board.edit(RecordKinds.task, 'mac', {
        'content': {'title': 'On the Mac', 'projectId': 'p-perch', 'machineId': 'm-2', 'cwd': '/Users/x/perch'},
        'column': {'column': 'ready'}
      });
      board.board.edit(RecordKinds.project, 'p-idea', {
        'content': {'name': 'Idea project', 'description': 'Only a name so far'}
      });
      final v = await api.view(claudeId: 'cc-1', cwd: term.cwd);
      final ps = v['projects'] as List;
      expect([for (final p in ps) p['name']], ['Perch', 'Idea project']);
      final perchTasks = {
        for (final c in (ps.first as Map)['columns'] as List)
          for (final t in (c as Map)['tasks'] as List) (t as Map)['title']: t['machine']
      };
      expect(perchTasks, {'Mine': 'Desk', 'An idea': 'Not assigned', 'On the Mac': 'Another machine'});
      expect((ps[1] as Map)['folder'], '');
      expect((ps[1] as Map)['count'], 0);
    });

    test('folder_matching_takes_parents_but_not_lookalike_names', () {
      expect(folderHolds(r'D:\projects\perch', r'D:\projects\perch\packages'), isTrue);
      expect(folderHolds(r'D:\projects\perch', r'd:/projects/perch/'), isTrue);
      expect(folderHolds(r'D:\projects\perch', r'D:\projects\perch-scratch'), isFalse);
      expect(folderHolds('', r'D:\x'), isFalse);
    });
  });

  group('start in this session', () {
    test('links_the_task_like_run_types_nothing_and_reaches_review_with_the_report', () async {
      final sent = <String>[];
      final b = TaskBoard(
          board: HostBoard(stateDir: '${tmp.path}${sep}state2', machineId: machine, remoteOf: (_) => null),
          sessions: term,
          git: (args, cwd) async => ProcessResult(0, 1, '', ''),
          onSend: sent.add,
          settle: const Duration(milliseconds: 100),
          poll: const Duration(milliseconds: 50))
        ..start();
      addTearDown(b.dispose);
      b.board.edit(RecordKinds.project, projectPerch.id, projectGroupValues(projectPerch));
      final local = LocalBoard(
          board: b, sessionFor: (cid) async => cid == 'cc-1' ? term.summary : null,
          machineId: () => machine, machineName: () => 'Desk');
      final t = await b.save(BoardTask(
          id: 'id-notes', title: 'Make notes', description: 'Create notes.txt', cwd: perch.path, acceptance: const ['notes.txt exists']));
      term.event(UserMessage('earlier'));
      term.event(AssistantText('An earlier answer'));
      final r = await local.handle('start', 'POST', const {}, jsonEncode({'taskId': t.id, 'session': 'cc-1', 'cwd': term.cwd}));
      expect(r.status, 200, reason: '${r.body}');
      final prompt = r.body['prompt'] as String;
      expect(prompt, composeTaskPrompt('Make notes', 'Create notes.txt', acceptance: ['notes.txt exists']));
      expect(term.typed, isEmpty, reason: 'the menu sends it; the host types nothing');
      expect(sent, [prompt], reason: 'the push notifier hears of it as for a Run');
      final running = b.tasks.single;
      expect(running.column, TaskColumn.inProgress);
      expect(running.sessionId, 'term-1');
      expect(running.sessionName, 'My terminal');
      expect((r.body['task'] as Map)['linkedHere'], isTrue);
      // Started twice: refused, as Run is.
      final again = await local.handle('start', 'POST', const {}, jsonEncode({'taskId': t.id, 'session': 'cc-1'}));
      expect(again.status, 409);

      // The menu's message reaches the conversation and Claude answers: Review.
      term.setState(SessionState.working);
      term.event(UserMessage(prompt));
      term.event(ToolCall('w1', 'Write', {'file_path': '${perch.path}${sep}notes.txt'}));
      term.event(ToolResult('w1', 'ok'));
      term.event(AssistantText('Done.\n\n## Report\nCreated notes.txt.\n- [x] notes.txt exists'));
      term.setState(SessionState.idle);
      await waitUntil(() => b.tasks.single.column == TaskColumn.review, timeout: const Duration(seconds: 10));
      final done = b.tasks.single;
      expect(done.report!.text, contains('Created notes.txt'));
      expect(done.report!.text, isNot(contains('earlier')));
      expect(done.report!.files.single, endsWith('notes.txt'));
      expect(done.report!.criteria.single.met, isTrue);
    });

    test('the_phone_run_into_the_same_session_still_types_and_links_the_same_way', () async {
      final t = await task('From the phone');
      final running = await board.run(t.id, sessionId: 'term-1');
      expect(term.typed, [TaskBoard.promptFor(t)]);
      expect(running.sessionId, 'term-1');
      expect(running.column, TaskColumn.inProgress);
      // A busy session is still refused for the phone (it would be typed over Claude).
      final t2 = await task('Second');
      term.setState(SessionState.working);
      await expectLater(board.run(t2.id, sessionId: 'term-1'), throwsA(isA<StateError>()));
      // From /perch it is queued by Claude Code itself: accepted.
      final r = await api.start(taskId: t2.id, claudeId: 'cc-1');
      expect((r['task'] as Map)['column'], 'inProgress');
    });

    test('start_in_this_session_assigns_this_machine_and_its_folder', () async {
      board.board.edit(RecordKinds.project, 'p-new', {
        'content': {'name': 'New idea'}
      });
      board.board.edit(RecordKinds.task, 'idea', {
        'content': {'title': 'Try it', 'projectId': 'p-new'},
        'column': {'column': 'ready'}
      });
      final r = await api.handle('start', 'POST', const {}, jsonEncode({'taskId': 'idea', 'session': 'cc-1', 'cwd': term.cwd}));
      expect(r.status, 200, reason: '${r.body}');
      final t = board.tasks.single;
      expect(t.machineId, machine);
      expect(t.cwd, term.cwd);
      expect(t.column, TaskColumn.inProgress);
      expect(t.sessionId, 'term-1');
      expect(projectOf(board.board.board.get(RecordKinds.project, 'p-new')!)!.folderOn(machine), term.cwd);
      expect(term.typed, isEmpty, reason: 'the menu sends the message itself');
    });

    test('a_session_perch_does_not_see_is_refused_with_a_reason', () async {
      final t = await task('Lost');
      final r = await api.handle('start', 'POST', const {}, jsonEncode({'taskId': t.id, 'session': 'cc-unknown'}));
      expect(r.status, 409);
      expect(r.body['error'], contains('does not see this session'));
      expect(board.tasks.single.column, TaskColumn.ready);
    });
  });

  group('add, move, finish', () {
    test('a_task_added_from_a_subfolder_goes_to_its_project_folder', () async {
      final r = await api.handle(
          'add',
          'POST',
          const {},
          jsonEncode({
            'session': 'cc-1',
            'cwd': term.cwd,
            'title': '  Write the README  ',
            'description': 'Explain /perch',
            'acceptance': 'It names the command\n\nIt says what it costs',
            'taskType': 'tests',
            'priority': 'high',
          }));
      expect(r.status, 200, reason: '${r.body}');
      final t = board.tasks.single;
      expect(t.id, 'new-1');
      expect(t.title, 'Write the README');
      expect(t.cwd, perch.path);
      expect(t.projectId, 'p-perch');
      expect(t.acceptance, ['It names the command', 'It says what it costs']);
      expect(t.taskType, 'tests');
      expect(t.priority, TaskPriority.high);
      expect(t.column, TaskColumn.backlog);
      expect(t.sessionId, isNull);
    });

    test('a_task_added_outside_any_project_gets_a_project_for_that_folder', () async {
      await api.add({'title': 'Loose', 'taskType': 'no-such-type', 'column': 'ready'}, cwd: other.path, claudeId: '');
      final t = board.tasks.single;
      expect(t.cwd, other.path);
      expect(t.projectId, autoProjectId(machineId: machine, folder: other.path));
      final p = projectOf(board.board.board.get(RecordKinds.project, t.projectId!)!)!;
      expect((p.name, p.auto, p.folderOn(machine)), ('other', true, other.path));
      expect(t.taskType, isNull);
      expect(t.column, TaskColumn.ready);
      final bad = await api.handle('add', 'POST', const {}, jsonEncode({'title': ' ', 'cwd': other.path}));
      expect(bad.status, 400);
      expect(bad.body['error'], 'Enter a title');
    });

    test('move_and_finish_with_this_sessions_report', () async {
      final t = await task('Fix it');
      expect((await api.handle('move', 'POST', const {}, jsonEncode({'taskId': t.id, 'column': 'backlog'}))).status, 200);
      expect(board.tasks.single.column, TaskColumn.backlog);
      expect((await api.handle('move', 'POST', const {}, jsonEncode({'taskId': t.id, 'column': 'sideways'}))).status, 400);
      expect((await api.handle('move', 'POST', const {}, jsonEncode({'taskId': 'gone', 'column': 'done'}))).status, 404);

      // Worked on by hand in this session, then sent to review from the menu.
      term.event(UserMessage('fix the bug'));
      term.event(ToolCall('e1', 'Edit', {'file_path': '${perch.path}${sep}bug.dart'}));
      term.event(AssistantText('Fixed.\n\n## Report\nFixed the bug in bug.dart.\n- [ ] It works'));
      final r = await api.handle('finish', 'POST', const {}, jsonEncode({'taskId': t.id, 'column': 'review', 'session': 'cc-1'}));
      expect(r.status, 200, reason: '${r.body}');
      final reviewed = board.tasks.single;
      expect(reviewed.column, TaskColumn.review);
      expect(reviewed.sessionId, 'term-1');
      expect(reviewed.report!.text, contains('Fixed the bug'));
      expect(reviewed.report!.files.single, endsWith('bug.dart'));
      expect(reviewed.report!.criteria.single.met, isFalse);
      // Later work in the session is not this task's: Done keeps the Review report.
      term.event(UserMessage('something else'));
      term.event(AssistantText('## Report\nOther work.'));
      final d = await api.handle('finish', 'POST', const {}, jsonEncode({'taskId': t.id, 'column': 'done', 'session': 'cc-1'}));
      expect(d.status, 200);
      expect(board.tasks.single.column, TaskColumn.done);
      expect(board.tasks.single.report!.text, contains('Fixed the bug'));
      expect((d.body['task'] as Map)['canStart'], isFalse);
      expect((await api.handle('finish', 'POST', const {}, jsonEncode({'taskId': t.id, 'column': 'ready', 'session': 'cc-1'}))).status,
          400);
    });

    test('a_finished_run_reports_only_its_own_turns', () async {
      final t = await task('Run then finish');
      term.event(UserMessage('before'));
      term.event(AssistantText('Old answer'));
      await api.start(taskId: t.id, claudeId: 'cc-1');
      term.event(UserMessage(TaskBoard.promptFor(t)));
      term.event(AssistantText('Half done.\n\n## Report\nPart one.'));
      term.setState(SessionState.working); // no turn end yet: finished by hand
      await api.finish(taskId: t.id, column: 'done', claudeId: 'cc-1');
      final f = board.tasks.single;
      expect(f.column, TaskColumn.done);
      expect(f.report!.text, contains('Part one'));
      expect(f.report!.text, isNot(contains('Old answer')));
      // Not waiting any more: the turn's end does not move it back to Review.
      term.setState(SessionState.idle);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(board.tasks.single.column, TaskColumn.done);
    });

    test('bad_requests_are_answered_with_a_reason', () async {
      expect((await api.handle('board', 'POST', const {}, '')).status, 405);
      expect((await api.handle('start', 'GET', const {}, '')).status, 405);
      expect((await api.handle('nope', 'POST', const {}, '{}')).status, 404);
      expect((await api.handle('add', 'POST', const {}, '[1]')).status, 400);
      expect((await api.handle('add', 'POST', const {}, 'not json')).status, 400);
      final ok = await api.handle('board', 'GET', {'session': 'cc-1', 'cwd': term.cwd}, '');
      expect(ok.status, 200);
      expect(jsonEncode(ok.body), isNotEmpty);
    });
  });

  group('server', () {
    late HostState state;
    late SessionManager manager;
    late FakeExternalSessions external;
    late TaskBoard hostBoard;
    late PerchServer server;
    late int port;

    setUp(() async {
      state = HostState.load('${tmp.path}${sep}hoststate');
      external = FakeExternalSessions();
      final config = Directory('${tmp.path}${sep}claude')..createSync();
      manager = SessionManager(launcher: fakeLauncher(), external: external, claudeConfigDir: config.path);
      hostBoard = TaskBoard(board: HostBoard(stateDir: state.directory, machineId: state.machineId, remoteOf: (_) => null), sessions: ManagerTaskSessions(manager))..start();
      server = PerchServer(manager: manager, state: state, machineName: 'Desk', bindAddress: '127.0.0.1', port: 0, board: hostBoard);
      port = await server.start();
    });

    tearDown(() async {
      await server.close();
      await hostBoard.dispose();
      await manager.dispose();
    });

    Future<({int status, String body})> call(String method, String path,
        {String? body, bool header = true, String? hostHeader, String? origin}) async {
      final c = HttpClient();
      try {
        final req = await c.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
        if (header) req.headers.set(PerchServer.menuHeader, '1');
        if (hostHeader != null) req.headers.host = hostHeader;
        if (origin != null) req.headers.set('origin', origin);
        if (body != null) req.write(body);
        final res = await req.close();
        return (status: res.statusCode, body: await res.transform(utf8.decoder).join());
      } finally {
        c.close(force: true);
      }
    }

    test('only_the_menu_on_this_machine_is_answered', () async {
      final path = '/local/perch/board?session=x&cwd=${Uri.encodeQueryComponent(tmp.path)}';
      final ok = await call('GET', path);
      expect(ok.status, 200);
      expect((jsonDecode(ok.body) as Map)['machine'], 'Desk');
      expect((await call('GET', path, header: false)).status, 403, reason: 'a browser page cannot add the header');
      expect((await call('GET', path, hostHeader: 'evil.example')).status, 403);
      expect((await call('GET', path, origin: 'https://evil.example')).status, 403);
      expect((await call('POST', '/local/perch/move', body: '{}', origin: 'https://evil.example')).status, 403);
      expect(PerchServer.menuAllowed(InternetAddress('192.168.1.20'), Uri.parse('http://localhost:1/'), {PerchServer.menuHeader: '1'}),
          isFalse);
    });

    test('a_terminal_session_is_found_by_its_claude_code_id_and_a_task_started_in_it', () async {
      external.entries = [external.entry(pid: 4242, sessionId: 'cc-terminal', cwd: tmp.path, name: 'Typed by me')];
      final s = await manager.sessionForClaudeId('cc-terminal');
      expect(s, isNotNull);
      expect(s!.name, 'Typed by me');
      expect(await manager.sessionForClaudeId('cc-missing'), isNull);
      await hostBoard.save(BoardTask(id: 'id-1', title: 'Do it', cwd: tmp.path, column: TaskColumn.ready));
      final r = await call('POST', '/local/perch/start', body: jsonEncode({'taskId': 'id-1', 'session': 'cc-terminal', 'cwd': tmp.path}));
      expect(r.status, 200, reason: r.body);
      final j = jsonDecode(r.body) as Map;
      expect(j['prompt'], startsWith('Do it'));
      expect(hostBoard.tasks.single.column, TaskColumn.inProgress);
      expect(hostBoard.tasks.single.sessionId, s.id);
    });

    test('an_unlisted_session_is_matched_through_claude_codes_registry', () async {
      final config = '${tmp.path}${sep}claude';
      Directory('$config${sep}sessions').createSync(recursive: true);
      File('$config${sep}sessions${sep}5151.json').writeAsStringSync(jsonEncode({'pid': 5151, 'sessionId': 'cc-reg'}));
      external.entries = [external.entry(pid: 5151, cwd: tmp.path)];
      final s = await manager.sessionForClaudeId('cc-reg');
      expect(s, isNotNull);
    });
  });
}
