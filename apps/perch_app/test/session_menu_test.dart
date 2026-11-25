import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/ui/labels.dart';
import 'package:perch_app/src/ui/sessions_screen.dart';
import 'package:perch_app/src/state/providers.dart';
import 'package:perch_app/src/state/session_prefs.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'glass_harness.dart';

void main() {
  late FakeChannels channels;
  late SessionPrefs prefs;
  final conns = <HostConnection>[];

  setUp(() {
    channels = FakeChannels();
    prefs = SessionPrefs(persist: false);
  });
  tearDown(() {
    for (final c in conns) {
      c.dispose();
    }
    conns.clear();
  });

  Future<(HostConnection, FakeHostSide)> online(WidgetTester tester, List<SessionSummary> sessions, {String id = 'm1'}) async {
    final c = HostConnection(testMachine(id: id, label: id, lan: ['10.0.0.1:8787']), channelFactory: channels.factory);
    conns.add(c);
    c.connect();
    final host = channels.last;
    host.send(welcome);
    host.send(Sessions(sessions: sessions));
    await tester.runAsync(() => eventually(() => c.link.value == LinkState.online && c.sessions.value.length == sessions.length));
    return (c, host);
  }

  Future<void> show(WidgetTester tester, HostConnection c) async {
    tallPhone(tester);
    await tester.pumpWidget(glassApp(SessionsScreen(connection: c, prefs: prefs)));
    await tester.pumpAndSettle();
  }

  Future<void> openMenu(WidgetTester tester, String name, [String? id]) async {
    await tester.scrollUntilVisible(find.text(name).first, 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    final row = find.ancestor(of: find.text(name).first, matching: find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('session-'))).first;
    await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.more_vert_rounded)));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String item) async {
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  List<ClientMessage> sent(FakeHostSide h) => h.messages.skip(1).toList();

  test('menu items follow the session state', () {
    final working = summary('a', state: SessionState.working);
    expect(sessionMenuItems(working, pinned: false, muted: false), [
      SessionMenuItem.interrupt,
      SessionMenuItem.mute,
      SessionMenuItem.rename,
      SessionMenuItem.model,
      SessionMenuItem.pin,
      SessionMenuItem.newHere,
      SessionMenuItem.end,
      SessionMenuItem.delete,
    ]);
    final ended = summary('b', state: SessionState.stopped, live: false);
    expect(sessionMenuItems(ended, pinned: true, muted: true), [
      SessionMenuItem.unmute,
      SessionMenuItem.rename,
      SessionMenuItem.unpin,
      SessionMenuItem.newHere,
      SessionMenuItem.resume,
      SessionMenuItem.hide,
      SessionMenuItem.delete,
    ]);
    expect(sessionMenuItems(summary('c'), pinned: false, muted: false), isNot(contains(SessionMenuItem.interrupt)));
  });

  testWidgets('three dots and press-and-hold open the same menu', (tester) async {
    final (c, _) = await online(tester, [summary('a', name: 'Busy one', state: SessionState.working)]);
    await show(tester, c);
    await openMenu(tester, 'Busy one');
    for (final item in ['Interrupt', 'Mute notifications', 'Rename…', 'Pin to top', 'New session here…', 'End session…', 'Delete…']) {
      expect(find.text(item), findsOneWidget, reason: item);
    }
    expect(find.text('Resume'), findsNothing);
    expect(find.text('Hide'), findsNothing);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('Interrupt'), findsNothing);

    await tester.longPress(find.text('Busy one'));
    await tester.pumpAndSettle();
    expect(find.text('Interrupt'), findsOneWidget);
  });

  testWidgets('interrupt and end session (after a confirmation) reach the host', (tester) async {
    final (c, host) = await online(tester, [summary('a', name: 'Busy one', state: SessionState.working)]);
    await show(tester, c);
    await openMenu(tester, 'Busy one');
    await choose(tester, 'Interrupt');
    await openMenu(tester, 'Busy one');
    await choose(tester, 'End session…');
    expect(find.text('End Busy one?'), findsOneWidget);
    await tapDanger(tester, 'End session');
    await tester.runAsync(() => pump(50));
    expect(sent(host).map((m) => m.runtimeType), [Interrupt, StopSession]);
  });

  testWidgets('pinned sessions show first; at most 5 per machine', (tester) async {
    final (c, _) = await online(tester, [
      for (var i = 0; i < 7; i++) summary('s$i', name: 'Session $i', startedAtMs: 100 - i),
    ]);
    await show(tester, c);
    double y(String text) => tester.getTopLeft(find.text(text).first).dy;
    expect(find.text('PINNED'), findsNothing);
    await openMenu(tester, 'Session 4');
    await choose(tester, 'Pin to top');
    expect(y('PINNED'), lessThan(y('Session 4')));
    expect(y('Session 4'), lessThan(y('Session 0')));
    expect(prefs.pins('m1'), ['s4']);

    for (final i in [0, 1, 2, 3]) {
      await prefs.pin('m1', 's$i');
    }
    await tester.pumpAndSettle();
    await openMenu(tester, 'Session 5');
    await choose(tester, 'Pin to top');
    expect(find.text('At most 5 pinned sessions per machine. Unpin one first.'), findsOneWidget);
    expect(prefs.pins('m1'), hasLength(5));

    // Other machines have their own five.
    for (var i = 0; i < 5; i++) {
      await prefs.pin('m2', 'x$i');
    }
    expect(prefs.pins('m2'), hasLength(5));
    await expectLater(prefs.pin('m2', 'x5'), throwsA(isA<TooManyPins>()));

    await openMenu(tester, 'Session 4');
    await choose(tester, 'Unpin');
    expect(prefs.pins('m1'), ['s0', 's1', 's2', 's3']);
  });

  testWidgets('hide leaves an ended session out until it runs again', (tester) async {
    final (c, host) = await online(tester, [
      summary('a', name: 'Old one', state: SessionState.stopped, live: false),
      summary('b', name: 'Live one'),
    ]);
    await show(tester, c);
    await tapKey(tester, 'not-running');
    await openMenu(tester, 'Old one');
    expect(find.text('Resume'), findsOneWidget);
    await choose(tester, 'Hide');
    expect(find.text('Old one'), findsNothing);
    expect(prefs.isHidden('m1', 'a'), isTrue);

    host.send(SessionUpdated(session: summary('a', name: 'Old one', state: SessionState.working)));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(find.text('Old one'), findsOneWidget);
    expect(prefs.isHidden('m1', 'a'), isFalse);
  });

  testWidgets('mute and unmute are this phone only', (tester) async {
    final (c, host) = await online(tester, [summary('a', name: 'Quiet one')]);
    await show(tester, c);
    await openMenu(tester, 'Quiet one');
    await choose(tester, 'Mute notifications');
    expect(prefs.isMuted('m1', 'a'), isTrue);
    expect(find.byIcon(Icons.notifications_off_rounded), findsOneWidget);
    await openMenu(tester, 'Quiet one');
    await choose(tester, 'Unmute notifications');
    expect(prefs.isMuted('m1', 'a'), isFalse);
    expect(sent(host), isEmpty);
  });

  testWidgets('rename asks the host and says what it did', (tester) async {
    final (c, host) = await online(tester, [summary('a', name: 'Old name')]);
    await show(tester, c);
    await openMenu(tester, 'Old name');
    await choose(tester, 'Rename…');
    await tester.enterText(field('Name'), '  Login   fix ');
    await tester.tap(button('Save'));
    await tester.pump();
    await tester.runAsync(() => eventually(() => sent(host).isNotEmpty));
    final m = sent(host).single as RenameSession;
    expect((m.sessionId, m.name), ('a', 'Login fix'));
    host.send(const SessionActionDone(action: SessionActions.rename, sessionId: 'a', message: 'Renamed to Login fix'));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(find.text('Renamed to Login fix'), findsOneWidget);
  });

  testWidgets('an older host is told apart from other errors', (tester) async {
    final (c, host) = await online(tester, [summary('a', name: 'Old one', state: SessionState.stopped, live: false)]);
    await show(tester, c);
    await tapKey(tester, 'not-running');
    await openMenu(tester, 'Old one');
    await choose(tester, 'Resume');
    await tester.runAsync(() => eventually(() => sent(host).isNotEmpty));
    expect(sent(host).single, isA<ResumeSession>());
    host.send(const ErrorMessage(code: ErrorCodes.badRequest, message: unknownMessageText));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(find.text(olderHostActionMessage), findsOneWidget);

    await openMenu(tester, 'Old one');
    await choose(tester, 'Resume');
    await tester.runAsync(() => eventually(() => sent(host).length == 2));
    host.send(const ErrorMessage(code: ErrorCodes.badRequest, message: "This session's folder no longer exists: D:\\x"));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(find.text("This session's folder no longer exists: D:\\x"), findsOneWidget);
  });

  testWidgets('delete warns it cannot be undone, then asks the host', (tester) async {
    await prefs.pin('m1', 'a');
    final (c, host) = await online(tester, [summary('a', name: 'Doomed', state: SessionState.idle)]);
    await show(tester, c);
    await openMenu(tester, 'Doomed');
    await choose(tester, 'Delete…');
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    expect(find.textContaining('It is ended first.'), findsOneWidget);
    await tapButton(tester, 'Cancel');
    expect(sent(host), isEmpty);

    await openMenu(tester, 'Doomed');
    await choose(tester, 'Delete…');
    await holdToConfirm(tester, 'Delete');
    await tester.runAsync(() => eventually(() => sent(host).isNotEmpty));
    expect(sent(host).single, isA<DeleteSession>());
    host.send(const SessionActionDone(action: SessionActions.delete, sessionId: 'a', message: 'Session deleted'));
    host.send(const Sessions(sessions: []));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(find.text('Session deleted'), findsOneWidget);
    expect(prefs.pins('m1'), isEmpty);
  });

  testWidgets('new session here starts with that folder chosen', (tester) async {
    final (c, host) = await online(tester, [summary('a', name: 'Here', cwd: r'D:\projects\perch\app')]);
    await show(tester, c);
    await openMenu(tester, 'Here');
    await choose(tester, 'New session here…');
    expect(find.text(r'Folder: D:\projects\perch\app'), findsOneWidget);
    await tester.runAsync(() => eventually(() => sent(host).isNotEmpty));
    expect((sent(host).first as ListDir).path, r'D:\projects\perch\app');
  });

  test('prefs survive a restart through shared preferences', () async {
    SharedPreferences.setMockInitialValues({});
    final a = SessionPrefs();
    await a.pin('m1', 's1');
    await a.hide('m1', 's2');
    await a.mute('m2', 's3');
    final b = SessionPrefs();
    await b.load();
    expect(b.pins('m1'), ['s1']);
    expect(b.isHidden('m1', 's2'), isTrue);
    expect(b.isMuted('m2', 's3'), isTrue);
    expect(b.isMuted('m1', 's3'), isFalse);
    await b.forgetMachine('m1');
    final again = SessionPrefs();
    await again.load();
    expect(again.pins('m1'), isEmpty);
    expect(again.isMuted('m2', 's3'), isTrue);
  });

  test('the providers default to an in-memory store', () {
    expect(sessionPrefsProvider, isNotNull);
  });
}
