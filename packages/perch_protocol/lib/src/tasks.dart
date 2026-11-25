// The task board and the model table (docs/superpowers/specs/2026-11-15-task-board-design.md).
// A task lives on the machine it targets (that host stores it); the app shows one board
// across machines. The model table is kept on the phone and synced to every host, like
// accounts; the newer table wins on either side.
import 'models.dart';

/// The board's columns, in order.
enum TaskColumn { backlog, ready, inProgress, review, done }

enum TaskPriority { high, normal, low }

T _byName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
int? _ms(Object? v) => v is num && v > 0 ? v.toInt() : null;
List<Object?> _list(Object? v) => v is List ? v : const [];

/// The longest task title Perch accepts (it also names the session, R12).
const maxTaskTitleLength = 100;

/// The line Perch appends to every task it sends (decision 5).
const taskReportRequest =
    'When you finish, end your answer with a short report under the heading "Report": what changed, which files, '
    'how it was tested, and what is left.';

/// The line Perch adds when a task has acceptance criteria.
const taskCriteriaRequest =
    'In the report, list each acceptance criterion as a checklist line: "- [x]" when it is met, "- [ ]" when it is not.';

/// What Perch sends into a session for [title] and [description]: the task as written (no
/// rewriting), its [acceptance] criteria numbered, then the report request (and, with
/// criteria, the request to tick them in the report).
String composeTaskPrompt(String title, String description, {List<String> acceptance = const []}) {
  final d = description.trim();
  final criteria = [for (final c in acceptance) if (c.trim().isNotEmpty) c.trim()];
  return [
    title.trim(),
    if (d.isNotEmpty) d,
    if (criteria.isNotEmpty) 'Acceptance criteria:\n${[for (final (i, c) in criteria.indexed) '${i + 1}. $c'].join('\n')}',
    taskReportRequest,
    if (criteria.isNotEmpty) taskCriteriaRequest,
  ].join('\n\n');
}

/// One acceptance criterion after a run: [met] true or false as Claude's report ticks it,
/// null when the report does not say.
class CriterionCheck {
  final String text;
  final bool? met;
  const CriterionCheck(this.text, {this.met});
  Map<String, dynamic> toJson() => {'text': text, 'met': ?met};
  static CriterionCheck? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final t = _s(j['text']);
    return t == null ? null : CriterionCheck(t, met: j['met'] is bool ? j['met'] as bool : null);
  }
}

final _checkLine = RegExp(r'^\s*(?:[-*+]|\d+[.)])?\s*(?:\[([ xX✓✔])\]|(✅|✔️|✔|☑|❌|✗|✘|☐))\s*(.+?)\s*$');

Set<String> _words(String s) =>
    {for (final w in s.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) if (w.length > 1) w};

/// Which of [criteria] Claude's [report] ticks: its checklist lines (`- [x]`, `- [ ]`, ✅,
/// ❌) matched to each criterion by wording, else by order when the checklist has as many
/// lines; a criterion the report does not mention stays unknown.
List<CriterionCheck> checkCriteria(List<String> criteria, String report) {
  final lines = <(bool, String)>[];
  for (final l in report.replaceAll('\r', '').split('\n')) {
    final m = _checkLine.firstMatch(l);
    if (m == null) continue;
    final box = m.group(1);
    final glyph = m.group(2);
    final met = box != null ? box != ' ' : !(glyph == '❌' || glyph == '✗' || glyph == '✘' || glyph == '☐');
    lines.add((met, m.group(3)!));
  }
  final out = <CriterionCheck>[];
  final used = <int>{};
  for (final (i, c) in criteria.indexed) {
    final want = _words(c);
    var best = -1;
    var bestScore = 0.0;
    for (final (j, l) in lines.indexed) {
      if (used.contains(j)) continue;
      final have = _words(l.$2);
      if (want.isEmpty || have.isEmpty) continue;
      final score = want.intersection(have).length / want.length;
      if (score > bestScore) {
        bestScore = score;
        best = j;
      }
    }
    if (best >= 0 && bestScore >= 0.6) {
      used.add(best);
      out.add(CriterionCheck(c, met: lines[best].$1));
    } else if (lines.length == criteria.length && !used.contains(i)) {
      used.add(i);
      out.add(CriterionCheck(c, met: lines[i].$1));
    } else {
      out.add(CriterionCheck(c));
    }
  }
  return out;
}

/// One item of Claude's own to-do list for a task.
class TodoItem {
  final String text;
  final bool done;
  const TodoItem(this.text, {this.done = false});
  Map<String, dynamic> toJson() => {'text': text, 'done': done};
  static TodoItem? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final t = _s(j['text']);
    return t == null ? null : TodoItem(t, done: j['done'] == true);
  }

  @override
  bool operator ==(Object other) => other is TodoItem && other.text == text && other.done == done;
  @override
  int get hashCode => Object.hash(text, done);
  @override
  String toString() => '${done ? '[x]' : '[ ]'} $text';
}

/// What the card shows in Review: Claude's report, its to-do list, the files it touched and,
/// in a git folder, a short summary of the changes since the task started.
class TaskReport {
  /// The final section of Claude's last answer for the task (the whole answer when it has
  /// no report heading).
  final String text;
  final List<TodoItem> todos;

  /// Files its edit tool calls touched, in the order first touched.
  final List<String> files;

  /// `git diff --stat` lines since the task started, plus new files; empty outside git.
  final List<String> changes;
  final int atMs;

  /// The session ended (not just its turn) before the report.
  final bool sessionEnded;

  /// The task's acceptance criteria and whether the report says each is met.
  final List<CriterionCheck> criteria;
  const TaskReport(
      {this.text = '',
      this.criteria = const [],
      this.todos = const [],
      this.files = const [],
      this.changes = const [],
      required this.atMs,
      this.sessionEnded = false});

  Map<String, dynamic> toJson() => {
        'text': text,
        if (criteria.isNotEmpty) 'criteria': [for (final c in criteria) c.toJson()],
        'todos': [for (final t in todos) t.toJson()],
        'files': files,
        'changes': changes,
        'atMs': atMs,
        if (sessionEnded) 'sessionEnded': true,
      };

  static TaskReport? tryFromJson(Object? j) {
    if (j is! Map) return null;
    return TaskReport(
      text: j['text'] is String ? j['text'] as String : '',
      criteria: [for (final c in _list(j['criteria'])) ?CriterionCheck.tryFromJson(c)],
      todos: [for (final t in _list(j['todos'])) ?TodoItem.tryFromJson(t)],
      files: [for (final f in _list(j['files'])) if (f is String) f],
      changes: [for (final c in _list(j['changes'])) if (c is String) c],
      atMs: _ms(j['atMs']) ?? 0,
      sessionEnded: j['sessionEnded'] == true,
    );
  }
}

/// A task on the board. The app writes [title], [description], [cwd], [taskType],
/// [priority] and [column]; the host owns the rest (the linked session, the report, the
/// git starting point, the last activity).
class BoardTask {
  /// Made by the device that creates it (so it can tell when the machine has it).
  final String id;
  final String title;
  final String description;

  /// The folder on the task's machine (the project's folder there).
  final String cwd;

  /// The project it belongs to (null: older tasks; matched by folder).
  final String? projectId;

  /// The machine the task is assigned to (null: not assigned yet; only that machine runs it).
  final String? machineId;

  /// What must be true when it is done, as the owner wrote it (sent to Claude, which is
  /// asked to tick them in its report).
  final List<String> acceptance;

  /// A model table row id; null: no type (the session uses the default model).
  final String? taskType;
  final TaskPriority priority;
  final TaskColumn column;
  final int createdAtMs;
  final int updatedAtMs;

  /// The session the task was sent to (host-owned).
  final String? sessionId;
  final String? sessionName;

  /// When the task (or the last notes) was sent to the session.
  final int? sentAtMs;
  final TaskReport? report;

  /// The last thing the linked session did while in progress (host-owned, not saved).
  final String? activity;
  final int? activityAtMs;

  /// The git remote of [cwd] on its machine (host-filled), for matching the project on
  /// another machine.
  final String? gitRemote;

  const BoardTask({
    required this.id,
    required this.title,
    this.description = '',
    required this.cwd,
    this.projectId,
    this.machineId,
    this.acceptance = const [],
    this.taskType,
    this.priority = TaskPriority.normal,
    this.column = TaskColumn.backlog,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
    this.sessionId,
    this.sessionName,
    this.sentAtMs,
    this.report,
    this.activity,
    this.activityAtMs,
    this.gitRemote,
  });

  BoardTask copyWith({
    String? title,
    String? description,
    String? cwd,
    String? projectId,
    String? machineId,
    bool clearMachine = false,
    List<String>? acceptance,
    String? taskType,
    bool clearTaskType = false,
    TaskPriority? priority,
    TaskColumn? column,
    int? createdAtMs,
    int? updatedAtMs,
    String? sessionId,
    String? sessionName,
    int? sentAtMs,
    TaskReport? report,
    bool clearReport = false,
    bool clearSession = false,
    String? activity,
    int? activityAtMs,
    String? gitRemote,
  }) =>
      BoardTask(
        id: id,
        title: title ?? this.title,
        description: description ?? this.description,
        cwd: cwd ?? this.cwd,
        projectId: projectId ?? this.projectId,
        machineId: clearMachine ? null : (machineId ?? this.machineId),
        acceptance: acceptance ?? this.acceptance,
        taskType: clearTaskType ? null : (taskType ?? this.taskType),
        priority: priority ?? this.priority,
        column: column ?? this.column,
        createdAtMs: createdAtMs ?? this.createdAtMs,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
        sessionId: clearSession ? null : (sessionId ?? this.sessionId),
        sessionName: clearSession ? null : (sessionName ?? this.sessionName),
        sentAtMs: clearSession ? null : (sentAtMs ?? this.sentAtMs),
        report: clearReport ? null : (report ?? this.report),
        activity: activity ?? this.activity,
        activityAtMs: activityAtMs ?? this.activityAtMs,
        gitRemote: gitRemote ?? this.gitRemote,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'cwd': cwd,
        'projectId': ?projectId,
        'machineId': ?machineId,
        if (acceptance.isNotEmpty) 'acceptance': acceptance,
        'taskType': ?taskType,
        'priority': priority.name,
        'column': column.name,
        'createdAtMs': createdAtMs,
        'updatedAtMs': updatedAtMs,
        'sessionId': ?sessionId,
        'sessionName': ?sessionName,
        'sentAtMs': ?sentAtMs,
        'report': ?report?.toJson(),
        'activity': ?activity,
        'activityAtMs': ?activityAtMs,
        'gitRemote': ?gitRemote,
      };

  static BoardTask? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id']), title = _s(j['title']);
    if (id == null || title == null) return null;
    return BoardTask(
      id: id,
      title: title,
      description: j['description'] is String ? j['description'] as String : '',
      cwd: j['cwd'] is String ? j['cwd'] as String : '',
      projectId: _s(j['projectId']),
      machineId: _s(j['machineId']),
      acceptance: [for (final a in _list(j['acceptance'])) if (a is String && a.trim().isNotEmpty) a],
      taskType: _s(j['taskType']),
      priority: _byName(TaskPriority.values, j['priority'], TaskPriority.normal),
      column: _byName(TaskColumn.values, j['column'], TaskColumn.backlog),
      createdAtMs: _ms(j['createdAtMs']) ?? 0,
      updatedAtMs: _ms(j['updatedAtMs']) ?? 0,
      sessionId: _s(j['sessionId']),
      sessionName: _s(j['sessionName']),
      sentAtMs: _ms(j['sentAtMs']),
      report: TaskReport.tryFromJson(j['report']),
      activity: _s(j['activity']),
      activityAtMs: _ms(j['activityAtMs']),
      gitRemote: _s(j['gitRemote']),
    );
  }

  /// Why [title] cannot be a task's title, or null when it can.
  static String? titleError(String title) {
    final t = title.trim();
    if (t.isEmpty) return 'Enter a title';
    if (t.length > maxTaskTitleLength) return 'At most $maxTaskTitleLength characters';
    return null;
  }
}

/// High before Normal before Low; then the oldest first.
int compareTasks(BoardTask a, BoardTask b) {
  final p = a.priority.index.compareTo(b.priority.index);
  return p != 0 ? p : a.createdAtMs.compareTo(b.createdAtMs);
}

/// One row of the model table: a task type and the model sessions of that type use.
class ModelRow {
  final String id;
  final String name;

  /// What most people use for it (shown as a hint only; never applied).
  final String hint;

  /// What it covers.
  final String covers;

  /// The model Perch passes (`--model`); null: the owner's current default (Perch passes
  /// nothing).
  final String? model;
  const ModelRow({required this.id, required this.name, this.hint = '', this.covers = '', this.model});

  ModelRow copyWith({String? name, String? model, bool clearModel = false}) => ModelRow(
      id: id, name: name ?? this.name, hint: hint, covers: covers, model: clearModel ? null : (model ?? this.model));

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, if (hint.isNotEmpty) 'hint': hint, if (covers.isNotEmpty) 'covers': covers, 'model': ?model};

  static ModelRow? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id']), name = _s(j['name']);
    if (id == null || name == null) return null;
    final model = _s(j['model']);
    return ModelRow(
        id: id,
        name: name,
        hint: j['hint'] is String ? j['hint'] as String : '',
        covers: j['covers'] is String ? j['covers'] as String : '',
        model: model != null && validModelName(model) ? model.trim() : null);
  }
}

/// Model names Perch passes on: aliases (`opus`, `sonnet[1m]`) and full ids.
bool validModelName(String m) => RegExp(r'^[A-Za-z0-9][A-Za-z0-9._\-\[\]]{0,63}$').hasMatch(m.trim());

/// The model choices the app offers (any other valid name can be typed).
const modelChoices = ['opus', 'sonnet', 'haiku'];

/// The table of task types and their models.
class ModelTable {
  final List<ModelRow> rows;

  /// When the owner last changed it (0: never: the starting table).
  final int updatedAtMs;
  const ModelTable({required this.rows, this.updatedAtMs = 0});

  /// The starting list (PRD 7.7): every row on the owner's current default.
  static const ModelTable starting = ModelTable(rows: [
    ModelRow(
        id: 'planning',
        name: 'Planning and architecture',
        covers: 'Designing an approach, breaking work down, technical decisions',
        hint: 'Strongest model'),
    ModelRow(
        id: 'debugging',
        name: 'Hard debugging and security',
        covers: 'Problems with an unclear cause; risky code',
        hint: 'Strongest model'),
    ModelRow(id: 'review', name: 'Code review', covers: 'Reviewing a diff or a finished task', hint: 'Strongest model'),
    ModelRow(id: 'feature', name: 'Feature work', covers: 'Building something to a known plan', hint: 'Everyday model'),
    ModelRow(id: 'bugfix', name: 'Bug fixes and refactoring', covers: 'Known-cause fixes, restructuring', hint: 'Everyday model'),
    ModelRow(id: 'tests', name: 'Tests and documentation', covers: 'Writing tests, docs, comments', hint: 'Everyday model'),
    ModelRow(
        id: 'chores',
        name: 'Search and chores',
        covers: 'Finding things in the codebase, summaries, renames, formatting',
        hint: 'Fastest model'),
  ]);

  ModelRow? row(String? id) => id == null ? null : rows.where((r) => r.id == id).firstOrNull;

  /// The model for a task of [taskType]; null: the default (pass nothing).
  String? modelFor(String? taskType) => row(taskType)?.model;

  /// The name of [taskType] ('No type' for none, 'Removed type' for one no longer listed).
  String nameOf(String? taskType) => taskType == null ? 'No type' : (row(taskType)?.name ?? 'Removed type');

  ModelTable withRow(ModelRow r, {required int atMs}) {
    final i = rows.indexWhere((x) => x.id == r.id);
    return ModelTable(rows: i < 0 ? [...rows, r] : [...rows.sublist(0, i), r, ...rows.sublist(i + 1)], updatedAtMs: atMs);
  }

  ModelTable without(String id, {required int atMs}) =>
      ModelTable(rows: [for (final r in rows) if (r.id != id) r], updatedAtMs: atMs);

  Map<String, dynamic> toJson() => {'rows': [for (final r in rows) r.toJson()], 'updatedAtMs': updatedAtMs};

  static ModelTable? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final rows = [for (final r in _list(j['rows'])) ?ModelRow.tryFromJson(r)];
    return ModelTable(rows: rows, updatedAtMs: _ms(j['updatedAtMs']) ?? 0);
  }
}

/// A folder on a machine and its git remote (`origin`).
class GitFolder {
  final String path;
  final String remote;
  const GitFolder({required this.path, required this.remote});
  Map<String, dynamic> toJson() => {'path': path, 'remote': remote};
  static GitFolder? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final p = _s(j['path']), r = _s(j['remote']);
    return p == null || r == null ? null : GitFolder(path: p, remote: r);
  }
}

/// One spelling for every way of writing the same remote: `git@github.com:o/r.git`,
/// `https://github.com/o/r`, `ssh://git@github.com/o/r.git` all become `github.com/o/r`
/// (lower case; credentials, ports and `.git` dropped).
String normalizeGitRemote(String url) {
  var u = url.trim();
  if (u.isEmpty) return '';
  final scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://').firstMatch(u);
  if (scheme != null) {
    u = u.substring(scheme.end);
  } else {
    // scp-like: [user@]host:path
    final m = RegExp(r'^(?:[^@/]+@)?([^:/]+):(?!//)(.*)$').firstMatch(u);
    if (m != null) u = '${m.group(1)}/${m.group(2)}';
  }
  final at = u.indexOf('@');
  final slash = u.indexOf('/');
  if (at >= 0 && (slash < 0 || at < slash)) u = u.substring(at + 1);
  final firstSlash = u.indexOf('/');
  var host = firstSlash < 0 ? u : u.substring(0, firstSlash);
  var path = firstSlash < 0 ? '' : u.substring(firstSlash + 1);
  host = host.replaceFirst(RegExp(r':\d+$'), '');
  path = path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  if (path.endsWith('.git')) path = path.substring(0, path.length - 4);
  path = path.replaceAll(RegExp(r'/+$'), '');
  return (path.isEmpty ? host : '$host/$path').toLowerCase();
}

/// The folder on another machine with the same project as [remote] (null: none). With
/// several, the one whose last segment matches [preferName] wins, else the first.
GitFolder? matchGitFolder(String? remote, List<GitFolder> folders, {String? preferName}) {
  if (remote == null || remote.isEmpty) return null;
  final want = normalizeGitRemote(remote);
  final same = [for (final f in folders) if (normalizeGitRemote(f.remote) == want) f];
  if (same.isEmpty) return null;
  if (preferName != null) {
    final name = preferName.toLowerCase();
    for (final f in same) {
      final parts = f.path.split(RegExp(r'[\\/]+')).where((p) => p.isNotEmpty);
      if (parts.isNotEmpty && parts.last.toLowerCase() == name) return f;
    }
  }
  return same.first;
}

/// The final section of Claude's answer: from the last heading that says "Report" (a
/// markdown heading, a bold line, or a line starting `Report:`) to the end; without one,
/// the whole answer.
String reportSection(String answer) {
  final lines = answer.replaceAll('\r', '').split('\n');
  final heading = RegExp(r'^\s{0,3}(#{1,6}\s+.*report.*|\*\*[^*]*report[^*]*\*\*.*|report\s*:.*|report\s*)$',
      caseSensitive: false);
  for (var i = lines.length - 1; i >= 0; i--) {
    if (heading.hasMatch(lines[i])) return lines.sublist(i).join('\n').trim();
  }
  return answer.trim();
}

/// The tools whose calls change a file, and the input field naming it.
const _editTools = {'Edit': 'file_path', 'Write': 'file_path', 'MultiEdit': 'file_path', 'NotebookEdit': 'notebook_path'};

/// Assembles the Review report from a session's events since the task was sent: the final
/// section of Claude's last answer, its to-do list (the last `TodoWrite`, or its
/// `TaskCreate`/`TaskUpdate` calls) with the finished items ticked, and the files its edit
/// tool calls touched (subagents' too).
TaskReport buildTaskReport(List<ConversationEvent> events,
    {required int atMs, List<String> changes = const [], bool sessionEnded = false, List<String> acceptance = const []}) {
  final sorted = [...events]..sort((a, b) => a.seq.compareTo(b.seq));
  String? last;
  List<TodoItem>? todoWrite;
  // TaskCreate items in order: [id, text, done]. The id is a guess (1, 2, …) until the
  // tool's result says which number Claude Code gave it.
  final items = <List<Object>>[];
  final created = <String, List<Object>>{}; // tool use id -> item
  final files = <String>[];
  for (final e in sorted) {
    switch (e) {
      case AssistantText(:final text) when e.parentToolUseId == null && text.trim().isNotEmpty:
        last = text;
      case ToolCall(:final name, :final input, :final toolUseId):
        final field = _editTools[name];
        if (field != null) {
          final f = input[field];
          if (f is String && f.isNotEmpty && !files.contains(f)) files.add(f);
        }
        if (e.parentToolUseId != null) break;
        if (name == 'TodoWrite') {
          todoWrite = [
            for (final t in _list(input['todos']))
              if (t is Map && _s(t['content']) != null) TodoItem(t['content'] as String, done: t['status'] == 'completed')
          ];
        } else if (name == 'TaskCreate') {
          final subject = _s(input['subject']) ?? _s(input['description']);
          if (subject != null) {
            final item = <Object>['${items.length + 1}', subject, false];
            items.add(item);
            created[toolUseId] = item;
          }
        } else if (name == 'TaskUpdate') {
          final id = '${input['taskId'] ?? ''}'.replaceFirst('#', '');
          final item = items.where((x) => x[0] == id).firstOrNull;
          if (item == null) break;
          final status = input['status'];
          if (status == 'deleted') {
            items.remove(item);
          } else {
            if (_s(input['subject']) != null) item[1] = input['subject'] as String;
            if (status != null) item[2] = status == 'completed';
          }
        }
      case ToolResult(:final toolUseId, :final text):
        // "Task #3 created successfully: …": the id TaskUpdate uses.
        final item = created.remove(toolUseId);
        final m = RegExp(r'#(\d+)').firstMatch(text);
        if (item != null && m != null) item[0] = m.group(1)!;
      default:
        break;
    }
  }
  final text = last == null ? '' : reportSection(last);
  return TaskReport(
    text: text,
    criteria: acceptance.isEmpty ? const [] : checkCriteria(acceptance, last ?? ''),
    todos: todoWrite ?? [for (final x in items) TodoItem(x[1] as String, done: x[2] as bool)],
    files: files,
    changes: changes,
    atMs: atMs,
    sessionEnded: sessionEnded,
  );
}


// ---------------------------------------------------------------- projects

/// A path as a key: forward slashes, no trailing slash, case folded (Windows and macOS
/// fold case; a project's folder is matched the same way on every machine).
String folderKey(String path) {
  var p = path.trim().replaceAll('\\', '/');
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p.toLowerCase();
}

/// The id of a project Perch made on its own (from tasks made before projects): the same on
/// every device, so two devices grouping the same tasks agree.
String autoProjectId({String? remote, String? machineId, String? folder}) {
  final key = remote != null && remote.trim().isNotEmpty
      ? 'r:${normalizeGitRemote(remote)}'
      : 'f:$machineId:${folderKey(folder ?? '')}';
  var h = 0x811c9dc5;
  for (final c in key.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return 'p-auto-${h.toRadixString(36)}';
}

/// A project: machine-agnostic (a name, its git remote) and, per machine, the folder where
/// it lives there (a project may be on one machine only).
class Project {
  final String id;
  final String name;

  /// What it is (optional: an idea project may have only a name and this).
  final String? description;

  /// Its git remote (`origin`), for finding its folder on another machine.
  final String? gitRemote;

  /// Machine id -> the project's folder on that machine.
  final Map<String, String> folders;

  /// Made by Perch from tasks that existed before projects (renaming it makes it the owner's).
  final bool auto;
  final int createdAtMs;
  const Project(
      {required this.id,
      required this.name,
      this.description,
      this.gitRemote,
      this.folders = const {},
      this.auto = false,
      this.createdAtMs = 0});

  String? folderOn(String machineId) => folders[machineId];

  Project withFolder(String machineId, String? folder) => Project(
      id: id,
      name: name,
      description: description,
      gitRemote: gitRemote,
      folders: {
        for (final e in folders.entries)
          if (e.key != machineId) e.key: e.value,
        if (folder != null && folder.trim().isNotEmpty) machineId: folder.trim(),
      },
      auto: auto,
      createdAtMs: createdAtMs);

  Project copyWith(
          {String? name,
          String? description,
          bool clearDescription = false,
          String? gitRemote,
          bool clearRemote = false,
          bool? auto}) =>
      Project(
      id: id,
      name: name ?? this.name,
      description: clearDescription ? null : (description ?? this.description),
      gitRemote: clearRemote ? null : (gitRemote ?? this.gitRemote),
      folders: folders,
      auto: auto ?? this.auto,
      createdAtMs: createdAtMs);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': ?description,
        'gitRemote': ?gitRemote,
        'folders': folders,
        if (auto) 'auto': true,
        'createdAtMs': createdAtMs,
      };

  static Project? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id']), name = _s(j['name']);
    if (id == null || name == null) return null;
    final f = j['folders'];
    return Project(
      id: id,
      name: name.trim(),
      description: _s(j['description']),
      gitRemote: _s(j['gitRemote']),
      folders: {
        if (f is Map)
          for (final e in f.entries)
            if (e.key is String && e.value is String && (e.value as String).trim().isNotEmpty) e.key as String: e.value as String
      },
      auto: j['auto'] == true,
      createdAtMs: _ms(j['createdAtMs']) ?? 0,
    );
  }

  /// Why [name] cannot be a project's name, or null when it can.
  static String? nameError(String name) {
    final t = name.trim();
    if (t.isEmpty) return 'Enter a name';
    if (t.length > 60) return 'At most 60 characters';
    return null;
  }
}

/// Every project, kept on the phone and synced to every machine like the model table: the
/// newer list wins on either side.
class ProjectList {
  final List<Project> projects;
  final int updatedAtMs;
  const ProjectList({this.projects = const [], this.updatedAtMs = 0});

  Project? byId(String? id) => id == null ? null : projects.where((p) => p.id == id).firstOrNull;

  /// The project [task] (on [machineId]) belongs to: its project id, else the project whose
  /// folder on that machine is the task's folder.
  Project? projectOf(BoardTask task, String machineId) {
    final byTask = byId(task.projectId);
    if (byTask != null) return byTask;
    final key = folderKey(task.cwd);
    if (key.isEmpty) return null;
    for (final p in projects) {
      final f = p.folderOn(machineId);
      if (f != null && folderKey(f) == key) return p;
    }
    return null;
  }

  ProjectList withProject(Project p, {required int atMs}) {
    final i = projects.indexWhere((x) => x.id == p.id);
    return ProjectList(
        projects: i < 0 ? [...projects, p] : [...projects.sublist(0, i), p, ...projects.sublist(i + 1)], updatedAtMs: atMs);
  }

  ProjectList without(String id, {required int atMs}) =>
      ProjectList(projects: [for (final p in projects) if (p.id != id) p], updatedAtMs: atMs);

  Map<String, dynamic> toJson() => {'projects': [for (final p in projects) p.toJson()], 'updatedAtMs': updatedAtMs};

  static ProjectList? tryFromJson(Object? j) {
    if (j is! Map) return null;
    return ProjectList(
        projects: [for (final p in _list(j['projects'])) ?Project.tryFromJson(p)], updatedAtMs: _ms(j['updatedAtMs']) ?? 0);
  }
}

/// The last segment of a folder path.
String _lastFolder(String cwd) {
  final parts = cwd.split(RegExp(r'[\\/]+')).where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? cwd : parts.last;
}

/// Tasks made before projects existed, grouped into projects: each task with no project
/// joins the project with the same git remote that has no folder on its machine yet, else a
/// new project named after its folder (Perch-made, with an id every device computes the
/// same). Perch-made projects with the same remote on different machines are merged.
/// Tasks that name a project (made since) are left alone. Null: nothing changed.
ProjectList? groupIntoProjects(ProjectList list, Iterable<(String machineId, BoardTask task)> tasks, {required int atMs}) {
  var l = list;
  var changed = false;
  for (final (m, t) in tasks) {
    if (t.projectId != null || t.cwd.trim().isEmpty) continue;
    final p = l.projectOf(t, m);
    final r = t.gitRemote;
    if (p != null) {
      if (p.gitRemote == null && r != null) {
        l = l.withProject(p.copyWith(gitRemote: r), atMs: atMs);
        changed = true;
      }
      continue;
    }
    final same = r == null
        ? null
        : l.projects
            .where((p) => p.gitRemote != null && normalizeGitRemote(p.gitRemote!) == normalizeGitRemote(r) && p.folderOn(m) == null)
            .firstOrNull;
    if (same != null) {
      l = l.withProject(same.withFolder(m, t.cwd), atMs: atMs);
    } else {
      var id = autoProjectId(remote: r, machineId: m, folder: t.cwd);
      if (l.byId(id) != null) id = autoProjectId(machineId: m, folder: t.cwd);
      final name = _lastFolder(t.cwd);
      l = l.withProject(
          Project(
              id: id,
              name: name.isEmpty ? t.cwd : name,
              gitRemote: r,
              folders: {m: t.cwd},
              auto: true,
              createdAtMs: atMs),
          atMs: atMs);
    }
    changed = true;
  }
  // Two Perch-made projects of one remote on different machines are one project.
  for (var i = 0; i < l.projects.length; i++) {
    final a = l.projects[i];
    if (!a.auto || a.gitRemote == null) continue;
    for (var j = i + 1; j < l.projects.length; j++) {
      final b = l.projects[j];
      if (!b.auto || b.gitRemote == null || normalizeGitRemote(a.gitRemote!) != normalizeGitRemote(b.gitRemote!)) continue;
      if (b.folders.keys.any(a.folders.containsKey)) continue;
      var merged = a;
      for (final e in b.folders.entries) {
        merged = merged.withFolder(e.key, e.value);
      }
      l = l.withProject(merged, atMs: atMs).without(b.id, atMs: atMs);
      changed = true;
      return groupIntoProjects(l, const [], atMs: atMs) ?? l;
    }
  }
  return changed ? l : null;
}
