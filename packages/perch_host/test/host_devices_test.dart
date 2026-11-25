import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_state.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('perch_devices_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('approved devices persist with their key, permission and times', () {
    final s = HostState.load(tmp.path);
    expect(s.devices, isEmpty);
    final d = s.approveDevice('dev-aaaa1', name: 'Pixel', permission: DevicePermissions.watch, nowMs: 100);
    expect(base64UrlDecodeNoPad(d.key!), hasLength(32));
    expect(d.keyed, isFalse, reason: 'keyed once the device has used its key');
    s.approveDevice('dev-bbbb2', name: 'Old phone', permission: DevicePermissions.full, nowMs: 200);
    final again = HostState.load(tmp.path);
    expect(again.devices.map((d) => d.id), ['dev-aaaa1', 'dev-bbbb2']);
    final a = again.device('dev-aaaa1')!;
    expect(a.name, 'Pixel');
    expect(a.permission, DevicePermissions.watch);
    expect(a.key, d.key);
    expect(a.approvedAtMs, 100);
    final b = again.device('dev-bbbb2')!;
    expect(b.key, isNot(a.key), reason: 'every device gets its own key');
    expect(b.keyed, isFalse);
  });

  test('a keyless (legacy) device written by an older host is dropped on load', () {
    final s = HostState.load(tmp.path);
    s.approveDevice('dev-keyed', name: 'Pixel', permission: DevicePermissions.full, nowMs: 1);
    final f = File('${tmp.path}${Platform.pathSeparator}host.json');
    final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    (j['devices'] as List)
      ..add({'id': 'dev-legacy', 'name': 'Old phone', 'permission': 'full', 'key': null, 'keyed': false, 'approvedAtMs': 2})
      ..add({'id': 'dev-broken', 'name': 'Broken', 'permission': 'full', 'key': 'short', 'keyed': true, 'approvedAtMs': 3});
    f.writeAsStringSync(jsonEncode(j));
    final again = HostState.load(tmp.path);
    expect(again.devices.map((d) => d.id), ['dev-keyed']);
  });

  test('a device is marked keyed and seen, renamed, changed and removed', () {
    final s = HostState.load(tmp.path);
    s.approveDevice('dev-aaaa1', name: 'Pixel', permission: DevicePermissions.full, nowMs: 1);
    s.confirmKey('dev-aaaa1');
    s.deviceSeen('dev-aaaa1', 50);
    s.renameDevice('dev-aaaa1', '  Work phone ');
    s.setDevicePermission('dev-aaaa1', DevicePermissions.watch);
    final again = HostState.load(tmp.path).device('dev-aaaa1')!;
    expect(again.keyed, isTrue);
    expect(again.lastSeenAtMs, 50);
    expect(again.name, 'Work phone');
    expect(again.permission, DevicePermissions.watch);
    expect(() => s.renameDevice('dev-aaaa1', ''), throwsArgumentError);
    expect(() => s.renameDevice('dev-aaaa1', 'x' * 41), throwsArgumentError);
    expect(() => s.setDevicePermission('dev-aaaa1', 'admin'), throwsArgumentError);
    expect(s.removeDevice('dev-aaaa1'), isNotNull);
    expect(s.removeDevice('dev-aaaa1'), isNull);
    expect(HostState.load(tmp.path).devices, isEmpty);
  });

  test('a short prefix finds one device; an ambiguous or too short one does not', () {
    final s = HostState.load(tmp.path)
      ..approveDevice('3f9a1111', name: 'A', permission: DevicePermissions.full)
      ..approveDevice('3f9a2222', name: 'B', permission: DevicePermissions.full);
    expect(s.findDevice('3f9a1')?.name, 'A');
    expect(s.findDevice('3f9a2222')?.name, 'B');
    expect(() => s.findDevice('3f9a'), throwsArgumentError);
    expect(() => s.findDevice('3f9'), throwsArgumentError);
    expect(s.findDevice('ffff'), isNull);
  });

  test('forget-devices clears the device list', () {
    final s = HostState.load(tmp.path)..approveDevice('d1xx', name: 'A', permission: DevicePermissions.full);
    s.forgetDevices();
    expect(s.devices, isEmpty);
    expect(HostState.load(tmp.path).devices, isEmpty);
  });

  test('bad device entries in host.json are skipped', () {
    final s = HostState.load(tmp.path);
    final j = jsonDecode(File('${tmp.path}/host.json').readAsStringSync()) as Map<String, dynamic>;
    final key = base64UrlNoPad(List<int>.filled(32, 9));
    j['devices'] = [
      {'id': 'ok11', 'name': 'A', 'permission': 'watch', 'approvedAtMs': 1, 'key': key},
      {'name': 'no id', 'key': key},
      7,
      {'id': 'odd1', 'permission': 'root', 'key': key},
    ];
    File('${tmp.path}/host.json').writeAsStringSync(jsonEncode(j));
    final again = HostState.load(tmp.path);
    expect(again.devices.map((d) => d.id), ['ok11', 'odd1']);
    expect(again.device('odd1')!.permission, DevicePermissions.watch, reason: 'an unknown permission is the safe one');
    expect(s.devices, isEmpty);
  });
}
