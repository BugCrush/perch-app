import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/devices_cli.dart';
import 'package:perch_host/src/host_state.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late List<String> out, err, queries;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_devcli_');
    out = [];
    err = [];
    queries = [];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<int> run(List<String> rest, {bool watch = false, ({int status, String body})? answer, bool host = true}) =>
      runDevicesCommand(rest,
          watchFlag: watch,
          stateDir: tmp.path,
          control: (q) async {
            queries.add(q);
            return host ? (answer ?? (status: 200, body: 'OK\n')) : null;
          },
          out: out.add,
          err: err.add);

  test('a running host lists devices and pending requests', () async {
    final now = DateTime(2026, 11, 19, 12);
    final lines = devicesTable({
      'devices': [
        {'id': '3f9a1234abcd', 'name': 'Pixel', 'permission': 'full', 'keyed': true, 'lastSeenAtMs': now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch, 'connected': true},
        {'id': 'b2c4', 'name': 'Old', 'permission': 'watch', 'keyed': false, 'lastSeenAtMs': null, 'connected': false},
      ],
      'pending': [
        {'id': '77aa9900', 'name': 'Tablet', 'route': 'relay', 'requestedAtMs': 1},
      ],
    }, now: now);
    expect(lines[0], startsWith('ID'));
    expect(lines[1], contains('3f9a1234'));
    expect(lines[1], contains('full control'));
    expect(lines[1], contains('own key'));
    expect(lines[1], contains('5 min ago'));
    expect(lines[1], endsWith('yes'));
    expect(lines[2], contains('watch only'));
    expect(lines[2], contains('waiting'));
    expect(lines[2], contains('never'));
    expect(lines.join('\n'), contains('Waiting: allowed; it uses its own key from its next connection.'));
    expect(lines.join('\n'), isNot(contains('while its app was away')));
    expect(lines.join('\n'), contains('77aa  "Tablet" over the relay'));
    expect(lines.join('\n'), contains('devices allow 77aa'));
  });

  test('subcommands go to the running host', () async {
    expect(await run(['allow', '77aa'], watch: true), 0);
    expect(await run(['deny', '77aa']), 0);
    expect(await run(['full', '3f9a']), 0);
    expect(await run(['watch', '3f9a']), 0);
    expect(await run(['rename', '3f9a', 'Work', 'phone']), 0);
    expect(await run(['remove', '3f9a']), 0);
    expect(queries, [
      'action=device-decide&id=77aa&decision=watch',
      'action=device-decide&id=77aa&decision=deny',
      'action=device-permission&id=3f9a&permission=full',
      'action=device-permission&id=3f9a&permission=watch',
      'action=device-rename&id=3f9a&name=Work+phone',
      'action=device-remove&id=3f9a',
    ]);
  });

  test('the host refusing is shown and fails', () async {
    expect(await run(['allow', 'zz'], answer: (status: 400, body: 'No device is waiting with the id zz.\n')), 1);
    expect(err.single, 'No device is waiting with the id zz.');
  });

  test('with no host running it edits host.json; requests need a running host', () async {
    HostState.load(tmp.path).approveDevice('3f9a1234', name: 'Pixel', permission: DevicePermissions.full);
    expect(await run(['watch', '3f9a'], host: false), 0);
    expect(HostState.load(tmp.path).device('3f9a1234')!.permission, DevicePermissions.watch);
    expect(await run([], host: false), 0);
    expect(out.join('\n'), contains('Pixel'));
    expect(out.join('\n'), isNot(contains('CONNECTED')));
    expect(await run(['allow', '3f9a'], host: false), 1);
    expect(await run(['remove', '3f9a'], host: false), 0);
    expect(HostState.load(tmp.path).devices, isEmpty);
    expect(await run(['remove', '3f9a'], host: false), 1);
    final j = jsonDecode(File('${tmp.path}/host.json').readAsStringSync()) as Map;
    expect(j['devices'], isEmpty);
  });

  test('a missing id is a usage error', () async {
    expect(await run(['allow']), 64);
    expect(await run(['bogus', 'x']), 64);
  });
}
