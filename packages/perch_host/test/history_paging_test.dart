import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'server_test.dart' show TestClient;

const sid = '22222222-3333-4444-8555-666666666666';
final sep = Platform.pathSeparator;

void main() {
  late Directory tmp;
  late SessionManager manager;
  late HostState state;
  late PerchServer server;
  late TestClient c;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_page_');
    final project = Directory('${tmp.path}${sep}config${sep}projects${sep}D--work')..createSync(recursive: true);
    final start = DateTime.utc(2026, 11, 12, 9);
    File('${project.path}$sep$sid.jsonl').writeAsStringSync([
      for (var i = 1; i <= 700; i++)
        jsonEncode({
          'type': 'user',
          'timestamp': start.add(Duration(seconds: i)).toIso8601String(),
          'message': {'role': 'user', 'content': 'message $i'},
        }),
      '',
    ].join('\n'));
    final work = Directory('${tmp.path}${sep}work')..createSync();
    final external = FakeExternalSessions();
    external.entries = [external.entry(pid: 4242, sessionId: sid, cwd: work.path, name: 'long')];
    manager = SessionManager(
        launcher: fakeLauncher(), external: external, typer: FakeConsoleTyper(), claudeConfigDir: '${tmp.path}${sep}config');
    state = HostState.load('${tmp.path}${sep}state');
    server = PerchServer(manager: manager, state: state, machineName: 'm', bindAddress: '127.0.0.1', port: 0);
    final port = await server.start();
    state.approveDevice('dev-test', name: 'Phone', permission: DevicePermissions.full);
    c = await TestClient.connect(port, state);
    c.send(const Hello(deviceName: 'Phone'));
    await c.next<Sessions>();
  });

  tearDown(() async {
    await c.close();
    await server.close();
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String text(ConversationEvent e) => (e as UserMessage).text;

  test('first_subscribe_returns_latest_300_with_has_earlier', () async {
    c.send(const Subscribe(sessionId: sid));
    final ev = await c.next<Events>();
    expect(ev.events, hasLength(300));
    expect(ev.hasEarlier, isTrue);
    expect(text(ev.events.first), 'message 401');
    expect(text(ev.events.last), 'message 700');

    // A reconnect catch-up still gets everything after its seq, without paging.
    final mark = c.received.length;
    c.send(Subscribe(sessionId: sid, afterSeq: ev.events.last.seq - 400));
    final again = await c.next<Events>(from: mark);
    expect(again.events, hasLength(400));
    expect(again.hasEarlier, isFalse);
  });

  test('load_earlier_returns_previous_page', () async {
    c.send(const Subscribe(sessionId: sid));
    final ev = await c.next<Events>();
    c.send(LoadEarlier(sessionId: sid, beforeSeq: ev.events.first.seq));
    final p1 = await c.next<EarlierEvents>();
    expect(p1.events, hasLength(300));
    expect(text(p1.events.first), 'message 101');
    expect(text(p1.events.last), 'message 400');
    expect(p1.hasEarlier, isTrue);
    c.send(LoadEarlier(sessionId: sid, beforeSeq: p1.events.first.seq));
    final p2 = await c.next<EarlierEvents>(where: (m) => m != p1);
    expect(p2.events, hasLength(100));
    expect(text(p2.events.first), 'message 1');
    expect(p2.hasEarlier, isFalse);
  });
}
