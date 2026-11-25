import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/connection/machine_store.dart';
import 'package:perch_app/src/state/providers.dart';
import 'package:perch_app/src/ui/add_machine_screen.dart' show qrScannerProvider;
import 'package:perch_app/src/ui/devices_screen.dart';
import 'package:perch_app/src/ui/glass/widgets.dart' show GlassOrb;
import 'package:perch_app/src/ui/home_screen.dart';
import 'package:perch_app/src/ui/labels.dart';
import 'package:perch_app/src/ui/session_screen.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'glass_harness.dart';

const watchWelcome =
    Welcome(machineName: 'devbox', os: 'macos', hostVersion: '0.2.0', permission: DevicePermissions.watch);
const fullWelcome = Welcome(machineName: 'devbox', os: 'macos', hostVersion: '0.2.0', permission: DevicePermissions.full);

void main() {
  late FakeChannels channels;

  setUp(() {
    channels = FakeChannels();
    SharedPreferences.setMockInitialValues({
      MachineStore.key: jsonEncode([testMachine(label: 'Desk').toJson()])
    });
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
  }

  Future<void> pumpHome(WidgetTester tester) async {
    tallPhone(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        channelFactoryProvider.overrideWithValue(channels.factory),
        qrScannerProvider.overrideWithValue(null),
      ],
      child: glassApp(const HomeScreen()),
    ));
    await settle(tester);
  }

  Future<void> hostSends(WidgetTester tester, HostMessage m) async {
    channels.last.send(m);
    await settle(tester);
  }

  group('machine row', () {
    testWidgets('waiting for approval says where to allow it', (tester) async {
      await pumpHome(tester);
      await hostSends(tester, const PairingPending(machineName: 'devbox'));
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.text('Waiting for approval on devbox. Allow this device there.'), findsOneWidget);
    });

    testWidgets('not allowed: Ask again connects again', (tester) async {
      await pumpHome(tester);
      await hostSends(tester, const ErrorMessage(code: ErrorCodes.pairingDenied, message: 'This device was not allowed on devbox.'));
      expect(find.text('Not allowed'), findsOneWidget);
      expect(find.text('This device was not allowed on devbox.'), findsOneWidget);
      final before = channels.hosts.length;
      await tapKey(tester, 'ask-again-m1');
      await settle(tester);
      expect(channels.hosts.length, greaterThan(before));
    });

    testWidgets('removed: Ask to pair again drops the key and asks with the pairing secret', (tester) async {
      await pumpHome(tester);
      await hostSends(tester, DeviceKey(key: base64UrlNoPad(List.filled(32, 4)), permission: 'full'));
      await hostSends(tester, const ErrorMessage(code: ErrorCodes.deviceRemoved, message: 'devbox removed this device.'));
      expect(find.text('Removed by the machine'), findsOneWidget);
      await tapKey(tester, 'ask-to-pair-again-m1');
      await settle(tester);
      expect((await MachineStore().load()).single.deviceKey, isNull);
      expect(channels.last.usedKey, isNull);
    });

    testWidgets('a watch-only device shows it and its menu has nothing that acts', (tester) async {
      await pumpHome(tester);
      await hostSends(tester, watchWelcome);
      expect(find.byKey(const ValueKey('watch-only-m1')), findsOneWidget);
      await tester.longPress(find.text('devbox'));
      await tester.pumpAndSettle();
      expect(find.text('Stop all sessions…'), findsNothing);
      expect(find.text('Devices…'), findsNothing);
      expect(find.text('Reconnect'), findsOneWidget);
    });
  });

  testWidgets('a full device manages the machine\'s devices', (tester) async {
    await pumpHome(tester);
    await hostSends(tester, fullWelcome);
    expect(find.byKey(const ValueKey('watch-only-m1')), findsNothing);
    await tester.longPress(find.text('devbox'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Devices…'));
    await settle(tester);
    expect(find.byType(DevicesScreen), findsOneWidget);
    expect(channels.last.messages.whereType<ListDevices>(), isNotEmpty);
    await hostSends(
        tester,
        DevicesMessage(devices: [
          const DeviceInfo(
              id: 'test-device', name: 'Android', permission: 'full', keyed: true, approvedAtMs: 1, thisDevice: true, connected: true),
          DeviceInfo(
              id: 'old-phone-1',
              name: 'Old phone',
              permission: 'watch',
              keyed: false,
              approvedAtMs: 1,
              lastSeenAtMs: DateTime.now().subtract(const Duration(hours: 3)).millisecondsSinceEpoch),
        ], pending: const [
          PendingDevice(id: 'tab-9999', name: 'Tablet', route: 'relay', requestedAtMs: 1),
        ]));
    expect(find.text('Tablet'), findsOneWidget);
    expect(find.text('tab- · Over the relay'), findsOneWidget);
    expect(find.text('This phone'), findsOneWidget);
    expect(find.text('Allowed; it gets its own key when it next connects.'), findsOneWidget);
    expect(find.textContaining('seen 3 h ago'), findsOneWidget);

    await tapKey(tester, 'watch-tab-9999');
    expect(channels.last.messages.whereType<DecideDevice>().single.decision, DeviceDecisions.watch);

    await tapKey(tester, 'permission-old-phone-1');
    expect(channels.last.messages.whereType<SetDevicePermission>().single.permission, DevicePermissions.full);

    await tapKey(tester, 'rename-old-phone-1');
    await tester.enterText(field('Device name'), 'Spare');
    await tapKey(tester, 'rename-save');
    expect(channels.last.messages.whereType<RenameDevice>().single.name, 'Spare');

    await tapKey(tester, 'remove-old-phone-1');
    expect(find.text('Remove Old phone from devbox?'), findsOneWidget);
    await tapDanger(tester, 'Remove device');
    await settle(tester);
    expect(channels.last.messages.whereType<RemoveDevice>().single.deviceId, 'old-phone-1');

    // Making this phone watch only asks first.
    await tapKey(tester, 'permission-test-device');
    expect(find.text('Make this phone watch only?'), findsOneWidget);
  });

  testWidgets('watch only: the composer cannot send and cards cannot be answered', (tester) async {
    final conn = HostConnection(testMachine(id: 'm', label: 'Desk'), channelFactory: channels.factory);
    addTearDown(conn.dispose);
    conn.connect();
    channels.last.send(watchWelcome);
    channels.last.send(Sessions(sessions: [summary('s1', name: 'Fix login', state: SessionState.waitingPermission)]));
    await tester.runAsync(() => eventually(() => conn.link.value == LinkState.online && conn.sessions.value.isNotEmpty));
    tallPhone(tester, height: 2340);
    await tester.pumpWidget(glassApp(SessionScreen(connection: conn, sessionId: 's1')));
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<Subscribe>().isNotEmpty));
    channels.last.send(const Events(sessionId: 's1', events: [], openPrompts: [
      PromptRequest(promptId: 'p1', kind: PromptKind.permission, toolName: 'Bash', input: {'command': 'ls'}, suggestions: []),
    ]));
    await settle(tester);
    expect(find.text(watchOnlyHint), findsWidgets);
    expect(find.byKey(const ValueKey('card-watch-only')), findsOneWidget);
    final send = tester.widget<GlassOrb>(find.byKey(const ValueKey('send')));
    expect(send.onTap, isNull);
    await tester.tap(find.text('Allow').last, warnIfMissed: false);
    await settle(tester);
    expect(channels.last.messages.whereType<AnswerPrompt>(), isEmpty);
  });
}
