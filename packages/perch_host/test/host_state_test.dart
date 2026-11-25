import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:perch_host/src/host_notice.dart';
import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/qr_render.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('perch_state_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String path(String name) => '${tmp.path}${Platform.pathSeparator}$name';

  test('first_load_creates_identity_and_later_loads_keep_it', () {
    final a = HostState.load(tmp.path);
    expect(a.createdNow, isTrue);
    expect(base64UrlDecodeNoPad(a.machineId), hasLength(16));
    expect(a.secret, hasLength(32));
    expect(a.everPaired, isFalse);
    expect(a.relayUrl, isNull);
    final b = HostState.load(tmp.path);
    expect(b.createdNow, isFalse);
    expect(b.machineId, a.machineId);
    expect(b.secret, a.secret);
    final j = jsonDecode(File(path('host.json')).readAsStringSync()) as Map;
    expect(j['machineId'], a.machineId);
  });

  test('a_phase_1_state_file_gets_a_new_identity', () {
    File(path('host.json')).writeAsStringSync('{"code":"ABCD2345"}');
    final s = HostState.load(tmp.path);
    expect(s.createdNow, isTrue);
    expect(s.secret, hasLength(32));
    final j = jsonDecode(File(path('host.json')).readAsStringSync()) as Map;
    expect(j.containsKey('code'), isFalse);
  });

  test('forget_devices_rotates_secret_and_machine_id', () {
    final s = HostState.load(tmp.path)
      ..markPaired()
      ..setRelay('https://relay.example');
    final oldSecret = Uint8List.fromList(s.secret);
    final oldId = s.machineId;
    final oldHost = s.hostToken;
    s.forgetDevices();
    expect(s.secret, isNot(equals(oldSecret)));
    expect(s.machineId, isNot(oldId));
    expect(s.hostToken, isNot(oldHost));
    expect(s.everPaired, isFalse);
    expect(s.relayUrl, 'https://relay.example');
    final again = HostState.load(tmp.path);
    expect(again.secret, s.secret);
    expect(again.machineId, s.machineId);
  });

  test('relay_url_and_paired_flag_persist', () {
    final s = HostState.load(tmp.path);
    s.setRelay('https://perch-relay.example.workers.dev/');
    s.markPaired();
    final again = HostState.load(tmp.path);
    expect(again.relayUrl, 'https://perch-relay.example.workers.dev');
    expect(again.everPaired, isTrue);
    again.setRelay(null);
    expect(HostState.load(tmp.path).relayUrl, isNull);
    expect(() => again.setRelay('ftp://x'), throwsArgumentError);
  });

  test('last_serve_name_and_port_persist', () {
    final s = HostState.load(tmp.path)..rememberServe(name: 'Desk', port: 8790);
    final again = HostState.load(tmp.path);
    expect(again.lastName, 'Desk');
    expect(again.lastPort, 8790);
    expect(s.lastPort, 8790);
  });

  test('machine_name_set_persists_trims_and_clears', () {
    final s = HostState.load(tmp.path);
    expect(s.machineName, isNull);
    expect(serveName(s), Platform.localHostname);
    s.setMachineName('  Studio desk  ');
    expect(s.machineName, 'Studio desk');
    final again = HostState.load(tmp.path);
    expect(again.machineName, 'Studio desk');
    expect(again.machineId, s.machineId);
    expect(serveName(again), 'Studio desk');
    expect(serveName(again, flag: 'From flag'), 'From flag');
    expect(() => again.setMachineName('   '), throwsArgumentError);
    expect(() => again.setMachineName('x' * (maxMachineNameLength + 1)), throwsArgumentError);
    expect(HostState.load(tmp.path).machineName, 'Studio desk');
    again.setMachineName(null);
    expect(HostState.load(tmp.path).machineName, isNull);
  });

  test('pairing_link_carries_identity', () {
    final s = HostState.load(tmp.path)..setRelay('https://relay.example');
    final link = PairingLink.parse(s.link(name: 'Desk', lan: ['192.168.1.20:8787']).toString())!;
    expect(link.machineId, s.machineId);
    expect(link.secret, s.secret);
    expect(link.relayUrl, 'https://relay.example');
    expect(link.lan, ['192.168.1.20:8787']);
    expect(link.name, 'Desk');
  });

  group('banner', () {
    test('qr_shows_until_a_device_has_paired', () {
      final s = HostState.load(tmp.path);
      expect(showQrInBanner(s), isTrue);
      s.markPaired();
      expect(showQrInBanner(HostState.load(tmp.path)), isFalse);
      s.forgetDevices();
      expect(showQrInBanner(HostState.load(tmp.path)), isTrue);
    });

    test('relay_line', () {
      expect(relayLine(null), 'Relay not set');
      expect(relayLine('https://r.example', status: 'connected'), 'Relay: https://r.example (connected)');
    });

    test('pairing_lines_hold_the_link_and_write_the_picture', () {
      final s = HostState.load(tmp.path);
      final lines = pairingLines(s, name: 'Desk', lan: ['10.0.0.2:8787']);
      final link = lines.firstWhere((l) => l.startsWith('perch://pair?'));
      expect(PairingLink.parse(link)!.machineId, s.machineId);
      expect(File(s.pngPath).existsSync(), isTrue);
      expect(lines.any((l) => l.contains('█')), isTrue);
      s.forgetDevices();
      expect(File(s.pngPath).existsSync(), isFalse);
    });

    test('banner_text_has_no_pairing_code', () {
      final t = bannerText(address: '10.0.0.2', port: 8787);
      expect(t, contains('REMOTE ACCESS IS LIVE'));
      expect(t, isNot(contains('Pairing code')));
    });
  });

  group('qr', () {
    const data = 'perch://pair?v=1&n=Desk&m=AAECAwQFBgcICQoLDA0ODw&k=0123456789abcdefghijklmnopqrstuvwxyzABCDEFG';

    test('text_qr_is_square_ish_with_quiet_zone', () {
      final text = qrText(data);
      final lines = text.split('\n');
      expect(lines.length, greaterThan(10));
      expect(lines.map((l) => l.length).toSet(), hasLength(1));
      // The quiet zone is light: the first line is all full blocks.
      expect(lines.first.split('').toSet(), {'█'});
    });

    test('png_has_signature_and_size', () {
      final png = qrPng(data, scale: 4, border: 4);
      expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final bd = ByteData.sublistView(png);
      final width = bd.getUint32(16);
      final height = bd.getUint32(20);
      expect(width, height);
      expect(width % 4, 0);
      expect(String.fromCharCodes(png.sublist(png.length - 8, png.length - 4)), 'IEND');
    });

    test('crc32_known_value', () {
      expect(crc32('IEND'.codeUnits), 0xAE426082);
    });
  });
}
