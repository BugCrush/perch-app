import 'dart:typed_data';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

Uint8List bytes(int n, int seed) => Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed) & 0xff));

void main() {
  group('device trust wire messages', () {
    test('hello carries the pairing version; older hellos have none', () {
      final h = decodeClient(encodeClient(const Hello(deviceName: 'Pixel', pairing: 2))) as Hello;
      expect(h.pairing, 2);
      expect(h.deviceName, 'Pixel');
      final old = decodeClient('{"type":"hello","code":"","deviceName":"Pixel"}') as Hello;
      expect(old.pairing, isNull);
      expect(encodeClient(const Hello(deviceName: 'x')), isNot(contains('pairing')));
    });

    test('welcome carries the permission; older hosts omit it', () {
      final w = decodeHost(encodeHost(const Welcome(
          machineName: 'm', os: 'macos', hostVersion: '1', permission: DevicePermissions.watch))) as Welcome;
      expect(w.permission, 'watch');
      final old = decodeHost('{"type":"welcome","machineName":"m","os":"macos","hostVersion":"1"}') as Welcome;
      expect(old.permission, isNull);
    });

    test('client device messages round-trip', () {
      final msgs = <ClientMessage>[
        const ListDevices(),
        const DecideDevice(deviceId: 'd1', decision: DeviceDecisions.watch),
        const SetDevicePermission(deviceId: 'd1', permission: DevicePermissions.full),
        const RenameDevice(deviceId: 'd1', name: 'Pixel 9'),
        const RemoveDevice(deviceId: 'd1'),
      ];
      for (final m in msgs) {
        final back = decodeClient(encodeClient(m));
        expect(back.runtimeType, m.runtimeType, reason: encodeClient(m));
        expect(encodeClient(back!), encodeClient(m));
      }
    });

    test('malformed device messages decode to null', () {
      expect(decodeClient('{"type":"decideDevice","deviceId":"d1","decision":"maybe"}'), isNull);
      expect(decodeClient('{"type":"decideDevice","deviceId":"","decision":"full"}'), isNull);
      expect(decodeClient('{"type":"setDevicePermission","deviceId":"d1","permission":"admin"}'), isNull);
      expect(decodeClient('{"type":"renameDevice","deviceId":"d1","name":""}'), isNull);
      expect(decodeClient('{"type":"renameDevice","deviceId":"d1","name":"${'x' * 41}"}'), isNull);
      expect(decodeClient('{"type":"removeDevice"}'), isNull);
    });

    test('host device messages round-trip', () {
      final msgs = <HostMessage>[
        const PairingPending(machineName: 'Mac'),
        const DeviceKey(key: 'a2V5', permission: DevicePermissions.watch),
        const DevicesMessage(devices: [
          DeviceInfo(
              id: 'd1',
              name: 'Pixel',
              permission: DevicePermissions.full,
              keyed: true,
              approvedAtMs: 10,
              lastSeenAtMs: 20,
              connected: true,
              thisDevice: true),
          DeviceInfo(id: 'd2', name: 'Old', permission: DevicePermissions.watch, keyed: false, approvedAtMs: 1),
        ], pending: [
          PendingDevice(id: 'd3', name: 'New', route: 'relay', requestedAtMs: 30),
        ]),
      ];
      for (final m in msgs) {
        final back = decodeHost(encodeHost(m));
        expect(back.runtimeType, m.runtimeType, reason: encodeHost(m));
        expect(encodeHost(back!), encodeHost(m));
      }
      final d = decodeHost(encodeHost(msgs[2])) as DevicesMessage;
      expect(d.devices.first.thisDevice, isTrue);
      expect(d.devices.last.lastSeenAtMs, isNull);
      expect(d.pending.single.route, 'relay');
    });

    test('a device key message without a key is dropped; bad entries are skipped', () {
      expect(decodeHost('{"type":"deviceKey","permission":"full"}'), isNull);
      final d = decodeHost('{"type":"devices","devices":[{"id":"d1"},7,{"name":"no id"}],"pending":[{"id":"p"}]}')
          as DevicesMessage;
      expect(d.devices.single.id, 'd1');
      expect(d.devices.single.permission, DevicePermissions.full);
      expect(d.pending.single.id, 'p');
    });

    test('new error codes exist', () {
      expect({
        ErrorCodes.awaitingApproval,
        ErrorCodes.pairingDenied,
        ErrorCodes.pairingExpired,
        ErrorCodes.deviceRemoved,
        ErrorCodes.watchOnly,
      }, hasLength(5));
    });
  });

  group('host handshake candidates', () {
    test('the host can derive a session for another secret from one hello', () {
      final pairing = bytes(32, 1);
      final deviceKey = bytes(32, 9);
      final client = ClientHandshake(secret: deviceKey, machineId: 'm1', deviceId: 'dev-1');
      final accepted = HostHandshake.accept(secret: pairing, machineId: 'm1', frame: client.hello);
      final app = client.finish(accepted.reply);
      final first = app.seal('{"type":"hello"}').single;
      // The pairing secret does not open it ...
      expect(() => accepted.session.open(first), throwsA(isA<ChannelError>()));
      // ... the device key does, from the same hello.
      final keyed = accepted.sessionFor(deviceKey);
      expect(keyed.open(first), '{"type":"hello"}');
      expect(app.open(keyed.seal('back').single), 'back');
    });

    test('each candidate session is independent', () {
      final pairing = bytes(32, 1);
      final client = ClientHandshake(secret: pairing, machineId: 'm1', deviceId: 'dev-1');
      final accepted = HostHandshake.accept(secret: pairing, machineId: 'm1', frame: client.hello);
      final app = client.finish(accepted.reply);
      final first = app.seal('x').single;
      expect(() => accepted.sessionFor(bytes(32, 2)).open(first), throwsA(isA<ChannelError>()));
      expect(accepted.sessionFor(pairing).open(first), 'x');
    });

    test('device keys are 32 random bytes in base64url', () {
      final k = newDeviceKey();
      expect(base64UrlDecodeNoPad(k), hasLength(32));
      expect(newDeviceKey(), isNot(k));
    });
  });
}
