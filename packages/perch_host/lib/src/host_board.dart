// This machine's replica of the board (docs/superpowers/specs/2026-11-24-projects-first-board-design.md):
// every project, every task (assigned to any machine or none) and the model table, as
// versioned records in `<state dir>/board.json`, written atomically. Devices, the board
// page, `/perch` and the relay copy all meet here; the task board runs the tasks assigned
// to this machine.
//
// On the first start on this design (no board.json yet) the tasks in tasks.json become
// records assigned to this machine (a task without a project joins the project whose folder
// here is the task's folder, else a Perch-made project, as the app grouped them before), the
// project list and model table in host.json become records, and tasks.json is renamed
// tasks.json.migrated.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

/// Records that changed, and the device they came from (null: changed here).
class BoardChange {
  final List<BoardRecord> records;
  final String? from;
  const BoardChange(this.records, {this.from});
}

/// The git remote (`origin`) of a folder, or null.
String? gitRemoteSync(String folder) {
  try {
    if (!Directory(folder).existsSync()) return null;
    final r = Process.runSync('git', ['remote', 'get-url', 'origin'], workingDirectory: folder);
    final out = '${r.stdout}'.trim();
    return r.exitCode == 0 && out.isNotEmpty ? out : null;
  } catch (_) {
    return null;
  }
}

class HostBoard {
  final String stateDir;
  final String machineId;
  final DateTime Function() _now;
  final void Function(String line)? log;
  final String? Function(String folder) _remoteOf;

  late final HlcClock clock;
  Board _board = Board();
  final _changes = StreamController<BoardChange>.broadcast();

  HostBoard({
    required this.stateDir,
    required this.machineId,
    ProjectList? legacyProjects,
    ModelTable? legacyModels,
    DateTime Function()? now,
    this.log,
    String? Function(String folder)? remoteOf,
  })  : _now = now ?? DateTime.now,
        _remoteOf = remoteOf ?? gitRemoteSync {
    clock = HlcClock(machineId, now: _now);
    _load(legacyProjects, legacyModels);
  }

  Board get board => _board;

  /// Every change: edits made here ([BoardChange.from] null) and records merged from a device.
  Stream<BoardChange> get changes => _changes.stream;

  String get _path => '$stateDir${Platform.pathSeparator}board.json';
  int get _nowMs => _now().millisecondsSinceEpoch;

  void _load(ProjectList? legacyProjects, ModelTable? legacyModels) {
    final f = File(_path);
    if (f.existsSync()) {
      try {
        final j = jsonDecode(f.readAsStringSync());
        if (j is! Map) throw const FormatException('not an object');
        _board = Board.fromJson(j);
      } catch (e) {
        final aside = '$_path.broken-$_nowMs';
        try {
          f.renameSync(aside);
        } catch (_) {}
        log?.call('Could not read board.json ($e); it was kept as ${aside.split(Platform.pathSeparator).last} '
            'and the board starts empty here (devices and the relay copy fill it again).');
        _board = Board();
      }
      for (final r in _board.records) {
        clock.observe(r.newest);
      }
      final pruned = _board.prune(_nowMs);
      if (pruned > 0) save();
      return;
    }
    _migrate(legacyProjects, legacyModels);
  }

  void _migrate(ProjectList? legacyProjects, ModelTable? legacyModels) {
    final projects = legacyProjects ?? const ProjectList();
    // The old list's version: its own time (or a moment ago), written by "legacy" so any
    // later edit on any device wins.
    Hlc at(int ms) => Hlc(ms > 0 ? ms : 1, 0, 'legacy');
    for (final p in projects.projects) {
      _put(RecordKinds.project, p.id, projectGroupValues(p), at(projects.updatedAtMs));
    }
    if (legacyModels != null && legacyModels.updatedAtMs > 0) {
      _put(RecordKinds.modelTable, modelTableRecordId, modelTableGroups(legacyModels), at(legacyModels.updatedAtMs));
    }
    final tasksFile = File('$stateDir${Platform.pathSeparator}tasks.json');
    var moved = 0;
    if (tasksFile.existsSync()) {
      try {
        final j = jsonDecode(tasksFile.readAsStringSync());
        final list = j is Map && j['tasks'] is List ? j['tasks'] as List : const [];
        var known = projects;
        for (final raw in list) {
          var t = BoardTask.tryFromJson(raw);
          if (t == null || raw is! Map) continue;
          t = t.copyWith(machineId: machineId);
          if (t.projectId == null) {
            final remote = t.cwd.trim().isEmpty ? null : _remoteOf(t.cwd);
            final grouped = groupIntoProjects(known, [(machineId, t.copyWith(gitRemote: remote))], atMs: _nowMs);
            if (grouped != null) known = grouped;
            final p = known.projectOf(t, machineId);
            if (p != null) {
              t = t.copyWith(projectId: p.id);
              if (_board.get(RecordKinds.project, p.id) == null ||
                  projectOf(_board.get(RecordKinds.project, p.id)!)?.folderOn(machineId) == null) {
                _put(RecordKinds.project, p.id, projectGroupValues(p), clock.tick());
              }
            }
          }
          final v = at(t.updatedAtMs);
          clock.observe(v);
          _put(RecordKinds.task, t.id, {
            'content': taskContent(t),
            'column': taskColumn(t),
            'run': {
              ...taskRun(t),
              // What only this machine needs to finish a run after a restart.
              if (raw['gitHead'] is String) 'gitHead': raw['gitHead'],
              if (raw['gitDirty'] is List) 'gitDirty': raw['gitDirty'],
              if (raw['awaiting'] == true) 'awaiting': true,
              if (raw['runAtMs'] is int) 'runAtMs': raw['runAtMs'],
            },
          }, v);
          moved++;
        }
        tasksFile.renameSync('${tasksFile.path}.migrated');
        log?.call('Moved $moved task${moved == 1 ? '' : 's'} from tasks.json into the board (tasks.json.migrated is kept).');
      } catch (e) {
        log?.call('Could not move tasks.json into the board: $e');
      }
    }
    for (final r in _board.records) {
      clock.observe(r.newest);
    }
    save();
  }

  void _put(String kind, String id, Map<String, Map<String, dynamic>> groups, Hlc v) {
    _board.merge(BoardRecord(kind, id, {for (final e in groups.entries) e.key: BoardGroup(e.value, v)}));
  }

  /// Merges records from a device [from] (null: the relay or a local source); saves and
  /// tells the listeners what changed. True when anything changed.
  bool mergeAll(Iterable<BoardRecord> rs, {String? from}) {
    final changed = <BoardRecord>[];
    for (final r in rs) {
      if (_board.merge(r, clock: clock)) changed.add(_board.get(r.kind, r.id)!);
    }
    if (changed.isEmpty) return false;
    save();
    if (!_changes.isClosed) _changes.add(BoardChange(changed, from: from));
    return true;
  }

  /// Writes [groups] of one record here (each a whole group, one new version); saves and
  /// tells the listeners.
  BoardRecord edit(String kind, String id, Map<String, Map<String, dynamic>> groups) {
    final r = _board.put(kind, id, groups, clock);
    save();
    if (!_changes.isClosed) _changes.add(BoardChange([r]));
    return r;
  }

  /// Records already merged into [board] elsewhere (the relay sync): saved, and told to the
  /// listeners as coming [from] there.
  void announce(List<BoardRecord> changed, {String? from}) {
    if (changed.isEmpty) return;
    save();
    if (!_changes.isClosed) _changes.add(BoardChange(changed, from: from));
  }

  /// Live tasks assigned to this machine.
  List<BoardTask> get myTasks => [
        for (final t in _board.liveTasks)
          if (t.machineId == machineId) t
      ];

  /// Written beside it, then moved over it.
  void save() {
    Directory(stateDir).createSync(recursive: true);
    final tmp = File('$_path.tmp');
    tmp.writeAsStringSync(jsonEncode({'version': 1, ..._board.toJson()}));
    tmp.renameSync(_path);
  }

  Future<void> dispose() => _changes.close();
}
