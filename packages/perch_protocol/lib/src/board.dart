// The board as a set of versioned records (docs/superpowers/specs/2026-11-24-projects-first-board-design.md,
// section 4): one record per project, per task and one for the model table. A record's
// fields are split into groups, each with its own hybrid-clock version; merging two
// copies keeps, per group, the value with the newer version ("newest change wins per
// group"). Deletes are tombstones in the `life` group, remembered for 180 days.
import 'hlc.dart';

abstract final class RecordKinds {
  static const project = 'project';
  static const task = 'task';
  static const modelTable = 'modelTable';
  static const all = {project, task, modelTable};
}

/// How long a deleted record is remembered (and listed in the bin).
const tombstoneKeep = Duration(days: 180);

/// One group of a record's fields and its version.
class BoardGroup {
  final Map<String, dynamic> value;
  final Hlc version;
  BoardGroup(Map<String, dynamic> value, this.version) : value = Map.unmodifiable(value);

  Map<String, dynamic> toJson() => {'v': version.encode(), 'value': value};

  static BoardGroup? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final v = j['v'], value = j['value'];
    final version = v is String ? Hlc.parse(v) : null;
    if (version == null || value is! Map) return null;
    return BoardGroup({for (final e in value.entries) if (e.key is String) e.key as String: e.value}, version);
  }
}

class BoardRecord {
  final String kind;
  final String id;
  final Map<String, BoardGroup> groups;
  BoardRecord(this.kind, this.id, Map<String, BoardGroup> groups) : groups = Map.unmodifiable(groups);

  String get key => '$kind/$id';

  Map<String, dynamic>? get life => groups['life']?.value;

  /// Deleted (a tombstone), shown in the bin unless [purged].
  bool get deleted => life?['deleted'] == true;

  /// Deleted for good: still a tombstone, no longer listed in the bin.
  bool get purged => deleted && life?['purged'] == true;

  /// When it was deleted (falls back to the life group's version).
  int get deletedAtMs {
    final v = life?['deletedAtMs'];
    return v is num && v > 0 ? v.toInt() : (groups['life']?.version.ms ?? 0);
  }

  Hlc get newest {
    var n = Hlc.zero;
    for (final g in groups.values) {
      if (g.version > n) n = g.version;
    }
    return n;
  }

  /// This record with [other]'s groups that are newer (null when nothing changes).
  BoardRecord? mergedWith(BoardRecord other) {
    Map<String, BoardGroup>? out;
    for (final e in other.groups.entries) {
      final mine = groups[e.key];
      if (mine == null || e.value.version > mine.version) {
        (out ??= {...groups})[e.key] = e.value;
      }
    }
    return out == null ? null : BoardRecord(kind, id, out);
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'id': id,
        'groups': {for (final k in (groups.keys.toList()..sort())) k: groups[k]!.toJson()},
      };

  static BoardRecord? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final kind = j['kind'], id = j['id'], gs = j['groups'];
    if (kind is! String || !RecordKinds.all.contains(kind) || id is! String || id.isEmpty || gs is! Map) return null;
    final groups = <String, BoardGroup>{};
    for (final e in gs.entries) {
      final g = BoardGroup.tryFromJson(e.value);
      if (e.key is String && g != null) groups[e.key as String] = g;
    }
    if (groups.isEmpty) return null;
    return BoardRecord(kind, id, groups);
  }
}

/// One replica of the board.
class Board {
  final Map<String, BoardRecord> _records = {};

  Board();

  Iterable<BoardRecord> get records => _records.values;

  BoardRecord? get(String kind, String id) => _records['$kind/$id'];

  /// Takes [incoming]'s newer groups; true when anything changed. With [clock], the clock
  /// moves past the incoming versions.
  bool merge(BoardRecord incoming, {HlcClock? clock}) {
    clock?.observe(incoming.newest);
    final have = _records[incoming.key];
    if (have == null) {
      _records[incoming.key] = incoming;
      return true;
    }
    final merged = have.mergedWith(incoming);
    if (merged == null) return false;
    _records[incoming.key] = merged;
    return true;
  }

  /// Writes the named [groups] (whole groups) with one new version from [clock]; returns
  /// the record as it now is.
  BoardRecord put(String kind, String id, Map<String, Map<String, dynamic>> groups, HlcClock clock) {
    final v = clock.tick();
    final have = _records['$kind/$id'];
    final out = <String, BoardGroup>{...?have?.groups};
    for (final e in groups.entries) {
      out[e.key] = BoardGroup(e.value, v);
    }
    return _records['$kind/$id'] = BoardRecord(kind, id, out);
  }

  /// What this replica has: record key -> group -> encoded version.
  Map<String, Map<String, String>> summary() => {
        for (final r in _records.values) r.key: {for (final g in r.groups.entries) g.key: g.value.version.encode()}
      };

  /// The records (whole) of which [theirs] lacks a group or has an older one.
  List<BoardRecord> newerThan(Map<String, Map<String, String>> theirs) {
    final out = <BoardRecord>[];
    for (final r in _records.values) {
      final t = theirs[r.key];
      if (t == null) {
        out.add(r);
        continue;
      }
      for (final g in r.groups.entries) {
        final tv = t[g.key];
        if (tv == null || g.value.version.encode().compareTo(tv) > 0) {
          out.add(r);
          break;
        }
      }
    }
    return out;
  }

  /// Drops tombstones older than [keep]; returns how many.
  int prune(int nowMs, {Duration keep = tombstoneKeep}) {
    final cut = nowMs - keep.inMilliseconds;
    final gone = [for (final r in _records.values) if (r.deleted && r.deletedAtMs < cut) r.key];
    for (final k in gone) {
      _records.remove(k);
    }
    return gone.length;
  }

  Map<String, dynamic> toJson() => {
        'records': [for (final k in (_records.keys.toList()..sort())) _records[k]!.toJson()]
      };

  static Board fromJson(Object? j) {
    final b = Board();
    final rs = j is Map ? j['records'] : null;
    if (rs is List) {
      for (final r in rs) {
        final rec = BoardRecord.tryFromJson(r);
        if (rec != null) b.merge(rec);
      }
    }
    return b;
  }
}

/// Parses a summary sent over the wire (bad entries skipped).
Map<String, Map<String, String>> summaryFromJson(Object? j) => {
      if (j is Map)
        for (final e in j.entries)
          if (e.key is String && e.value is Map)
            e.key as String: {
              for (final g in (e.value as Map).entries)
                if (g.key is String && g.value is String) g.key as String: g.value as String
            }
    };
