import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/ui/sessions_screen.dart';
import 'package:perch_app/src/time_format.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'fakes.dart';
import 'glass_harness.dart';

int utc(String iso) => DateTime.parse(iso).millisecondsSinceEpoch;

void main() {
  group('IST times', () {
    // 2026-11-14 23:00 IST is 17:30 UTC.
    final now = DateTime.utc(2026, 11, 14, 17, 30);

    test('today in IST shows the 24-hour clock only', () {
      expect(formatIst(utc('2026-11-14T15:41:00Z'), now: now), '21:11');
      expect(formatIst(utc('2026-11-14T03:35:00Z'), now: now), '09:05');
    });

    test('another IST day shows the day and month too', () {
      expect(formatIst(utc('2026-11-13T15:41:00Z'), now: now), '13 Nov 21:11');
      expect(formatIst(utc('2025-12-31T18:29:00Z'), now: now), '31 Dec 23:59');
    });

    test('UTC is converted to IST (+05:30), whatever the phone\'s timezone', () {
      // 19:00 UTC on the 13th is 00:30 IST on the 14th: today in IST.
      expect(formatIst(utc('2026-11-13T19:00:00Z'), now: now), '00:30');
      // A local (non-UTC) "now" names the same instant.
      expect(formatIst(utc('2026-11-13T19:00:00Z'), now: now.toLocal()), '00:30');
    });

    test('the IST midnight boundary', () {
      // 18:29:59 UTC is 23:59 IST on the 13th; 18:30 UTC is 00:00 IST on the 14th.
      expect(formatIst(utc('2026-11-13T18:29:59Z'), now: now), '13 Nov 23:59');
      expect(formatIst(utc('2026-11-13T18:30:00Z'), now: now), '00:00');
      // Just after IST midnight, a message from 23:58 IST is yesterday.
      final justAfter = DateTime.utc(2026, 11, 13, 18, 31);
      expect(formatIst(utc('2026-11-13T18:28:00Z'), now: justAfter), '13 Nov 23:58');
      expect(formatIst(utc('2026-11-13T18:30:30Z'), now: justAfter), '00:00');
    });
  });

  testWidgets('each session tile shows when the owner last messaged it, in IST', (tester) async {
    final channels = FakeChannels();
    final c = HostConnection(testMachine(id: 'm1', label: 'm1', lan: ['10.0.0.1:8787']), channelFactory: channels.factory);
    addTearDown(c.dispose);
    c.connect();
    channels.last.send(welcome);
    channels.last.send(Sessions(sessions: [
      summary('a', name: 'Today', lastPromptAtMs: utc('2026-11-14T15:41:00Z')),
      summary('b', name: 'Earlier', lastPromptAtMs: utc('2026-11-12T04:05:00Z')),
      summary('c', name: 'Unknown'),
    ]));
    await tester.runAsync(() => eventually(() => c.sessions.value.length == 3));
    tallPhone(tester);
    await tester.pumpWidget(glassApp(SessionsScreen(connection: c, clock: () => DateTime.utc(2026, 11, 14, 17, 30))));
    await tester.pumpAndSettle();
    expect(find.text('Last message 21:11'), findsOneWidget);
    expect(find.text('Last message 12 Nov 09:35'), findsOneWidget);
    expect(find.byKey(const ValueKey('lastMessage-c')), findsNothing);

    // A newer message arrives: the tile follows.
    channels.last.send(SessionUpdated(session: summary('c', name: 'Unknown', lastPromptAtMs: utc('2026-11-14T17:00:00Z'))));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(find.text('Last message 22:30'), findsOneWidget);
  });
}
