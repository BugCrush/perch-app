// Share a task or a whole project as JSON (docs/superpowers/specs/2026-11-24-projects-first-board-design.md,
// section 6): everything about the task(s), Done included, pretty-printed, for pasting into
// another agent, an email or notes. Ids are kept (a later import could match them); no
// secret is in a task or a project, so none can appear.
import 'dart:convert';

import 'tasks.dart';

const _encoder = JsonEncoder.withIndent('  ');

String? _at(int? ms) => ms == null || ms <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

String? _blank(String? s) => s == null || s.trim().isEmpty ? null : s;

Map<String, dynamic> _project(Project p, Map<String, String> machineNames) => {
      'id': p.id,
      'name': p.name,
      'description': p.description,
      'gitRemote': p.gitRemote,
      'folders': [
        for (final e in p.folders.entries)
          {
            'machine': {'id': e.key, 'name': machineNames[e.key] ?? e.key},
            'path': e.value
          }
      ],
      'createdAt': _at(p.createdAtMs),
    };

Map<String, dynamic>? _report(TaskReport? r) => r == null
    ? null
    : {
        'text': r.text,
        'todos': [for (final t in r.todos) {'text': t.text, 'done': t.done}],
        'files': r.files,
        'changes': r.changes,
        'criteria': [for (final c in r.criteria) {'text': c.text, 'met': c.met}],
        'at': _at(r.atMs),
        'sessionEnded': r.sessionEnded,
      };

Map<String, dynamic> _task(BoardTask t, String? machineName, ModelTable? models) {
  final row = models?.row(t.taskType);
  return {
    'id': t.id,
    'title': t.title,
    'description': t.description,
    'acceptance': t.acceptance,
    'type': t.taskType == null
        ? null
        : {'id': t.taskType, 'name': row?.name ?? (models ?? ModelTable.starting).nameOf(t.taskType), 'model': row?.model},
    'priority': t.priority.name,
    'column': t.column.name,
    'machine': t.machineId == null ? null : {'id': t.machineId, 'name': machineName ?? t.machineId},
    'folder': _blank(t.cwd),
    'createdAt': _at(t.createdAtMs),
    'updatedAt': _at(t.updatedAtMs),
    'session': t.sessionId == null ? null : {'id': t.sessionId, 'name': t.sessionName, 'sentAt': _at(t.sentAtMs)},
    'report': _report(t.report),
    'gitRemote': t.gitRemote,
  };
}

/// One task (with its project) as pretty-printed JSON.
String taskShareJson(BoardTask t, {Project? project, String? machineName, ModelTable? models}) => _encoder.convert({
      'perch': 'task',
      'version': 1,
      'project': project == null
          ? null
          : _project(project, {if (t.machineId != null && machineName != null) t.machineId!: machineName}),
      'task': _task(t, machineName, models),
    });

/// A project and every one of its [tasks] (all columns), by column, then priority, then
/// last change.
String projectShareJson(Project p, List<BoardTask> tasks,
    {Map<String, String> machineNames = const {}, ModelTable? models}) {
  final sorted = [...tasks]..sort((a, b) {
      final c = a.column.index.compareTo(b.column.index);
      if (c != 0) return c;
      final pr = a.priority.index.compareTo(b.priority.index);
      return pr != 0 ? pr : a.updatedAtMs.compareTo(b.updatedAtMs);
    });
  return _encoder.convert({
    'perch': 'project',
    'version': 1,
    'project': _project(p, machineNames),
    'tasks': [for (final t in sorted) _task(t, machineNames[t.machineId], models)],
  });
}
