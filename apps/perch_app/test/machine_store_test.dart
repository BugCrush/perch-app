import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:perch_app/src/connection/machine_store.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('save_reload_replace_remove', () async {
    final store = MachineStore();
    await store.save(testMachine(id: 'a', label: 'Desk'));
    await store.save(testMachine(id: 'b', label: 'Mac', lan: ['192.168.1.21:9000'], relayUrl: 'https://r.example'));
    var all = await MachineStore().load();
    expect(all.map((m) => m.id), ['a', 'b']);
    expect(all[1].lan, ['192.168.1.21:9000']);
    expect(all[1].relayUrl, 'https://r.example');
    expect(all[1].secretBytes, testSecret);

    await store.save(testMachine(id: 'a', label: 'Desk 2'));
    all = await MachineStore().load();
    expect(all.length, 2);
    expect(all.firstWhere((m) => m.id == 'a').label, 'Desk 2');

    await store.remove('a');
    all = await MachineStore().load();
    expect(all.map((m) => m.id), ['b']);
  });

  test('alias_persists_and_is_kept_by_copies', () async {
    final store = MachineStore();
    await store.save(testMachine(id: 'a', label: 'devbox', alias: 'Big rig'));
    var m = (await MachineStore().load()).single;
    expect(m.alias, 'Big rig');
    expect(m.label, 'devbox');
    expect(m.displayName, 'Big rig');
    expect(m.copyWith(relayUrl: 'https://r.example').alias, 'Big rig');
    expect(m.copyWith(label: 'devbox 2').displayName, 'Big rig');
    final cleared = m.copyWith(clearAlias: true);
    expect(cleared.alias, isNull);
    expect(cleared.displayName, 'devbox');
    await store.save(cleared);
    m = (await MachineStore().load(fresh: true)).single;
    expect(m.alias, isNull);
    // Machines saved before aliases existed, and blank aliases, have none.
    expect(Machine.fromJson({'id': 'x', 'label': 'L'})!.alias, isNull);
    expect(Machine.fromJson({'id': 'x', 'label': 'L', 'alias': '  '})!.alias, isNull);
  });

  test('alias_validation_trims_and_limits_length', () {
    expect(aliasError(''), isNotNull);
    expect(aliasError('   '), isNotNull);
    expect(aliasError('x' * (maxAliasLength + 1)), isNotNull);
    expect(aliasError('  ${'x' * maxAliasLength}  '), isNull);
    expect(aliasError(' Big rig '), isNull);
    expect(maxAliasLength, 40);
  });

  test('corrupt_storage_loads_empty', () async {
    SharedPreferences.setMockInitialValues({'machines': 'not json'});
    expect(await MachineStore().load(), isEmpty);
  });

  test('a_phase_1_machine_loads_and_needs_pairing', () async {
    SharedPreferences.setMockInitialValues({
      'machines': jsonEncode([
        {'id': 'old', 'label': 'Desk', 'host': '192.168.1.20', 'port': 8787, 'code': 'ABCD2345'}
      ])
    });
    final m = (await MachineStore().load()).single;
    expect(m.needsPairing, isTrue);
    expect(m.lan, ['192.168.1.20:8787']);
    expect(m.address, '192.168.1.20:8787');
  });

  test('from_pairing_link', () {
    final link = PairingLink(
        name: 'Desk', machineId: 'mid', secret: Uint8List.fromList(testSecret), lan: const ['10.0.0.2:8787']);
    final m = Machine.fromLink(PairingLink.parse(link.toString())!);
    expect(m.id, 'mid');
    expect(m.label, 'Desk');
    expect(m.needsPairing, isFalse);
    expect(m.secretBytes, testSecret);
    expect(m.relayUrl, isNull);
  });

  test('device_id_is_created_once', () async {
    final a = await loadDeviceId();
    final b = await loadDeviceId();
    expect(a, b);
    expect(a.length, greaterThan(10));
  });
}
