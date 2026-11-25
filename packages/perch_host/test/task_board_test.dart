// The task board on the host: tasks saved per machine (tasks.json, written atomically),
// edit / move / delete, Run in a new session (named after the task, on its type's model)
// or in an existing one, the Review report when the turn ends (Claude's report, its to-do
// list with ticks, files touched, the git changes since the task started), notes back,
// Done, and the git remotes of known folders. Sessions are the scripted fake `claude`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_board.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/task_board.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final sep = Platform.pathSeparator;

Future<void> git(String cwd, List<String> args) async {
  final r = await Process.run(
      'git', ['-c', 'user.name=Perch Test', '-c', 'user.email=test@example.invalid', '-c', 'core.autocrlf=false', ...args],
      workingDirectory: cwd);
  if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
}

/// A git repository with one commit (README.md) and an origin remote.
Future<Directory> repo(Directory parent, String name, {String? remote}) async {
  final d = Directory('${parent.path}$sep$name')..createSync(recursive: true);
  await git(d.path, ['init', '-q']);
  File('${d.path}${sep}README.md').writeAsStringSync('# test\n');
  await git(d.path, ['add', '.']);
  await git(d.path, ['commit', '-q', '-m', 'first']);
  if (remote != null) await git(d.path, ['remote', 'add', 'origin', remote]);
  return d;
}

void main() {
  late Directory tmp;
  late Directory state;
  late Directory work;
  late String argsFile;
  late String stdinLog;
  late SessionManager manager;
  late TaskBoard board;
  var table = ModelTable.starting;
  final sent = <String>[];

  HostBoard hostBoard(String dir) => HostBoard(stateDir: dir, machineId: 'm-here', remoteOf: (_) => null);

  TaskBoard newBoard() => TaskBoard(
        board: hostBoard(state.path),
        sessions: ManagerTaskSessions(manager),
        modelTable: () => table,
        settle: const Duration(milliseconds: 200),
        poll: const Duration(milliseconds: 200),
        onSend: sent.add,
      );

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_tasks_');
    state = Directory('${tmp.path}${sep}state')..createSync();
    work = await repo(tmp, 'proj', remote: 'git@github.com:owner/proj.git');
    argsFile = '${tmp.path}${sep}args.txt';
    stdinLog = '${tmp.path}${sep}stdin.txt';
    table = ModelTable.starting;
    sent.clear();
    manager = SessionManager(
        launcher: fakeLauncher(env: {'FAKE_CLAUDE_ARGS_FILE': argsFile, 'FAKE_CLAUDE_STDIN_LOG': stdinLog}),
        external: FakeExternalSessions());
    board = newBoard()..start();
  });

  tearDown(() async {
    await board.dispose();
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  BoardTask task(String title, {String description = '', String? type, TaskColumn column = TaskColumn.ready}) =>
      BoardTask(
          id: 'task-${title.hashCode.abs()}',
          title: title,
          description: description,
          cwd: work.path,
          taskType: type,
          column: column,
          createdAtMs: 1000);

  Future<BoardTask> until(String id, bool Function(BoardTask t) ok) async {
    await waitUntil(() => board.tasks.any((t) => t.id == id && ok(t)), timeout: const Duration(seconds: 60));
    return board.tasks.firstWhere((t) => t.id == id);
  }

  group('storage', () {
    test('create_edit_move_delete_are_saved_atomically_and_survive_a_restart', () async {
      final changes = <List<BoardTask>>[];
      final sub = board.changes.listen(changes.add);
      final a = await board.save(task('Add footer', description: 'Small', type: 'feature'));
      expect(a.createdAtMs, 1000);
      expect(a.updatedAtMs, greaterThan(0));
      await board.save(task('Second'));
      await board.save(a.copyWith(title: 'Add a footer', column: TaskColumn.done));
      board.move(a.id, TaskColumn.inProgress);
      final file = File('${state.path}${sep}board.json');
      expect(file.existsSync(), isTrue);
      expect(state.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);

      final again = newBoard();
      final t = again.tasks.firstWhere((t) => t.id == a.id);
      expect(t.title, 'Add a footer');
      expect(t.description, 'Small');
      expect(t.taskType, 'feature');
      // An edit keeps the column (moves are separate).
      expect(t.column, TaskColumn.inProgress);
      board.delete(a.id);
      expect(newBoard().tasks.map((t) => t.title), ['Second']);
      await again.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(changes.length, greaterThanOrEqualTo(4));
      await sub.cancel();
    });

    test('the_project_and_acceptance_criteria_are_kept_on_create_and_edit', () async {
      final a = await board.save(task('With criteria').copyWith(projectId: 'p1', acceptance: ['It works', 'Tests pass']));
      expect(a.projectId, 'p1');
      expect(a.acceptance, ['It works', 'Tests pass']);
      final b = await board.save(a.copyWith(acceptance: ['It works']));
      expect(b.acceptance, ['It works']);
      final again = newBoard();
      expect(again.tasks.single.projectId, 'p1');
      expect(again.tasks.single.acceptance, ['It works']);
      await again.dispose();
    });

    test('a_task_is_checked', () async {
      await expectLater(board.save(task('')), throwsArgumentError);
      await expectLater(board.save(task('x').copyWith(cwd: '${tmp.path}${sep}missing')), throwsArgumentError);
      expect(() => board.move('nope', TaskColumn.done), throwsA(isA<StateError>()));
    });

    test('a_new_task_never_starts_linked_or_in_progress', () async {
      final t = await board.save(task('Copied', column: TaskColumn.review).copyWith(
          sessionId: 'elsewhere', report: const TaskReport(text: 'old', atMs: 1)));
      expect(t.column, TaskColumn.ready);
      expect(t.sessionId, isNull);
      expect(t.report, isNull);
    });
  });

  group('run', () {
    test('new_session_named_after_the_task_on_its_type_model_then_review_with_the_report', () async {
      table = table.withRow(table.row('chores')!.copyWith(model: 'haiku'), atMs: 5);
      File('${work.path}${sep}README.md').writeAsStringSync('# test\nchanged before\n'); // dirty at start
      final t = await board.save(task('Make notes', description: 'todo-task: create notes.txt', type: 'chores'));
      final running = await board.run(t.id);
      expect(running.column, TaskColumn.inProgress);
      expect(running.sessionId, isNotNull);
      expect(running.sessionName, 'Make notes');
      expect(sent.single, composeTaskPrompt('Make notes', 'todo-task: create notes.txt'));
      await waitUntil(() => File(argsFile).existsSync());
      final args = File(argsFile).readAsLinesSync();
      expect(args, containsAllInOrder(['--model', 'haiku']));
      final summary = manager.summaryOf(running.sessionId!)!;
      expect(summary.name, 'Make notes');

      final done = await until(t.id, (t) => t.column == TaskColumn.review);
      final r = done.report!;
      expect(r.text, startsWith('## Report'));
      expect(r.text, contains('created notes.txt'));
      expect(r.todos, const [TodoItem('Create notes.txt', done: true), TodoItem('Check its contents', done: true)]);
      expect(r.files.single, endsWith('notes.txt'));
      expect(r.changes.join('\n'), contains('notes.txt'));
      expect(r.changes.join('\n'), contains('README.md'));
      expect(r.changes.join('\n'), contains('before the task'));
      expect(done.sessionId, running.sessionId);
      // Saved: a restarted host still has the report.
      final again = newBoard();
      expect(again.tasks.single.report!.todos, hasLength(2));
      await again.dispose();
    });

    test('the_acceptance_criteria_go_to_claude_and_the_report_ticks_them', () async {
      final t = await board.save(task('Make notes', description: 'todo-task: create notes.txt')
          .copyWith(acceptance: ['notes.txt exists', 'Nothing else changed']));
      await board.run(t.id);
      expect(sent.single, composeTaskPrompt('Make notes', 'todo-task: create notes.txt',
          acceptance: ['notes.txt exists', 'Nothing else changed']));
      expect(sent.single, contains('Acceptance criteria:\n1. notes.txt exists'));
      final done = await until(t.id, (t) => t.column == TaskColumn.review);
      final c = done.report!.criteria;
      expect([for (final x in c) x.text], ['notes.txt exists', 'Nothing else changed']);
    });

    test('a_task_type_on_the_default_passes_no_model', () async {
      final t = await board.save(task('Plain', description: 'echo plain', type: 'feature'));
      await board.run(t.id);
      await waitUntil(() => File(argsFile).existsSync());
      expect(File(argsFile).readAsLinesSync(), isNot(contains('--model')));
      final done = await until(t.id, (t) => t.column == TaskColumn.review);
      expect(done.report!.text, contains('echo: Plain'));
      expect(done.report!.todos, isEmpty);
    });

    test('notes_back_go_into_the_same_session_and_the_card_returns_to_review', () async {
      final t = await board.save(task('Notes', description: 'echo first'));
      final running = await board.run(t.id);
      await until(t.id, (t) => t.column == TaskColumn.review);
      final back = await board.notes(t.id, 'Also add a second line');
      expect(back.column, TaskColumn.inProgress);
      expect(back.report, isNull);
      expect(back.sessionId, running.sessionId);
      final again = await until(t.id, (t) => t.column == TaskColumn.review);
      expect(again.report!.text, 'echo: Also add a second line');
      expect(File(stdinLog).readAsStringSync(), contains('Also add a second line'));
      expect(sent.last, 'Also add a second line');
      // Done leaves the session as it is.
      board.move(t.id, TaskColumn.done);
      expect(board.tasks.single.column, TaskColumn.done);
      expect(manager.summaryOf(running.sessionId!)!.live, isTrue);
    });

    test('an_existing_session_on_the_machine_gets_the_task', () async {
      final s = await manager.start(cwd: work.path, prompt: 'echo hello', name: 'Already here');
      await waitUntil(() => manager.summaryOf(s.id)!.state == SessionState.idle, timeout: const Duration(seconds: 60));
      final t = await board.save(task('Into existing', description: 'echo more'));
      final running = await board.run(t.id, sessionId: s.id);
      expect(running.sessionId, s.id);
      expect(running.sessionName, 'Already here');
      final done = await until(t.id, (t) => t.column == TaskColumn.review);
      expect(done.report!.text, startsWith('echo: Into existing'));
      // The answer to the earlier message is not the report.
      expect(done.report!.text, isNot(contains('hello')));
    });

    test('a_busy_or_missing_session_is_refused', () async {
      final s = await manager.start(cwd: work.path, prompt: 'slow', name: 'Busy');
      await waitUntil(() => manager.summaryOf(s.id)!.state == SessionState.working, timeout: const Duration(seconds: 60));
      final t = await board.save(task('Wait'));
      await expectLater(board.run(t.id, sessionId: s.id), throwsA(isA<StateError>()));
      await expectLater(board.run(t.id, sessionId: 'nope'), throwsA(isA<NoSuchSession>()));
      expect(board.tasks.single.column, TaskColumn.ready);
      await manager.interrupt(s.id);
    });

    test('a_terminal_session_reaches_review_only_once_idle_after_an_answer', () async {
      // A session in a terminal window: its state comes from hooks or the listing, its
      // conversation from the transcript, each at its own pace.
      final fake = ScriptedSessions(work.path);
      final b = TaskBoard(
          board: hostBoard('${state.path}${sep}t2'),
          sessions: fake,
          settle: const Duration(milliseconds: 150),
          poll: const Duration(milliseconds: 50))
        ..start();
      addTearDown(b.dispose);
      final t = await b.save(task('In a terminal'));
      final running = await b.run(t.id);
      expect(running.sessionId, 'pid:77');
      expect(fake.started.single.name, 'In a terminal');
      Future<TaskColumn> after(Duration d) async {
        await Future<void>.delayed(d);
        return b.tasks.single.column;
      }
      // Moving to Review saves the board and runs git: allow it a moment on a slow disk.
      Future<TaskColumn> reaches(TaskColumn want) async {
        final sw = Stopwatch()..start();
        while (b.tasks.single.column != want && sw.elapsedMilliseconds < 3000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return b.tasks.single.column;
      }

      // Idle before the prompt shows up as working: not finished.
      expect(await after(const Duration(milliseconds: 300)), TaskColumn.inProgress);
      fake.event(UserMessage(fake.started.single.prompt));
      fake.state(SessionState.working);
      fake.event(AssistantText('Let me look.'));
      fake.event(ToolCall('w1', 'Write', {'file_path': '${work.path}${sep}a.txt'}));
      // Idle, but the last thing was a tool call (the listing lags behind): not finished.
      fake.state(SessionState.idle);
      expect(await after(const Duration(milliseconds: 300)), TaskColumn.inProgress);
      expect(b.tasks.single.activity, 'Write a.txt');
      fake.state(SessionState.working);
      fake.event(ToolResult('w1', 'ok'));
      fake.event(AssistantText('Done.\n\nReport: wrote a.txt'));
      fake.state(SessionState.idle);
      expect(await reaches(TaskColumn.review), TaskColumn.review);
      expect(b.tasks.single.report!.text, 'Report: wrote a.txt');
      expect(b.tasks.single.report!.files.single, endsWith('a.txt'));

      // Notes back: the session still says idle and the old answer is the last word until
      // the notes reach the conversation (seen live): not a new review yet.
      await b.notes(t.id, 'Reply OK');
      expect(await after(const Duration(milliseconds: 400)), TaskColumn.inProgress);
      fake.event(UserMessage('Reply OK'));
      fake.event(AssistantText('OK'));
      expect(await reaches(TaskColumn.review), TaskColumn.review);
      expect(b.tasks.single.report!.text, 'OK');
      // The files cover the whole task, not just the last turn.
      expect(b.tasks.single.report!.files.single, endsWith('a.txt'));
    });
  });

  group('the board', () {
    test('a_task_assigned_to_another_machine_is_never_run', () async {
      final v = board.board.clock.tick();
      BoardRecord rec(String id, String? machine, {int later = 1}) => BoardRecord(RecordKinds.task, id, {
            'content': BoardGroup({'title': id, 'cwd': work.path, 'machineId': ?machine, 'projectId': 'p'}, Hlc(v.ms + later, 0, 'phone'))
          });
      board.board.mergeAll([rec('elsewhere', 'm-other'), rec('idea', null)], from: 'phone');
      expect(board.tasks, isEmpty);
      await expectLater(board.run('elsewhere'), throwsA(isA<StateError>()));
      await expectLater(board.run('idea'), throwsA(isA<StateError>()));
      expect(await manager.list(), isEmpty);
      // Assigned here: it runs.
      board.board.mergeAll([rec('idea', 'm-here', later: 2)], from: 'phone');
      expect(board.tasks.single.id, 'idea');
    });

    test('a_task_with_no_folder_runs_in_its_projects_folder_here', () async {
      final fake = ScriptedSessions(work.path);
      final b = TaskBoard(board: hostBoard('${state.path}${sep}t3'), sessions: fake, poll: const Duration(milliseconds: 50))
        ..start();
      addTearDown(b.dispose);
      b.board.edit(RecordKinds.project, 'p', {
        'content': {'name': 'P'},
        'folder:m-here': {'path': work.path}
      });
      b.board.edit(RecordKinds.task, 'idea', {
        'content': {'title': 'Idea', 'projectId': 'p', 'machineId': 'm-here'}
      });
      final t = await b.run('idea');
      expect(t.cwd, work.path);
      expect(t.column, TaskColumn.inProgress);
    });

    test('a_report_written_here_does_not_undo_a_title_edited_on_the_phone', () async {
      final fake = ScriptedSessions(work.path);
      final b = TaskBoard(
          board: hostBoard('${state.path}${sep}t4'),
          sessions: fake,
          settle: const Duration(milliseconds: 100),
          poll: const Duration(milliseconds: 50))
        ..start();
      addTearDown(b.dispose);
      final t = await b.save(task('Original title'));
      await b.run(t.id);
      // The phone renames the task while it runs (its clock is ahead).
      final content = b.board.board.get(RecordKinds.task, t.id)!.groups['content']!.value;
      b.board.mergeAll([
        BoardRecord(RecordKinds.task, t.id, {
          'content': BoardGroup({...content, 'title': 'Renamed on the phone'}, Hlc(b.board.clock.last.ms + 60000, 0, 'phone'))
        })
      ], from: 'phone');
      fake.event(UserMessage(fake.started.single.prompt));
      fake.event(AssistantText('Report: done here'));
      fake.state(SessionState.idle);
      await waitUntil(() => b.tasks.single.column == TaskColumn.review);
      final done = b.tasks.single;
      expect(done.title, 'Renamed on the phone');
      expect(done.report!.text, 'Report: done here');
      expect(done.machineId, 'm-here');
    });
  });

  group('git remotes', () {
    test('known_folders_report_their_origin_and_tasks_carry_it', () async {
      final other = await repo(tmp, 'other', remote: 'https://github.com/owner/other');
      final plain = Directory('${tmp.path}${sep}plain')..createSync();
      await board.save(task('Here'));
      await board.save(task('There').copyWith(cwd: other.path));
      await board.save(task('Not git').copyWith(cwd: plain.path));
      final folders = await board.gitRemotes();
      expect({for (final f in folders) f.path: normalizeGitRemote(f.remote)},
          {work.path: 'github.com/owner/proj', other.path: 'github.com/owner/other'});
      expect(board.tasks.firstWhere((t) => t.title == 'Here').gitRemote, 'git@github.com:owner/proj.git');
      expect(board.tasks.firstWhere((t) => t.title == 'Not git').gitRemote, isNull);
      expect(jsonDecode(File('${state.path}${sep}board.json').readAsStringSync()), isA<Map>());
    });
  });
}

/// Sessions driven by the test: one terminal session `pid:77` whose state and events the
/// test sets.
class ScriptedSessions implements TaskSessions {
  final String cwd;
  ScriptedSessions(this.cwd);
  final started = <({String prompt, String? name, String? model})>[];
  final _updates = StreamController<SessionSummary>.broadcast();
  final _events = StreamController<({String sessionId, ConversationEvent event})>.broadcast();
  final List<ConversationEvent> _log = [];
  SessionState _state = SessionState.idle;
  var _seq = 0;

  SessionSummary get _summary => SessionSummary(
      id: 'pid:77', name: started.isEmpty ? '' : started.last.name ?? '', cwd: cwd, origin: SessionOrigin.external, state: _state, startedAtMs: 1);

  void state(SessionState s) {
    _state = s;
    _updates.add(_summary);
  }

  void event(ConversationEvent e) {
    e
      ..seq = ++_seq
      ..atMs = DateTime.now().millisecondsSinceEpoch;
    _log.add(e);
    _events.add((sessionId: 'pid:77', event: e));
  }

  @override
  Future<SessionSummary> startSession({required String cwd, required String prompt, String? name, String? model}) async {
    started.add((prompt: prompt, name: name, model: model));
    return _summary;
  }

  @override
  Future<void> sendTo(String sessionId, String text) async {}
  @override
  SessionSummary? summaryOf(String sessionId) => sessionId == 'pid:77' && started.isNotEmpty ? _summary : null;
  @override
  List<ConversationEvent> eventsOf(String sessionId) => List.of(_log);
  @override
  Stream<SessionSummary> get sessionUpdates => _updates.stream;
  @override
  Stream<({String sessionId, ConversationEvent event})> get events => _events.stream;
  @override
  Future<List<String>> recentFolders() async => [cwd];
}
