import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('a search request goes over the wire', () {
    final m = decodeClient(encodeClient(const SearchSessions(query: 'flaky test'))) as SearchSessions;
    expect(m.query, 'flaky test');
    expect(decodeClient('{"type":"searchSessions","query":""}'), isNull, reason: 'an empty search is no request');
  });

  test('search results go over the wire, hits in order', () {
    const r = SearchResults(query: 'flaky', truncated: true, hits: [
      SearchHit(
          sessionId: 's1',
          name: 'Fix login',
          cwd: '/work/app',
          atMs: 1700,
          fromUser: true,
          snippet: '…the flaky test in…',
          running: true),
      SearchHit(sessionId: 's2', name: 'Docs', cwd: '/work/docs', atMs: 1600, fromUser: false, snippet: 'flaky'),
    ]);
    final back = decodeHost(encodeHost(r)) as SearchResults;
    expect(back.query, 'flaky');
    expect(back.truncated, isTrue);
    expect(back.hits.map((h) => h.sessionId), ['s1', 's2']);
    final h = back.hits.first;
    expect(h.name, 'Fix login');
    expect(h.cwd, '/work/app');
    expect(h.atMs, 1700);
    expect(h.fromUser, isTrue);
    expect(h.snippet, '…the flaky test in…');
    expect(h.running, isTrue);
    expect(back.hits.last.running, isFalse);
  });

  test('a hit without a session id is dropped', () {
    final r = decodeHost('{"type":"searchResults","query":"x","hits":[{"sessionId":"","snippet":"x"},{"sessionId":"a","snippet":"x"}]}')
        as SearchResults;
    expect(r.hits.map((h) => h.sessionId), ['a']);
    expect(r.truncated, isFalse);
  });
}
