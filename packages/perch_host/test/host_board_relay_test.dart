// The host's sync with the board's encrypted copy in the relay (Task 12): after a change
// and on a timer; nothing without a relay or a key; a 429 logged once and retried the next
// UTC day; after a key rotation the board moves to the new id and the old one is deleted.
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:perch_host/src/host_board.dart';
import 'package:perch_host/src/host_board_relay.dart';
import 'package:perch_host/src/host_state.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

final sep = Platform.pathSeparator;

/// A relay's board stores in memory (per board id), as relay/src/board.ts keeps them.
class FakeBoards {
  final boards = <String, Map<String, ({String version, int seq, String data})>>{};
  final deleted = <String>{};
  var seq = 0;
  var limited = false;
  final calls = <String>[];

  Future<({int status, String body})> call(String method, Uri uri, Map<String, String> headers, String? body) async {
    final parts = uri.pathSegments;
    final id = parts[1];
    calls.add('$method ${parts.skip(2).join('/')}');
    if (deleted.contains(id)) return (status: 410, body: '{"error":"deleted"}');
    final recs = boards.putIfAbsent(id, () => {});
    if (method == 'DELETE') {
      deleted.add(id);
      boards.remove(id);
      return (status: 200, body: '{}');
    }
    if (method == 'GET' && parts[2] == 'changes') {
      final after = int.parse(uri.queryParameters['after']!);
      final list = recs.entries.where((e) => e.value.seq > after).toList()..sort((a, b) => a.value.seq.compareTo(b.value.seq));
      return (
        status: 200,
        body: jsonEncode({
          'seq': list.isEmpty ? seq : list.last.value.seq,
          'records': [for (final e in list) {'key': e.key, 'version': e.value.version, 'data': e.value.data}]
        })
      );
    }
    if (method == 'PUT') {
      if (limited) return (status: 429, body: '{"error":"daily limit"}');
      for (final r in ((jsonDecode(body!) as Map)['records'] as List).cast<Map>()) {
        final have = recs[r['key']];
        if (have == null || (r['version'] as String).compareTo(have.version) > 0) {
          recs[r['key'] as String] = (version: r['version'] as String, seq: ++seq, data: r['data'] as String);
        }
      }
      return (status: 200, body: jsonEncode({'seq': seq}));
    }
    return (status: 404, body: '{}');
  }
}

void main() {
  late Directory tmp;
  late HostState state;
  late HostBoard board;
  late FakeBoards relay;
  late List<String> log;
  var now = DateTime.utc(2026, 11, 24, 10);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_board_relay_');
    state = HostState.load('${tmp.path}${sep}state', environment: const {})..setRelay('https://relay.example');
    board = HostBoard(stateDir: state.directory, machineId: state.machineId, remoteOf: (_) => null);
    relay = FakeBoards();
    log = [];
    now = DateTime.utc(2026, 11, 24, 10);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void giveKey() {
    final k = newBoardKey();
    state.takeBoardKey(k.boardId, base64UrlNoPad(k.key), Hlc(1, 0, 'phone').encode());
  }

  HostBoardRelay sync() => HostBoardRelay(
      board: board,
      state: state,
      http: relay.call,
      every: const Duration(minutes: 3),
      afterChange: const Duration(seconds: 5),
      now: () => now,
      log: log.add);

  test('syncs_after_a_change_and_on_a_timer', () {
    giveKey();
    fakeAsync((fa) {
      final s = sync()..start();
      fa.flushMicrotasks();
      expect(relay.calls, ['GET changes'], reason: 'at start');
      board.edit(RecordKinds.task, 't1', {
        'content': {'title': 'Idea'}
      });
      fa.elapse(const Duration(seconds: 4));
      expect(relay.calls.where((c) => c.startsWith('PUT')), isEmpty);
      fa.elapse(const Duration(seconds: 2));
      expect(relay.calls.where((c) => c.startsWith('PUT')), hasLength(1));
      expect(relay.boards[state.boardId]!.keys, ['task/t1']);
      final before = relay.calls.length;
      fa.elapse(const Duration(minutes: 3));
      expect(relay.calls.length, greaterThan(before), reason: 'the timer');
      // Records another device put in the relay reach this board (and its devices).
      final other = Board()..put(RecordKinds.task, 'from-mac', {'content': {'title': 'Mac idea'}}, HlcClock('mac'));
      final macSync = BoardRelaySync(
          relayUrl: 'https://relay.example', boardId: state.boardId!, boardKey: state.boardKeyBytes!, http: relay.call);
      macSync.syncOnce(other);
      fa.flushMicrotasks();
      final changes = <BoardChange>[];
      board.changes.listen(changes.add);
      s.syncNow();
      fa.flushMicrotasks();
      expect(board.board.get(RecordKinds.task, 'from-mac'), isNotNull);
      expect(changes.single.records.single.id, 'from-mac');
      expect(changes.single.from, HostBoardRelay.from);
      // Its own merges do not start another sync.
      final n = relay.calls.length;
      fa.elapse(const Duration(seconds: 10));
      expect(relay.calls.length, n);
      s.dispose();
      fa.flushMicrotasks();
    });
  });

  test('nothing_happens_without_a_relay_or_a_key', () async {
    var s = sync()..start();
    await s.syncNow();
    expect(relay.calls, isEmpty, reason: 'no key');
    await s.dispose();
    giveKey();
    state.setRelay(null);
    s = sync()..start();
    await s.syncNow();
    expect(relay.calls, isEmpty, reason: 'no relay');
    await s.dispose();
  });

  test('a_429_is_logged_once_and_retried_next_day', () async {
    giveKey();
    relay.limited = true;
    board.edit(RecordKinds.task, 't1', {
      'content': {'title': 'Idea'}
    });
    final s = sync();
    await s.syncNow();
    await s.syncNow();
    expect(log.where((l) => l.contains('daily limit')), hasLength(1));
    expect(log.single, contains('05:30 IST'));
    final puts = relay.calls.where((c) => c.startsWith('PUT')).length;
    expect(puts, 1, reason: 'waits for the next day');
    now = DateTime.utc(2026, 11, 25, 0, 1);
    relay.limited = false;
    await s.syncNow();
    expect(relay.calls.where((c) => c.startsWith('PUT')).length, 2);
    expect(relay.boards[state.boardId]!.keys, ['task/t1']);
    await s.dispose();
  });

  test('relay_usage_lines_show_the_machine_and_the_board_against_the_caps', () async {
    giveKey();
    final asked = <String>[];
    final lines = await relayUsageLines(state, http: (method, uri, headers, body) async {
      asked.add('${uri.path} ${headers['Authorization']!.substring(0, 7)}');
      if (uri.path.endsWith('/usage') && uri.path.contains('/m/')) {
        return (status: 200, body: '{"messagesToday": 1234, "messageLimit": 50000}');
      }
      return (status: 200, body: '{"writesToday": 12, "writeLimit": 5000, "bytes": 524288, "byteLimit": 20971520}');
    });
    expect(lines[0], 'This machine today: 1,234 of 50,000 relay messages.');
    expect(lines[1], 'The board today: 12 of 5,000 writes; 0.50 MB of 20.0 MB stored.');
    expect(asked, ['/m/${state.machineId}/usage Bearer ', '/b/${state.boardId}/usage Bearer ']);
    expect(lines.join('\n'), isNot(contains(state.boardKey!)));
  });

  test('a_rotated_key_moves_the_board_and_deletes_the_old_one', () async {
    giveKey();
    board.edit(RecordKinds.task, 't1', {
      'content': {'title': 'Idea'}
    });
    final s = sync();
    await s.syncNow();
    final oldId = state.boardId!;
    expect(relay.boards[oldId]!.keys, ['task/t1']);
    expect(state.rotateBoardKey(), isTrue);
    await s.syncNow();
    expect(state.boardId, isNot(oldId));
    expect(relay.boards[state.boardId]!.keys, ['task/t1']);
    expect(relay.deleted, {oldId});
    expect(state.oldBoards, isEmpty);
    expect(log.join('\n'), isNot(contains(state.boardKey!)));
    await s.dispose();
  });

  test('the relay owner is warned once a day when the shared pool passes 80%; friends never', () async {
    var answer = '{"messagesToday": 1, "messageLimit": 50000, "exempt": true, "pool": {"used": 700000, "limit": 1000000, "shut": false}}';
    final warned = <int>[];
    final watch = RelayPoolWatch(state: state, warn: warned.add, http: (m, u, h, b) async => (status: 200, body: answer));
    expect(await watch.check(), 70);
    expect(warned, isEmpty);
    answer = answer.replaceFirst('700000', '820000');
    expect(await watch.check(), 82);
    expect(await watch.check(), 82);
    expect(warned, [82], reason: 'once a day');
    final friend = RelayPoolWatch(
        state: state,
        warn: warned.add,
        http: (m, u, h, b) async => (status: 200, body: answer.replaceFirst('"exempt": true', '"exempt": false')));
    expect(await friend.check(), isNull);
    expect(warned, [82]);
    // `relay usage` shows it too.
    final lines = await relayUsageLines(state, http: (m, u, h, b) async => (status: 200, body: answer));
    expect(lines[1], "Shared pool today: 82% used; this machine is the relay owner's and keeps working.");
  });
}
