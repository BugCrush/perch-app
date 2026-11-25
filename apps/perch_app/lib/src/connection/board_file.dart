// The board kept on the phone (docs/superpowers/specs/2026-11-24-projects-first-board-design.md,
// section 4.3): every project, every task and the model table as versioned records, in
// `board.json` in the app's own storage (written atomically), read at start so the board
// opens at once and works with no connection at all. The board key (the relay copy's
// key) is kept in secure storage, never in the file.
//
// Changes carry an origin: null for an edit made here, else what they came from (a
// machine's connection, the relay sync). Each connection passes on what did not come from
// its own machine, so the phone carries changes between machines that never meet.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'account_store.dart' show SecretBox;
import 'board_store.dart';

/// The board's id, its key (32 bytes) and the key's version (an encoded [Hlc]).
class BoardKey {
  final String boardId;
  final List<int> key;
  final String keyVersion;
  const BoardKey({required this.boardId, required this.key, required this.keyVersion});

  String get keyText => base64UrlNoPad(key);

  Map<String, dynamic> toJson() => {'boardId': boardId, 'key': keyText, 'keyVersion': keyVersion};

  static BoardKey? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['boardId'], k = j['key'], v = j['keyVersion'];
    if (id is! String || k is! String || v is! String || Hlc.parse(v) == null) return null;
    final bytes = base64UrlDecodeNoPad(k);
    if (bytes == null || bytes.length != pairingSecretLength || !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(id)) return null;
    return BoardKey(boardId: id, key: bytes, keyVersion: v);
  }

  /// A new key, versioned by [clock].
  static BoardKey create(HlcClock clock) {
    final k = newBoardKey();
    return BoardKey(boardId: k.boardId, key: k.key, keyVersion: clock.tick().encode());
  }
}

/// Records that changed, and where they came from (null: edited here).
class BoardFileChange {
  final List<BoardRecord> records;
  final Object? origin;
  const BoardFileChange(this.records, this.origin);
}

class BoardFile extends ChangeNotifier {
  static const keyName = 'perch.boardKey';

  /// Where board.json lives (null: memory only, as on the board page in a browser).
  final Directory? dir;
  final String writer;
  final SecretBox? keyBox;
  final DateTime Function() _now;

  BoardFile({required this.dir, required this.writer, this.keyBox, DateTime Function()? now})
      : _now = now ?? DateTime.now,
        clock = HlcClock(writer, now: now);

  final HlcClock clock;
  Board _board = Board();
  BoardKey? _key;
  int? _lastSyncAtMs;
  int? _lastEditAtMs;
  bool _loaded = false;
  final _changes = StreamController<BoardFileChange>.broadcast();
  final _keys = StreamController<Object?>.broadcast();
  Future<void> _writing = Future.value();

  Board get board => _board;
  bool get loaded => _loaded;

  /// Every change, with its origin.
  Stream<BoardFileChange> get changes => _changes.stream;

  /// Only the edits made here.
  Stream<List<BoardRecord>> get localEdits => changes.where((c) => c.origin == null).map((c) => c.records);

  /// The board key changed (the origin it came from; null: made here).
  Stream<Object?> get keyChanges => _keys.stream;

  BoardKey? get boardKey => _key;

  /// A machine or the relay has taken the board at least once.
  bool get everSynced => _lastSyncAtMs != null;

  /// Something was edited here after the last time a machine or the relay was reached.
  bool get unsynced => _lastEditAtMs != null && (_lastSyncAtMs == null || _lastSyncAtMs! < _lastEditAtMs!);

  File? get _file => dir == null ? null : File('${dir!.path}${Platform.pathSeparator}board.json');

  /// Reads board.json (and the key); the first time, takes the projects and model table the
  /// older app kept ([legacy]).
  Future<void> load({BoardStore? legacy}) async {
    final f = _file;
    var fresh = true;
    if (f != null && await f.exists()) {
      fresh = false;
      try {
        final j = jsonDecode(await f.readAsString());
        _board = Board.fromJson(j);
        final meta = j is Map ? j['meta'] : null;
        if (meta is Map) {
          _lastSyncAtMs = meta['lastSyncAtMs'] is int ? meta['lastSyncAtMs'] as int : null;
          _lastEditAtMs = meta['lastEditAtMs'] is int ? meta['lastEditAtMs'] as int : null;
        }
      } catch (_) {
        try {
          await f.rename('${f.path}.broken-${_now().millisecondsSinceEpoch}');
        } catch (_) {}
        _board = Board();
      }
    }
    for (final r in _board.records) {
      clock.observe(r.newest);
    }
    _board.prune(_now().millisecondsSinceEpoch);
    if (fresh && legacy != null) _migrate(legacy);
    try {
      final raw = await keyBox?.read(keyName);
      if (raw != null) _key = BoardKey.tryFromJson(jsonDecode(raw));
    } catch (_) {}
    _loaded = true;
    if (fresh) _save();
    notifyListeners();
  }

  void _migrate(BoardStore legacy) {
    Hlc at(int ms) => Hlc(ms > 0 ? ms : 1, 0, 'legacy');
    final p = legacy.projects;
    for (final project in p.projects) {
      _board.merge(BoardRecord(RecordKinds.project, project.id,
          {for (final g in projectGroupValues(project).entries) g.key: BoardGroup(g.value, at(p.updatedAtMs))}));
    }
    final t = legacy.table;
    if (t.updatedAtMs > 0) {
      _board.merge(BoardRecord(RecordKinds.modelTable, modelTableRecordId,
          {for (final g in modelTableGroups(t).entries) g.key: BoardGroup(g.value, at(t.updatedAtMs))}));
    }
  }

  /// Written beside it, then moved over it; one write at a time.
  void _save() {
    final f = _file;
    if (f == null) return;
    final text = jsonEncode({
      'version': 1,
      ..._board.toJson(),
      'meta': {'lastSyncAtMs': ?_lastSyncAtMs, 'lastEditAtMs': ?_lastEditAtMs},
    });
    _writing = _writing.then((_) async {
      try {
        await f.parent.create(recursive: true);
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(f.path);
      } catch (_) {}
    });
  }

  /// Waits until every write so far is on disk.
  Future<void> flush() => _writing;

  /// Writes [groups] of one record here (whole groups, one new version).
  BoardRecord edit(String kind, String id, Map<String, Map<String, dynamic>> groups) {
    final r = _board.put(kind, id, groups, clock);
    _lastEditAtMs = _now().millisecondsSinceEpoch;
    _save();
    if (!_changes.isClosed) _changes.add(BoardFileChange([r], null));
    notifyListeners();
    return r;
  }

  /// Merges records from [origin]; returns those that changed here.
  List<BoardRecord> mergeAll(Iterable<BoardRecord> rs, {required Object origin}) {
    final changed = <BoardRecord>[];
    for (final r in rs) {
      if (_board.merge(r, clock: clock)) changed.add(_board.get(r.kind, r.id)!);
    }
    announce(changed, origin: origin);
    return changed;
  }

  /// Records already merged into [board] (by the relay sync): saved and told.
  void announce(List<BoardRecord> changed, {required Object origin}) {
    if (changed.isEmpty) return;
    _save();
    if (!_changes.isClosed) _changes.add(BoardFileChange(changed, origin));
    notifyListeners();
  }

  /// A machine or the relay has everything edited here so far.
  void markSynced() {
    final was = unsynced;
    _lastSyncAtMs = _now().millisecondsSinceEpoch;
    _save();
    if (was) notifyListeners();
  }

  /// Keeps [k] when it is newer than the key here (or there is none); true when taken.
  Future<bool> takeBoardKey(BoardKey k, {Object? origin}) async {
    final mine = _key;
    final v = Hlc.parse(k.keyVersion);
    if (v == null) return false;
    if (mine != null && !(v > Hlc.parse(mine.keyVersion)!)) return false;
    _key = k;
    clock.observe(v);
    try {
      await keyBox?.write(keyName, jsonEncode(k.toJson()));
    } catch (_) {}
    if (!_keys.isClosed) _keys.add(origin);
    notifyListeners();
    return true;
  }

  /// The key, made here when there is none yet.
  Future<BoardKey> ensureBoardKey() async {
    final k = _key;
    if (k != null) return k;
    final made = BoardKey.create(clock);
    await takeBoardKey(made);
    return _key!;
  }

  @override
  void dispose() {
    _changes.close();
    _keys.close();
    super.dispose();
  }
}
