// The task board's words and rules, shared by the screens and the tests. Since the
// projects-first board (2026-11-24) the board is the device's own copy (BoardFile): every
// project and every task, assigned to a machine or to none; a machine is chosen only when a
// task runs (Run on…).
import 'dart:async';

import 'package:perch_protocol/perch_protocol.dart';

import '../connection/board_file.dart';
import '../connection/board_store.dart' show BoardFilters, BoardStore;
import '../connection/host_connection.dart';

/// What a task assigned to no machine shows where the machine's name goes.
const notAssignedLabel = 'Not assigned';

/// The note under the column chips while edits made here have reached no machine and not
/// the relay.
const savedOnPhoneNote = 'Saved on this phone; syncs when a machine or the relay is reachable';

/// A task and the connection of the machine it is assigned to (null: not assigned, or a
/// machine this device is not paired with).
class BoardItem {
  final BoardTask task;
  final HostConnection? connection;
  const BoardItem(this.task, [this.connection]);
  String? get machineId => task.machineId;

  /// The project the task belongs to (its own; an older task's by its folder there).
  Project? projectIn(ProjectList projects) =>
      projects.byId(task.projectId) ?? (task.machineId == null ? null : projects.projectOf(task, task.machineId!));
}

/// The connection of [machineId] among [all] (null: none).
HostConnection? connectionOf(Iterable<HostConnection> all, String? machineId) =>
    machineId == null ? null : all.where((c) => c.machine.id == machineId).firstOrNull;

/// The name of the machine a task is assigned to, or "Not assigned".
String assignedLabel(BoardTask t, Iterable<HostConnection> all) {
  if (t.machineId == null) return notAssignedLabel;
  final c = connectionOf(all, t.machineId);
  return c == null ? 'Another machine' : (c.displayName.value);
}

/// The host still speaks only the task messages (an older Perch): edits to its tasks go
/// through them.
bool olderHost(HostConnection? c) =>
    c != null && c.link.value == LinkState.online && !c.boardSync && c.supportsTasks;

/// Whether [cwd] is the [folder] or inside it (folders compared as keys).
bool folderHolds(String folder, String cwd) {
  final f = folderKey(folder), c = folderKey(cwd);
  if (f.isEmpty || c.isEmpty) return false;
  return c == f || c.startsWith(f.endsWith('/') ? f : '$f/');
}

/// The project a session in [cwd] on [machineId] works in: the one whose folder there holds
/// it most closely; null when none does.
Project? projectForFolder(ProjectList projects, String machineId, String cwd) {
  Project? best;
  var length = -1;
  for (final p in projects.projects) {
    final f = p.folderOn(machineId);
    if (f == null || !folderHolds(f, cwd)) continue;
    if (folderKey(f).length > length) {
      best = p;
      length = folderKey(f).length;
    }
  }
  return best;
}

/// What `/perch` picked in a session's composer does in the app: the board shows the
/// session's project (every machine it is on), or this machine's tasks when the folder is
/// in no project. Returns the project, if any.
Future<Project?> focusBoardOn(BoardFilters store, {required String machineId, required String cwd}) async {
  final p = projectForFolder(store.projects, machineId, cwd);
  await store.setProjectFilter(p?.id);
  await store.setFilter(p == null ? machineId : null);
  return p;
}

String columnLabel(TaskColumn c) => switch (c) {
      TaskColumn.backlog => 'Backlog',
      TaskColumn.ready => 'Ready',
      TaskColumn.inProgress => 'In progress',
      TaskColumn.review => 'Review',
      TaskColumn.done => 'Done',
    };

String priorityLabel(TaskPriority p) => switch (p) {
      TaskPriority.high => 'High',
      TaskPriority.normal => 'Normal',
      TaskPriority.low => 'Low',
    };

/// Every live task on the board, with what only its machine knows now (what its session
/// does) from that machine's connection.
List<BoardItem> boardItems(BoardStore store, Iterable<HostConnection> all) {
  final b = store.file?.board;
  if (b == null) return const [];
  final out = <BoardItem>[];
  for (final t in b.liveTasks) {
    final c = connectionOf(all, t.machineId);
    final live = c?.tasks.value?.where((x) => x.id == t.id).firstOrNull;
    out.add(BoardItem(
        live == null ? t : t.copyWith(activity: live.activity, activityAtMs: live.activityAtMs, gitRemote: live.gitRemote), c));
  }
  return out;
}

/// The board's tasks in [column] (only [machineFilter]'s when set, only [projectFilter]'s
/// when set), High first, then the oldest.
List<BoardItem> boardColumn(List<BoardItem> items, TaskColumn column,
        {String? machineFilter, String? projectFilter, ProjectList projects = const ProjectList()}) =>
    [
      for (final i in items)
        if (i.task.column == column &&
            (machineFilter == null || i.task.machineId == machineFilter) &&
            (projectFilter == null || i.projectIn(projects)?.id == projectFilter))
          i
    ]..sort((a, b) => compareTasks(a.task, b.task));

/// Whether [c]'s host has said which projects it has (or had time to: an older host never
/// does).
bool projectsSettled(HostConnection c, {DateTime? now}) {
  if (c.hostProjects.value != null) return true;
  final since = c.onlineSince;
  return since != null && (now ?? DateTime.now()).difference(since) >= c.boardGrace;
}

/// A new task id: made on the device that writes it down.
String newTaskId() => 'task-${base64UrlNoPad(randomBytes(9)).replaceAll(RegExp(r'[^A-Za-z0-9]'), 'x')}';

/// What a task's menu offers, in order.
enum TaskMenuItem { open, runOn, notes, done, moveColumn, edit, share, duplicate, delete }

List<TaskMenuItem> taskMenuItems(BoardTask t) => [
      TaskMenuItem.open,
      if (t.column != TaskColumn.inProgress) TaskMenuItem.runOn,
      if (t.column == TaskColumn.review && t.sessionId != null) TaskMenuItem.notes,
      if (t.column == TaskColumn.review) TaskMenuItem.done,
      TaskMenuItem.moveColumn,
      TaskMenuItem.edit,
      TaskMenuItem.share,
      TaskMenuItem.duplicate,
      TaskMenuItem.delete,
    ];

String taskMenuLabel(TaskMenuItem i) => switch (i) {
      TaskMenuItem.open => 'Open',
      TaskMenuItem.runOn => 'Run on…',
      TaskMenuItem.notes => 'Send notes back…',
      TaskMenuItem.done => 'Done',
      TaskMenuItem.moveColumn => 'Move to a column…',
      TaskMenuItem.edit => 'Edit…',
      TaskMenuItem.share => 'Share',
      TaskMenuItem.duplicate => 'Duplicate',
      TaskMenuItem.delete => 'Delete…',
    };

/// A copy of [t] to work on separately: a new id, no machine, no folder, no session or
/// report; a task in progress or in review starts again as Ready.
BoardTask duplicateOf(BoardTask t, {String? id, int? nowMs}) => BoardTask(
      id: id ?? newTaskId(),
      title: t.title,
      description: t.description,
      cwd: '',
      projectId: t.projectId,
      acceptance: t.acceptance,
      taskType: t.taskType,
      priority: t.priority,
      column: switch (t.column) {
        TaskColumn.inProgress || TaskColumn.review => TaskColumn.ready,
        final c => c,
      },
      createdAtMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
    );

/// "3 min ago", "just now", "2 h ago", "yesterday".
String agoLabel(int atMs, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(DateTime.fromMillisecondsSinceEpoch(atMs));
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes < 1 ? 1 : d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays == 1) return 'yesterday';
  return '${d.inDays} days ago';
}

/// The model a row uses, as the table shows it.
String modelLabel(String? model) => model ?? 'Default';

// ---------------------------------------------------------------- actions

/// The board's edits: into the device's own board (every machine and the relay get them),
/// or, for a task on a machine that still runs an older Perch, through its task messages.
class BoardActions {
  final BoardStore store;
  final List<HostConnection> all;
  const BoardActions(this.store, this.all);

  BoardFile get _file => store.file ?? (throw StateError('The board is not loaded yet.'));

  HostConnection? _older(BoardTask t) {
    final c = connectionOf(all, t.machineId);
    return olderHost(c) ? c : null;
  }

  /// A new task (Backlog unless [t] says otherwise; no machine) or an edit of its content.
  Future<void> save(BoardTask t, {required bool isNew}) async {
    final old = _older(t);
    if (old != null) return old.saveTask(t);
    final f = _file;
    if (isNew) {
      f.edit(RecordKinds.task, t.id, {
        'content': taskContent(t),
        'column': taskColumn(t),
      });
    } else {
      f.edit(RecordKinds.task, t.id, {'content': taskContent(t)});
    }
  }

  Future<void> move(BoardTask t, TaskColumn column) async {
    final old = _older(t);
    if (old != null) return old.moveTask(t.id, column);
    _file.edit(RecordKinds.task, t.id, {
      'column': {'column': column.name}
    });
  }

  /// Deletes [t] (it goes to the bin; Restore brings it back).
  Future<void> delete(BoardTask t) async {
    final old = _older(t);
    if (old != null) return old.deleteTask(t.id);
    _file.edit(RecordKinds.task, t.id, {
      'life': {'deleted': true, 'deletedAtMs': DateTime.now().millisecondsSinceEpoch}
    });
  }

  /// A copy of [t] with no machine.
  BoardTask duplicate(BoardTask t) {
    final copy = duplicateOf(t);
    _file.edit(RecordKinds.task, copy.id, {'content': taskContent(copy), 'column': taskColumn(copy)});
    return copy;
  }

  /// Assigns [t] to [c]'s machine in [cwd] (saved even while the machine is offline).
  void assign(BoardTask t, HostConnection c, String cwd) {
    _file.edit(RecordKinds.task, t.id, {'content': taskContent(t.copyWith(machineId: c.machine.id, cwd: cwd))});
  }

  /// Run on…: assigns [t] to [c] in [cwd], waits until that machine has it (or 3 s), then
  /// runs it there (a new session, or [sessionId]).
  Future<void> runOn(BoardTask t, HostConnection c, String cwd, {String? sessionId, Duration wait = const Duration(seconds: 3)}) async {
    final assigned = t.copyWith(machineId: c.machine.id, cwd: cwd);
    if (olderHost(c)) {
      // An older host keeps its tasks itself: it gets the task with the old messages.
      if ((c.tasks.value ?? const []).every((x) => x.id != t.id)) await c.saveTask(assigned);
      await c.runTask(t.id, sessionId: sessionId);
      return;
    }
    assign(t, c, cwd);
    bool has() => (c.tasks.value ?? const <BoardTask>[]).any((x) => x.id == t.id && x.cwd == cwd);
    if (!has()) {
      final done = Completer<void>();
      void check() {
        if (has() && !done.isCompleted) done.complete();
      }

      c.tasks.addListener(check);
      try {
        await done.future.timeout(wait, onTimeout: () {});
      } finally {
        c.tasks.removeListener(check);
      }
    }
    await c.runTask(t.id, sessionId: sessionId);
  }
}
