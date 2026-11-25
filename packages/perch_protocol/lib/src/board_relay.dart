// The board's encrypted copy in the relay (docs/superpowers/specs/2026-11-24-projects-first-board-design.md,
// section 5). The phone makes one board key (32 random bytes) and board id (16 random
// bytes, base64url); every record goes to the relay sealed with a key derived from it
// (AES-256-GCM, a random 12-byte nonce, the record key as associated data). The relay sees
// record keys, sizes, times and a version string in the clear, never a title or a report.
//
// Sealed record (standard base64): [version 1][12-byte nonce][ciphertext][16-byte tag].
//
// The relay keeps one sealed record per key, the one with the greater version string.
// Records are merged per group on the devices, so the version a device sends is a fresh
// tick of its clock (newer than everything it has seen), and a device pushes a record
// again whenever it holds a group the relay's copy lacks or has older: two devices that
// push at once converge on their next sync.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Mac, SecretBox, SecretKeyData;
import 'package:cryptography/dart.dart' show DartAesGcm;

import 'board.dart';
import 'hlc.dart';
import 'secure_channel.dart';

const _sealVersion = 1;
final _aes = DartAesGcm.with256bits();

/// A new board: its id (22 base64url characters) and its key (32 random bytes).
({String boardId, List<int> key}) newBoardKey() =>
    (boardId: base64UrlNoPad(randomBytes(16)), key: randomBytes(pairingSecretLength));

/// The key records are sealed with.
Uint8List _recordKey(List<int> boardKey) => hkdfSha256(boardKey, info: utf8.encode('perch v1 board record'));

/// The token the relay knows this board by (it keeps only its hash).
String relayBoardToken(List<int> boardKey) =>
    base64UrlNoPad(hkdfSha256(boardKey, info: utf8.encode('perch v1 board token')));

/// [r] sealed with [boardKey].
String sealRecord(List<int> boardKey, BoardRecord r) {
  final nonce = randomBytes(12);
  final box = _aes.encryptSync(utf8.encode(jsonEncode(r.toJson())),
      secretKeyData: SecretKeyData(_recordKey(boardKey)), nonce: nonce, aad: utf8.encode(r.key));
  return base64.encode([_sealVersion, ...nonce, ...box.cipherText, ...box.mac.bytes]);
}

/// The record in [sealed] when it opens with [boardKey] as [recordKey]; null otherwise.
BoardRecord? openRecord(List<int> boardKey, String recordKey, String sealed) {
  try {
    final b = base64.decode(sealed.trim());
    if (b.length < 1 + 12 + 16 + 1 || b[0] != _sealVersion) return null;
    final plain = _aes.decryptSync(
      SecretBox(b.sublist(13, b.length - 16), nonce: b.sublist(1, 13), mac: Mac(b.sublist(b.length - 16))),
      secretKeyData: SecretKeyData(_recordKey(boardKey)),
      aad: utf8.encode(recordKey),
    );
    final r = BoardRecord.tryFromJson(jsonDecode(utf8.decode(plain)));
    return r?.key == recordKey ? r : null;
  } catch (_) {
    return null;
  }
}

/// One HTTP call: (method, url, headers, body) -> (status, body).
typedef RelayHttp = Future<({int status, String body})> Function(
    String method, Uri uri, Map<String, String> headers, String? body);

/// The relay answered something other than success or its daily limit.
class BoardRelayError implements Exception {
  final int status;
  final String body;
  BoardRelayError(this.status, this.body);
  @override
  String toString() => 'BoardRelayError($status)';
}

/// The most records one PUT carries.
const boardRelayBatch = 200;

/// Syncs one board replica with its encrypted copy in the relay.
class BoardRelaySync {
  final String relayUrl;
  final String boardId;
  final List<int> boardKey;
  final RelayHttp http;

  /// The relay's sequence number this replica has pulled up to.
  int cursor = 0;

  /// What the relay's copy of each record holds: record key -> group -> encoded version.
  final Map<String, Map<String, String>> relayGroups = {};

  final HlcClock _ownClock = HlcClock('sync');

  BoardRelaySync({required this.relayUrl, required this.boardId, required this.boardKey, required this.http});

  Uri _uri(String path, [Map<String, String>? query]) {
    var base = relayUrl.trim();
    if (base.startsWith('wss://')) base = 'https://${base.substring(6)}';
    if (base.startsWith('ws://')) base = 'http://${base.substring(5)}';
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return Uri.parse('$base/b/$boardId$path').replace(queryParameters: query);
  }

  Map<String, String> get _headers =>
      {'Authorization': 'Bearer ${relayBoardToken(boardKey)}', 'Content-Type': 'application/json'};

  static Map<String, String> _groupsOf(BoardRecord r) =>
      {for (final g in r.groups.entries) g.key: g.value.version.encode()};

  bool _relayLacks(BoardRecord r) {
    final have = relayGroups[r.key];
    if (have == null) return true;
    for (final g in r.groups.entries) {
      final v = have[g.key];
      if (v == null || g.value.version.encode().compareTo(v) > 0) return true;
    }
    return false;
  }

  /// Pulls what changed in the relay since [cursor] and merges it into [board], then pushes
  /// every record the relay lacks or has older ([push] false: pull only). A daily limit
  /// (429) is reported, not thrown; any other failure throws [BoardRelayError] (or the
  /// transport's exception). [changed] lists the records the pull changed in [board].
  Future<({int pulled, int pushed, bool limited, List<BoardRecord> changed})> syncOnce(Board board,
      {HlcClock? clock, bool push = true}) async {
    final c = clock ?? _ownClock;
    var pulled = 0;
    final changed = <String, BoardRecord>{};
    while (true) {
      final res = await http('GET', _uri('/changes', {'after': '$cursor'}), _headers, null);
      if (res.status == 429) return (pulled: pulled, pushed: 0, limited: true, changed: changed.values.toList());
      if (res.status != 200) throw BoardRelayError(res.status, res.body);
      final j = jsonDecode(res.body);
      if (j is! Map) throw BoardRelayError(res.status, 'bad answer');
      final rs = j['records'] is List ? j['records'] as List : const [];
      for (final e in rs) {
        if (e is! Map || e['key'] is! String || e['data'] is! String) continue;
        final v = e['version'] is String ? Hlc.parse(e['version'] as String) : null;
        if (v != null) c.observe(v);
        final r = openRecord(boardKey, e['key'] as String, e['data'] as String);
        if (r == null) continue;
        relayGroups[r.key] = _groupsOf(r);
        if (board.merge(r, clock: c)) changed[r.key] = board.get(r.kind, r.id)!;
        pulled++;
      }
      final seq = j['seq'];
      if (seq is num && seq.toInt() > cursor) cursor = seq.toInt();
      if (j['more'] != true || rs.isEmpty) break;
    }
    if (!push) return (pulled: pulled, pushed: 0, limited: false, changed: changed.values.toList());
    final out = [for (final r in board.records) if (_relayLacks(r)) r];
    var pushed = 0;
    for (var i = 0; i < out.length; i += boardRelayBatch) {
      final batch = out.sublist(i, i + boardRelayBatch > out.length ? out.length : i + boardRelayBatch);
      final body = jsonEncode({
        'records': [
          for (final r in batch) {'key': r.key, 'version': c.tick().encode(), 'data': sealRecord(boardKey, r)}
        ]
      });
      final res = await http('PUT', _uri('/records'), _headers, body);
      if (res.status == 429) return (pulled: pulled, pushed: pushed, limited: true, changed: changed.values.toList());
      if (res.status != 200) throw BoardRelayError(res.status, res.body);
      for (final r in batch) {
        relayGroups[r.key] = _groupsOf(r);
      }
      pushed += batch.length;
    }
    return (pulled: pulled, pushed: pushed, limited: false, changed: changed.values.toList());
  }

  /// Wipes this board in the relay (after the key was rotated to a new board).
  Future<void> deleteBoard() async {
    final res = await http('DELETE', _uri(''), _headers, null);
    if (res.status != 200 && res.status != 404) throw BoardRelayError(res.status, res.body);
    relayGroups.clear();
    cursor = 0;
  }

  /// Today's use of this board in the relay (`writesToday`, `writeLimit`, `bytes`, `byteLimit`).
  Future<Map<String, dynamic>> usage() async {
    final res = await http('GET', _uri('/usage'), _headers, null);
    if (res.status != 200) throw BoardRelayError(res.status, res.body);
    final j = jsonDecode(res.body);
    return j is Map ? j.cast<String, dynamic>() : const {};
  }
}
