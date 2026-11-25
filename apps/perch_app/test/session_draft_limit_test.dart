import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/ui/drafts.dart';
import 'package:perch_app/src/ui/session_screen.dart';
import 'package:perch_app/src/ui/usage_limit_card.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'glass_harness.dart';

void main() {
  late FakeChannels channels;
  late HostConnection conn;
  var opened = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Drafts.reset();
    channels = FakeChannels();
  });
  tearDown(() {
    if (opened) conn.dispose();
    opened = false;
  });

  Future<void> connect(WidgetTester tester) async {
    opened = true;
    conn = HostConnection(testMachine(id: 'm', label: 'Desk', lan: ['10.0.0.1:8787']), channelFactory: channels.factory);
    conn.connect();
    channels.last.send(welcome);
    channels.last.send(Sessions(sessions: [summary('s1', name: 'Fix login'), summary('s2', name: 'Docs')]));
    await tester.runAsync(() => eventually(() => conn.link.value == LinkState.online && conn.sessions.value.isNotEmpty));
    tallPhone(tester, height: 2340);
  }

  Future<void> open(WidgetTester tester, String sessionId) async {
    await tester.pumpWidget(glassApp(SessionScreen(key: ValueKey(sessionId), connection: conn, sessionId: sessionId)));
    await tester.runAsync(() => pump(30));
    await tester.pumpAndSettle();
  }

  Finder composer() => find.descendant(of: find.byKey(const ValueKey('composer')), matching: find.byType(TextField));
  String typed(WidgetTester tester) => tester.widget<TextField>(composer()).controller!.text;

  group('drafts', () {
    testWidgets('a message typed and not sent is still there after leaving the conversation', (tester) async {
      await connect(tester);
      await open(tester, 's1');
      await tester.enterText(composer(), 'half a thought');
      await tester.pumpWidget(glassApp(const SizedBox())); // closed: the board, another screen…
      await tester.pumpAndSettle();
      await open(tester, 's1');
      expect(typed(tester), 'half a thought');
    });

    testWidgets('each conversation keeps its own draft', (tester) async {
      await connect(tester);
      await open(tester, 's1');
      await tester.enterText(composer(), 'for s1');
      await open(tester, 's2');
      expect(typed(tester), '');
      await tester.enterText(composer(), 'for s2');
      await open(tester, 's1');
      expect(typed(tester), 'for s1');
    });

    testWidgets('sending clears the draft', (tester) async {
      await connect(tester);
      await open(tester, 's1');
      await tester.enterText(composer(), 'send me');
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.runAsync(() => pump(30));
      await tester.pumpAndSettle();
      await tester.pumpWidget(glassApp(const SizedBox()));
      await open(tester, 's1');
      expect(typed(tester), '');
    });

    test('drafts survive the app being closed (kept on the phone)', () async {
      Drafts.set('m', 's1', 'kept');
      await Drafts.flush();
      Drafts.reset();
      await Drafts.load();
      expect(Drafts.get('m', 's1'), 'kept');
      Drafts.set('m', 's1', '');
      await Drafts.flush();
      Drafts.reset();
      await Drafts.load();
      expect(Drafts.get('m', 's1'), '');
    });
  });

  group('usage limit in the conversation', () {
    UsageLimit limit(List<String> paused) => UsageLimit(
          resetsAtMs: DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch,
          window: LimitWindows.fiveHour,
          choice: LimitChoices.continueWhenAvailable,
          sessions: [for (final id in paused) LimitedSession(id: id, name: id, claudeWaiting: false)],
        );

    testWidgets('a session the limit paused shows the usage-limit card in its conversation', (tester) async {
      await connect(tester);
      await open(tester, 's1');
      expect(find.byType(UsageLimitCard), findsNothing);
      channels.last.send(UsageLimitMessage(limit: limit(['s1'])));
      await tester.runAsync(() => pump(30));
      await tester.pumpAndSettle();
      expect(find.byType(UsageLimitCard), findsOneWidget);
    });

    testWidgets('a limit on another session only is not shown here', (tester) async {
      await connect(tester);
      await open(tester, 's1');
      channels.last.send(UsageLimitMessage(limit: limit(['s2'])));
      await tester.runAsync(() => pump(30));
      await tester.pumpAndSettle();
      expect(find.byType(UsageLimitCard), findsNothing);
    });
  });
}
