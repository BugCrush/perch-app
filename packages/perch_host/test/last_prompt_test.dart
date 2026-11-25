// The time of the owner's last message to a session, from its transcript.
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/transcript.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final sep = Platform.pathSeparator;
const cid = 'aaaaaaaa-0000-4000-8000-000000000001';

String user(String text, String at, {Map<String, dynamic> extra = const {}}) => jsonEncode({
      'type': 'user',
      'message': {'role': 'user', 'content': text},
      'timestamp': at,
      ...extra,
    });

String assistant(String text, String at) => jsonEncode({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': text}
        ]
      },
      'timestamp': at,
    });

String toolResult(String at) => jsonEncode({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': 'toolu_1', 'content': 'done'}
        ]
      },
      'timestamp': at,
    });

String peer(String name, String body, String at) => jsonEncode({
      'type': 'user',
      'isMeta': true,
      'message': {'role': 'user', 'content': 'Another Claude session sent a message:\n$body'},
      'origin': {'kind': 'peer', 'from': 'unknown', 'name': name, 'body': body},
      'timestamp': at,
    });

int ms(String iso) => DateTime.parse(iso).millisecondsSinceEpoch;

int? promptAt(String line) {
  final t = parseTranscriptLine(line);
  return t is TranscriptEvents ? t.ownerPromptAtMs : null;
}

void main() {
  group('which lines are the owner\'s messages', () {
    const at = '2026-11-14T15:41:00.000Z';
    test('typed or sent from Perch: yes', () {
      expect(promptAt(user('Fix the login', at)), ms(at));
      expect(promptAt(peer('perch-phone', 'From the phone', at)), ms(at), reason: 'the inbox');
    });
    test('replies, tool results, meta and other sessions: no', () {
      expect(promptAt(assistant('Done', at)), isNull);
      expect(promptAt(toolResult(at)), isNull);
      expect(promptAt(peer('api-worker', 'Schema changed', at)), isNull);
      expect(promptAt(user('<command-name>/exit</command-name>', at)), isNull);
      expect(promptAt(user('Caveat', at, extra: {'isMeta': true})), isNull);
      expect(promptAt(user('Summary of the earlier conversation', at,
          extra: {'isCompactSummary': true, 'isVisibleInTranscriptOnly': true})), isNull);
      expect(promptAt(user('Subagent prompt', at, extra: {'isSidechain': true})), isNull);
    });
  });

  test('the tail scan finds the latest owner message, past later replies and tool results', () {
    final tmp = Directory.systemTemp.createTempSync('perch_lp_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final f = File('${tmp.path}$sep$cid.jsonl');
    final lines = [
      user('first', '2026-11-14T10:00:00.000Z'),
      // Lots of output after the second prompt: more than one 64 KB chunk.
      user('second', '2026-11-14T10:05:00.000Z'),
      for (var i = 0; i < 400; i++) assistant('x' * 300, '2026-11-14T10:06:00.000Z'),
      toolResult('2026-11-14T10:07:00.000Z'),
      peer('api-worker', 'not the owner', '2026-11-14T10:08:00.000Z'),
    ];
    f.writeAsStringSync(lines.join('\n'));
    expect(latestOwnerPromptMs(f), ms('2026-11-14T10:05:00.000Z'));
    f.writeAsStringSync([assistant('only replies', '2026-11-14T10:00:00.000Z')].join('\n'));
    expect(latestOwnerPromptMs(f), isNull);
  });

  group('the session list', () {
    late Directory tmp;
    late Directory work;
    late String config;
    late FakeExternalSessions external;
    late SessionManager manager;
    late File transcript;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('perch_lp_');
      work = Directory('${tmp.path}${sep}work')..createSync();
      config = '${tmp.path}${sep}config';
      final dir = Directory('$config${sep}projects$sep-w')..createSync(recursive: true);
      transcript = File('${dir.path}$sep$cid.jsonl')
        ..writeAsStringSync('${user('hello', '2026-11-14T10:00:00.000Z')}\n${assistant('hi', '2026-11-14T10:00:01.000Z')}\n');
      external = FakeExternalSessions()..entries = [];
      manager = SessionManager(launcher: fakeLauncher(), external: external, claudeConfigDir: config);
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
    });

    tearDown(() async {
      await manager.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('an unwatched session carries the time, re-read only when the file changes', () async {
      expect((await manager.list()).single.lastPromptAtMs, ms('2026-11-14T10:00:00.000Z'));
      transcript.writeAsStringSync('${user('again', '2026-11-14T11:30:00.000Z')}\n', mode: FileMode.append);
      expect((await manager.list()).single.lastPromptAtMs, ms('2026-11-14T11:30:00.000Z'));
      // A reply does not change it.
      transcript.writeAsStringSync('${assistant('ok', '2026-11-14T11:31:00.000Z')}\n', mode: FileMode.append);
      expect((await manager.list()).single.lastPromptAtMs, ms('2026-11-14T11:30:00.000Z'));
    });

    test('a watched session tells devices at once when a new message arrives', () async {
      final id = (await manager.list()).single.id;
      manager.history(id); // a device opened it: its transcript is watched
      final updates = <SessionSummary>[];
      final sub = manager.sessionUpdates.listen(updates.add);
      addTearDown(sub.cancel);
      transcript.writeAsStringSync('${peer('perch-phone', 'from the phone', '2026-11-14T12:00:00.000Z')}\n',
          mode: FileMode.append);
      await waitUntil(() => updates.any((u) => u.lastPromptAtMs == ms('2026-11-14T12:00:00.000Z')),
          timeout: const Duration(seconds: 5));
      expect((await manager.list()).single.lastPromptAtMs, ms('2026-11-14T12:00:00.000Z'));
    });

    test('a session that ended keeps it', () async {
      await manager.list();
      external.entries = [];
      final ended = (await manager.list()).single;
      expect(ended.live, isFalse);
      expect(ended.lastPromptAtMs, ms('2026-11-14T10:00:00.000Z'));
    });

    test('a message sent to a session Perch runs counts', () async {
      external.entries = [];
      final s = await manager.start(cwd: work.path, prompt: 'go');
      expect(s.lastPromptAtMs, isNotNull);
    });
  });
}
