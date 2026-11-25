import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/push_notifier.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'server_hooks_test.dart' show post, questions;
import 'server_test.dart' show TestClient;

const sid = '55555555-6666-4777-8888-999999999999';

void main() {
  late Directory tmp;
  late SessionManager manager;
  late HostState state;
  late PerchServer server;
  late PushNotifier notifier;
  late int port;
  late List<({Map<String, dynamic> body, PushNote note})> pushed;
  final clients = <TestClient>[];

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_srvp_');
    final external = FakeExternalSessions()
      ..entries = [FakeExternalSessions().entry(pid: 6161, sessionId: sid, cwd: tmp.path, status: 'busy', name: 'work')];
    manager = SessionManager(
        launcher: fakeLauncher(),
        external: external,
        typer: FakeConsoleTyper(),
        claudeConfigDir: '${tmp.path}${Platform.pathSeparator}cfg');
    state = HostState.load('${tmp.path}${Platform.pathSeparator}state')
      ..setRelay('https://relay.example')
      ..approveDevice('owner-phone', name: 'Phone', permission: DevicePermissions.full)
      ..confirmKey('owner-phone');
    pushed = [];
    notifier = PushNotifier(
      source: manager,
      state: state,
      machineName: 'test-machine',
      settle: const Duration(milliseconds: 50),
      poster: (uri, headers, body) async {
        final j = jsonDecode(body) as Map<String, dynamic>;
        // One post per device now (each sealed with its own key): follow the owner's phone.
        if (!(j['devices'] as List).contains('owner-phone')) return (status: 200, body: '{"sent":1,"failed":0}');
        pushed.add((body: j, note: (() {
          for (final d in state.devices) {
            final n = openPush(d.keyBytes!, state.machineId, j['payload'] as String);
            if (n != null) return n;
          }
          return null;
        })()!));
        return (status: 200, body: '{"sent":1,"failed":0}');
      },
    );
    server = PerchServer(
      manager: manager,
      state: state,
      machineName: 'test-machine',
      bindAddress: '127.0.0.1',
      port: 0,
      pollInterval: const Duration(minutes: 10),
      notifier: notifier,
    );
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

  Future<TestClient> paired(String deviceId) async {
    if (state.device(deviceId) == null) {
      state.approveDevice(deviceId, name: 'Phone', permission: DevicePermissions.full);
    }
    final c = await TestClient.connect(port, state, deviceId: deviceId);
    clients.add(c);
    c.send(const Hello(deviceName: 'Phone'));
    await c.next<Sessions>();
    return c;
  }

  Future<void> question(String id) => post('127.0.0.1', port, {
        'session_id': sid,
        'cwd': tmp.path,
        'hook_event_name': 'PreToolUse',
        'tool_name': 'AskUserQuestion',
        'tool_input': questions,
        'tool_use_id': id,
      });

  test('a hook-opened card is pushed, except to the device showing that session, and withdrawn on answer', () async {
    final phone = await paired('phone');
    await paired('tablet');
    phone.send(const FocusSession(sessionId: sid));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.focusedDevices(sid), ['phone']);

    await question('toolu_P1');
    await waitUntil(() => pushed.isNotEmpty, timeout: const Duration(seconds: 5));
    expect(pushed.single.note.body, 'work: asked a question');
    expect(pushed.single.note.title, 'test-machine');
    expect(pushed.single.body['except'], ['phone']);

    // Answered at the terminal and the turn ended: the Stop hook closes the card, and the
    // finished turn replaces its notification (every session's finished turn is told).
    await post('127.0.0.1', port, {'session_id': sid, 'hook_event_name': 'Stop'});
    await waitUntil(() => pushed.length == 2, timeout: const Duration(seconds: 5));
    expect(pushed[1].note.kind, PushKinds.finished);
    expect(pushed[1].body['collapseKey'], pushed[0].body['collapseKey']);

    // The phone leaves the session: it is told again next time.
    phone.send(const FocusSession());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await question('toolu_P2');
    await waitUntil(() => pushed.length == 3, timeout: const Duration(seconds: 5));
    expect(pushed[2].body.containsKey('except'), isFalse);
  });

  test('typing at the terminal silences the session', () async {
    await paired('phone');
    await post('127.0.0.1', port,
        {'session_id': sid, 'hook_event_name': 'UserPromptSubmit', 'prompt': 'typed at the desk'});
    await question('toolu_Q1');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(pushed, isEmpty);
    await post('127.0.0.1', port, {'session_id': sid, 'hook_event_name': 'Stop'});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(pushed, isEmpty);
  });

  test('a message sent from Perch: its hook is not the owner typing, and the finished turn is pushed', () async {
    final phone = await paired('phone');
    phone.send(const SendMessage(sessionId: sid, text: 'carry on please'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await post('127.0.0.1', port,
        {'session_id': sid, 'hook_event_name': 'UserPromptSubmit', 'prompt': 'carry on please'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await post('127.0.0.1', port, {'session_id': sid, 'hook_event_name': 'Stop'});
    await waitUntil(() => pushed.isNotEmpty, timeout: const Duration(seconds: 5));
    expect(pushed.single.note.body, 'work: finished');
    expect(pushed.single.note.kind, PushKinds.finished);
  });

  test('a usage limit from Claude Code is pushed in its own words', () async {
    await post('127.0.0.1', port, {
      'session_id': sid,
      'hook_event_name': 'Notification',
      'notification_type': 'quota_exceeded',
      'message': 'Usage limit reached',
    });
    await waitUntil(() => pushed.isNotEmpty, timeout: const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(pushed.single.note.body, 'work: hit a usage limit');
  });

  test('after name set and reload the notification title is the new name', () async {
    HostState.load(state.directory).setMachineName('Studio desk');
    await server.reloadState();
    await question('toolu_N1');
    await waitUntil(() => pushed.isNotEmpty, timeout: const Duration(seconds: 5));
    expect(pushed.single.note.title, 'Studio desk');
  });

  test('stopping remote access stops notifications', () async {
    await server.stopRemoteAccess();
    await question('toolu_S1');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(pushed, isEmpty);
  });
}
