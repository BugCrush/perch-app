import 'dart:convert';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

HlcClock clockAt(String writer, int ms) => HlcClock(writer, now: () => DateTime.fromMillisecondsSinceEpoch(ms));

/// A relay board store in memory, with the same rules as relay/src/board.ts.
class FakeRelay {
  final records = <String, ({String version, int seq, String data})>{};
  var seq = 0;
  String? tokenSeen;
  var limited = false;
  var puts = 0;
  var deleted = <String>[];
  final pageSize = 3; // small, so paging is exercised

  Future<({int status, String body})> call(String method, Uri uri, Map<String, String> headers, String? body) async {
    final auth = headers['Authorization'] ?? '';
    tokenSeen ??= auth;
    if (auth != tokenSeen) return (status: 401, body: '{"error":"unauthorized"}');
    final parts = uri.pathSegments;
    expect(parts[0], 'b');
    if (method == 'DELETE') {
      deleted.add(parts[1]);
      records.clear();
      return (status: 200, body: '{}');
    }
    if (method == 'GET' && parts[2] == 'changes') {
      final after = int.parse(uri.queryParameters['after']!);
      final list = records.entries.where((e) => e.value.seq > after).toList()
        ..sort((a, b) => a.value.seq.compareTo(b.value.seq));
      final page = list.take(pageSize).toList();
      return (
        status: 200,
        body: jsonEncode({
          'seq': page.isEmpty ? seq : page.last.value.seq,
          'more': list.length > page.length,
          'records': [
            for (final e in page) {'key': e.key, 'version': e.value.version, 'data': e.value.data}
          ]
        })
      );
    }
    if (method == 'PUT' && parts[2] == 'records') {
      puts++;
      if (limited) return (status: 429, body: '{"error":"daily limit"}');
      final rs = (jsonDecode(body!) as Map)['records'] as List;
      var stored = 0;
      for (final r in rs.cast<Map>()) {
        final have = records[r['key']];
        if (have == null || (r['version'] as String).compareTo(have.version) > 0) {
          records[r['key'] as String] = (version: r['version'] as String, seq: ++seq, data: r['data'] as String);
          stored++;
        }
      }
      return (status: 200, body: jsonEncode({'seq': seq, 'stored': stored}));
    }
    return (status: 404, body: '{}');
  }
}

void main() {
  final k = newBoardKey();

  test('new_board_key_shapes', () {
    expect(k.boardId.length, 22);
    expect(RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(k.boardId), isTrue);
    expect(k.key.length, 32);
    expect(newBoardKey().boardId, isNot(k.boardId));
    expect(relayBoardToken(k.key), relayBoardToken(k.key));
    expect(relayBoardToken(k.key), isNot(relayBoardToken(newBoardKey().key)));
  });

  final r = BoardRecord(RecordKinds.task, 't1', {'content': BoardGroup({'title': 'Secret idea'}, Hlc(5, 0, 'phone'))});

  test('seal_open_roundtrip', () {
    final sealed = sealRecord(k.key, r);
    expect(sealed, isNot(contains('Secret')));
    expect(utf8.decode(base64.decode(sealed), allowMalformed: true), isNot(contains('Secret')));
    final back = openRecord(k.key, r.key, sealed)!;
    expect(jsonEncode(back.toJson()), jsonEncode(r.toJson()));
    expect(sealRecord(k.key, r), isNot(sealed), reason: 'random nonce');
  });

  test('a_record_sealed_for_one_id_does_not_open_as_another', () {
    final sealed = sealRecord(k.key, r);
    expect(openRecord(k.key, 'task/t2', sealed), isNull);
  });

  test('wrong_key_does_not_open', () {
    expect(openRecord(newBoardKey().key, r.key, sealRecord(k.key, r)), isNull);
    expect(openRecord(k.key, r.key, 'garbage'), isNull);
  });

  test('sync_pulls_then_pushes_only_newer', () async {
    final relay = FakeRelay();
    final other = Board()..put(RecordKinds.task, 'remote', {'content': {'title': 'from relay'}}, clockAt('mac', 100));
    // Put the other device's record into the relay through its own sync.
    final otherSync = BoardRelaySync(relayUrl: 'https://relay.test', boardId: k.boardId, boardKey: k.key, http: relay.call);
    expect((await otherSync.syncOnce(other, clock: clockAt('mac', 100))).pushed, 1);

    final b = Board();
    final c = clockAt('phone', 200);
    b.put(RecordKinds.task, 'local', {'content': {'title': 'idea'}}, c);
    final s = BoardRelaySync(relayUrl: 'https://relay.test/', boardId: k.boardId, boardKey: k.key, http: relay.call);
    final res = await s.syncOnce(b, clock: c);
    expect(res.pulled, 1);
    expect(res.pushed, 1);
    expect(b.get(RecordKinds.task, 'remote'), isNotNull);
    expect(relay.records.keys.toSet(), {'task/remote', 'task/local'});
    expect(relay.tokenSeen, 'Bearer ${relayBoardToken(k.key)}');
    // Nothing new: nothing pushed again.
    final putsBefore = relay.puts;
    final again = await s.syncOnce(b, clock: c);
    expect(again.pushed, 0);
    expect(relay.puts, putsBefore);
    // One group changes: that record goes again.
    b.put(RecordKinds.task, 'remote', {'column': {'column': 'ready'}}, c);
    expect((await s.syncOnce(b, clock: c)).pushed, 1);
    // The relay never saw plaintext.
    for (final v in relay.records.values) {
      expect(v.data, isNot(contains('idea')));
    }
  });

  test('paging_pulls_everything', () async {
    final relay = FakeRelay();
    final a = Board();
    final c = clockAt('a', 10);
    for (var i = 0; i < 10; i++) {
      a.put(RecordKinds.task, 't$i', {'content': {'title': 'n$i'}}, c);
    }
    await BoardRelaySync(relayUrl: 'https://x', boardId: k.boardId, boardKey: k.key, http: relay.call).syncOnce(a, clock: c);
    final b = Board();
    final res =
        await BoardRelaySync(relayUrl: 'https://x', boardId: k.boardId, boardKey: k.key, http: relay.call).syncOnce(b);
    expect(res.pulled, 10);
    expect(res.pushed, 0);
    expect(b.records.length, 10);
  });

  test('a_429_is_reported_not_thrown', () async {
    final relay = FakeRelay()..limited = true;
    final b = Board()..put(RecordKinds.task, 't', {'content': {'title': 'x'}}, clockAt('a', 1));
    final res =
        await BoardRelaySync(relayUrl: 'https://x', boardId: k.boardId, boardKey: k.key, http: relay.call).syncOnce(b);
    expect(res.limited, isTrue);
    expect(res.pushed, 0);
  });

  test('a_wrong_token_throws_a_relay_error', () async {
    final relay = FakeRelay()..tokenSeen = 'Bearer someone-else';
    expect(
        () => BoardRelaySync(relayUrl: 'https://x', boardId: k.boardId, boardKey: k.key, http: relay.call).syncOnce(Board()),
        throwsA(isA<BoardRelayError>().having((e) => e.status, 'status', 401)));
  });

  test('two_replicas_converge_through_the_fake_relay_only', () async {
    final relay = FakeRelay();
    final phone = Board(), machine = Board();
    final pc = clockAt('phone', 5000), mc = clockAt('win', 1000); // the phone's clock is ahead
    final ps = BoardRelaySync(relayUrl: 'https://x', boardId: k.boardId, boardKey: k.key, http: relay.call);
    final ms = BoardRelaySync(relayUrl: 'https://x', boardId: k.boardId, boardKey: k.key, http: relay.call);
    phone.put(RecordKinds.task, 't', {'content': {'title': 'phone title'}}, pc);
    machine.put(RecordKinds.task, 't', {'run': {'sessionId': 's1'}}, mc);
    await ps.syncOnce(phone, clock: pc);
    await ms.syncOnce(machine, clock: mc); // pulls the phone's, pushes its merged record
    await ps.syncOnce(phone, clock: pc);
    for (final b in [phone, machine]) {
      final rec = b.get(RecordKinds.task, 't')!;
      expect(rec.groups['content']!.value['title'], 'phone title');
      expect(rec.groups['run']!.value['sessionId'], 's1');
    }
    // A later edit on the slow machine wins over the phone's earlier one.
    machine.put(RecordKinds.task, 't', {'content': {'title': 'machine title'}}, mc);
    await ms.syncOnce(machine, clock: mc);
    await ps.syncOnce(phone, clock: pc);
    expect(phone.get(RecordKinds.task, 't')!.groups['content']!.value['title'], 'machine title');
    expect(jsonEncode(phone.toJson()), jsonEncode(machine.toJson()));
  });

  test('delete_board', () async {
    final relay = FakeRelay();
    final s = BoardRelaySync(relayUrl: 'https://x', boardId: k.boardId, boardKey: k.key, http: relay.call);
    await s.syncOnce(Board()..put(RecordKinds.task, 't', {'content': {'title': 'x'}}, clockAt('a', 1)));
    await s.deleteBoard();
    expect(relay.deleted, [k.boardId]);
    expect(relay.records, isEmpty);
  });
}
