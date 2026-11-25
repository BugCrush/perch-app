import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/main.dart';
import 'package:perch_app/src/connection/machine_store.dart';
import 'package:perch_app/src/push/push_notes.dart';
import 'package:perch_app/src/push/push_service.dart';
import 'package:perch_app/src/ui/add_machine_screen.dart';
import 'package:perch_app/src/ui/home_screen.dart';
import 'package:perch_app/src/ui/session_screen.dart';
import 'package:perch_app/src/ui/sessions_screen.dart';
import 'package:perch_app/src/state/providers.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'glass_harness.dart';

class FakePush implements PushService {
  final ValueNotifier<PushTap?> tapNotifier = ValueNotifier(null);
  final synced = <List<String>>[];
  final paired = <String>[];
  final forgotten = <String>[];
  @override
  ValueListenable<PushTap?> get taps => tapNotifier;
  @override
  void consumeTap() => tapNotifier.value = null;
  @override
  Future<void> start(String deviceId) async {}
  @override
  void syncMachines(List<Machine> machines) => synced.add([for (final m in machines) m.id]);
  @override
  Future<void> forget(Machine m) async => forgotten.add(m.id);
  @override
  Future<void> afterPairing(BuildContext context, Machine m) async => paired.add(m.id);
  int asked = 0;
  @override
  Future<void> askOnce(BuildContext context) async => asked++;
}

void main() {
  late FakeChannels channels;
  late FakePush push;

  setUp(() {
    channels = FakeChannels();
    push = FakePush();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tallPhone(tester);
    await tester.pumpWidget(ProviderScope(overrides: [
      channelFactoryProvider.overrideWithValue(channels.factory),
      pushServiceProvider.overrideWithValue(push),
      qrScannerProvider.overrideWithValue(null),
    ], child: const PerchApp()));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
  }

  testWidgets('a notification that started the app opens its session once the machines are loaded', (tester) async {
    SharedPreferences.setMockInitialValues({
      MachineStore.key: jsonEncode([testMachine(id: 'mid-desk', label: 'Desk').toJson()])
    });
    push.tapNotifier.value = const PushTap(machineId: 'mid-desk', sessionId: 's1', promptId: 'toolu_1');
    await pumpApp(tester);
    expect(find.byType(SessionScreen), findsOneWidget);
    expect(tester.widget<SessionScreen>(find.byType(SessionScreen)).sessionId, 's1');
    expect(push.tapNotifier.value, isNull);
    // Back goes to the machine's sessions, then to the first screen.
    await tapKey(tester, 'back');
    expect(find.byType(SessionsScreen), findsOneWidget);
    await tapKey(tester, 'back');
    expect(find.byType(HomeScreen), findsOneWidget);
    // The relay of every saved machine learns the token; a machine paired before
    // notifications existed gets the question once at start.
    expect(push.synced.last, ['mid-desk']);
    expect(push.asked, 1);
  });

  testWidgets('a tap while running opens that session; one for an unknown machine waits', (tester) async {
    SharedPreferences.setMockInitialValues({
      MachineStore.key: jsonEncode([testMachine(id: 'mid-desk', label: 'Desk').toJson()])
    });
    await pumpApp(tester);
    expect(find.byType(SessionScreen), findsNothing);
    push.tapNotifier.value = const PushTap(machineId: 'mid-other', sessionId: 's9');
    await tester.pumpAndSettle();
    expect(find.byType(SessionScreen), findsNothing);
    push.tapNotifier.value = const PushTap(machineId: 'mid-desk', sessionId: 's2');
    await tester.pumpAndSettle();
    expect(tester.widget<SessionScreen>(find.byType(SessionScreen)).sessionId, 's2');
  });

  testWidgets('the session screen tells the host it is in front, and the background tells it nothing is', (tester) async {
    SharedPreferences.setMockInitialValues({
      MachineStore.key: jsonEncode([testMachine(id: 'mid-desk', label: 'Desk').toJson()])
    });
    await pumpApp(tester);
    channels.last.send(welcome);
    await tester.runAsync(() => pump(50));
    push.tapNotifier.value = const PushTap(machineId: 'mid-desk', sessionId: 's3');
    await tester.pumpAndSettle();
    await tester.runAsync(() => pump(50));
    List<String?> focus() => [for (final m in channels.last.messages.whereType<FocusSession>()) m.sessionId];
    expect(focus(), ['s3']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.runAsync(() => pump(50));
    expect(focus(), ['s3', null]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() => pump(50));
    expect(focus(), ['s3', null, 's3']);
    await tapKey(tester, 'back');
    await tester.runAsync(() => pump(50));
    expect(focus(), ['s3', null, 's3', null]);
  });

  testWidgets("the machine's usage notification opens the machine, and a button the background could not send is sent",
      (tester) async {
    SharedPreferences.setMockInitialValues({
      MachineStore.key: jsonEncode([testMachine(id: 'mid-desk', label: 'Desk').toJson()])
    });
    await pumpApp(tester);
    channels.last.send(welcome);
    channels.last.send(Sessions(sessions: [summary('s1', name: 'Docs', state: SessionState.blocked)]));
    channels.last.send(const UsageLimitMessage(
        limit: UsageLimit(back: true, sessions: [LimitedSession(id: 's1', name: 'Docs')])));
    await tester.runAsync(() => pump(50));
    push.tapNotifier.value =
        const PushTap(machineId: 'mid-desk', sessionId: usageLimitPushId, action: PushActions.continueNow);
    await tester.pumpAndSettle();
    await tester.runAsync(() => pump(50));
    expect(find.byType(SessionsScreen), findsOneWidget);
    expect(find.byType(SessionScreen), findsNothing);
    expect(find.byKey(const ValueKey('usage-limit-card')), findsOneWidget);
    final sentChoice = channels.last.messages.whereType<UsageLimitChoice>().single;
    expect(sentChoice.choice, LimitChoices.continueNow);
  });

  testWidgets('a session that resumed differently shows the 15-second toast; Stop interrupts it', (tester) async {
    SharedPreferences.setMockInitialValues({
      MachineStore.key: jsonEncode([testMachine(id: 'mid-desk', label: 'Desk').toJson()])
    });
    await pumpApp(tester);
    channels.last.send(welcome);
    channels.last.send(Sessions(sessions: [summary('s1', name: 'Docs', state: SessionState.working)]));
    await tester.runAsync(() => pump(50));
    channels.last.send(const ResumeReport(sessionId: 's1', sessionName: 'Docs', changed: false, text: 'Resumed after the usage limit'));
    await tester.runAsync(() => pump(50));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('resumed-toast')), findsNothing, reason: 'a quiet note only');
    channels.last.send(const ResumeReport(sessionId: 's1', sessionName: 'Docs', changed: true, text: 'Resumed without the subagent'));
    await tester.runAsync(() => pump(50));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Docs resumed without the subagent'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600)); // slid in
    await tester.tap(find.byKey(const ValueKey('toast-stop')));
    await tester.runAsync(() => pump(50));
    expect(channels.last.messages.whereType<Interrupt>().single.sessionId, 's1');
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('resumed-toast')), findsNothing);
  });

  testWidgets('the home screen sums up a machine at its usage limit', (tester) async {
    SharedPreferences.setMockInitialValues({
      MachineStore.key: jsonEncode([testMachine(id: 'mid-desk', label: 'Desk').toJson()])
    });
    await pumpApp(tester);
    channels.last.send(welcome);
    channels.last.send(Sessions(sessions: [summary('s1', name: 'Docs', state: SessionState.blocked)]));
    channels.last.send(const UsageLimitMessage(limit: UsageLimit(sessions: [LimitedSession(id: 's1', name: 'Docs')])));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('limit-summary-mid-desk')), findsOneWidget);
    expect(find.text('Usage limit · reset time unknown'), findsOneWidget);
  });

  testWidgets('pairing asks about notifications; removing a machine forgets its token', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpApp(tester);
    await tapKey(tester, 'add-machine');
    await tester.enterText(field('Pairing link'), testLink(id: 'mid-new', name: 'Desk'));
    await tester.tap(button('Pair'));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(find.byType(AddMachineScreen), findsNothing);
    expect(push.paired, ['mid-new']);
    expect(push.synced.last, ['mid-new']);

    await tapKey(tester, 'machine-menu-mid-new');
    await tester.tap(find.text('Remove machine…'));
    await tester.pumpAndSettle();
    await tapDanger(tester, 'Remove machine');
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(push.forgotten, ['mid-new']);
  });
}
