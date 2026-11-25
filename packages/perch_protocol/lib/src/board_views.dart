// Tasks, projects and the model table as board records, and back
// (docs/superpowers/plans/2026-11-24-projects-first-board.md, Task 3).
//
// Task groups: content (title, description, acceptance, taskType, priority, projectId,
// machineId, cwd, createdAtMs), column (column), run (sessionId, sessionName, sentAtMs,
// report, gitRemote: only the assigned machine writes it), life (deleted, deletedAtMs,
// deletedWith, purged). Project: content (name, description, gitRemote, auto, createdAtMs),
// one `folder:<machineId>` group per machine, life. Model table: `modelTable/main`, content.
import 'board.dart';
import 'tasks.dart';

const taskGroups = {'content', 'column', 'run', 'life'};

/// The id of the model table's one record.
const modelTableRecordId = 'main';

/// A project's folder group for [machineId].
String folderGroup(String machineId) => 'folder:$machineId';

Map<String, dynamic> taskContent(BoardTask t) => {
      'title': t.title,
      'description': t.description,
      'acceptance': t.acceptance,
      'taskType': ?t.taskType,
      'priority': t.priority.name,
      'projectId': ?t.projectId,
      'machineId': ?t.machineId,
      'cwd': t.cwd,
      'createdAtMs': t.createdAtMs,
    };

Map<String, dynamic> taskColumn(BoardTask t) => {'column': t.column.name};

Map<String, dynamic> taskRun(BoardTask t) => {
      'sessionId': ?t.sessionId,
      'sessionName': ?t.sessionName,
      'sentAtMs': ?t.sentAtMs,
      'report': ?t.report?.toJson(),
      'gitRemote': ?t.gitRemote,
    };

/// The content, column and run groups of [t] (and [life] when given).
Map<String, Map<String, dynamic>> taskGroupValues(BoardTask t, {Map<String, dynamic>? life}) => {
      'content': taskContent(t),
      'column': taskColumn(t),
      'run': taskRun(t),
      'life': ?life,
    };

/// The task in [r] (null for another kind or a broken one). Activity is not stored.
BoardTask? taskOf(BoardRecord r) {
  if (r.kind != RecordKinds.task) return null;
  final c = r.groups['content']?.value ?? const {};
  final col = r.groups['column']?.value ?? const {};
  final run = r.groups['run']?.value ?? const {};
  var updated = 0;
  for (final g in ['content', 'column', 'run']) {
    final v = r.groups[g]?.version.ms ?? 0;
    if (v > updated) updated = v;
  }
  return BoardTask.tryFromJson({
    ...c,
    ...col,
    ...run,
    'id': r.id,
    'updatedAtMs': updated,
  });
}

Map<String, dynamic> projectContent(Project p) => {
      'name': p.name,
      'description': ?p.description,
      'gitRemote': ?p.gitRemote,
      if (p.auto) 'auto': true,
      'createdAtMs': p.createdAtMs,
    };

/// The content group and one folder group per machine of [p].
Map<String, Map<String, dynamic>> projectGroupValues(Project p) => {
      'content': projectContent(p),
      for (final e in p.folders.entries) folderGroup(e.key): {'path': e.value},
    };

/// The project in [r] (folders gathered from every `folder:<machineId>` group with a path).
Project? projectOf(BoardRecord r) {
  if (r.kind != RecordKinds.project) return null;
  final c = r.groups['content']?.value;
  if (c == null) return null;
  return Project.tryFromJson({
    ...c,
    'id': r.id,
    'folders': {
      for (final e in r.groups.entries)
        if (e.key.startsWith('folder:') && e.value.value['path'] is String && (e.value.value['path'] as String).trim().isNotEmpty)
          e.key.substring('folder:'.length): e.value.value['path'],
    },
  });
}

Map<String, Map<String, dynamic>> modelTableGroups(ModelTable t) => {
      'content': {'rows': [for (final r in t.rows) r.toJson()]}
    };

/// The model table on the board (null: none yet; the starting table applies).
ModelTable? modelTableOf(Board b) {
  final r = b.get(RecordKinds.modelTable, modelTableRecordId);
  final c = r?.groups['content'];
  if (c == null) return null;
  final t = ModelTable.tryFromJson({'rows': c.value['rows']});
  return t == null ? null : ModelTable(rows: t.rows, updatedAtMs: c.version.ms);
}

extension BoardQueries on Board {
  /// Live projects, by name.
  List<Project> get projects {
    final out = [
      for (final r in records)
        if (r.kind == RecordKinds.project && !r.deleted) ?projectOf(r)
    ];
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// Live tasks.
  List<BoardTask> get liveTasks => [
        for (final r in records)
          if (r.kind == RecordKinds.task && !r.deleted) ?taskOf(r)
      ];

  /// Live tasks of one project.
  List<BoardTask> tasksOf(String projectId) => [
        for (final t in liveTasks)
          if (t.projectId == projectId) t
      ];

  /// Deleted and not purged, newest deletion first.
  List<BoardRecord> get bin {
    final out = [
      for (final r in records)
        if (r.deleted && !r.purged) r
    ];
    out.sort((a, b) => b.groups['life']!.version.compareTo(a.groups['life']!.version));
    return out;
  }
}
