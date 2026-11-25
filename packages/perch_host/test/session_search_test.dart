import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/session_search.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  final sep = Platform.pathSeparator;

  setUp(() => tmp = Directory.systemTemp.createTempSync('perch_search_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String line(String type, Object content, {String cwd = '/work/app', String at = '2026-11-19T10:00:00.000Z'}) =>
      jsonEncode({
        'type': type,
        'cwd': cwd,
        'timestamp': at,
        'message': {'role': type, 'content': content},
      });
  String user(String text, {String cwd = '/work/app', String at = '2026-11-19T10:00:00.000Z'}) =>
      line('user', text, cwd: cwd, at: at);
  String claude(String text, {String at = '2026-11-19T10:01:00.000Z'}) => line('assistant', [
        {'type': 'text', 'text': text}
      ], at: at);

  File transcript(String project, String id, List<String> lines, {DateTime? modified}) {
    final f = File('${tmp.path}${sep}projects$sep$project$sep$id.jsonl')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${lines.join('\n')}\n');
    if (modified != null) f.setLastModifiedSync(modified);
    return f;
  }

  const a = '11111111-1111-4111-8111-111111111111';
  const b = '22222222-2222-4222-8222-222222222222';

  test('finds the owner\'s messages and Claude\'s replies, case-insensitive, with the words around them', () {
    transcript('app', a, [
      user('Please look at the Flaky login test again'),
      claude('The flaky test waits on a timer; I made it wait for the event instead.'),
      line('user', [
        {'type': 'tool_result', 'tool_use_id': 't1', 'content': 'flaky output of a tool'}
      ]),
    ]);
    final r = searchTranscripts(configDir: tmp.path, query: 'flaky');
    expect(r.hits, hasLength(2), reason: 'tool output is not searched');
    final first = r.hits.firstWhere((h) => h.fromUser);
    expect(first.claudeId, a);
    expect(first.cwd, '/work/app');
    expect(first.snippet, contains('Flaky login test'));
    expect(first.atMs, DateTime.utc(2026, 11, 19, 10).millisecondsSinceEpoch);
    expect(r.hits.firstWhere((h) => !h.fromUser).snippet, contains('flaky test waits'));
    expect(r.truncated, isFalse);
  });

  test('the newest conversations come first; a few hits per conversation; a cap on all hits', () {
    transcript('app', a, [for (var i = 0; i < 6; i++) user('deploy step $i')], modified: DateTime(2026, 11, 1));
    transcript('docs', b, [user('deploy the docs')], modified: DateTime(2026, 11, 18));
    final r = searchTranscripts(configDir: tmp.path, query: 'deploy', perSession: 3, limit: 10);
    expect(r.hits.first.claudeId, b);
    expect(r.hits.where((h) => h.claudeId == a), hasLength(3));
    expect(r.truncated, isTrue, reason: 'more hits in a than shown');
    final capped = searchTranscripts(configDir: tmp.path, query: 'deploy', perSession: 10, limit: 4);
    expect(capped.hits, hasLength(4));
    expect(capped.truncated, isTrue);
  });

  test('a long message gives a short snippet around the match', () {
    final long = '${'word ' * 200}NEEDLE ${'more ' * 200}';
    transcript('app', a, [user(long)]);
    final h = searchTranscripts(configDir: tmp.path, query: 'needle').hits.single;
    expect(h.snippet.length, lessThan(220));
    expect(h.snippet, contains('NEEDLE'));
    expect(h.snippet, startsWith('…'));
    expect(h.snippet, endsWith('…'));
  });

  test('the session\'s name: the owner\'s name for it, else Claude\'s title, else its first message', () {
    transcript('app', a, [
      user('first words of the session'),
      jsonEncode({'type': 'ai-title', 'aiTitle': 'Claude title', 'sessionId': a}),
      jsonEncode({'type': 'custom-title', 'customTitle': 'My name', 'sessionId': a}),
      claude('match here'),
    ]);
    transcript('docs', b, [user('only a first message with a match')]);
    final r = searchTranscripts(configDir: tmp.path, query: 'match');
    expect(r.hits.firstWhere((h) => h.claudeId == a).name, 'My name');
    expect(r.hits.firstWhere((h) => h.claudeId == b).name, 'only a first message with a match');
  });

  test('the same conversation in two project folders is searched once (the newest copy)', () {
    transcript('old', a, [user('stale copy match')], modified: DateTime(2026, 11, 1));
    transcript('new', a, [user('fresh copy match')], modified: DateTime(2026, 11, 18));
    final r = searchTranscripts(configDir: tmp.path, query: 'match');
    expect(r.hits.single.snippet, contains('fresh copy'));
  });

  test('subagent transcripts, self-test sessions and other files are not searched', () {
    transcript('app', a, [user('top level match')]);
    File('${tmp.path}${sep}projects${sep}app$sep$a${sep}subagents${sep}agent-1.jsonl')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${user('subagent match')}\n');
    transcript('selftest', b, [user('self-test match', cwd: '${sep}x${sep}perch${sep}selftest')]);
    File('${tmp.path}${sep}projects${sep}app${sep}notes.txt').writeAsStringSync('match');
    final r = searchTranscripts(configDir: tmp.path, query: 'match');
    expect(r.hits.map((h) => h.snippet), ['top level match']);
  });

  test('no projects folder, an empty or too short query: nothing', () {
    expect(searchTranscripts(configDir: tmp.path, query: 'x').hits, isEmpty);
    transcript('app', a, [user('ab')]);
    expect(searchTranscripts(configDir: tmp.path, query: ' ').hits, isEmpty);
    expect(searchTranscripts(configDir: tmp.path, query: 'a').hits, isEmpty, reason: 'at least 2 characters');
  });

  group('the index', () {
    String index() => '${tmp.path}${sep}index';

    test('a search builds it; later only what was appended is read', () {
      final f = transcript('app', a, [user('first apple message')], modified: DateTime(2026, 11, 1));
      expect(searchTranscripts(configDir: tmp.path, indexDir: index(), query: 'apple').hits, hasLength(1));
      expect(File('${index()}$sep$a.json').existsSync(), isTrue);
      // Garble what was already read (same length): the index still has it, so it is not read again.
      final before = f.readAsStringSync();
      final garbled = before.replaceAll('apple', 'xxxxx');
      f.writeAsStringSync('$garbled${user('second apple message')}\n');
      f.setLastModifiedSync(DateTime(2026, 11, 2));
      final r = searchTranscripts(configDir: tmp.path, indexDir: index(), query: 'apple');
      expect(r.hits.map((h) => h.snippet), ['second apple message', 'first apple message']);
    });

    test('a transcript that was replaced or shrank is read again from the start', () {
      final f = transcript('app', a, [user('old words here'), user('more old words')], modified: DateTime(2026, 11, 1));
      searchTranscripts(configDir: tmp.path, indexDir: index(), query: 'old');
      f.writeAsStringSync('${user('new')}\n');
      f.setLastModifiedSync(DateTime(2026, 11, 2));
      expect(searchTranscripts(configDir: tmp.path, indexDir: index(), query: 'old').hits, isEmpty);
      expect(searchTranscripts(configDir: tmp.path, indexDir: index(), query: 'new').hits.single.snippet, 'new');
    });

    test('an entry whose conversation is gone is removed', () {
      final f = transcript('app', a, [user('gone soon')]);
      searchTranscripts(configDir: tmp.path, indexDir: index(), query: 'gone');
      f.deleteSync();
      searchTranscripts(configDir: tmp.path, indexDir: index(), query: 'gone');
      expect(File('${index()}$sep$a.json').existsSync(), isFalse);
    });

    test('very long lines (tool output, pictures) are skipped', () {
      transcript('app', a, [user('needle ${'x' * (maxIndexedLine + 10)}'), user('short needle')]);
      final r = searchTranscripts(configDir: tmp.path, indexDir: index(), query: 'needle');
      expect(r.hits.map((h) => h.snippet), ['short needle']);
    });

    test('out of time: conversations not indexed yet are left out and the result says so', () {
      transcript('new', a, [user('budget match new')], modified: DateTime(2026, 11, 18));
      transcript('old', b, [user('budget match old')], modified: DateTime(2026, 11, 1));
      var t = DateTime(2026, 11, 19, 10);
      DateTime clock() => t = t.add(const Duration(seconds: 3));
      final r = searchTranscripts(
          configDir: tmp.path, indexDir: index(), query: 'budget', budget: const Duration(seconds: 4), clock: clock);
      expect(r.hits.map((h) => h.claudeId), [a]);
      expect(r.truncated, isTrue);
      updateSearchIndex(configDir: tmp.path, indexDir: index());
      final all = searchTranscripts(configDir: tmp.path, indexDir: index(), query: 'budget', clock: clock);
      expect(all.hits.map((h) => h.claudeId), [a, b], reason: 'the background update indexed the rest');
    });
  });

  test('a session id is a Claude Code id (a UUID), never a path', () {
    expect(isClaudeSessionId(a), isTrue);
    expect(isClaudeSessionId('../../secret'), isFalse);
    expect(isClaudeSessionId('pid:1234'), isFalse);
    expect(isClaudeSessionId('${a}x'), isFalse);
  });
}
