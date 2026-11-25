import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/connection/machine_store.dart';
import 'package:perch_app/src/ui/glass/widgets.dart';
import 'package:perch_app/src/ui/home_screen.dart';
import 'package:perch_app/src/ui/sessions_screen.dart';
import 'package:perch_app/src/state/providers.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'glass_harness.dart';

const drifted = Compatibility(
  status: CompatibilityStatus.drifted,
  claudeVersion: '2.1.330',
  reason: 'Claude Code shows a dialog Perch cannot recognise.',
  evidence: 'Session: work (abc)\nExpected: a permission request\nClaude Code: 2.1.330\nScreen (last 2 lines):\n> 1. Maybe\n  2. Later',
);

const driftText =
    "Claude Code changed on devbox. Perch can't read its prompts any more. Answer in the terminal and update Perch.";

void main() {
  late FakeChannels channels;
  final conns = <HostConnection>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    channels = FakeChannels();
  });
  tearDown(() {
    for (final c in conns) {
      c.dispose();
    }
    conns.clear();
  });

  Future<HostConnection> online(WidgetTester tester, {Compatibility? compatibility, String? alias}) async {
    final c = HostConnection(testMachine(id: 'm1', label: 'm1', lan: ['10.0.0.1:8787'], alias: alias),
        channelFactory: channels.factory);
    conns.add(c);
    c.connect();
    channels.last.send(Welcome(machineName: 'devbox', os: 'windows', hostVersion: '0.1.0', compatibility: compatibility));
    channels.last.send(const Sessions(sessions: []));
    await tester.runAsync(() => eventually(() => c.link.value == LinkState.online));
    return c;
  }

  testWidgets('drifted_shows_a_red_banner_with_copyable_details_on_the_sessions_screen', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    final c = await online(tester, compatibility: drifted);
    tallPhone(tester);
    await tester.pumpWidget(glassApp(SessionsScreen(connection: c)));
    await tester.pumpAndSettle();
    expect(find.text(driftText), findsOneWidget);
    await tester.tap(button('Details'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Claude Code shows a dialog Perch cannot recognise.'), findsWidgets);
    expect(find.textContaining('> 1. Maybe'), findsOneWidget);
    await tester.tap(button('Copy'));
    await tester.pumpAndSettle();
    expect(copied.single, contains('Expected: a permission request'));
    expect(copied.single, contains('Claude Code shows a dialog Perch cannot recognise.'));
  });

  testWidgets('the_banner_and_the_checks_screen_use_the_alias', (tester) async {
    final c = await online(tester, compatibility: drifted, alias: 'Big rig');
    tallPhone(tester);
    await tester.pumpWidget(glassApp(SessionsScreen(connection: c)));
    await tester.pumpAndSettle();
    expect(find.text(driftText.replaceFirst('devbox', 'Big rig')), findsOneWidget);
    await tester.tap(button('Details'));
    await tester.pumpAndSettle();
    expect(find.text('Claude Code on Big rig'), findsOneWidget);
  });

  testWidgets('a_compatibility_push_updates_the_banner', (tester) async {
    final c = await online(tester);
    tallPhone(tester);
    await tester.pumpWidget(glassApp(SessionsScreen(connection: c)));
    await tester.pumpAndSettle();
    expect(find.text(driftText), findsNothing);
    channels.last.send(const CompatibilityMessage(
        compatibility: Compatibility(status: CompatibilityStatus.untested, claudeVersion: '2.1.324')));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(find.text("Claude Code 2.1.324 hasn't been checked yet"), findsOneWidget);
    channels.last.send(const CompatibilityMessage(compatibility: drifted));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(find.text(driftText), findsOneWidget);
    expect(find.textContaining("hasn't been checked"), findsNothing);
    channels.last.send(const CompatibilityMessage(compatibility: Compatibility(status: CompatibilityStatus.ok)));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(find.text(driftText), findsNothing);
  });

  testWidgets('the_machines_screen_shows_the_banner_at_the_top', (tester) async {
    SharedPreferences.setMockInitialValues({
      MachineStore.key: jsonEncode([testMachine().toJson()])
    });
    tallPhone(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [channelFactoryProvider.overrideWithValue(channels.factory)],
      child: glassApp(const HomeScreen()),
    ));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    channels.last.send(const Welcome(machineName: 'devbox', os: 'windows', hostVersion: '0.1.0', compatibility: drifted));
    channels.last.send(const Sessions(sessions: []));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(find.text(driftText), findsOneWidget);
    expect(tester.getTopLeft(find.text(driftText)).dy, lessThan(tester.getTopLeft(find.text('192.168.1.20:8787')).dy));
  });

  group('an unchecked version', () {
    const line = 'Fixed long options in lists and permission prompts being partly overwritten when they wrap';
    Compatibility untested(
            {ReleaseNotesFindings? notes, List<String> seen = const [], SelfTestStatus? selfTest}) =>
        Compatibility(
          status: CompatibilityStatus.untested,
          claudeVersion: '2.1.325',
          releaseNotes: notes,
          seenWorking: seen,
          selfTest: selfTest ?? const SelfTestStatus(enabled: false),
        );

    Future<HostConnection> shown(WidgetTester tester, Compatibility c) async {
      final conn = await online(tester, compatibility: c);
      tallPhone(tester);
      await tester.pumpWidget(glassApp(SessionsScreen(connection: conn)));
      await tester.pumpAndSettle();
      return conn;
    }

    testWidgets('the_amber_line_says_what_the_release_notes_say', (tester) async {
      await shown(tester, untested());
      expect(find.text("Claude Code 2.1.325 hasn't been checked yet"), findsOneWidget);
      channels.last.send(CompatibilityMessage(
          compatibility: untested(notes: const ReleaseNotesFindings(checked: true, versions: ['2.1.324', '2.1.325']))));
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      expect(find.text("Claude Code 2.1.325 hasn't been checked yet · release notes: nothing affecting Perch"),
          findsOneWidget);
      channels.last.send(CompatibilityMessage(
          compatibility: untested(
              notes: const ReleaseNotesFindings(checked: true, relevantLines: [line], topics: ['prompt']))));
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      expect(find.text("Claude Code 2.1.325 hasn't been checked yet · release notes mention prompt changes"),
          findsOneWidget);
      channels.last.send(CompatibilityMessage(
          compatibility: untested(notes: const ReleaseNotesFindings(checked: false, error: 'timed out'))));
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      expect(find.text("Claude Code 2.1.325 hasn't been checked yet · release notes could not be read"), findsOneWidget);
      // Checked now (real use or the self-test): the amber line goes.
      channels.last.send(const CompatibilityMessage(
          compatibility: Compatibility(status: CompatibilityStatus.ok, claudeVersion: '2.1.325')));
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      expect(find.textContaining("hasn't been checked"), findsNothing);
    });

    testWidgets('tapping_it_shows_the_notes_the_progress_and_the_self_test', (tester) async {
      await shown(
          tester,
          untested(
              notes: const ReleaseNotesFindings(
                  checked: true, versions: ['2.1.324', '2.1.325'], relevantLines: [line], topics: ['prompt']),
              seen: const ['question', 'permission']));
      await tester.tap(find.textContaining("hasn't been checked yet"));
      await tester.pumpAndSettle();
      expect(find.text('Claude Code on devbox'), findsOneWidget);
      expect(find.text('The release notes (2.1.324, 2.1.325) mention prompt:'), findsOneWidget);
      expect(find.text(line), findsOneWidget);
      expect(find.text('Seen working on 2.1.325: questions ✓, permissions ✓, plans —'), findsOneWidget);
      expect(find.text('Self-test new Claude Code versions'), findsOneWidget);
      expect(find.textContaining("a little of your plan's usage"), findsOneWidget);
      expect(tester.widget<GlassToggle>(find.byKey(const ValueKey('selftest-toggle'))).value, isFalse);
      expect(button('Run self-test now'), findsOneWidget);
    });

    testWidgets('notes_that_could_not_be_read_say_so', (tester) async {
      await shown(tester, untested(notes: const ReleaseNotesFindings(checked: false, error: 'Reading the release notes timed out after 10 s.')));
      await tester.tap(find.textContaining("hasn't been checked yet"));
      await tester.pumpAndSettle();
      expect(find.text('The release notes could not be read.'), findsOneWidget);
      expect(find.text('Reading the release notes timed out after 10 s.'), findsOneWidget);
    });

    testWidgets('the_toggle_and_the_run_button_reach_the_host_and_show_the_result', (tester) async {
      final conn = await shown(tester, untested());
      await tester.tap(find.textContaining("hasn't been checked yet"));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('selftest-toggle')));
      await tester.pumpAndSettle();
      await tester.runAsync(() => eventually(() => channels.last.messages.whereType<SetSelfTest>().isNotEmpty));
      expect(channels.last.messages.whereType<SetSelfTest>().single.enabled, isTrue);
      channels.last.send(CompatibilityMessage(compatibility: untested(selfTest: const SelfTestStatus(enabled: true))));
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      expect(tester.widget<GlassToggle>(find.byKey(const ValueKey('selftest-toggle'))).value, isTrue);

      await tester.tap(button('Run self-test now'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => eventually(() => channels.last.messages.whereType<RunSelfTest>().isNotEmpty));
      channels.last.send(CompatibilityMessage(
          compatibility: untested(selfTest: const SelfTestStatus(enabled: true, state: SelfTestState.running))));
      await tester.runAsync(() => pump(50));
      await tester.pump();
      expect(find.textContaining('Running'), findsOneWidget);
      expect(enabled(tester, 'Run self-test now'), isFalse);

      channels.last.send(const CompatibilityMessage(
          compatibility: Compatibility(
              status: CompatibilityStatus.drifted,
              claudeVersion: '2.1.325',
              reason: 'The self-test of Claude Code 2.1.325 failed: The plan was not approved.',
              evidence: 'Self-test steps:\n- approved the plan',
              selfTest: SelfTestStatus(
                  enabled: true, state: SelfTestState.failed, version: '2.1.325', reason: 'The plan was not approved.'))));
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      expect(find.text('Failed on Claude Code 2.1.325: The plan was not approved.'), findsOneWidget);
      expect(find.textContaining('Self-test steps:'), findsOneWidget); // the drift evidence

      channels.last.send(const CompatibilityMessage(
          compatibility: Compatibility(
              status: CompatibilityStatus.ok,
              claudeVersion: '2.1.325',
              selfTest: SelfTestStatus(enabled: true, state: SelfTestState.passed, version: '2.1.325'))));
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      expect(find.text('Passed on Claude Code 2.1.325.'), findsOneWidget);
      expect(conn.compatibility.value!.status, CompatibilityStatus.ok);
    });

    testWidgets('the_machine_menu_opens_the_checks', (tester) async {
      SharedPreferences.setMockInitialValues({
        MachineStore.key: jsonEncode([testMachine().toJson()])
      });
      tallPhone(tester);
      await tester.pumpWidget(ProviderScope(
        overrides: [channelFactoryProvider.overrideWithValue(channels.factory)],
        child: glassApp(const HomeScreen()),
      ));
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      channels.last.send(Welcome(machineName: 'devbox', os: 'windows', hostVersion: '0.2.0', compatibility: untested()));
      channels.last.send(const Sessions(sessions: []));
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      await tapKey(tester, 'machine-menu-m1');
      await tester.tap(find.text('Claude Code checks'));
      await tester.pumpAndSettle();
      expect(find.text('Self-test new Claude Code versions'), findsOneWidget);
    });
  });
}
