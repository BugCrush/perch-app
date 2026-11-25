import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/main.dart';
import 'package:perch_app/src/connection/machine_store.dart';
import 'package:perch_app/src/push/push_notes.dart';
import 'package:perch_app/src/state/providers.dart';
import 'package:perch_app/src/ui/add_machine_screen.dart' show qrScannerProvider;
import 'package:perch_app/src/ui/app_lock.dart';
import 'package:perch_app/src/ui/glass/widgets.dart' show GlassToggle;
import 'package:perch_app/src/ui/home_screen.dart';
import 'package:perch_app/src/ui/session_screen.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'glass_harness.dart';
import 'push_app_test.dart' show FakePush;

class FakeAuth implements Authenticator {
  @override
  bool available = true;
  bool answer = true;
  int asked = 0;

  /// Set: the next check waits for it.
  Completer<bool>? pending;
  @override
  Future<void> refresh() async {}
  @override
  Future<bool> authenticate() async {
    asked++;
    final p = pending;
    if (p != null) return p.future;
    return answer;
  }
}

void main() {
  late FakeChannels channels;
  late FakeAuth auth;
  late FakePush push;
  late DateTime now;

  setUp(() {
    AppLock.reset();
    channels = FakeChannels();
    auth = FakeAuth();
    push = FakePush();
    now = DateTime(2026, 11, 19, 12);
    AppLock.clock = () => now;
  });
  tearDown(AppLock.reset);

  Future<void> pumpApp(WidgetTester tester) async {
    tallPhone(tester);
    await tester.pumpWidget(ProviderScope(overrides: [
      channelFactoryProvider.overrideWithValue(channels.factory),
      pushServiceProvider.overrideWithValue(push),
      qrScannerProvider.overrideWithValue(null),
      authenticatorProvider.overrideWithValue(auth),
    ], child: const PerchApp()));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
  }

  Finder locked() => find.byKey(const ValueKey('app-locked'));

  Future<void> background(WidgetTester tester, Duration away) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(away);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  group('settings', () {
    test('on by default, after 5 minutes; choices are remembered', () async {
      SharedPreferences.setMockInitialValues({});
      await AppLock.load();
      expect(AppLock.enabled.value, isTrue);
      expect(AppLock.after.value, LockAfter.fiveMinutes);
      await AppLock.setEnabled(false);
      await AppLock.setAfter(LockAfter.oneMinute);
      AppLock.reset();
      await AppLock.load();
      expect(AppLock.enabled.value, isFalse);
      expect(AppLock.after.value, LockAfter.oneMinute);
    });
  });

  testWidgets('a cold start is locked and asks at once; passing opens the app', (tester) async {
    SharedPreferences.setMockInitialValues({});
    auth.pending = Completer<bool>();
    await pumpApp(tester);
    expect(locked(), findsOneWidget);
    expect(find.text('Perch is locked'), findsOneWidget);
    expect(auth.asked, 1);
    expect(AppLock.locked.value, isTrue);
    auth.pending!.complete(true);
    await tester.pumpAndSettle();
    expect(locked(), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('a failed check stays locked; Unlock asks again', (tester) async {
    SharedPreferences.setMockInitialValues({});
    auth.answer = false;
    await pumpApp(tester);
    expect(locked(), findsOneWidget);
    auth.answer = true;
    await tapKey(tester, 'unlock');
    expect(auth.asked, 2);
    expect(locked(), findsNothing);
  });

  testWidgets('back from the background: locks after the chosen time, not before', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpApp(tester);
    expect(locked(), findsNothing);
    await background(tester, const Duration(minutes: 4));
    expect(locked(), findsNothing);
    expect(auth.asked, 1);
    auth.pending = Completer<bool>();
    await background(tester, const Duration(minutes: 5));
    expect(locked(), findsOneWidget);
    expect(auth.asked, 2);
    auth.pending!.complete(true);
    await tester.pumpAndSettle();
    expect(locked(), findsNothing);

    await AppLock.setAfter(LockAfter.immediately);
    auth.pending = null;
    auth.answer = false;
    await background(tester, const Duration(seconds: 1));
    expect(locked(), findsOneWidget);
  });

  testWidgets('off, or a phone without a screen lock: never locked', (tester) async {
    SharedPreferences.setMockInitialValues({AppLock.enabledKey: false});
    await AppLock.load();
    await pumpApp(tester);
    expect(locked(), findsNothing);
    await background(tester, const Duration(hours: 1));
    expect(locked(), findsNothing);
    expect(auth.asked, 0);
  });

  testWidgets('a phone without a screen lock never locks and the setting says why', (tester) async {
    SharedPreferences.setMockInitialValues({});
    auth.available = false;
    await pumpApp(tester);
    expect(locked(), findsNothing);
    await tapKey(tester, 'open-menu');
    expect(find.text('Set a screen lock on this phone to use App lock'), findsOneWidget);
  });

  testWidgets('the menu turns the lock off and picks when it locks again', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpApp(tester);
    await tapKey(tester, 'open-menu');
    expect(find.text('App lock'), findsOneWidget);
    expect(find.text('Fingerprint, face or the phone\'s PIN when Perch opens'), findsOneWidget);
    await tapKey(tester, 'lock-after');
    await tester.tap(find.text('After 15 minutes').last);
    await tester.pumpAndSettle();
    expect(AppLock.after.value, LockAfter.fifteenMinutes);
    expect((await SharedPreferences.getInstance()).getString(AppLock.afterKey), 'fifteenMinutes');
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('app-lock-toggle')), matching: find.byType(GlassToggle)));
    await tester.pumpAndSettle();
    expect(AppLock.enabled.value, isFalse);
    expect(find.byKey(const ValueKey('lock-after')), findsNothing);
  });

  testWidgets('a notification tap waits until the app is unlocked', (tester) async {
    SharedPreferences.setMockInitialValues({
      MachineStore.key: jsonEncode([testMachine(id: 'mid-desk', label: 'Desk').toJson()])
    });
    auth.pending = Completer<bool>();
    push.tapNotifier.value =
        const PushTap(machineId: 'mid-desk', sessionId: 's1', promptId: 'toolu_1', action: PushActions.stop);
    await pumpApp(tester);
    expect(locked(), findsOneWidget);
    channels.last.send(welcome);
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(push.tapNotifier.value, isNotNull, reason: 'not taken while locked');
    expect(channels.last.messages.whereType<Interrupt>(), isEmpty);
    auth.pending!.complete(true);
    await tester.pumpAndSettle();
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    expect(push.tapNotifier.value, isNull);
    expect(find.byType(SessionScreen), findsOneWidget);
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<Interrupt>().isNotEmpty));
  });
}
