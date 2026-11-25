// What the phone keeps for the task board besides the board itself: the quick-add defaults
// (the project and machine used last) and the board's filters. Since the projects-first
// board (2026-11-24) the projects and the model table are records in the board
// (board_file.dart): once a [BoardFile] is attached, [projects], [table], [setProjects] and
// [setTable] read and write it, and older hosts' whole lists are merged into it at their
// own time. Before that (and in older tests) they live here, in shared preferences.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'board_file.dart';
import 'host_connection.dart' show ModelTableSource, ProjectSource;

/// The part of the board's store `/perch` sets.
abstract interface class BoardFilters {
  ProjectList get projects;
  Future<void> setProjectFilter(String? projectId);
  Future<void> setFilter(String? machineId);
}

class BoardStore extends ChangeNotifier implements ModelTableSource, ProjectSource, BoardFilters {
  static const key = 'perch.board';

  /// False in tests: nothing is written to the platform's preferences.
  final bool persist;
  BoardStore({this.persist = true});

  ModelTable _table = ModelTable.starting;
  String? _lastMachine;
  final Map<String, String> _lastFolder = {};
  String? _filter;
  ProjectList _projects = const ProjectList();
  String? _lastProject;
  String? _projectFilter;

  /// Called when the owner changed the table here (every machine is given it).
  VoidCallback? onTableChanged;

  /// Called when the projects changed here (every machine is given them).
  VoidCallback? onProjectsChanged;

  BoardFile? _file;

  /// The board the projects and the model table live in (null: not attached yet).
  BoardFile? get file => _file;

  /// From now on the projects and the model table are the board's.
  void attach(BoardFile f) {
    _file?.removeListener(notifyListeners);
    _file = f;
    f.addListener(notifyListeners);
    notifyListeners();
  }

  /// The newest version time of any project record (what older hosts compare lists by).
  int _projectsAtMs(Board b) {
    var at = 0;
    for (final r in b.records) {
      if (r.kind == RecordKinds.project && r.newest.ms > at) at = r.newest.ms;
    }
    return at;
  }

  @override
  ProjectList get projects {
    final f = _file;
    if (f == null) return _projects;
    return ProjectList(projects: f.board.projects, updatedAtMs: _projectsAtMs(f.board));
  }

  /// The project quick add uses (the last one a task was added to).
  String? get lastProject => _lastProject;

  /// The board's project filter (null: every project).
  String? get projectFilter => _projectFilter;

  @override
  ModelTable get table {
    final f = _file;
    if (f == null) return _table;
    return modelTableOf(f.board) ?? ModelTable.starting;
  }

  /// The machine quick add uses (the last one a task was added to).
  String? get lastMachine => _lastMachine;
  String? lastFolder(String machineId) => _lastFolder[machineId];

  /// The board's machine filter (null: every machine).
  String? get machineFilter => _filter;

  Future<void> load() async {
    if (!persist) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw != null) {
        final j = jsonDecode(raw);
        if (j is Map) {
          _table = ModelTable.tryFromJson(j['table']) ?? ModelTable.starting;
          _lastMachine = j['lastMachine'] is String ? j['lastMachine'] as String : null;
          _filter = j['filter'] is String ? j['filter'] as String : null;
          _projects = ProjectList.tryFromJson(j['projects']) ?? const ProjectList();
          _lastProject = j['lastProject'] is String ? j['lastProject'] as String : null;
          _projectFilter = j['projectFilter'] is String ? j['projectFilter'] as String : null;
          final f = j['lastFolder'];
          if (f is Map) {
            for (final e in f.entries) {
              if (e.key is String && e.value is String) _lastFolder[e.key as String] = e.value as String;
            }
          }
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    notifyListeners();
    if (!persist) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          key,
          jsonEncode({
            if (_file == null) 'table': _table.toJson(),
            'lastMachine': ?_lastMachine,
            'lastFolder': _lastFolder,
            'filter': ?_filter,
            if (_file == null) 'projects': _projects.toJson(),
            'lastProject': ?_lastProject,
            'projectFilter': ?_projectFilter,
          }));
    } catch (_) {}
  }

  /// The owner changed the table: kept, and every machine is given it.
  Future<void> setTable(ModelTable t) async {
    final f = _file;
    if (f != null) {
      f.edit(RecordKinds.modelTable, modelTableRecordId, modelTableGroups(t));
    } else {
      _table = t;
    }
    await _save();
    onTableChanged?.call();
  }

  /// An older host's model table: kept when newer (into the board at its own time).
  @override
  void adopt(ModelTable t) {
    final f = _file;
    if (f != null) {
      if (t.updatedAtMs <= table.updatedAtMs) return;
      final v = Hlc(t.updatedAtMs, 0, 'legacy_host');
      f.mergeAll([
        BoardRecord(RecordKinds.modelTable, modelTableRecordId,
            {for (final g in modelTableGroups(t).entries) g.key: BoardGroup(g.value, v)})
      ], origin: 'legacy');
      return;
    }
    if (t.updatedAtMs <= _table.updatedAtMs) return;
    _table = t;
    _save();
  }

  /// The project quick add starts on next time.
  Future<void> rememberProject(String projectId) async {
    _lastProject = projectId;
    await _save();
  }

  Future<void> remember(String machineId, String folder, {String? projectId}) async {
    _lastMachine = machineId;
    _lastFolder[machineId] = folder;
    if (projectId != null) _lastProject = projectId;
    await _save();
  }

  /// The owner (or the grouping of older tasks) changed the projects: kept, and every
  /// machine is given them.
  Future<void> setProjects(ProjectList p) async {
    final f = _file;
    if (f != null) {
      final now = {for (final x in projects.projects) x.id: x};
      for (final x in p.projects) {
        final old = now.remove(x.id);
        final groups = <String, Map<String, dynamic>>{};
        if (old == null || jsonEncode(projectContent(old)) != jsonEncode(projectContent(x))) {
          groups['content'] = projectContent(x);
        }
        for (final m in {...x.folders.keys, ...?old?.folders.keys}) {
          if (old?.folders[m] != x.folders[m]) groups[folderGroup(m)] = {'path': x.folders[m] ?? ''};
        }
        if (groups.isNotEmpty) f.edit(RecordKinds.project, x.id, groups);
      }
      for (final gone in now.keys) {
        deleteProject(gone);
      }
    } else {
      _projects = p;
    }
    if (_projectFilter != null && p.byId(_projectFilter) == null) _projectFilter = null;
    await _save();
    onProjectsChanged?.call();
  }

  /// Deletes a project and its tasks (they go to the bin together and come back together).
  void deleteProject(String id) {
    final f = _file;
    if (f == null) return;
    final at = DateTime.now().millisecondsSinceEpoch;
    f.edit(RecordKinds.project, id, {
      'life': {'deleted': true, 'deletedAtMs': at}
    });
    for (final t in f.board.tasksOf(id)) {
      f.edit(RecordKinds.task, t.id, {
        'life': {'deleted': true, 'deletedAtMs': at, 'deletedWith': id}
      });
    }
    if (_projectFilter == id) {
      _projectFilter = null;
      _save();
    }
  }

  /// An older host's project list: each project kept when the list is newer (into the board
  /// at the list's time, so anything newer on the board stays).
  @override
  void adoptProjects(ProjectList p) {
    final f = _file;
    if (f != null) {
      if (p.updatedAtMs <= 0) return;
      final v = Hlc(p.updatedAtMs, 0, 'legacy_host');
      f.mergeAll([
        for (final x in p.projects)
          BoardRecord(RecordKinds.project, x.id, {for (final g in projectGroupValues(x).entries) g.key: BoardGroup(g.value, v)})
      ], origin: 'legacy');
      return;
    }
    if (p.updatedAtMs <= _projects.updatedAtMs) return;
    _projects = p;
    _save();
  }

  @override
  Future<void> setProjectFilter(String? projectId) async {
    _projectFilter = projectId;
    await _save();
  }

  @override
  Future<void> setFilter(String? machineId) async {
    _filter = machineId;
    await _save();
  }
}
