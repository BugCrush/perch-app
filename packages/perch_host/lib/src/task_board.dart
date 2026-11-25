// The task board on this machine (docs/superpowers/specs/2026-11-15-task-board-design.md,
// and since 2026-11-24 the projects-first board): tasks are records in the board every
// device keeps (host_board.dart); this machine runs the tasks assigned to it.
// Run sends a task into a new session (named after it, on its task type's model, the
// machine's current account) or an existing one; when that session's turn ends the card
// moves to Review with Claude's report, its to-do list, the files it touched and, in a git
// folder, the changes since the task started. Notes back go into the same session.
//
// A run writes only the task's `column` and `run` groups (never its content), so a title
// edited on the phone while the task runs survives the report written here.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

import 'host_board.dart';
import 'session_manager.dart';

/// Runs `git` with [args] in [cwd].
typedef GitRunner = Future<ProcessResult> Function(List<String> args, String cwd);

Future<ProcessResult> runGit(List<String> args, String cwd) =>
    Process.run('git', args, workingDirectory: cwd, stdoutEncoding: utf8, stderrEncoding: utf8)
        .timeout(const Duration(seconds: 20));

/// What the board needs from the sessions on this machine.
abstract interface class TaskSessions {
  /// Starts a session (in a terminal window where the host opens them) on the machine's
  /// current account.
  Future<SessionSummary> startSession({required String cwd, required String prompt, String? name, String? model});

  /// Sends a message, as from the phone (typed, or through the inbox route).
  Future<void> sendTo(String sessionId, String text);
  SessionSummary? summaryOf(String sessionId);

  /// The session's conversation as the host holds it.
  List<ConversationEvent> eventsOf(String sessionId);
  Stream<SessionSummary> get sessionUpdates;
  Stream<({String sessionId, ConversationEvent event})> get events;

  /// Folders of current and recent sessions.
  Future<List<String>> recentFolders();
}

class ManagerTaskSessions implements TaskSessions {
  final SessionManager m;
  ManagerTaskSessions(this.m);
  @override
  Future<SessionSummary> startSession({required String cwd, required String prompt, String? name, String? model}) =>
      m.start(cwd: cwd, prompt: prompt, name: name, model: model);
  @override
  Future<void> sendTo(String sessionId, String text) => m.send(sessionId, text);
  @override
  SessionSummary? summaryOf(String sessionId) => m.summaryOf(sessionId);
  @override
  List<ConversationEvent> eventsOf(String sessionId) {
    try {
      return m.history(sessionId).events;
    } on NoSuchSession {
      return const [];
    }
  }

  @override
  Stream<SessionSummary> get sessionUpdates => m.sessionUpdates;
  @override
  Stream<({String sessionId, ConversationEvent event})> get events => m.events;
  @override
  Future<List<String>> recentFolders() => m.recentFolders();
}

/// What the host remembers about a running task only while it runs (event numbers start
/// again after a restart) and the card's last activity (not stored).
class _Memo {
  /// The session's last event number when the task (or the notes) was sent: only later
  /// events belong to this turn.
  int? fromSeq;

  /// The same for the run itself (notes back keep it): the report's to-do list and files
  /// cover the whole task.
  int? runFromSeq;
  String? activity;
  int? activityAtMs;
}

class TaskBoard {
  final HostBoard board;
  final TaskSessions sessions;
  final ModelTable Function() modelTable;
  final GitRunner git;

  /// How long a turn must look finished before the card moves to Review.
  final Duration settle;

  /// How often running tasks are looked at (besides session updates).
  final Duration poll;

  /// How long a folder's git remote is remembered.
  final Duration remoteLife;

  /// Called with each text Perch sends into a session (the push notifier must not take it
  /// for the owner typing).
  final void Function(String text)? onSend;
  void Function(String line)? log;

  TaskBoard({
    required this.board,
    required this.sessions,
    ModelTable Function()? modelTable,
    GitRunner? git,
    this.settle = const Duration(seconds: 3),
    this.poll = const Duration(seconds: 5),
    this.remoteLife = const Duration(minutes: 10),
    this.onSend,
    this.log,
  })  : modelTable = modelTable ?? (() => modelTableOf(board.board) ?? ModelTable.starting),
        git = git ?? runGit;

  final _changes = StreamController<List<BoardTask>>.broadcast();
  final List<StreamSubscription<dynamic>> _subs = [];
  final Map<String, Timer> _settling = {};
  final Map<String, _Memo> _memos = {};
  final Map<String, ({String? remote, DateTime at})> _remotes = {};
  Timer? _poll;
  Timer? _emitSoon;
  bool _disposed = false;

  String get machineId => board.machineId;

  BoardTask _decorate(BoardTask t) {
    final m = _memos[t.id];
    final remote = _remotes[_key(t.cwd)]?.remote;
    return t.copyWith(gitRemote: remote, activity: m?.activity, activityAtMs: m?.activityAtMs);
  }

  /// Every live task assigned to this machine, with its folder's git remote when known.
  List<BoardTask> get tasks => [for (final t in board.myTasks) _decorate(t)];

  /// The tasks after every change.
  Stream<List<BoardTask>> get changes => _changes.stream;

  void _emit() {
    if (!_changes.isClosed) _changes.add(tasks);
  }

  /// The run group as stored, with what only this machine needs (gitHead, gitDirty,
  /// awaiting, runAtMs).
  Map<String, dynamic> _run(String id) => board.board.get(RecordKinds.task, id)?.groups['run']?.value ?? const {};

  bool _awaiting(String id) => _run(id)['awaiting'] == true;

  /// Writes the task's run group (whole) from [t] and this machine's extras.
  void _writeRun(BoardTask t,
      {required bool awaiting, TaskColumn? column, String? gitHead, List<String>? gitDirty, int? runAtMs, bool keep = true}) {
    final old = keep ? _run(t.id) : const <String, dynamic>{};
    final head = gitHead ?? (old['gitHead'] is String ? old['gitHead'] as String : null);
    final dirty = gitDirty ?? [for (final f in (old['gitDirty'] is List ? old['gitDirty'] as List : const [])) if (f is String) f];
    final at = runAtMs ?? (old['runAtMs'] is int ? old['runAtMs'] as int : null);
    board.edit(RecordKinds.task, t.id, {
      'run': {
        ...taskRun(t.copyWith(gitRemote: _remotes[_key(t.cwd)]?.remote ?? t.gitRemote)),
        'gitHead': ?head,
        if (dirty.isNotEmpty) 'gitDirty': dirty,
        if (awaiting) 'awaiting': true,
        'runAtMs': ?at,
      },
      'column': ?(column == null ? null : {'column': column.name}),
    });
  }

  /// Starts watching sessions for the tasks sent to them, and the board for changes.
  void start() {
    _subs
      ..add(sessions.sessionUpdates.listen((s) {
        for (final t in board.myTasks) {
          if (t.sessionId == s.id && _awaiting(t.id)) _check(t.id);
        }
      }))
      ..add(sessions.events.listen((e) {
        for (final t in board.myTasks) {
          if (t.sessionId != e.sessionId || !_awaiting(t.id)) continue;
          _activity(t.id, e.event);
          _check(t.id);
        }
      }))
      ..add(board.changes.listen((c) {
        if (c.records.any((r) => r.kind == RecordKinds.task)) _emit();
      }));
    _poll = Timer.periodic(poll, (_) {
      for (final t in board.myTasks) {
        if (_awaiting(t.id)) _check(t.id);
      }
    });
    unawaited(_warmRemotes());
  }

  BoardTask _get(String id) {
    final t = board.myTasks.where((t) => t.id == id).firstOrNull;
    if (t != null) return t;
    final any = board.board.get(RecordKinds.task, id);
    final other = any == null || any.deleted ? null : taskOf(any);
    if (other != null) {
      throw StateError(other.machineId == null
          ? 'This task is not assigned to a machine yet.'
          : 'This task is assigned to another machine.');
    }
    throw StateError('This task no longer exists.');
  }

  static String _key(String path) {
    var p = path.replaceAll('\\', '/');
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    // Windows and macOS (APFS) fold case.
    return (Platform.isWindows || Platform.isMacOS) ? p.toLowerCase() : p;
  }

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  /// Creates a task on this machine (a new id) or edits one (the older apps' path). A new
  /// task never starts linked to a session or in a column only a run reaches; an edit keeps
  /// the host's fields and the column.
  Future<BoardTask> save(BoardTask incoming) async {
    final err = BoardTask.titleError(incoming.title);
    if (err != null) throw ArgumentError(err);
    if (incoming.id.isEmpty || incoming.id.length > 64) throw ArgumentError('A task needs an id.');
    final cwd = incoming.cwd.trim();
    if (cwd.isEmpty || !Directory(cwd).existsSync()) {
      throw ArgumentError('The folder ${cwd.isEmpty ? '(none)' : cwd} does not exist on this machine.');
    }
    final now = _nowMs;
    final existing = board.myTasks.where((t) => t.id == incoming.id).firstOrNull;
    if (existing == null) {
      final column = switch (incoming.column) {
        TaskColumn.inProgress || TaskColumn.review => TaskColumn.ready,
        final c => c,
      };
      final t = BoardTask(
        id: incoming.id,
        title: incoming.title.trim(),
        description: incoming.description,
        cwd: cwd,
        projectId: incoming.projectId,
        machineId: machineId,
        acceptance: _criteria(incoming.acceptance),
        taskType: incoming.taskType,
        priority: incoming.priority,
        column: column,
        createdAtMs: incoming.createdAtMs > 0 ? incoming.createdAtMs : now,
      );
      final had = board.board.get(RecordKinds.task, t.id);
      board.edit(RecordKinds.task, t.id, {
        'content': taskContent(t),
        'column': taskColumn(t),
        'run': const {},
        if (had != null && had.deleted) 'life': {'deleted': false},
      });
      unawaited(_remoteOf(cwd).then((_) => _emit()));
      return _decorate(_get(t.id));
    }
    final t = existing.copyWith(
      title: incoming.title.trim(),
      description: incoming.description,
      cwd: cwd,
      projectId: incoming.projectId,
      acceptance: _criteria(incoming.acceptance),
      taskType: incoming.taskType,
      clearTaskType: incoming.taskType == null,
      priority: incoming.priority,
    );
    board.edit(RecordKinds.task, t.id, {'content': taskContent(t)});
    if (_key(existing.cwd) != _key(cwd)) unawaited(_remoteOf(cwd).then((_) => _emit()));
    return _decorate(_get(t.id));
  }

  /// The owner's criteria, trimmed, the empty ones dropped (at most 30).
  static List<String> _criteria(List<String> a) =>
      [for (final c in a) if (c.trim().isNotEmpty) c.trim()].take(30).toList();

  /// Moves a task to [column] (Done leaves its session as it is). Moving it out of In
  /// progress stops waiting for its session.
  BoardTask move(String id, TaskColumn column) {
    final t = _get(id);
    if (column != TaskColumn.inProgress && _awaiting(id)) {
      _settling.remove(id)?.cancel();
      _writeRun(t, awaiting: false, column: column);
    } else {
      board.edit(RecordKinds.task, id, {
        'column': {'column': column.name}
      });
    }
    return _decorate(_get(id));
  }

  void delete(String id) {
    _get(id);
    _settling.remove(id)?.cancel();
    board.edit(RecordKinds.task, id, {
      'life': {'deleted': true, 'deletedAtMs': _nowMs}
    });
  }

  /// What Perch sends into a session for [t].
  static String promptFor(BoardTask t) => composeTaskPrompt(t.title, t.description, acceptance: t.acceptance);

  /// Sends the task into a new session ([sessionId] null) or an existing one on this
  /// machine; the card moves to In progress, linked to that session. Only a task assigned to
  /// this machine runs here; one without a folder takes its project's folder here.
  ///
  /// [deliver] false: `/perch` in that session's own terminal sends [promptFor] itself
  /// (Claude Code queues it until the session is idle), so the host types nothing and does
  /// not ask whether the session is idle; everything else (the link, the report, Review) is
  /// the same as a Run from the phone.
  Future<BoardTask> run(String id, {String? sessionId, bool deliver = true}) async {
    var t = _get(id);
    if (_awaiting(id) && t.column == TaskColumn.inProgress) {
      throw StateError('This task is already running in ${t.sessionName ?? 'a session'}.');
    }
    if (t.cwd.trim().isEmpty) {
      final pr = board.board.get(RecordKinds.project, t.projectId ?? '');
      final folder = pr == null ? null : projectOf(pr)?.folderOn(machineId);
      if (folder == null) throw ArgumentError('Choose the project\'s folder on this machine first.');
      t = t.copyWith(cwd: folder);
      board.edit(RecordKinds.task, id, {'content': taskContent(t)});
    }
    if (!Directory(t.cwd).existsSync()) throw ArgumentError('The folder ${t.cwd} does not exist on this machine.');
    SessionSummary? existing;
    if (sessionId != null) {
      existing = sessions.summaryOf(sessionId);
      if (existing == null) throw NoSuchSession(sessionId);
      if (deliver && !existing.live) {
        throw StateError('${existing.name} is not running. Resume it first, or run the task in a new session.');
      }
      if (deliver && existing.state != SessionState.idle) {
        throw StateError('${existing.name} is busy. Run the task when it is idle, or in a new session.');
      }
    } else if (!deliver) {
      throw ArgumentError('Name the session the task starts in.');
    }
    final base = await _gitBaseline(t.cwd);
    final fromSeq = existing == null ? 0 : _lastSeq(existing.id);
    final prompt = promptFor(t);
    final sentAt = _nowMs;
    String sid;
    String name;
    onSend?.call(prompt);
    if (existing == null) {
      final model = modelTable().modelFor(t.taskType);
      final s = await sessions.startSession(cwd: t.cwd, prompt: prompt, name: t.title, model: model);
      if (s.state == SessionState.blocked && s.reason != trustReason) {
        throw StateError(s.reason ?? 'Could not start Claude Code.');
      }
      sid = s.id;
      name = s.name;
      log?.call('Task "${t.title}" started in a new session${model == null ? '' : ' on $model'}.');
    } else {
      if (deliver) await sessions.sendTo(existing.id, prompt);
      sid = existing.id;
      name = existing.name;
      log?.call('Task "${t.title}" ${deliver ? 'sent to' : 'started with /perch in'} ${existing.name}.');
    }
    _memos[id] = _Memo()
      ..fromSeq = fromSeq
      ..runFromSeq = fromSeq
      ..activity = 'Sent to Claude'
      ..activityAtMs = sentAt;
    final latest = _get(id);
    _writeRun(
        latest.copyWith(sessionId: sid, sessionName: name, sentAtMs: sentAt, clearReport: true),
        awaiting: true,
        column: TaskColumn.inProgress,
        gitHead: base?.head ?? '',
        gitDirty: base?.dirty ?? const [],
        runAtMs: sentAt,
        keep: false);
    return _decorate(_get(id));
  }

  /// Types the owner's notes into the task's session; the card goes back to In progress.
  Future<BoardTask> notes(String id, String text) async {
    final t = _get(id);
    final sid = t.sessionId;
    final notes = text.trim();
    if (notes.isEmpty) throw ArgumentError('Write the notes first.');
    if (sid == null) throw StateError('This task has not been run yet.');
    onSend?.call(notes);
    final sentAt = _nowMs;
    final fromSeq = _lastSeq(sid);
    await sessions.sendTo(sid, notes);
    (_memos[id] ??= _Memo())
      ..fromSeq = fromSeq
      ..activity = 'Notes sent'
      ..activityAtMs = sentAt;
    _writeRun(_get(id).copyWith(sentAtMs: sentAt, clearReport: true), awaiting: true, column: TaskColumn.inProgress);
    return _decorate(_get(id));
  }

  /// `/perch` in a session's terminal: the task goes to Review or Done with that session's
  /// report, as the board's own turn end makes it (Claude's report, its to-do list, the
  /// files it touched and the git changes since the task started). A task run in that
  /// session covers its run; any other task covers the whole conversation and is linked to
  /// the session from now on.
  Future<BoardTask> finishIn(String id, String sessionId, TaskColumn column) async {
    if (column != TaskColumn.review && column != TaskColumn.done) {
      throw ArgumentError('A task is finished into Review or Done.');
    }
    final t = _get(id);
    final s = sessions.summaryOf(sessionId) ?? (throw NoSuchSession(sessionId));
    final run = _run(id);
    final m = _memos[id];
    final linked = t.sessionId == sessionId && (m?.runFromSeq != null || run['runAtMs'] != null);
    _settling.remove(id)?.cancel();
    final now = _nowMs;
    final TaskReport report;
    final kept = t.report;
    if (kept != null && !_awaiting(id)) {
      // Already reported (Review): Done keeps that report; later turns of the session
      // belong to other work.
      report = kept;
    } else {
      final changes = linked ? await _gitChanges(t) : const <String>[];
      final events = linked ? _since(t, wholeRun: true) : sessions.eventsOf(sessionId);
      report = buildTaskReport(events, atMs: now, changes: changes, acceptance: t.acceptance);
    }
    (_memos[id] ??= _Memo())
      ..activity = column == TaskColumn.done ? 'Done' : 'Ready for review'
      ..activityAtMs = now;
    _writeRun(_get(id).copyWith(report: report, sessionId: sessionId, sessionName: s.name),
        awaiting: false, column: column);
    log?.call('Task "${t.title}" ${column == TaskColumn.done ? 'marked done' : 'sent to review'} from ${s.name}.');
    return _decorate(_get(id));
  }

  // ------------------------------------------------------------ the turn ends

  int _lastSeq(String sessionId) {
    var last = 0;
    for (final e in sessions.eventsOf(sessionId)) {
      if (e.seq > last) last = e.seq;
    }
    return last;
  }

  /// Events of the task's session since it was sent: by event number; after a restart of
  /// the host (numbers start again), by time.
  List<ConversationEvent> _since(BoardTask t, {bool wholeRun = false}) {
    final all = sessions.eventsOf(t.sessionId!);
    final m = _memos[t.id];
    final from = wholeRun ? m?.runFromSeq : m?.fromSeq;
    if (from != null) return [for (final e in all) if (e.seq > from) e];
    final runAt = _run(t.id)['runAtMs'];
    final at = ((wholeRun && runAt is int ? runAt : null) ?? t.sentAtMs ?? 0) - 1000;
    return [for (final e in all) if (e.atMs >= at) e];
  }

  /// Whether the session's turn for the task looks finished: the session is idle (or ended)
  /// and Claude's last word was an answer, not a tool call.
  bool _turnOver(BoardTask t) {
    final sid = t.sessionId;
    if (sid == null || !_awaiting(t.id) || t.column != TaskColumn.inProgress) return false;
    final s = sessions.summaryOf(sid);
    if (s == null) return false;
    final ended = !s.live || s.state == SessionState.finished || s.state == SessionState.stopped;
    if (!ended && s.state != SessionState.idle) return false;
    if (ended) return true;
    // The message Perch sent must have reached the conversation, and Claude answered it
    // last (not with a tool call still to come).
    final since = [for (final e in _since(t)) if (e.parentToolUseId == null) e];
    final asked = since.indexWhere((e) => e is UserMessage);
    if (asked < 0) return false;
    final turn = [
      for (final e in since.sublist(asked + 1))
        if (e is AssistantText || e is ToolCall || e is ToolResult || e is TurnEnded) e
    ];
    if (!turn.any((e) => e is AssistantText)) return false;
    final last = turn.last;
    return last is AssistantText || last is TurnEnded;
  }

  BoardTask? _mine(String id) => board.myTasks.where((t) => t.id == id).firstOrNull;

  /// Tasks whose finish is running (it waits for git): no second finish starts meanwhile.
  final Set<String> _finishing = {};

  void _check(String id) {
    final t = _mine(id);
    if (_disposed || t == null || _settling.containsKey(id) || _finishing.contains(id) || !_turnOver(t)) return;
    _settling[id] = Timer(settle, () async {
      _settling.remove(id);
      final now = _mine(id);
      if (_disposed || now == null || _finishing.contains(id) || !_turnOver(now)) return;
      _finishing.add(id);
      try {
        await _finish(now);
      } finally {
        _finishing.remove(id);
      }
    });
  }

  Future<void> _finish(BoardTask t) async {
    final s = sessions.summaryOf(t.sessionId!);
    // Notes sent while git runs start a new turn: this finish is then out of date.
    final fromSeq = _memos[t.id]?.fromSeq;
    final sentAt = _mine(t.id)?.sentAtMs;
    final changes = await _gitChanges(t);
    if (!_awaiting(t.id) || _disposed) return;
    if (_memos[t.id]?.fromSeq != fromSeq || _mine(t.id)?.sentAtMs != sentAt) return;
    final now = _nowMs;
    final report = buildTaskReport(_since(t, wholeRun: true),
        atMs: now,
        changes: changes,
        sessionEnded: s == null || !s.live || s.state == SessionState.stopped,
        acceptance: t.acceptance);
    (_memos[t.id] ??= _Memo())
      ..activity = 'Ready for review'
      ..activityAtMs = now;
    // The latest task: its content may have changed on another device meanwhile.
    final latest = _mine(t.id) ?? t;
    _writeRun(latest.copyWith(report: report, sessionName: s?.name), awaiting: false, column: TaskColumn.review);
    log?.call('Task "${latest.title}" is ready for review.');
  }

  /// The last thing the linked session did, for the card (sent at most once a second).
  void _activity(String id, ConversationEvent e) {
    if (e.parentToolUseId != null) return;
    final String? text = switch (e) {
      ToolCall(:final name, :final input) => _toolLine(name, input),
      AssistantText(:final text) => text.trim().split('\n').first,
      _ => null,
    };
    if (text == null || text.isEmpty) return;
    (_memos[id] ??= _Memo())
      ..activity = text.length > 90 ? '${text.substring(0, 89)}…' : text
      ..activityAtMs = e.atMs > 0 ? e.atMs : _nowMs;
    _emitSoon ??= Timer(const Duration(seconds: 1), () {
      _emitSoon = null;
      _emit();
    });
  }

  static String _toolLine(String name, Map<String, dynamic> input) {
    final arg = input['file_path'] ?? input['notebook_path'] ?? input['command'] ?? input['pattern'] ?? input['description'];
    if (arg is! String || arg.isEmpty) return name;
    final short = arg.split(RegExp(r'[\\/]')).last;
    return '$name ${input['command'] != null ? arg.split('\n').first : short}';
  }

  // ------------------------------------------------------------ git

  Future<({String head, List<String> dirty})?> _gitBaseline(String cwd) async {
    try {
      final head = await git(['rev-parse', 'HEAD'], cwd);
      if (head.exitCode != 0) return null;
      return (head: '${head.stdout}'.trim(), dirty: await _status(cwd).then((s) => s.keys.toList()));
    } catch (_) {
      return null;
    }
  }

  /// `git status` of [cwd]: path -> its two-letter state.
  Future<Map<String, String>> _status(String cwd) async {
    final r = await git(['status', '--porcelain=v1', '-uall', '--', '.'], cwd);
    if (r.exitCode != 0) return const {};
    return {
      for (final l in const LineSplitter().convert('${r.stdout}'))
        if (l.length > 3) l.substring(3).trim().replaceAll('"', ''): l.substring(0, 2)
    };
  }

  /// The changes since the task was run: `git diff --stat` against the commit it started
  /// at, new files, and the files that were already changed before it.
  Future<List<String>> _gitChanges(BoardTask t) async {
    final run = _run(t.id);
    final head = run['gitHead'] is String && (run['gitHead'] as String).isNotEmpty ? run['gitHead'] as String : null;
    final dirtyBefore = [for (final f in (run['gitDirty'] is List ? run['gitDirty'] as List : const [])) if (f is String) f];
    final cwd = t.cwd;
    if (head == null) return const [];
    try {
      final out = <String>[];
      final diff = await git(['diff', '--stat=120', head, '--', '.'], cwd);
      if (diff.exitCode == 0) {
        out.addAll(const LineSplitter().convert('${diff.stdout}').where((l) => l.trim().isNotEmpty));
      }
      final status = await _status(cwd);
      final fresh = [
        for (final e in status.entries)
          if (e.value == '??' && !dirtyBefore.contains(e.key)) e.key
      ];
      out.addAll([for (final f in fresh) ' new file: $f']);
      final before = [for (final f in dirtyBefore) if (status.containsKey(f) || out.any((l) => l.contains(f))) f];
      if (before.isNotEmpty) out.add('Changed before the task started too: ${before.join(', ')}');
      if (out.length > 40) return [...out.take(39), '… and ${out.length - 39} more lines'];
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// The git remote (`origin`) of [cwd], remembered for a while; null outside git.
  Future<String?> _remoteOf(String cwd) async {
    final key = _key(cwd);
    final known = _remotes[key];
    if (known != null && DateTime.now().difference(known.at) < remoteLife) return known.remote;
    String? remote;
    try {
      if (cwd.trim().isNotEmpty && Directory(cwd).existsSync()) {
        final r = await git(['remote', 'get-url', 'origin'], cwd);
        final out = '${r.stdout}'.trim();
        if (r.exitCode == 0 && out.isNotEmpty) remote = out;
      }
    } catch (_) {}
    _remotes[key] = (remote: remote, at: DateTime.now());
    return remote;
  }

  Future<void> _warmRemotes() async {
    final mine = board.myTasks;
    for (final t in mine) {
      await _remoteOf(t.cwd);
    }
    if (mine.isNotEmpty) _emit();
  }

  /// The git remotes of this machine's known folders: recent sessions', tasks' and the
  /// projects' folders here.
  Future<List<GitFolder>> gitRemotes() async {
    final seen = <String>{};
    final folders = <String>[];
    List<String> recent;
    try {
      recent = await sessions.recentFolders();
    } catch (_) {
      recent = const [];
    }
    for (final f in [
      ...recent,
      for (final t in board.myTasks) t.cwd,
      for (final p in board.board.projects) ?p.folderOn(machineId),
    ]) {
      if (f.isNotEmpty && seen.add(_key(f))) folders.add(f);
    }
    final out = <GitFolder>[];
    for (final f in folders.take(60)) {
      final r = await _remoteOf(f);
      if (r != null) out.add(GitFolder(path: f, remote: r));
    }
    _emit();
    return out;
  }

  Future<void> dispose() async {
    _disposed = true;
    _poll?.cancel();
    _emitSoon?.cancel();
    for (final t in _settling.values) {
      t.cancel();
    }
    _settling.clear();
    for (final s in _subs) {
      await s.cancel();
    }
    await _changes.close();
  }
}
