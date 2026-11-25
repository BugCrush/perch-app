// The app's side of a usage limit: the connection, the Memory Glass card with its countdown
// and choices, the home summary, the session menu's own choice, the resumed-differently
// toast and note, and the notifications with their buttons.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/push/push_notes.dart';
import 'package:perch_app/src/state/session_prefs.dart';
import 'package:perch_app/src/ui/conversation.dart';
import 'package:perch_app/src/ui/glass/widgets.dart';
import 'package:perch_app/src/ui/labels.dart';
import 'package:perch_app/src/ui/resumed_toast.dart';
import 'package:perch_app/src/ui/sessions_screen.dart';
import 'package:perch_app/src/ui/usage_limit_card.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'fakes.dart';
import 'glass_harness.dart';
import 'push_test.dart' show FakeSink;

void main() {
  late FakeChannels channels;
  final conns = <HostConnection>[];

  setUp(() => channels = FakeChannels());
  tearDown(() {
    for (final c in conns) {
      c.dispose();
    }
    conns.clear();
  });

  final now = DateTime(2026, 11, 15, 14, 3, 30);
  final reset = DateTime(2026, 11, 15, 15, 45);

  UsageLimit limit(
          {bool back = false,
          String choice = LimitChoices.continueWhenAvailable,
          int? resetsAtMs,
          String window = LimitWindows.fiveHour,
          String? problem,
          List<LimitedSession>? sessions}) =>
      UsageLimit(
        resetsAtMs: resetsAtMs ?? reset.millisecondsSinceEpoch,
        window: window,
        choice: choice,
        back: back,
        problem: problem,
        sessions: sessions ??
            const [
              LimitedSession(id: 's1', name: 'Docs', claudeWaiting: true),
              LimitedSession(id: 's2', name: 'Build', claudeWaiting: false, override: LimitChoices.wait),
            ],
      );

  Future<(HostConnection, FakeHostSide)> online(WidgetTester tester, {List<SessionSummary>? sessions}) async {
    final c = HostConnection(testMachine(id: 'm1', label: 'Desk', lan: ['10.0.0.1:8787']), channelFactory: channels.factory);
    conns.add(c);
    c.connect();
    final host = channels.last;
    host.send(welcome);
    host.send(Sessions(sessions: sessions ?? [summary('s1', name: 'Docs', state: SessionState.blocked)]));
    await tester.runAsync(() => eventually(() => c.link.value == LinkState.online && c.sessions.value.isNotEmpty));
    return (c, host);
  }

  List<ClientMessage> sent(FakeHostSide h) => h.messages.skip(1).toList();

  group('the connection', () {
    test('the limit arrives, a new welcome clears it, reports are passed on', () async {
      final c = HostConnection(testMachine(), channelFactory: channels.factory);
      conns.add(c);
      final reports = <ResumeReport>[];
      c.resumeReports.listen(reports.add);
      c.connect();
      channels.last.send(welcome);
      channels.last.send(UsageLimitMessage(limit: limit()));
      channels.last.send(const ResumeReport(sessionId: 's1', sessionName: 'Docs', changed: true, text: 'Resumed without the subagent'));
      await eventually(() => c.usageLimit.value != null && reports.isNotEmpty);
      expect(c.usageLimit.value!.sessions.length, 2);
      expect(reports.single.changed, isTrue);
      channels.last.send(welcome);
      await eventually(() => c.usageLimit.value == null);
    });

    test('a choice completes when the host answers; an older host is named', () async {
      final c = HostConnection(testMachine(), channelFactory: channels.factory);
      conns.add(c);
      c.connect();
      final host = channels.last;
      host.send(welcome);
      await eventually(() => c.link.value == LinkState.online);
      final done = c.chooseLimit(LimitChoices.wait, sessionId: 's1');
      await eventually(() => host.messages.whereType<UsageLimitChoice>().isNotEmpty);
      final m = host.messages.whereType<UsageLimitChoice>().single;
      expect((m.choice, m.sessionId), (LimitChoices.wait, 's1'));
      host.send(UsageLimitMessage(limit: limit(choice: LimitChoices.wait)));
      await done;
      final failing = c.chooseLimit(LimitChoices.wait);
      host.send(const ErrorMessage(code: ErrorCodes.badRequest, message: unknownMessageText));
      await expectLater(failing, throwsA(isA<SessionActionFailed>().having((e) => e.message, 'message', olderHostLimitMessage)));
    });

    test('sendWhenOnline waits for the connection', () async {
      final c = HostConnection(testMachine(), channelFactory: channels.factory);
      conns.add(c);
      final f = c.sendWhenOnline(const Interrupt(sessionId: 's1'));
      await eventually(() => channels.hosts.isNotEmpty);
      channels.last.send(welcome);
      expect(await f, isTrue);
      await eventually(() => channels.last.messages.whereType<Interrupt>().isNotEmpty);
    });
  });

  group('words', () {
    test('the countdown, the summary and each session\'s line', () {
      expect(limitCountdown(reset.millisecondsSinceEpoch, now), '01:42');
      expect(limitCountdown(reset.millisecondsSinceEpoch, reset.add(const Duration(seconds: 5))), '00:00');
      expect(limitCountdown(reset.add(const Duration(days: 2)).millisecondsSinceEpoch, now), isNull);
      expect(limitSummary(limit(back: true), now), 'Usage is back');
      expect(limitSummary(limit(), now), startsWith('Usage limit · resets '));
      final l = limit();
      expect(limitedSessionLine(l, l.sessions[0]), 'Claude Code continues by itself');
      expect(limitedSessionLine(l, l.sessions[1]), 'Waits for you (this session)');
      expect(limitedSessionLine(limit(sessions: const [LimitedSession(id: 'x', name: 'x', claudeWaiting: false)]),
          const LimitedSession(id: 'x', name: 'x', claudeWaiting: false)), 'Perch sends please continue');
    });

    test('the session menu offers the choice only while that session is paused', () {
      final s = summary('s1', state: SessionState.blocked);
      final items = sessionMenuItems(s, pinned: false, muted: false, limit: limit());
      expect(items.take(2), [SessionMenuItem.limitContinue, SessionMenuItem.limitWait]);
      expect(sessionMenuItems(summary('zz'), pinned: false, muted: false, limit: limit()),
          isNot(contains(SessionMenuItem.limitWait)));
      expect(sessionMenuChosen(SessionMenuItem.limitWait, 's2', limit()), isTrue);
      expect(sessionMenuChosen(SessionMenuItem.limitContinue, 's1', limit()), isTrue);
    });
  });

  group('the card', () {
    testWidgets('countdown, sessions, the choice marked, Switch account greyed on an older host', (tester) async {
      final (c, host) = await online(tester);
      tallPhone(tester);
      await tester.pumpWidget(glassApp(GlassScaffold(
          child: SingleChildScrollView(
              child: UsageLimitCard(
                  connection: c, limit: limit(problem: "Couldn't stop Claude Code from continuing on Desk"), clock: () => now)))));
      await tester.pump();
      expect(find.text('USAGE LIMIT'), findsOneWidget);
      expect(find.text('5-hour'), findsOneWidget);
      expect(find.bySemanticsLabel('01:42'), findsOneWidget);
      expect(find.text('Docs'), findsOneWidget);
      expect(find.text('Waits for you (this session)'), findsOneWidget);
      expect(find.textContaining("Couldn't stop Claude Code"), findsOneWidget);
      expect(find.text('Not available yet'), findsNothing);
      expect(find.text('Update Perch on this machine to switch accounts'), findsOneWidget);
      // A host without accounts: Switch account does nothing.
      await tester.tap(find.byKey(const ValueKey('limit-switch-account')));
      await tester.pump();
      expect(sent(host).whereType<UsageLimitChoice>(), isEmpty);
      // Wait is chosen for the machine.
      await tester.tap(find.byKey(const ValueKey('limit-choose-wait')));
      await tester.pump();
      await tester.runAsync(() => eventually(() => sent(host).whereType<UsageLimitChoice>().isNotEmpty));
      expect(sent(host).whereType<UsageLimitChoice>().single.choice, LimitChoices.wait);
      host.send(UsageLimitMessage(limit: limit(choice: LimitChoices.wait)));
      await tester.runAsync(() => eventually(() => c.usageLimit.value?.choice == LimitChoices.wait));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a weekly limit shows its date; an unknown reset says so', (tester) async {
      final (c, _) = await online(tester);
      tallPhone(tester);
      final weekly = limit(window: LimitWindows.sevenDay, resetsAtMs: DateTime.utc(2026, 11, 17, 18, 30).millisecondsSinceEpoch);
      await tester.pumpWidget(glassApp(UsageLimitCard(connection: c, limit: weekly, clock: () => now)));
      expect(find.text('Weekly'), findsOneWidget);
      expect(find.text('Resets 18 Nov 00:00'), findsOneWidget, reason: 'IST, as every time in the app');
      await tester.pumpWidget(glassApp(UsageLimitCard(
          connection: c, limit: const UsageLimit(sessions: [LimitedSession(id: 's1', name: 'Docs')]), clock: () => now)));
      expect(find.text('Reset time unknown'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('usage is back: Continue sends please continue to every paused session, Open opens one', (tester) async {
      final (c, host) = await online(tester);
      tallPhone(tester);
      final opened = <String>[];
      await tester.pumpWidget(glassApp(GlassScaffold(
          child: UsageLimitCard(
              connection: c, limit: limit(back: true), clock: () => now, onOpenSession: (_, _, id) => opened.add(id)))));
      expect(find.text('USAGE IS BACK'), findsOneWidget);
      expect(find.text('2 sessions paused'), findsOneWidget);
      expect(find.text('Switch account'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('limit-continue-now')));
      await tester.pump();
      await tester.runAsync(() => eventually(() => sent(host).whereType<UsageLimitChoice>().isNotEmpty));
      final m = sent(host).whereType<UsageLimitChoice>().single;
      expect((m.choice, m.sessionId), (LimitChoices.continueNow, null));
      host.send(UsageLimitMessage(limit: limit(back: true)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('limit-open')));
      expect(opened, ['s1']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the machine screen shows the card on top', (tester) async {
      final (c, host) = await online(tester);
      host.send(UsageLimitMessage(limit: limit()));
      await tester.runAsync(() => eventually(() => c.usageLimit.value != null));
      tallPhone(tester);
      await tester.pumpWidget(glassApp(SessionsScreen(connection: c, prefs: SessionPrefs(persist: false))));
      await tester.pump();
      expect(find.byKey(const ValueKey('usage-limit-card')), findsOneWidget);
      host.send(const UsageLimitMessage());
      await tester.runAsync(() => eventually(() => c.usageLimit.value == null));
      await tester.pump();
      expect(find.byKey(const ValueKey('usage-limit-card')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the toast and the note', () {
    testWidgets('15 seconds with Stop and Open', (tester) async {
      tallPhone(tester);
      var stopped = 0, opened = 0;
      await tester.pumpWidget(glassApp(const SizedBox.expand(key: ValueKey('page'))));
      void show() => showResumedToast(Overlay.of(tester.element(find.byKey(const ValueKey('page')))),
          text: resumedToastText('Docs', 'Resumed without the subagent'), onStop: () => stopped++, onOpen: () => opened++);
      show();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Docs resumed without the subagent'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(find.byKey(const ValueKey('resumed-toast')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('toast-stop')));
      await tester.pump();
      expect(stopped, 1);
      expect(find.text('Stopped. The session waits for you.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('resumed-toast')), findsNothing);
      // Left alone, it goes after 15 seconds.
      show();
      await tester.pump(const Duration(seconds: 14));
      expect(find.byKey(const ValueKey('resumed-toast')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('resumed-toast')), findsNothing);
      expect(opened, 0);
    });

    testWidgets('the lasting note stands out in the conversation; the quiet one does not', (tester) async {
      await tester.pumpWidget(glassApp(Column(children: [
        EventView(Notice('Resumed without the subagent', atMs: DateTime.utc(2026, 11, 15, 10).millisecondsSinceEpoch)),
        EventView(Notice('Resumed after the usage limit')),
      ])));
      expect(find.byKey(const ValueKey('resumed-changed-note')), findsOneWidget);
      expect(find.text('— Resumed after the usage limit —'), findsOneWidget);
      expect(isResumedChangedNote('Resumed with a different agent (Explore instead of general-purpose)'), isTrue);
    });
  });

  group('notifications', () {
    final desk = testMachine(id: 'mid-desk', label: 'Desk', relayUrl: 'https://relay.example');
    Map<String, dynamic> data(PushNote n) => {'m': desk.id, 'p': sealPush(desk.secretBytes!, desk.id, n)};
    PushNote back() => PushNote(
        title: 'Desk',
        body: 'Usage is back · 2 sessions paused',
        machineId: desk.id,
        sessionId: usageLimitPushId,
        kind: PushKinds.usageBack,
        sessionIds: const ['s1', 's2']);

    test('usage is back has Continue and Open; it is dropped only when every session is muted', () async {
      final sink = FakeSink();
      expect(await handlePushData(data(back()), [desk], sink, muted: (m, s) => s == 's1'), isNotNull);
      expect(sink.buttons.single.map((b) => b.id), [PushActions.continueNow, PushActions.open]);
      expect(sink.buttons.single.first.opensApp, isFalse);
      final tap = PushTap.decode(sink.shown.single.payload)!;
      expect(tap.forMachine, isTrue);
      expect(await handlePushData(data(back()), [desk], FakeSink(), muted: (m, s) => true), isNull);
    });

    test('resumed differently has Stop and Open, and is left to the toast while the app is in front', () async {
      final note = PushNote(
          title: 'Desk', body: 'Docs resumed without the subagent', machineId: desk.id, sessionId: 's1', kind: PushKinds.resumedChanged);
      final sink = FakeSink();
      expect(await handlePushData(data(note), [desk], sink), isNotNull);
      expect(sink.buttons.single.map((b) => b.id), [PushActions.stop, PushActions.open]);
      expect(await handlePushData(data(note), [desk], FakeSink(), foreground: true), isNull);
    });

    test('a button is a message to the host', () {
      const t = PushTap(machineId: 'm', sessionId: usageLimitPushId);
      expect(pushActionMessage(t), isNull);
      final cont = pushActionMessage(t.withAction(PushActions.continueNow)) as UsageLimitChoice;
      expect((cont.choice, cont.sessionId), (LimitChoices.continueNow, null));
      final stop = pushActionMessage(const PushTap(machineId: 'm', sessionId: 's1', action: PushActions.stop)) as Interrupt;
      expect(stop.sessionId, 's1');
      expect(PushTap.decode(t.withAction(PushActions.stop).encode())!.action, PushActions.stop);
    });

    test('Continue from the notification reaches the host on a connection of its own', () async {
      final f = sendPushAction(
          const PushTap(machineId: 'mid-desk', sessionId: usageLimitPushId, action: PushActions.continueNow), [desk], 'dev-1',
          channelFactory: channels.factory);
      await eventually(() => channels.hosts.isNotEmpty);
      final host = channels.last;
      host.send(welcome);
      await eventually(() => host.messages.whereType<UsageLimitChoice>().isNotEmpty);
      expect(host.messages.whereType<UsageLimitChoice>().single.choice, LimitChoices.continueNow);
      host.send(UsageLimitMessage(limit: limit(back: true)));
      expect(await f, isTrue);
    });

    test('an unknown machine or no answer: false (the app is opened instead)', () async {
      expect(
          await sendPushAction(const PushTap(machineId: 'nope', sessionId: 's', action: PushActions.stop), [desk], 'd'), isFalse);
      channels.modeFor = (_) => FakeMode.silent;
      expect(
          await sendPushAction(const PushTap(machineId: 'mid-desk', sessionId: 's1', action: PushActions.stop), [desk], 'd',
              channelFactory: channels.factory, within: const Duration(milliseconds: 300)),
          isFalse);
    });
  });
}
