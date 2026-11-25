// What `/perch` (the Perch menu inside a Claude Code terminal session) asks the host, over
// loopback only (`/local/perch/<action>`, see PerchServer): the whole board (every project,
// every live task, assigned to any machine or to none) grouped by project, the project of
// the session's folder first; and the board's actions
// for that session: start a task in it (the same Run as from the phone, except that the
// menu sends the message itself), add a task to the folder's project, move a task, and
// finish one into Review or Done with the session's report.
//
// The menu draws what it is given: the grouping, the order, the labels and the counts are
// decided here, so they are tested here.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:perch_protocol/perch_protocol.dart';

import 'host_board.dart';
import 'session_manager.dart' show NoSuchSession;
import 'task_board.dart';

/// The labels the menu shows for the columns (as the app's chips name them).
const columnLabels = {
  TaskColumn.backlog: 'Backlog',
  TaskColumn.ready: 'Ready',
  TaskColumn.inProgress: 'In progress',
  TaskColumn.review: 'Review',
  TaskColumn.done: 'Done',
};

const priorityLabels = {TaskPriority.high: 'High', TaskPriority.normal: 'Normal', TaskPriority.low: 'Low'};

/// A request the menu got wrong, or one the board refused: its message is shown as is.
class LocalBoardError implements Exception {
  final int status;
  final String message;
  LocalBoardError(this.message, {this.status = 400});
  @override
  String toString() => message;
}

String _newTaskId() {
  final r = Random.secure();
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  return 'task-${List.generate(12, (_) => chars[r.nextInt(chars.length)]).join()}';
}

/// Whether [folder] is [cwd] or one of its parents (folders compared as keys).
bool folderHolds(String folder, String cwd) {
  final f = folderKey(folder), c = folderKey(cwd);
  if (f.isEmpty || c.isEmpty) return false;
  return c == f || c.startsWith(f.endsWith('/') ? f : '$f/');
}

String _baseName(String path) {
  final parts = path.replaceAll('\\', '/').split('/').where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

/// A project as the menu shows it: a real one (from the synced list), or the folder of tasks
/// that belong to none yet.
class _Group {
  final String id;
  final String name;
  final String folder;
  final bool real;
  final List<BoardTask> tasks = [];
  _Group(this.id, this.name, this.folder, {required this.real});
}

/// What a task assigned to no machine shows where the machine's name goes.
const notAssignedLabel = 'Not assigned';

/// What a task assigned to another machine shows (this host knows only its own name).
const otherMachineLabel = 'Another machine';

class LocalBoard {
  final TaskBoard board;

  /// The session with a Claude Code session id (null: Perch does not see it).
  final Future<SessionSummary?> Function(String claudeId) sessionFor;
  final String Function() machineId;
  final String Function() machineName;
  final ModelTable Function() modelTable;
  final String Function() newId;

  LocalBoard({
    required this.board,
    required this.sessionFor,
    required this.machineId,
    required this.machineName,
    ModelTable Function()? modelTable,
    String Function()? newId,
  })  : modelTable = modelTable ?? (() => modelTableOf(board.board.board) ?? ModelTable.starting),
        newId = newId ?? _newTaskId;

  HostBoard get _host => board.board;

  /// Every live task on the board (any machine, or none).
  List<BoardTask> get _allTasks {
    final mine = {for (final t in board.tasks) t.id: t}; // with git remotes and activity
    return [for (final t in _host.board.liveTasks) mine[t.id] ?? t];
  }

  /// Every project on the board, and the one [cwd] is in (even with no project or task).
  List<_Group> _groups(String cwd) {
    final mid = machineId();
    final list = ProjectList(projects: _host.board.projects);
    final groups = <String, _Group>{};
    _Group? here;
    var hereLength = -1;
    for (final p in list.projects) {
      final f = p.folderOn(mid);
      final g = groups[p.id] = _Group(p.id, p.name, f ?? '', real: true);
      if (f != null && folderHolds(f, cwd) && folderKey(f).length > hereLength) {
        here = g;
        hereLength = folderKey(f).length;
      }
    }
    for (final t in _allTasks) {
      final p = list.projectOf(t, mid);
      _Group g;
      if (p != null) {
        g = groups.putIfAbsent(p.id, () => _Group(p.id, p.name, p.folderOn(mid) ?? t.cwd, real: true));
      } else {
        final id = autoProjectId(remote: t.gitRemote, machineId: mid, folder: t.cwd);
        g = groups.putIfAbsent(id, () => _Group(id, _baseName(t.cwd), t.cwd, real: false));
        if (here == null || !here.real) {
          if (folderHolds(t.cwd, cwd) && folderKey(t.cwd).length > hereLength) {
            here = g;
            hereLength = folderKey(t.cwd).length;
          }
        }
      }
      g.tasks.add(t);
    }
    if (here == null && cwd.trim().isNotEmpty) {
      final id = autoProjectId(machineId: mid, folder: cwd);
      here = groups.putIfAbsent(id, () => _Group(id, _baseName(cwd), cwd, real: false));
    }
    final rest = [for (final g in groups.values) if (g != here && (g.real || g.tasks.isNotEmpty)) g]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return [?here, ...rest];
  }

  Map<String, dynamic> _task(BoardTask t, {SessionSummary? session}) {
    final table = modelTable();
    return {
      ...t.toJson(),
      'columnLabel': columnLabels[t.column],
      'priorityLabel': priorityLabels[t.priority],
      'typeLabel': t.taskType == null ? null : (table.row(t.taskType)?.name ?? 'Removed type'),
      'machine': t.machineId == null
          ? notAssignedLabel
          : t.machineId == machineId()
              ? machineName()
              : otherMachineLabel,
      'assigned': t.machineId != null,
      'linkedHere': session != null && t.sessionId == session.id,
      // As on the board: a task is started from Backlog or Ready (Review has notes back).
      'canStart': t.column == TaskColumn.backlog || t.column == TaskColumn.ready,
    };
  }

  Future<SessionSummary?> _session(String claudeId) async => claudeId.isEmpty ? null : sessionFor(claudeId);

  Future<SessionSummary> _requireSession(String claudeId) async =>
      await _session(claudeId) ??
      (throw LocalBoardError(
          'Perch does not see this session yet. Check that the Perch host runs and its hooks are installed '
          '(perch_host hooks status), then open /perch again.',
          status: 409));

  /// Everything the menu shows: the machine, this session as Perch knows it, the projects
  /// (this folder's first) with their tasks by column, and the task types for a new task.
  Future<Map<String, dynamic>> view({required String claudeId, required String cwd}) async {
    final s = await _session(claudeId);
    final groups = _groups(cwd);
    return {
      'machine': machineName(),
      'cwd': cwd,
      'session': s == null ? null : {'id': s.id, 'name': s.name, 'state': s.state.name, 'live': s.live},
      'projects': [
        for (final (i, g) in groups.indexed)
          {
            'id': g.id,
            'name': g.name,
            'folder': g.folder,
            'here': i == 0 && folderHolds(g.folder, cwd),
            'count': g.tasks.length,
            'columns': [
              for (final c in TaskColumn.values)
                {
                  'column': c.name,
                  'label': columnLabels[c],
                  'tasks': [
                    for (final t in [...g.tasks.where((t) => t.column == c)]..sort(compareTasks)) _task(t, session: s)
                  ],
                }
            ],
          }
      ],
      'columns': [for (final c in TaskColumn.values) {'column': c.name, 'label': columnLabels[c]}],
      'taskTypes': [for (final r in modelTable().rows) {'id': r.id, 'label': r.name}],
      'priorities': [for (final p in TaskPriority.values) {'id': p.name, 'label': priorityLabels[p]}],
    };
  }

  BoardTask _taskById(String id) =>
      _allTasks.where((t) => t.id == id).firstOrNull ?? (throw LocalBoardError('This task no longer exists.', status: 404));

  /// Assigns [t] to this machine in [session]'s folder (saved as the project's folder here
  /// when it has none), unless it is already this machine's.
  void _assignHere(BoardTask t, SessionSummary session) {
    final mid = machineId();
    if (t.machineId == mid && t.cwd.trim().isNotEmpty) return;
    final pr = t.projectId == null ? null : _host.board.get(RecordKinds.project, t.projectId!);
    final project = pr == null || pr.deleted ? null : projectOf(pr);
    final folder = project?.folderOn(mid);
    final cwd = folder != null && folderHolds(folder, session.cwd) ? folder : session.cwd;
    if (project != null && folder == null) {
      _host.edit(RecordKinds.project, project.id, {
        folderGroup(mid): {'path': session.cwd}
      });
    }
    _host.edit(RecordKinds.task, t.id, {'content': taskContent(t.copyWith(machineId: mid, cwd: cwd))});
  }

  /// Starts [taskId] in this session: the task is assigned to this machine (in the session's
  /// folder) when it is not yet, and the card goes to In progress linked to the session,
  /// exactly as a Run into an existing session from the phone; the answer carries the
  /// message the menu sends into the conversation itself.
  Future<Map<String, dynamic>> start({required String taskId, required String claudeId}) async {
    final s = await _requireSession(claudeId);
    _assignHere(_taskById(taskId), s);
    final t = await board.run(taskId, sessionId: s.id, deliver: false);
    return {'task': _task(t, session: s), 'prompt': TaskBoard.promptFor(t)};
  }

  /// Adds a task to the project of [cwd] (its folder there), or to [cwd] itself.
  Future<Map<String, dynamic>> add(Map<String, dynamic> body, {required String cwd, required String claudeId}) async {
    final title = body['title'] is String ? (body['title'] as String).trim() : '';
    final err = BoardTask.titleError(title);
    if (err != null) throw LocalBoardError(err);
    final here = _groups(cwd).firstOrNull;
    final folder = here != null && folderHolds(here.folder, cwd) ? here.folder : cwd;
    final acceptance = switch (body['acceptance']) {
      final List<dynamic> l => [for (final a in l) if (a is String) a],
      final String s => s.split('\n'),
      _ => const <String>[],
    };
    final type = body['taskType'] is String && modelTable().row(body['taskType'] as String) != null ? body['taskType'] as String : null;
    final priority = TaskPriority.values.where((p) => p.name == body['priority']).firstOrNull ?? TaskPriority.normal;
    final column = switch (body['column']) {
      'ready' => TaskColumn.ready,
      _ => TaskColumn.backlog,
    };
    // Every task belongs to a project: the folder's, else a Perch-made one for the folder.
    String projectId;
    if (here != null && here.real && folderHolds(here.folder, cwd)) {
      projectId = here.id;
    } else {
      final mid = machineId();
      projectId = autoProjectId(machineId: mid, folder: folder);
      final had = _host.board.get(RecordKinds.project, projectId);
      if (had == null || had.deleted) {
        _host.edit(RecordKinds.project, projectId, {
          ...projectGroupValues(Project(
              id: projectId,
              name: _baseName(folder),
              folders: {mid: folder},
              auto: true,
              createdAtMs: DateTime.now().millisecondsSinceEpoch)),
          if (had != null) 'life': {'deleted': false},
        });
      }
    }
    final BoardTask t;
    try {
      t = await board.save(BoardTask(
        id: newId(),
        title: title,
        description: body['description'] is String ? (body['description'] as String).trim() : '',
        cwd: folder,
        projectId: projectId,
        acceptance: acceptance,
        taskType: type,
        priority: priority,
        column: column,
      ));
    } on ArgumentError catch (e) {
      throw LocalBoardError('${e.message}');
    }
    return {'task': _task(t, session: await _session(claudeId))};
  }

  Future<Map<String, dynamic>> move({required String taskId, required String column, required String claudeId}) async {
    final c = TaskColumn.values.where((c) => c.name == column).firstOrNull ?? (throw LocalBoardError('Unknown column.'));
    final had = _taskById(taskId);
    if (had.machineId == machineId()) {
      board.move(taskId, c);
    } else {
      _host.edit(RecordKinds.task, taskId, {
        'column': {'column': c.name}
      });
    }
    return {'task': _task(_taskById(taskId), session: await _session(claudeId))};
  }

  /// Review or Done, with this session's report.
  Future<Map<String, dynamic>> finish({required String taskId, required String column, required String claudeId}) async {
    final c = switch (column) {
      'review' => TaskColumn.review,
      'done' => TaskColumn.done,
      _ => throw LocalBoardError('A task is finished into Review or Done.'),
    };
    final s = await _requireSession(claudeId);
    _assignHere(_taskById(taskId), s);
    final t = await board.finishIn(taskId, s.id, c);
    return {'task': _task(t, session: s)};
  }

  /// Answers one `/local/perch/<action>` request (the server checked where it came from).
  /// GET `board?session=&cwd=`; POST `start`, `add`, `move`, `finish` with a JSON body
  /// holding `session` and `cwd` beside the action's fields.
  Future<({int status, Map<String, dynamic> body})> handle(String action, String method,
      Map<String, String> query, String bodyText) async {
    try {
      if (action == 'board') {
        if (method != 'GET') throw LocalBoardError('Use GET.', status: 405);
        return (status: 200, body: await view(claudeId: query['session'] ?? '', cwd: query['cwd'] ?? ''));
      }
      if (method != 'POST') throw LocalBoardError('Use POST.', status: 405);
      Map<String, dynamic> body;
      try {
        final j = jsonDecode(bodyText.isEmpty ? '{}' : bodyText);
        if (j is! Map) throw const FormatException();
        body = j.cast<String, dynamic>();
      } on FormatException {
        throw LocalBoardError('The request is not a JSON object.');
      }
      String str(String k) => body[k] is String ? body[k] as String : '';
      final sid = str('session');
      final out = switch (action) {
        'start' => await start(taskId: str('taskId'), claudeId: sid),
        'add' => await add(body, cwd: str('cwd'), claudeId: sid),
        'move' => await move(taskId: str('taskId'), column: str('column'), claudeId: sid),
        'finish' => await finish(taskId: str('taskId'), column: str('column'), claudeId: sid),
        _ => throw LocalBoardError('Unknown action.', status: 404),
      };
      return (status: 200, body: out);
    } on LocalBoardError catch (e) {
      return (status: e.status, body: {'error': e.message});
    } on NoSuchSession {
      return (status: 409, body: {'error': 'Perch does not see this session yet.'});
    } on StateError catch (e) {
      return (status: 409, body: {'error': e.message});
    } on ArgumentError catch (e) {
      return (status: 400, body: {'error': '${e.message}'});
    } on FileSystemException catch (e) {
      return (status: 500, body: {'error': e.message});
    }
  }
}
