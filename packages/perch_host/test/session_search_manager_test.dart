import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late Directory tmp;
  late String config;
  late FakeExternalSessions external;
  late SessionManager manager;
  final sep = Platform.pathSeparator;
  const old = '33333333-3333-4333-8333-333333333333';
  const live = '44444444-4444-4444-8444-444444444444';

  String user(String text) => jsonEncode({
        'type': 'user',
        'cwd': '/work/app',
        'timestamp': '2026-11-19T10:00:00.000Z',
        'message': {'role': 'user', 'content': text},
      });
  String claude(String text) => jsonEncode({
        'type': 'assistant',
        'cwd': '/work/app',
        'timestamp': '2026-11-19T10:01:00.000Z',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': text}
          ]
        },
      });

  void transcript(String id, List<String> lines) => File('$config${sep}projects${sep}work-app$sep$id.jsonl')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('${lines.join('\n')}\n');

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_search_mgr_');
    config = '${tmp.path}${sep}config';
    external = FakeExternalSessions();
    manager = SessionManager(launcher: fakeLauncher(), external: external, claudeConfigDir: config);
  });

  tearDown(() async {
    await manager.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('a hit in a session the machine lists opens that session, marked running', () async {
    transcript(live, [user('rename the parser'), claude('Renamed the parser module.')]);
    external.entries = [external.entry(pid: 4242, sessionId: live, cwd: '/work/app', name: 'Parser work')];
    await manager.list();
    final r = await manager.search('parser');
    expect(r.query, 'parser');
    expect(r.hits, hasLength(2));
    final listed = (await manager.list()).firstWhere((s) => s.cwd == '/work/app');
    expect(r.hits.every((h) => h.sessionId == listed.id), isTrue);
    expect(r.hits.first.running, isTrue);
    expect(r.hits.first.name, 'Parser work');
  });

  test('an old conversation nobody lists opens by its id and is listed as not running from then on', () async {
    transcript(old, [user('why does the cache miss'), claude('The cache key ignored the locale.')]);
    final r = await manager.search('cache');
    expect(r.hits.first.sessionId, old);
    expect(r.hits.first.running, isFalse);
    expect(r.hits.first.name, 'why does the cache miss');

    final updates = <SessionSummary>[];
    final sub = manager.sessionUpdates.listen(updates.add);
    final h = manager.history(old);
    expect([for (final e in h.events) if (e is AssistantText) e.text], ['The cache key ignored the locale.']);
    await Future<void>.delayed(Duration.zero);
    expect(updates.single.id, old);
    expect(updates.single.state, SessionState.stopped);
    final listed = await manager.list();
    expect(listed.firstWhere((s) => s.id == old).reason, 'Not running');
    await sub.cancel();
  });

  test('ids that are not Claude Code session ids never reach the file system', () {
    expect(() => manager.history('..$sep..${sep}secret'), throwsA(isA<NoSuchSession>()));
    expect(() => manager.history('55555555-5555-4555-8555-555555555555'), throwsA(isA<NoSuchSession>()),
        reason: 'a well-formed id without a transcript');
  });
}
