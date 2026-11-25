import 'package:flutter_test/flutter_test.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/connection/machine_store.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'fakes.dart';

final List<int> deviceKey = List.generate(32, (i) => (i * 7 + 1) & 0xff);
String get deviceKeyText => base64UrlNoPad(deviceKey);

void main() {
  late FakeChannels channels;
  late HostConnection conn;
  late List<Machine> saved;

  HostConnection make(Machine m) => HostConnection(m,
      channelFactory: channels.factory, deviceName: 'Pixel', deviceId: 'dev-7', onMachineUpdated: saved.add);

  setUp(() {
    channels = FakeChannels();
    saved = [];
    conn = make(testMachine(id: 'm1', label: 'Desk'));
  });
  tearDown(() => conn.dispose());

  group('machine', () {
    test('the device key is saved with the machine and survives copies', () {
      final m = testMachine().copyWith(deviceKey: deviceKeyText);
      expect(m.keyBytes, deviceKey);
      final back = Machine.fromJson(m.toJson())!;
      expect(back.deviceKey, deviceKeyText);
      expect(back.copyWith(alias: 'x').deviceKey, deviceKeyText);
      expect(back.copyWith(clearDeviceKey: true).deviceKey, isNull);
      expect(testMachine().keyBytes, isNull);
      expect(Machine.fromJson({...m.toJson(), 'deviceKey': 'short'})!.keyBytes, isNull);
    });
  });

  test('a new app says it pairs with keys', () async {
    conn.connect();
    await eventually(() => channels.last.messages.isNotEmpty);
    expect((channels.last.messages.first as Hello).pairing, 2);
  });

  test('waiting for approval, then the key is saved and used next time', () async {
    conn.connect();
    await eventually(() => channels.last.messages.isNotEmpty);
    channels.last.send(const PairingPending(machineName: 'Desk'));
    await eventually(() => conn.link.value == LinkState.awaitingApproval);
    expect(conn.lastError.value, 'Waiting for approval on Desk. Allow this device there.');

    channels.last.send(DeviceKey(key: deviceKeyText, permission: DevicePermissions.watch));
    channels.last.send(const Welcome(
        machineName: 'Desk', os: 'macos', hostVersion: '0.2.0', permission: DevicePermissions.watch));
    await eventually(() => conn.link.value == LinkState.online);
    expect(saved.last.deviceKey, deviceKeyText);
    expect(conn.machine.deviceKey, deviceKeyText);
    expect(conn.permission.value, DevicePermissions.watch);
    expect(conn.canControl, isFalse);

    // The next connection uses the device key.
    channels.deviceKeys = [deviceKey];
    conn.connect();
    await eventually(() => channels.last.messages.isNotEmpty);
    expect(channels.last.usedKey, deviceKey);
  });

  test('an older host leaves the device with full control', () async {
    conn.connect();
    channels.last.send(welcome);
    await eventually(() => conn.link.value == LinkState.online);
    expect(conn.permission.value, DevicePermissions.full);
    expect(conn.canControl, isTrue);
  });

  test('denied or expired: not allowed, no retry on its own', () async {
    for (final code in [ErrorCodes.pairingDenied, ErrorCodes.pairingExpired]) {
      conn.connect();
      await eventually(() => channels.last.messages.isNotEmpty);
      final hosts = channels.hosts.length;
      channels.last.send(ErrorMessage(code: code, message: 'No.'));
      await channels.last.close();
      await eventually(() => conn.link.value == LinkState.denied);
      await pump(1300);
      expect(channels.hosts.length, hosts, reason: 'no retry on its own');
      expect(conn.lastError.value, 'No.');
    }
  });

  test('removed by the machine: removed state; asking to pair again drops the key', () async {
    channels.deviceKeys = [deviceKey];
    conn.dispose();
    conn = make(testMachine(id: 'm1', label: 'Desk').copyWith(deviceKey: deviceKeyText));
    conn.connect();
    await eventually(() => channels.last.messages.isNotEmpty);
    channels.last.send(const ErrorMessage(code: ErrorCodes.deviceRemoved, message: 'Desk removed this device.'));
    await channels.last.close();
    await eventually(() => conn.link.value == LinkState.removed);
    await pump(1300);
    expect(conn.link.value, LinkState.removed);

    conn.askToPairAgain();
    expect(conn.machine.deviceKey, isNull);
    expect(saved.last.deviceKey, isNull);
    await eventually(() => channels.last.messages.isNotEmpty);
    expect(channels.last.usedKey, isNull, reason: 'the pairing secret asks');
    expect((channels.last.messages.first as Hello).pairing, 2);
  });

  test('a key the host no longer knows means removed, not a new QR', () async {
    conn.dispose();
    conn = make(testMachine(id: 'm1', label: 'Desk').copyWith(deviceKey: deviceKeyText));
    channels.modeFor = (_) => FakeMode.wrongSecret;
    conn.connect();
    await eventually(() => conn.link.value == LinkState.removed);
    expect(conn.lastError.value, contains('removed this device'));
  });

  test('a watch-only device does not send the automatic syncs and is told what it cannot do', () async {
    conn.connect();
    channels.last.send(const Welcome(
        machineName: 'Desk', os: 'macos', hostVersion: '0.2.0', permission: DevicePermissions.watch));
    await eventually(() => conn.link.value == LinkState.online);
    conn.syncModelTable();
    conn.syncProjects();
    conn.syncAccounts();
    await pump(50);
    expect(channels.last.messages.where((m) => m is SyncModelTable || m is SyncProjects || m is SyncAccounts),
        isEmpty);
  });

  test('the device list and pending requests arrive; this device follows its own entry', () async {
    conn.connect();
    channels.last.send(const Welcome(machineName: 'Desk', os: 'macos', hostVersion: '0.2.0', permission: 'full'));
    channels.last.send(const DevicesMessage(devices: [
      DeviceInfo(id: 'dev-7', name: 'Pixel', permission: 'watch', keyed: true, approvedAtMs: 1, thisDevice: true),
    ], pending: [
      PendingDevice(id: 'dev-9', name: 'Tablet', route: 'relay', requestedAtMs: 2),
    ]));
    await eventually(() => conn.devices.value != null);
    expect(conn.devices.value!.pending.single.name, 'Tablet');
    expect(conn.permission.value, DevicePermissions.watch);
    conn.decideDevice('dev-9', DeviceDecisions.full);
    conn.renameDevice('dev-7', 'My phone');
    conn.setDevicePermission('dev-7', DevicePermissions.full);
    conn.removeDevice('dev-9');
    conn.listDevices();
    await eventually(() => channels.last.messages.whereType<ListDevices>().isNotEmpty);
    final sent = channels.last.messages;
    expect(sent.whereType<DecideDevice>().single.decision, 'full');
    expect(sent.whereType<RenameDevice>().single.name, 'My phone');
    expect(sent.whereType<SetDevicePermission>().single.permission, 'full');
    expect(sent.whereType<RemoveDevice>().single.deviceId, 'dev-9');
  });
}
