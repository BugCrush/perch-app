import 'dart:io';

import 'package:perch_host/src/host_notice.dart';
import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'server_test.dart' show TestClient;

void main() {
  test('the keys line mentions A / W / D only while a device waits', () {
    expect(keysLineFor(pending: false), keysLine);
    expect(keysLineFor(pending: false), isNot(contains('A = ')));
    expect(keysLineFor(pending: true), contains('A = allow'));
    expect(keysLineFor(pending: true), contains('W = watch only'));
    expect(keysLineFor(pending: true), contains('D = deny'));
  });

  test('the banner says the pairing code only asks', () {
    final t = bannerText(address: '10.0.0.2', port: 8787);
    expect(t, contains('allow'));
    expect(t, isNot(contains('can control Claude Code')));
  });

  group('keys', () {
    late Directory tmp;
    late SessionManager manager;
    late HostState state;
    late PerchServer server;
    late HostNotice notice;
    late int port;
    final lines = <String>[];

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('perch_notice_');
      manager = SessionManager(launcher: fakeLauncher(), external: FakeExternalSessions());
      state = HostState.load(tmp.path);
      server = PerchServer(manager: manager, state: state, machineName: 'm', bindAddress: '127.0.0.1', port: 0);
      port = await server.start();
      lines.clear();
      notice = HostNotice(server, state: state, addresses: const [], out: lines.add);
    });

    tearDown(() async {
      await server.close();
      await manager.dispose();
      tmp.deleteSync(recursive: true);
    });

    Future<TestClient> ask(String id) async {
      final c = await TestClient.connect(port, state, deviceId: id);
      c.send(const Hello(deviceName: 'Pixel', pairing: 2));
      await c.next<PairingPending>();
      return c;
    }

    test('A, W and D answer the oldest request; with none they say so', () async {
      final a = await ask('aaaa-1');
      final b = await ask('bbbb-2');
      final c = await ask('cccc-3');
      await notice.handleKey('A');
      expect((await a.next<DeviceKey>()).permission, DevicePermissions.full);
      await notice.handleKey('w');
      expect((await b.next<DeviceKey>()).permission, DevicePermissions.watch);
      await notice.handleKey('D');
      expect((await c.next<ErrorMessage>()).code, ErrorCodes.pairingDenied);
      await notice.handleKey('A');
      expect(lines.last, contains('No device is waiting'));
      for (final t in [a, b, c]) {
        await t.close();
      }
    });
  });
}
