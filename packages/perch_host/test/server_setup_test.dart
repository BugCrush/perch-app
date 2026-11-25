// What the Perch plugin asks the host: `/local/perch/status` (paired yet? the macOS
// Accessibility permission?) and `/local/perch/pairing` (the QR code and link for /perch),
// both for the menu on this machine only; and `/control?action=switch-when-idle` after
// `perch_host setup` installed a newer build: the host restarts into it once nothing is in
// flight.
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final sep = Platform.pathSeparator;

void main() {
  late Directory tmp;
  late HostState state;
  late SessionManager manager;
  late PerchServer server;
  late int port;
  var switched = 0;
  bool? trusted;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_srvsetup_');
    state = HostState.load('${tmp.path}${sep}state');
    manager = SessionManager(
        launcher: fakeLauncher(), external: FakeExternalSessions(), claudeConfigDir: '${tmp.path}${sep}cfg');
    switched = 0;
    trusted = null;
    server = PerchServer(
      manager: manager,
      state: state,
      machineName: 'Desk',
      bindAddress: '127.0.0.1',
      port: 0,
      lanAddresses: const ['192.168.1.5:8787'],
      accessibility: () async => trusted,
      onSwitch: () async => switched++,
      switchCheck: const Duration(milliseconds: 50),
    );
    port = await server.start();
  });

  tearDown(() async {
    await server.close();
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<({int status, String body})> call(String path, {bool menu = true, bool control = false, String? origin}) async {
    final c = HttpClient();
    try {
      final req = await c.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
      if (menu) req.headers.set(PerchServer.menuHeader, '1');
      if (control) req.headers.set(PerchServer.controlHeader, '1');
      if (origin != null) req.headers.set('origin', origin);
      final res = await req.close();
      return (status: res.statusCode, body: await res.transform(utf8.decoder).join());
    } finally {
      c.close(force: true);
    }
  }

  test('status_says_whether_a_phone_is_paired_and_the_mac_permission', () async {
    var r = await call('/local/perch/status');
    expect(r.status, 200);
    var j = jsonDecode(r.body) as Map;
    expect(j['paired'], isFalse);
    expect(j['version'], hostVersion);
    expect(j['machine'], 'Desk');
    expect(j.containsKey('accessibility'), isFalse, reason: 'not a Mac');
    trusted = false;
    j = jsonDecode((await call('/local/perch/status')).body) as Map;
    expect(j['accessibility'], isFalse);
    expect(j['accessibilityHelp'], contains('Accessibility'));
    state.markPaired();
    j = jsonDecode((await call('/local/perch/status')).body) as Map;
    expect(j['paired'], isTrue);
  });

  test('pairing_gives_the_link_and_qr_to_the_menu_only', () async {
    final r = await call('/local/perch/pairing');
    expect(r.status, 200);
    final j = jsonDecode(r.body) as Map;
    expect(j['link'], startsWith('perch://pair?'));
    expect((j['qr'] as String).split('\n').length, greaterThan(10));
    expect((await call('/local/perch/pairing', menu: false)).status, 403);
    expect((await call('/local/perch/pairing', origin: 'https://evil.example')).status, 403);
  });

  test('switch_when_idle_restarts_once_nothing_is_in_flight', () async {
    expect((await call('/control?action=switch-when-idle', menu: false)).status, 403, reason: 'perch_host only');
    final r = await call('/control?action=switch-when-idle', menu: false, control: true);
    expect(r.status, 200);
    expect(manager.quiet, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(switched, 1, reason: 'once');
  });
}
