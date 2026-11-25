// The app's sync with the board's encrypted copy in the relay (Task 17): an idea written
// while every machine is off goes to the relay; a change another device put there shows on
// the board.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:perch_app/src/connection/account_store.dart';
import 'package:perch_app/src/connection/board_file.dart';
import 'package:perch_app/src/connection/board_relay_app.dart';
import 'package:perch_protocol/perch_protocol.dart';

/// One board store of the relay, in memory, with its rules (newer versions only, by seq).
class FakeRelayBoard {
  final records = <String, ({String version, int seq, String data})>{};
  var seq = 0;
  var limited = false;
  final calls = <String>[];

  Future<({int status, String body})> call(String method, Uri uri, Map<String, String> headers, String? body) async {
    calls.add('$method ${uri.pathSegments.skip(2).join('/')}');
    if (method == 'GET') {
      final after = int.parse(uri.queryParameters['after']!);
      final list = records.entries.where((e) => e.value.seq > after).toList()..sort((a, b) => a.value.seq.compareTo(b.value.seq));
      return (
        status: 200,
        body: jsonEncode({
          'seq': list.isEmpty ? seq : list.last.value.seq,
          'records': [for (final e in list) {'key': e.key, 'version': e.value.version, 'data': e.value.data}]
        })
      );
    }
    if (limited) return (status: 429, body: '{"error":"daily limit"}');
    for (final r in ((jsonDecode(body!) as Map)['records'] as List).cast<Map>()) {
      final have = records[r['key']];
      if (have == null || (r['version'] as String).compareTo(have.version) > 0) {
        records[r['key'] as String] = (version: r['version'] as String, seq: ++seq, data: r['data'] as String);
      }
    }
    return (status: 200, body: jsonEncode({'seq': seq}));
  }
}

void main() {
  late BoardFile file;
  late FakeRelayBoard relay;
  late BoardKey key;

  setUp(() async {
    file = BoardFile(dir: null, writer: 'phone', keyBox: MemorySecretBox());
    await file.load();
    key = await file.ensureBoardKey();
    relay = FakeRelayBoard();
  });

  test('an_idea_written_with_every_machine_off_goes_to_the_relay', () async {
    final sync = AppBoardRelay(file: file, relayUrl: () => 'https://relay.example', http: relay.call);
    file.edit(RecordKinds.project, 'p1', {
      'content': {'name': 'Ideas'}
    });
    file.edit(RecordKinds.task, 'idea', {
      'content': {'title': 'Written on the train', 'projectId': 'p1'}
    });
    expect(file.unsynced, isTrue);
    await sync.syncNow();
    expect(relay.records.keys.toSet(), {'project/p1', 'task/idea'});
    for (final r in relay.records.values) {
      expect(r.data, isNot(contains('train')), reason: 'sealed');
    }
    final opened = openRecord(key.key, 'task/idea', relay.records['task/idea']!.data)!;
    expect(taskOf(opened)!.title, 'Written on the train');
    expect(file.unsynced, isFalse);
    sync.dispose();
  });

  test('nothing_without_a_relay_or_a_key_and_a_429_says_nothing', () async {
    final none = AppBoardRelay(file: file, relayUrl: () => null, http: relay.call);
    file.edit(RecordKinds.task, 't', {
      'content': {'title': 'x', 'projectId': 'p'}
    });
    await none.syncNow();
    expect(relay.calls, isEmpty);
    relay.limited = true;
    final s = AppBoardRelay(file: file, relayUrl: () => 'https://relay.example', http: relay.call);
    await s.syncNow();
    expect(file.unsynced, isTrue);
    await s.syncNow();
    expect(relay.calls.where((c) => c.startsWith('PUT')), hasLength(1), reason: 'waits for the next UTC day');
    s.dispose();
    none.dispose();
  });

  test('a_change_from_the_relay_shows_on_the_board', () async {
    // Another device (the Mac) put a task into the relay.
    final mac = Board()..put(RecordKinds.task, 'from-mac', {'content': {'title': 'Mac idea', 'projectId': 'p1'}}, HlcClock('mac'));
    await BoardRelaySync(relayUrl: 'https://relay.example', boardId: key.boardId, boardKey: key.key, http: relay.call).syncOnce(mac);
    final sync = AppBoardRelay(file: file, relayUrl: () => 'https://relay.example', http: relay.call);
    final seen = <BoardFileChange>[];
    final sub = file.changes.listen(seen.add);
    await sync.syncNow();
    expect(file.board.liveTasks.single.title, 'Mac idea');
    await Future<void>.delayed(Duration.zero);
    expect(seen.single.origin, same(sync), reason: 'machines get it from the phone too');
    await sub.cancel();
    sync.dispose();
  });

  test('a_local_edit_is_synced_within_a_few_seconds', () async {
    final sync = AppBoardRelay(
        file: file, relayUrl: () => 'https://relay.example', http: relay.call, afterChange: const Duration(milliseconds: 50))
      ..start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    file.edit(RecordKinds.task, 'later', {
      'content': {'title': 'y', 'projectId': 'p'}
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(relay.records.keys, contains('task/later'));
    sync.dispose();
  });
}
