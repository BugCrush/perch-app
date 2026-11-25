import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'server_test.dart' show TestClient;

void main() {
  late Directory tmp;
  late SessionManager manager;
  late HostState state;
  late PerchServer server;
  late int port;
  final clients = <TestClient>[];
  final sep = Platform.pathSeparator;
  const old = '66666666-6666-4666-8666-666666666666';

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_search_srv_');
    final config = '${tmp.path}${sep}config';
    File('$config${sep}projects${sep}work$sep$old.jsonl')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${jsonEncode({
            'type': 'user',
            'cwd': '/work',
            'timestamp': '2026-11-19T10:00:00.000Z',
            'message': {'role': 'user', 'content': 'migrate the database schema'},
          })}\n');
    manager = SessionManager(launcher: fakeLauncher(), external: FakeExternalSessions(), claudeConfigDir: config);
    state = HostState.load('${tmp.path}${sep}state')
      ..approveDevice('dev-full', name: 'Phone', permission: DevicePermissions.full)
      ..approveDevice('dev-watch', name: 'Tablet', permission: DevicePermissions.watch);
    server = PerchServer(manager: manager, state: state, machineName: 'test-machine', bindAddress: '127.0.0.1', port: 0);
    port = await server.start();
  });

  tearDown(() async {
    for (final c in clients) {
      await c.close();
    }
    clients.clear();
    await server.close();
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<TestClient> device(String id) async {
    final c = await TestClient.connect(port, state, deviceId: id);
    clients.add(c);
    c.send(const Hello(deviceName: 'Phone', pairing: 2));
    await c.next<Sessions>();
    return c;
  }

  test('a device searches the machine\'s conversations and opens an old one', () async {
    final c = await device('dev-full');
    c.send(const SearchSessions(query: 'schema'));
    final r = await c.next<SearchResults>();
    expect(r.query, 'schema');
    expect(r.hits.single.sessionId, old);
    expect(r.hits.single.snippet, 'migrate the database schema');
    c.send(const Subscribe(sessionId: old));
    final events = await c.next<Events>(where: (e) => e.sessionId == old);
    expect(events.events.whereType<UserMessage>().single.text, 'migrate the database schema');
  });

  test('a watch-only device may search (it only reads)', () async {
    final c = await device('dev-watch');
    c.send(const SearchSessions(query: 'schema'));
    final r = await c.next<SearchResults>();
    expect(r.hits, hasLength(1));
    expect(c.received.whereType<ErrorMessage>(), isEmpty);
  });
}
