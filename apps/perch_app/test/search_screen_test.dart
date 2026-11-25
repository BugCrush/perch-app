import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/ui/search_screen.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'fakes.dart';
import 'glass_harness.dart';

void main() {
  late FakeChannels channels;
  late HostConnection conn;
  final opened = <(String, String)>[];

  setUp(() {
    channels = FakeChannels();
    opened.clear();
  });
  tearDown(() => conn.dispose());

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => pump(40));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    conn = HostConnection(testMachine(id: 'm', label: 'Desk', lan: ['10.0.0.1:8787']), channelFactory: channels.factory);
    conn.connect();
    channels.last.send(welcome);
    channels.last.send(const Sessions(sessions: []));
    await tester.runAsync(() => eventually(() => conn.link.value == LinkState.online));
    tallPhone(tester);
    await tester.pumpWidget(glassApp(SearchScreen(
      connections: [conn],
      onOpen: (context, c, sessionId) => opened.add((c.machine.id, sessionId)),
    )));
    await tester.pumpAndSettle();
  }

  Finder field() => find.descendant(of: find.byKey(const ValueKey('search-field')), matching: find.byType(EditableText));

  Future<SearchSessions> typed(WidgetTester tester, String text) async {
    await tester.enterText(field(), text);
    await tester.pump(const Duration(milliseconds: 500)); // past the pause after typing
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<SearchSessions>().any((m) => m.query == text)));
    return channels.last.messages.whereType<SearchSessions>().last;
  }

  testWidgets('searches every machine as you type and shows the matches; a tap opens the conversation', (tester) async {
    await open(tester);
    expect(find.text('Search every conversation on your machines.'), findsOneWidget);
    await tester.enterText(field(), 'f');
    await tester.pump(const Duration(milliseconds: 500));
    expect(channels.last.messages.whereType<SearchSessions>(), isEmpty, reason: 'one letter is not enough');

    final ask = await typed(tester, 'flaky');
    expect(ask.query, 'flaky');
    channels.last.send(const SearchResults(query: 'flaky', hits: [
      SearchHit(
          sessionId: 's1',
          name: 'Fix login',
          cwd: r'D:\work\app',
          atMs: 1795000000000,
          fromUser: true,
          snippet: 'look at the flaky login test',
          running: true),
      SearchHit(sessionId: 'old-1', name: 'Old work', cwd: '/work/old', atMs: 1790000000000, snippet: 'flaky again'),
    ]));
    await settle(tester);
    expect(find.text(conn.displayName.value.toUpperCase()), findsOneWidget);
    expect(find.text('Fix login'), findsOneWidget);
    expect(find.text('Old work'), findsOneWidget);
    expect(find.textContaining('Not running'), findsOneWidget);
    expect(find.textContaining('look at the', findRichText: true), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-hit-m-old-1-0')));
    await tester.pumpAndSettle();
    expect(opened, [('m', 'old-1')]);
  });

  testWidgets('no matches, more matches than shown, and an older host are said plainly', (tester) async {
    await open(tester);
    await typed(tester, 'nothing');
    channels.last.send(const SearchResults(query: 'nothing', hits: []));
    await settle(tester);
    expect(find.text('No matches.'), findsOneWidget);

    await typed(tester, 'many');
    channels.last.send(const SearchResults(
        query: 'many', truncated: true, hits: [SearchHit(sessionId: 's1', name: 'A', snippet: 'many')]));
    await settle(tester);
    expect(find.text('More matched than shown: add words to narrow it.'), findsOneWidget);

    await typed(tester, 'older');
    channels.last.send(const ErrorMessage(code: ErrorCodes.badRequest, message: unknownMessageText));
    await settle(tester);
    expect(find.text(olderHostSearchMessage(conn.displayName.value)), findsOneWidget);
  });

  testWidgets('a late answer to an earlier search does not replace the newer one', (tester) async {
    await open(tester);
    await typed(tester, 'first');
    await typed(tester, 'second');
    channels.last.send(const SearchResults(query: 'first', hits: [SearchHit(sessionId: 's1', name: 'Stale', snippet: 'first')]));
    channels.last.send(const SearchResults(query: 'second', hits: [SearchHit(sessionId: 's2', name: 'Fresh', snippet: 'second')]));
    await settle(tester);
    expect(find.text('Fresh'), findsOneWidget);
    expect(find.text('Stale'), findsNothing);
  });
}
