import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/ui/session_screen.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'fakes.dart';
import 'glass_harness.dart';

void main() {
  late FakeChannels channels;
  late HostConnection conn;

  setUp(() => channels = FakeChannels());
  tearDown(() => conn.dispose());

  Future<void> open(WidgetTester tester, {int replies = 40}) async {
    conn = HostConnection(testMachine(id: 'm', label: 'Desk', lan: ['10.0.0.1:8787']), channelFactory: channels.factory);
    conn.connect();
    channels.last.send(welcome);
    channels.last.send(Sessions(sessions: [summary('s1', name: 'Fix login')]));
    await tester.runAsync(() => eventually(() => conn.link.value == LinkState.online && conn.sessions.value.isNotEmpty));
    tallPhone(tester, height: 2340);
    await tester.pumpWidget(glassApp(SessionScreen(connection: conn, sessionId: 's1')));
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<Subscribe>().isNotEmpty));
    channels.last.send(Events(sessionId: 's1', events: [
      for (var i = 1; i <= replies; i++) AssistantText('Reply number $i\n\nwith a second paragraph to give it height', seq: i),
    ]));
    await tester.runAsync(() => pump(30));
    await tester.pumpAndSettle();
  }

  Finder toBottom() => find.byKey(const ValueKey('to-bottom'));

  testWidgets('scrolling up a little shows the go-to-bottom button; a tap goes back to the newest message', (tester) async {
    await open(tester);
    expect(toBottom(), findsNothing, reason: 'at the bottom: no button');
    expect(find.text('Reply number 40', findRichText: true), findsWidgets);

    await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(toBottom(), findsOneWidget);

    await tester.tap(toBottom());
    await tester.pumpAndSettle();
    expect(toBottom(), findsNothing);
    final s = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(s.pixels, closeTo(s.maxScrollExtent, 2));
  });

  testWidgets('a very small scroll does not show it', (tester) async {
    await open(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(toBottom(), findsNothing);
  });

  testWidgets('a short conversation that fits never shows it', (tester) async {
    await open(tester, replies: 1);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(toBottom(), findsNothing);
  });

  testWidgets('the end moving while it glides down (new messages, a longer list than estimated): it still ends at the newest one', (tester) async {
    await open(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 300));
    await tester.pumpAndSettle();
    await tester.tap(toBottom());
    await tester.pump(const Duration(milliseconds: 100));
    channels.last.send(Events(sessionId: 's1', events: [
      for (var i = 41; i <= 44; i++) AssistantText('Reply number $i\n\nwith a second paragraph to give it height', seq: i),
    ]));
    // Delivered while the glide is still on its way.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('Reply number 44', findRichText: true), findsWidgets);
    await tester.pumpAndSettle();
    final s = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(s.pixels, closeTo(s.maxScrollExtent, 2));
    expect(toBottom(), findsNothing);
  });
}
