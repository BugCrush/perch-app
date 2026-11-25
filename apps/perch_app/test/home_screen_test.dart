import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/machine_store.dart';
import 'package:perch_app/src/state/providers.dart';
import 'package:perch_app/src/ui/add_machine_screen.dart';
import 'package:perch_app/src/ui/app_menu.dart';
import 'package:perch_app/src/ui/glass/settings.dart';
import 'package:perch_app/src/ui/home_screen.dart';
import 'package:perch_app/src/ui/model_table_screen.dart';
import 'package:perch_app/src/ui/projects_screen.dart';
import 'package:perch_app/src/ui/search_screen.dart';
import 'package:perch_app/src/ui/sessions_screen.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'glass_harness.dart';

/// A stand-in for the camera: a button that "scans" [code].
QrScannerBuilder fakeScanner(String Function() code) =>
    (context, onCode) => Center(child: TextButton(onPressed: () => onCode(code()), child: const Text('Simulate scan')));

void main() {
  late FakeChannels channels;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    channels = FakeChannels();
  });

  void seed(List<Map<String, dynamic>> machines) =>
      SharedPreferences.setMockInitialValues({MachineStore.key: jsonEncode(machines)});

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
  }

  Future<void> pumpScreen(WidgetTester tester, {QrScannerBuilder? scanner}) async {
    tallPhone(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        channelFactoryProvider.overrideWithValue(channels.factory),
        qrScannerProvider.overrideWithValue(scanner),
      ],
      child: glassApp(const HomeScreen()),
    ));
    await settle(tester);
  }

  Future<void> addMachine(WidgetTester tester) => tapKey(tester, 'add-machine');

  Future<void> pairWith(WidgetTester tester, String link) async {
    await tester.enterText(field('Pairing link'), link);
    await tester.tap(button('Pair'));
    await settle(tester);
  }

  testWidgets('add_machine_by_pasting_a_link', (tester) async {
    await pumpScreen(tester);
    expect(find.text('Stop all sessions'), findsOneWidget);
    expect(find.text('No machines yet. Start the Perch host on a computer and add it with its QR code.'), findsOneWidget);
    await addMachine(tester);
    expect(find.byType(AddMachineScreen), findsOneWidget);
    expect(find.text('Simulate scan'), findsNothing);
    await pairWith(tester, testLink(name: 'Desk'));
    expect(find.byType(AddMachineScreen), findsNothing);
    expect(find.text('Desk'), findsOneWidget);
    expect(find.text('192.168.1.20:8787'), findsOneWidget);
    expect(find.text('Paired with Desk'), findsOneWidget);
    expect(channels.hosts, isNotEmpty);
    expect(channels.last.uri.toString(), 'ws://192.168.1.20:8787/ws');
    final saved = await tester.runAsync(() => MachineStore().load());
    expect(saved!.single.id, 'mid-1');
    expect(saved.single.needsPairing, isFalse);
  });

  testWidgets('the search button opens search across the machines', (tester) async {
    await pumpScreen(tester);
    await tapKey(tester, 'open-search');
    expect(find.byType(SearchScreen), findsOneWidget);
  });

  testWidgets('a_bad_link_is_rejected', (tester) async {
    await pumpScreen(tester);
    await addMachine(tester);
    await tester.enterText(field('Pairing link'), 'http://192.168.1.20:8787');
    await tester.tap(button('Pair'));
    await tester.pumpAndSettle();
    expect(find.text(notALinkText), findsOneWidget);
    expect(channels.hosts, isEmpty);
  });

  testWidgets('scanning_the_qr_code_pairs_and_ignores_other_codes', (tester) async {
    var code = 'https://example.com/not-perch';
    await pumpScreen(tester, scanner: fakeScanner(() => code));
    await addMachine(tester);
    expect(find.text('Or paste the pairing link'), findsOneWidget);
    await tester.tap(find.text('Simulate scan'));
    await tester.pumpAndSettle();
    expect(find.byType(AddMachineScreen), findsOneWidget);
    expect(find.text(notALinkText), findsNothing);
    code = testLink(name: 'Scanned box', relay: 'https://relay.example');
    await tester.tap(find.text('Simulate scan'));
    await settle(tester);
    expect(find.byType(AddMachineScreen), findsNothing);
    expect(find.text('Scanned box'), findsOneWidget);
  });

  testWidgets('a_phase_1_machine_shows_pair_again_and_pairing_replaces_it', (tester) async {
    seed([
      {'id': 'old-1', 'label': 'Old desk', 'host': '192.168.1.20', 'port': 8787, 'code': 'ABCD2345'}
    ]);
    await pumpScreen(tester);
    expect(find.text('Old desk'), findsOneWidget);
    expect(find.text('Not paired'), findsOneWidget);
    expect(channels.hosts, isEmpty);
    await tapKey(tester, 'pair-again-old-1');
    expect(find.text('Pair again'), findsOneWidget, reason: 'the pairing screen is titled Pair again');
    await pairWith(tester, testLink(name: 'Desk'));
    expect(find.text('Old desk'), findsNothing);
    expect(find.text('Desk'), findsOneWidget);
    expect(find.text('Not paired'), findsNothing);
    final saved = await tester.runAsync(() => MachineStore().load());
    expect(saved!.map((m) => m.id), ['mid-1']);
  });

  testWidgets('row_shows_online_route_sessions_attention_and_the_hero', (tester) async {
    seed([testMachine(label: 'Desk').toJson()]);
    await pumpScreen(tester);
    channels.last.send(welcome);
    channels.last.send(Sessions(sessions: [
      summary('a', name: 'Busy', state: SessionState.working),
      summary('b', name: 'Wants Bash', state: SessionState.waitingPermission),
      summary('c', name: 'Stuck', state: SessionState.blocked, reason: 'x'),
    ]));
    await settle(tester);
    // The row follows the name the host gives itself (no alias set).
    expect(find.text('devbox'), findsOneWidget);
    expect(find.textContaining('Machine name:'), findsNothing);
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('On this network'), findsOneWidget);
    expect(find.text('3 sessions · 2 need you'), findsOneWidget);
    expect(find.text('1 working'), findsOneWidget);
    // The hero counts what waits on you; the list below names it.
    expect(find.text('sessions need you'), findsOneWidget);
    expect(find.text('WAITING ON YOU'), findsOneWidget);
    expect(find.text('Wants Bash'), findsOneWidget);
    expect(find.text('Stuck'), findsOneWidget);
    expect(find.text('Busy'), findsNothing);
  });

  testWidgets('row_says_through_relay', (tester) async {
    seed([testMachine(label: 'Work PC', lan: const [], relayUrl: 'https://relay.example').toJson()]);
    await pumpScreen(tester);
    expect(channels.last.uri.scheme, 'wss');
    channels.last.send(const Welcome(machineName: 'work', os: 'windows', hostVersion: '0.2.0', relayUrl: 'https://relay.example'));
    channels.last.send(const Sessions(sessions: []));
    await settle(tester);
    expect(find.text('Through relay'), findsOneWidget);
    expect(find.text('On this network'), findsNothing);
  });

  testWidgets('usage_lines_show_when_the_host_reports_usage', (tester) async {
    seed([testMachine(label: 'Desk').toJson()]);
    await pumpScreen(tester);
    channels.last.send(welcome);
    channels.last.send(const Sessions(sessions: []));
    await settle(tester);
    expect(find.text('5-hour'), findsNothing);
    channels.last.send(const UsageMessage(
        usage: UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0.42, resetsAt: 0, status: 'allowed'),
            sevenDay: UsageWindow(utilization: 0.18, resetsAt: 0, status: 'allowed'))));
    await settle(tester);
    expect(find.text('5-hour'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('Week'), findsOneWidget);
    expect(find.text('18%'), findsOneWidget);
  });

  testWidgets('instant_updates_off_note_shows_and_can_be_dismissed', (tester) async {
    seed([testMachine(label: 'Desk').toJson()]);
    await pumpScreen(tester);
    channels.last.send(welcome);
    channels.last.send(const Sessions(sessions: []));
    await settle(tester);
    expect(find.text('Instant updates are off on this machine'), findsNothing);

    channels.last.send(const Welcome(machineName: 'devbox', os: 'windows', hostVersion: '0.1.0', hooksInstalled: false));
    await settle(tester);
    expect(find.text('Instant updates are off on this machine'), findsOneWidget);
    await tapKey(tester, 'dismiss-hooks-m1');
    expect(find.text('Instant updates are off on this machine'), findsNothing);
  });

  Future<void> openMenu(WidgetTester tester, [String id = 'm1']) => tapKey(tester, 'machine-menu-$id');

  Future<void> openRename(WidgetTester tester) async {
    await openMenu(tester);
    await tester.tap(find.text('Rename…'));
    await tester.pumpAndSettle();
  }

  Finder renameField() => field('Name on this device');

  testWidgets('rename_sets_an_alias_shown_on_the_row_with_the_own_name_under_it', (tester) async {
    seed([testMachine(label: 'Desk').toJson()]);
    await pumpScreen(tester);
    channels.last.send(welcome); // the host calls itself devbox
    channels.last.send(const Sessions(sessions: []));
    await settle(tester);
    expect(find.text('devbox'), findsOneWidget);

    await openRename(tester);
    expect(tester.widget<TextField>(renameField()).controller!.text, 'devbox');
    await tester.enterText(renameField(), '  Big rig  ');
    await tester.tap(button('Save'));
    await settle(tester);
    expect(find.text('Rename machine'), findsNothing);
    expect(find.text('Big rig'), findsOneWidget);
    expect(find.text('Machine name: devbox'), findsOneWidget);
    final saved = await tester.runAsync(() => MachineStore().load());
    expect(saved!.single.alias, 'Big rig');
    expect(saved.single.label, 'devbox', reason: 'the own name from welcome is saved too');
  });

  testWidgets('press_and_hold_on_a_machine_opens_its_menu', (tester) async {
    seed([testMachine(label: 'Desk').toJson()]);
    await pumpScreen(tester);
    channels.last.send(welcome);
    channels.last.send(const Sessions(sessions: []));
    await settle(tester);
    await tester.longPress(find.text('devbox'));
    await tester.pumpAndSettle();
    for (final item in ['Rename…', 'Reconnect', 'Claude Code checks', 'Devices…', 'Stop all sessions…', 'Pair again', 'Remove machine…']) {
      expect(find.text(item), findsOneWidget, reason: item);
    }
    await tester.tap(find.text('Rename…'));
    await tester.pumpAndSettle();
    expect(find.text('Rename machine'), findsOneWidget);
  });

  testWidgets('rename_refuses_blank_and_cancel_keeps_the_name', (tester) async {
    seed([testMachine(label: 'Desk').toJson()]);
    await pumpScreen(tester);
    await openRename(tester);
    expect(tester.widget<TextField>(renameField()).controller!.text, 'Desk');
    await tester.enterText(renameField(), '   ');
    await tester.tap(button('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Rename machine'), findsOneWidget);
    expect(find.text('Enter a name'), findsOneWidget);
    // At most 40 characters can be typed.
    await tester.enterText(renameField(), 'x' * 50);
    await tester.pump();
    expect(tester.widget<TextField>(renameField()).controller!.text, hasLength(40));
    await tester.tap(button('Cancel'));
    await settle(tester);
    expect(find.text('Desk'), findsOneWidget);
    final saved = await tester.runAsync(() => MachineStore().load());
    expect(saved!.single.alias, isNull);
  });

  testWidgets('use_the_machines_own_name_clears_the_alias', (tester) async {
    seed([testMachine(label: 'Desk', alias: 'Big rig').toJson()]);
    await pumpScreen(tester);
    expect(find.text('Big rig'), findsOneWidget);
    expect(find.text('Machine name: Desk'), findsOneWidget);
    await openRename(tester);
    expect(tester.widget<TextField>(renameField()).controller!.text, 'Big rig');
    await tester.tap(find.text("Use the machine's own name"));
    await settle(tester);
    expect(find.text('Big rig'), findsNothing);
    expect(find.text('Desk'), findsOneWidget);
    expect(find.textContaining('Machine name:'), findsNothing);
    final saved = await tester.runAsync(() => MachineStore().load());
    expect(saved!.single.alias, isNull);
  });

  testWidgets('the_alias_survives_a_restart_and_pairing_the_same_machine_again', (tester) async {
    seed([testMachine(id: 'mid-1', label: 'Desk', alias: 'Big rig').toJson()]);
    await pumpScreen(tester);
    expect(find.text('Big rig'), findsOneWidget);
    await openMenu(tester, 'mid-1');
    await tester.tap(find.text('Pair again'));
    await tester.pumpAndSettle();
    await pairWith(tester, testLink(name: 'Desk'));
    expect(find.text('Big rig'), findsOneWidget);
    final saved = await tester.runAsync(() => MachineStore().load());
    expect(saved!.single.alias, 'Big rig');
  });

  testWidgets('a_rename_on_the_host_updates_the_own_name_line', (tester) async {
    seed([testMachine(label: 'Desk', alias: 'Big rig').toJson()]);
    await pumpScreen(tester);
    channels.last.send(welcome);
    channels.last.send(const Sessions(sessions: []));
    await settle(tester);
    expect(find.text('Machine name: devbox'), findsOneWidget);
    channels.last.send(const MachineRenamed(machineName: 'Studio'));
    await settle(tester);
    expect(find.text('Machine name: Studio'), findsOneWidget);
    expect(find.text('Big rig'), findsOneWidget);
    final saved = await tester.runAsync(() => MachineStore().load());
    expect(saved!.single.label, 'Studio');
    expect(saved.single.alias, 'Big rig');
  });

  testWidgets('a_host_that_forgot_this_device_shows_pair_again', (tester) async {
    channels.modeFor = (_) => FakeMode.wrongSecret;
    seed([testMachine(label: 'Desk').toJson()]);
    await pumpScreen(tester);
    await settle(tester);
    expect(find.text('Not paired'), findsOneWidget);
    expect(find.byKey(const ValueKey('pair-again-m1')), findsOneWidget);
  });

  testWidgets('reconnect_and_remove_from_the_menu', (tester) async {
    seed([testMachine(label: 'Desk').toJson()]);
    await pumpScreen(tester);
    channels.last.send(welcome);
    channels.last.send(const Sessions(sessions: []));
    await settle(tester);
    final before = channels.hosts.length;
    await openMenu(tester);
    await tester.tap(find.text('Reconnect'));
    await settle(tester);
    expect(channels.hosts.length, greaterThan(before));
    expect(find.text('Reconnecting to devbox…'), findsOneWidget);

    // Remove asks first; Cancel keeps the machine.
    await openMenu(tester);
    await tester.tap(find.text('Remove machine…'));
    await tester.pumpAndSettle();
    expect(find.text('Remove devbox from this phone?'), findsOneWidget);
    expect(find.textContaining('Nothing on the machine itself is deleted'), findsOneWidget);
    await tapButton(tester, 'Cancel');
    expect(find.text('devbox'), findsOneWidget);
    await openMenu(tester);
    await tester.tap(find.text('Remove machine…'));
    await tester.pumpAndSettle();
    await tapDanger(tester, 'Remove machine');
    await settle(tester);
    expect(find.text('devbox'), findsNothing);
    final saved = await tester.runAsync(() => MachineStore().load());
    expect(saved, isEmpty);
  });

  testWidgets('kill_switch_on_the_first_screen_asks_then_stops_every_machine', (tester) async {
    seed([testMachine(label: 'Desk').toJson()]);
    await pumpScreen(tester);
    channels.last.send(welcome);
    channels.last.send(Sessions(sessions: [summary('a', state: SessionState.working), summary('b')]));
    await settle(tester);
    await tapDanger(tester, 'Stop all sessions');
    expect(find.text('Stop all 2 sessions on devbox?'), findsOneWidget);
    expect(find.textContaining('cut off mid-step'), findsOneWidget, reason: 'it names what is lost');
    // A tap, or letting go early, does nothing: it must be held.
    await tester.tap(find.widgetWithText(HoldButton, 'Stop all'));
    await tester.pumpAndSettle();
    await holdToConfirm(tester, 'Stop all', hold: const Duration(milliseconds: 500));
    await tester.runAsync(() => pump(50));
    expect(channels.last.messages.whereType<KillAll>(), isEmpty);
    expect(find.text('Stop all 2 sessions on devbox?'), findsOneWidget);
    await holdToConfirm(tester, 'Stop all');
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<KillAll>().isNotEmpty));
  });

  testWidgets('a_row_opens_the_machines_sessions_and_the_menu_stops_that_machine', (tester) async {
    seed([testMachine(label: 'Desk').toJson()]);
    await pumpScreen(tester);
    channels.last.send(welcome);
    channels.last.send(Sessions(sessions: [summary('a', name: 'Only one', state: SessionState.working)]));
    await settle(tester);
    await tester.tap(find.text('devbox'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionsScreen), findsOneWidget);
    expect(find.text('Only one'), findsOneWidget);
    await tester.longPress(find.byKey(const ValueKey('machine-title')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop all sessions…'));
    await tester.pumpAndSettle();
    expect(find.text('Stop all 1 sessions on devbox?'), findsOneWidget);
    await holdToConfirm(tester, 'Stop all');
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<KillAll>().isNotEmpty));
  });

  testWidgets('the Board sits next to Add machine, the same size', (tester) async {
    await pumpScreen(tester);
    final add = tester.getRect(find.byKey(const ValueKey('add-machine')));
    final board = tester.getRect(find.byKey(const ValueKey('open-board')));
    expect(board.size, add.size);
    expect(board.center.dy, add.center.dy, reason: 'on one row');
    expect((board.center.dx - add.center.dx).abs(), lessThan(140), reason: 'side by side');
    expect(find.text('Board'), findsOneWidget);
    expect(find.text('Add machine'), findsOneWidget);
  });

  testWidgets('the menu holds the settings; rows that change something have a pill, information has none', (tester) async {
    seed([testMachine(label: 'Desk').toJson()]);
    await pumpScreen(tester);
    channels.last.send(welcome);
    await settle(tester);
    expect(find.byType(ThemeSwitch), findsNothing, reason: 'the theme moved into the menu');
    expect(find.byKey(const ValueKey('open-accounts')), findsNothing);
    await tapKey(tester, 'open-menu');
    for (final k in ['open-models', 'open-projects', 'open-accounts', 'menu-checks-m1']) {
      final row = find.byKey(ValueKey(k));
      expect(row, findsOneWidget, reason: k);
      expect(find.descendant(of: row, matching: find.byType(ValuePill)), findsOneWidget, reason: '$k is a setting');
    }
    expect(find.byType(ThemeSwitch), findsOneWidget);
    expect(find.text('Version $appVersion'), findsOneWidget);
    for (final info in tester.widgetList<InfoRow>(find.byType(InfoRow))) {
      expect(find.descendant(of: find.byWidget(info), matching: find.byType(ValuePill)), findsNothing);
    }
    await tapKey(tester, 'open-models');
    expect(find.byType(ModelTableScreen), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    await tapKey(tester, 'open-menu');
    await tapKey(tester, 'open-projects');
    expect(find.byType(ProjectsScreen), findsOneWidget);
  });
}
