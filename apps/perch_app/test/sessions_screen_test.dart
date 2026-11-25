import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/connection/machine_store.dart';
import 'package:perch_app/src/state/providers.dart';
import 'package:perch_app/src/ui/glass/widgets.dart';
import 'package:perch_app/src/ui/home_screen.dart';
import 'package:perch_app/src/ui/labels.dart';
import 'package:perch_app/src/ui/sessions_screen.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'glass_harness.dart';

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

  Future<HostConnection> online(WidgetTester tester, List<SessionSummary> sessions,
      {String id = 'm1', String machineName = 'devbox', UsageSnapshot? usage, String? alias}) async {
    final c = HostConnection(testMachine(id: id, label: id, lan: ['10.0.0.1:8787'], alias: alias),
        channelFactory: channels.factory);
    conns.add(c);
    c.connect();
    final host = channels.last;
    host.send(Welcome(machineName: machineName, os: 'windows', hostVersion: '0.1.0'));
    host.send(Sessions(sessions: sessions, usage: usage));
    await tester.runAsync(() => eventually(() => c.link.value == LinkState.online && c.sessions.value.length == sessions.length));
    return c;
  }

  Future<void> show(WidgetTester tester, Widget w) async {
    tallPhone(tester);
    await tester.pumpWidget(glassApp(w));
    await tester.pumpAndSettle();
  }

  List<ClientMessage> sent(HostConnection c) =>
      channels.hosts.firstWhere((h) => c.machine.lan.first.startsWith('${h.uri.host}:')).messages.skip(1).toList();

  testWidgets('groups_sessions_by_need', (tester) async {
    final c = await online(tester, [
      summary('a', name: 'Busy one', state: SessionState.working),
      summary('b', name: 'Asking', state: SessionState.waitingQuestion),
      summary('c', name: 'Resting', state: SessionState.idle),
      summary('d', name: 'Stuck', state: SessionState.blocked, reason: 'not signed in'),
      summary('e', name: 'Done', state: SessionState.finished),
    ]);
    await show(tester, SessionsScreen(connection: c));
    double y(String text) => tester.getTopLeft(find.text(text).first).dy;
    expect(y('NEEDS YOU'), lessThan(y('Asking')));
    expect(y('Asking'), lessThan(y('WORKING')));
    expect(y('Stuck'), lessThan(y('WORKING')));
    expect(y('WORKING'), lessThan(y('Busy one')));
    expect(y('Busy one'), lessThan(y('IDLE AND FINISHED')));
    expect(y('IDLE AND FINISHED'), lessThan(y('Resting')));
    expect(y('IDLE AND FINISHED'), lessThan(y('Done')));
    expect(find.text('Asked a question'), findsOneWidget);
    expect(find.text('Blocked: not signed in'), findsOneWidget);
    expect(find.text('Finished'), findsOneWidget);
    expect(find.text('Idle'), findsOneWidget);
    expect(find.text('devbox'), findsOneWidget);
    expect(find.text('1 working now'), findsOneWidget);
    expect(find.text('ON THIS NETWORK'), findsOneWidget);
  });

  testWidgets('external_session_is_labelled_in_a_terminal_and_opens', (tester) async {
    final c = await online(tester, [
      summary('x', name: 'Terminal work', origin: SessionOrigin.external, cwd: r'D:\projects\perch\app'),
    ]);
    String? opened;
    await show(tester, SessionsScreen(connection: c, onOpenSession: (ctx, conn, id) => opened = id));
    expect(find.text('In a terminal'), findsOneWidget);
    expect(find.text(r'perch\app'), findsOneWidget);
    await tester.tap(find.text('Terminal work'));
    await tester.pumpAndSettle();
    expect(opened, 'x');
  });

  testWidgets('last_message_time_shows_in_ist', (tester) async {
    // 2026-11-15 15:41 UTC is 21:11 IST.
    final at = DateTime.utc(2026, 11, 15, 15, 41).millisecondsSinceEpoch;
    final c = await online(tester, [summary('x', name: 'Talked to', lastPromptAtMs: at), summary('y', name: 'Silent')]);
    await show(tester, SessionsScreen(connection: c, clock: () => DateTime.utc(2026, 11, 15, 18)));
    expect(find.text('Last message 21:11'), findsOneWidget);
    expect(find.byKey(const ValueKey('lastMessage-y')), findsNothing);
  });

  testWidgets('usage_meters_show_percentages_and_resets', (tester) async {
    final c = await online(tester, [],
        usage: const UsageSnapshot(
          fiveHour: UsageWindow(utilization: 0.87, resetsAt: 1794424800, status: 'allowed'),
          sevenDay: UsageWindow(utilization: 0.1, resetsAt: 1794906000, status: 'allowed'),
        ));
    await show(tester, SessionsScreen(connection: c));
    expect(find.text('5-HOUR'), findsOneWidget);
    expect(find.text('WEEKLY'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Semantics && (w.properties.label ?? '').startsWith('5-HOUR usage 87 percent')), findsOneWidget);
    expect(find.text('resets ${resetClock(1794424800)}'), findsOneWidget);
    expect(find.text('resets ${resetClock(1794906000, withDay: true)}'), findsOneWidget);
    expect(percent(const UsageWindow(utilization: 0.104, resetsAt: 0, status: '')), 10);
  });

  testWidgets('no_usage_no_meters', (tester) async {
    final c = await online(tester, []);
    await show(tester, SessionsScreen(connection: c));
    expect(find.byKey(const ValueKey('usage')), findsNothing);
    expect(find.text('No sessions on this machine yet.'), findsOneWidget);
  });

  /// Opens the New session sheet.
  Future<void> openSheet(WidgetTester tester, HostConnection c) async {
    await show(tester, SessionsScreen(connection: c));
    await tapKey(tester, 'new-session');
  }

  /// The host answers a listDir.
  Future<void> hostLists(WidgetTester tester, DirListing l) async {
    channels.last.send(l);
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
  }

  List<ListDir> listDirs(HostConnection c) => sent(c).whereType<ListDir>().toList();

  const projects = DirListing(
    path: r'D:\projects',
    parent: r'D:\',
    entries: [
      DirEntry(name: 'alpha-app', path: r'D:\projects\alpha-app'),
      DirEntry(name: 'beta-site', path: r'D:\projects\beta-site'),
    ],
    suggested: [
      DirEntry(name: 'perch', path: r'D:\projects\perch'),
      DirEntry(name: 'Home', path: r'C:\Users\me'),
    ],
  );

  testWidgets('new_session_requires_folder_and_instruction', (tester) async {
    final c = await online(tester, []);
    await openSheet(tester, c);
    await tapButton(tester, 'Start');
    expect(find.text('Enter a folder'), findsOneWidget);
    expect(find.text('Enter an instruction'), findsOneWidget);
    expect(sent(c).whereType<StartSession>(), isEmpty);
  });

  testWidgets('first_open_without_sessions_goes_to_home', (tester) async {
    final c = await online(tester, []);
    await openSheet(tester, c);
    await tester.runAsync(() => eventually(() => listDirs(c).isNotEmpty));
    expect(listDirs(c).single.path, isNull);
    await hostLists(tester, const DirListing(path: '', entries: [DirEntry(name: 'C:', path: r'C:\')], suggested: [
      DirEntry(name: 'Home', path: r'C:\Users\me'),
    ]));
    await tester.runAsync(() => eventually(() => listDirs(c).length == 2));
    expect(listDirs(c).last.path, r'C:\Users\me');
  });

  testWidgets('opens_in_most_recent_session_folder', (tester) async {
    final c = await online(tester, [
      summary('old', cwd: r'D:\projects\old', startedAtMs: 100),
      summary('new', cwd: r'D:\projects', origin: SessionOrigin.external, startedAtMs: 300),
      summary('mid', cwd: r'D:\projects\mid', startedAtMs: 200),
    ]);
    await openSheet(tester, c);
    await tester.runAsync(() => eventually(() => listDirs(c).isNotEmpty));
    expect(listDirs(c).single.path, r'D:\projects');
    expect(find.text('Loading folders…'), findsOneWidget);
    await hostLists(tester, projects);
    expect(tester.widget<Text>(find.byKey(const ValueKey('shownFolder'))).data, r'D:\projects');
    expect(find.text('alpha-app'), findsOneWidget);
    expect(find.text('beta-site'), findsOneWidget);
    expect(find.byKey(const ValueKey('chip-perch')), findsOneWidget);
    expect(find.byKey(const ValueKey('chip-Home')), findsOneWidget);
    expect(find.text('Folder: none chosen yet'), findsOneWidget);

    // A shortcut chip goes straight to its folder.
    await tapKey(tester, 'chip-Home');
    await tester.runAsync(() => eventually(() => listDirs(c).length == 2));
    expect(listDirs(c).last.path, r'C:\Users\me');
  });

  testWidgets('tapping_folder_enters_it', (tester) async {
    final c = await online(tester, [summary('a', cwd: r'D:\projects')]);
    await openSheet(tester, c);
    await hostLists(tester, projects);
    await tester.tap(find.text('beta-site'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => eventually(() => listDirs(c).length == 2));
    expect(listDirs(c).last.path, r'D:\projects\beta-site');
    await hostLists(tester, const DirListing(path: r'D:\projects\beta-site', parent: r'D:\projects'));
    expect(find.text(r'D:\projects\beta-site'), findsOneWidget);
    expect(find.text('No folders here'), findsOneWidget);
  });

  testWidgets('up_goes_to_parent', (tester) async {
    final c = await online(tester, [summary('a', cwd: r'D:\projects')]);
    await openSheet(tester, c);
    await hostLists(tester, projects);
    await tapKey(tester, 'folder-up');
    await tester.runAsync(() => eventually(() => listDirs(c).length == 2));
    expect(listDirs(c).last.path, r'D:\');

    // At a drive root, Up goes to the list of drives.
    await hostLists(tester, const DirListing(path: r'D:\', entries: [DirEntry(name: 'projects', path: r'D:\projects')]));
    await tapKey(tester, 'folder-up');
    await tester.runAsync(() => eventually(() => listDirs(c).length == 3));
    expect(listDirs(c).last.path, isNull);
    await hostLists(tester, const DirListing(path: '', entries: [DirEntry(name: 'D:', path: r'D:\')]));
    expect(find.text('This computer'), findsOneWidget);
    expect(tester.widget<GlassOrb>(find.byKey(const ValueKey('folder-up'))).onTap, isNull);
  });

  testWidgets('use_this_folder_fills_start_request', (tester) async {
    final c = await online(tester, [summary('a', cwd: r'D:\projects')]);
    await openSheet(tester, c);
    expect(find.text('Default'), findsOneWidget);
    await hostLists(tester, projects);
    await tester.tap(find.text('alpha-app'));
    await tester.pumpAndSettle();
    await hostLists(tester, const DirListing(path: r'D:\projects\alpha-app', parent: r'D:\projects'));
    await tapButton(tester, 'Use this folder');
    expect(find.text(r'Folder: D:\projects\alpha-app'), findsOneWidget);
    await tester.enterText(field('First instruction'), 'Write a haiku');
    await tester.ensureVisible(button('Start'));
    await tester.tap(button('Start'));
    await tester.runAsync(() => eventually(() => sent(c).whereType<StartSession>().isNotEmpty));
    final start = sent(c).whereType<StartSession>().single;
    expect(start.cwd, r'D:\projects\alpha-app');
    expect(start.prompt, 'Write a haiku');
    expect(start.model, isNull);
    expect(start.name, isNull);

    // A host error shows in the sheet.
    channels.last.send(const ErrorMessage(code: ErrorCodes.spawnFailed, message: 'Could not start claude'));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(find.text('Could not start claude'), findsOneWidget);

    // Trying again, the new session appearing closes the sheet.
    await tester.ensureVisible(button('Start'));
    await tester.tap(button('Start'));
    await tester.pump();
    channels.last.send(SessionUpdated(session: summary('new', name: 'Write a haiku')));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(button('Start'), findsNothing);
  });

  testWidgets('kill_all_requires_confirmation', (tester) async {
    final c = await online(tester, [
      summary('a', state: SessionState.working),
      summary('b', state: SessionState.idle),
      summary('c', state: SessionState.finished),
    ]);
    await show(tester, SessionsScreen(connection: c));
    await tester.ensureVisible(dangerButton('Stop all sessions'));
    await tapDanger(tester, 'Stop all sessions');
    expect(find.text('Stop all 2 sessions on devbox?'), findsOneWidget);
    await tapButton(tester, 'Cancel');
    await tester.runAsync(() => pump(30));
    expect(sent(c).whereType<KillAll>(), isEmpty);

    await tapDanger(tester, 'Stop all sessions');
    expect(sent(c).whereType<KillAll>(), isEmpty);
    await holdToConfirm(tester, 'Stop all');
    await tester.runAsync(() => eventually(() => sent(c).whereType<KillAll>().isNotEmpty));
  });

  testWidgets('waiting_on_you_lists_open_prompts_across_machines', (tester) async {
    SharedPreferences.setMockInitialValues({
      MachineStore.key: jsonEncode([
        testMachine(id: 'm1', label: 'desk', lan: ['10.0.0.1:8787']).toJson(),
        testMachine(id: 'm2', label: 'mac', lan: ['10.0.0.2:8787']).toJson(),
      ])
    });
    final opened = <String>[];
    tallPhone(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [channelFactoryProvider.overrideWithValue(channels.factory)],
      child: glassApp(HomeScreen(onOpenSession: (ctx, conn, id) => opened.add('${conn.machine.id}/$id'))),
    ));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    await tester.runAsync(() => eventually(() => channels.hosts.length >= 2));
    final a = channels.lastTo('ws://10.0.0.1');
    final b = channels.lastTo('ws://10.0.0.2');
    a.send(const Welcome(machineName: 'desk', os: 'windows', hostVersion: '0.1.0'));
    a.send(Sessions(sessions: [
      summary('a1', name: 'Needs permission here', state: SessionState.waitingPermission, openPrompts: 1),
      summary('a2', name: 'Quiet', state: SessionState.working),
    ]));
    b.send(const Welcome(machineName: 'mac', os: 'macos', hostVersion: '0.1.0'));
    b.send(Sessions(sessions: [
      summary('b1', name: 'Has a question', state: SessionState.waitingQuestion, openPrompts: 1),
      summary('b2', name: 'Broken', state: SessionState.blocked, reason: 'not signed in'),
      summary('b3', name: 'Old blocked', state: SessionState.blocked, live: false),
    ]));
    await tester.runAsync(() => pump(80));
    await tester.pumpAndSettle();
    expect(find.text('Needs permission here'), findsOneWidget);
    expect(find.text('Has a question'), findsOneWidget);
    expect(find.text('Broken'), findsOneWidget);
    expect(find.text('Quiet'), findsNothing);
    expect(find.text('Old blocked'), findsNothing);
    expect(find.textContaining('desk ·'), findsWidgets);
    expect(find.textContaining('mac ·'), findsWidgets);
    expect(find.text('sessions need you'), findsOneWidget);
    await tester.tap(find.text('Has a question'));
    await tester.pumpAndSettle();
    expect(opened, ['m2/b1']);
  });

  testWidgets('the_alias_is_the_title_the_kill_switch_and_the_waiting_list_name', (tester) async {
    final c = await online(tester, [
      summary('a', name: 'Asking', state: SessionState.waitingQuestion, openPrompts: 1),
    ], alias: 'Big rig');
    await show(tester, SessionsScreen(connection: c));
    expect(find.text('Big rig'), findsOneWidget);
    expect(find.text('devbox'), findsNothing);
    await tester.ensureVisible(dangerButton('Stop all sessions'));
    await tapDanger(tester, 'Stop all sessions');
    expect(find.text('Stop all 1 sessions on Big rig?'), findsOneWidget);
    await tapButton(tester, 'Cancel');

    // Renamed while the screen is open: it follows.
    c.machine = c.machine.copyWith(alias: 'Small rig');
    await tester.pumpAndSettle();
    expect(find.text('Small rig'), findsOneWidget);
  });

  testWidgets('not_running_sessions_are_grouped_last_and_not_counted', (tester) async {
    final c = await online(tester, [
      summary('a', name: 'Stuck', state: SessionState.blocked, reason: 'not signed in', startedAtMs: 10),
      summary('b', name: 'Long gone', state: SessionState.idle, reason: 'Not running', live: false, startedAtMs: 50),
      summary('c', name: 'Resting', state: SessionState.idle, startedAtMs: 5),
      summary('d', name: 'Old blocked', state: SessionState.blocked, live: false, origin: SessionOrigin.external),
    ]);
    await show(tester, SessionsScreen(connection: c));
    double y(String text) => tester.getTopLeft(find.text(text).first).dy;
    expect(y('NEEDS YOU'), lessThan(y('Stuck')));
    expect(y('IDLE AND FINISHED'), lessThan(y('NOT RUNNING')));
    expect(y('Resting'), lessThan(y('NOT RUNNING')));
    // Collapsed by default.
    expect(find.text('Long gone'), findsNothing);
    expect(find.text('Old blocked'), findsNothing);
    await tapKey(tester, 'not-running');
    expect(y('NOT RUNNING'), lessThan(y('Long gone')));
    expect(y('NOT RUNNING'), lessThan(y('Old blocked')));
    expect(find.text('Blocked: not signed in'), findsOneWidget);
    // The machine's "need you" count leaves them out.
    expect(sessionsNeedingYou(c.sessions.value), 1);
  });

  test('blocked_without_reason_has_no_colon', () {
    expect(stateLabel(summary('x', state: SessionState.blocked)), 'Blocked');
    expect(stateLabel(summary('x', state: SessionState.blocked, reason: '')), 'Blocked');
    expect(stateLabel(summary('x', state: SessionState.blocked, reason: 'not signed in')), 'Blocked: not signed in');
    expect(stateLabel(summary('x', state: SessionState.idle, reason: 'Not running', live: false)), 'Not running');
  });
}
