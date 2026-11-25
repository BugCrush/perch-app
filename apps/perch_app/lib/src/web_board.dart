// The board page: this app built for the web and served by the Perch host at
// http://localhost:<port>/ to a browser on the same machine. It learns the machine from the
// host's loopback-only `/local/pairing` (no QR code needed on the machine itself) and talks
// to the host over the same encrypted channel as the phone. No push, no camera, no account
// tokens here.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'connection/machine_store.dart';

/// The machine serving this page, from its `/local/pairing` ([base]: the page's address).
Future<Machine> fetchLocalMachine(Uri base, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final r = await c.get(base.resolve('local/pairing'));
    if (r.statusCode != 200) {
      throw StateError('The Perch host did not give this page its pairing (${r.statusCode}). '
          'Open the board at http://localhost:<port>/ on the machine itself.');
    }
    return localMachineFromPairing(jsonDecode(r.body), base);
  } finally {
    if (client == null) c.close();
  }
}

/// The machine for a `/local/pairing` answer: reached at the page's own host and port.
Machine localMachineFromPairing(Object? j, Uri base) {
  if (j is! Map || j['machineId'] is! String || j['secret'] is! String) {
    throw const FormatException('Not a pairing.');
  }
  final port = j['port'] is int ? j['port'] as int : (base.hasPort ? base.port : defaultPort);
  final host = base.host.isEmpty ? 'localhost' : base.host;
  return Machine(
    id: j['machineId'] as String,
    label: j['name'] is String ? j['name'] as String : 'This machine',
    lan: ['${host.contains(':') ? '[$host]' : host}:$port'],
    secret: j['secret'] as String,
  );
}

/// The page's only machine: never saved, never forgotten.
class LocalMachineStore extends MachineStore {
  final Machine machine;
  LocalMachineStore(this.machine);
  @override
  Future<List<Machine>> load({bool fresh = false}) async => [machine];
  @override
  Future<void> save(Machine m) async {}
  @override
  Future<void> remove(String id) async {}
}
