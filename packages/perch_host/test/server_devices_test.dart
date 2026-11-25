import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/approval_dialog.dart';
import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'server_test.dart' show TestClient;

/// An approval dialog that never shows anything: the test decides through [answer].
class FakePrompter implements ApprovalPrompter {
  final shown = <PendingDevice>[];
  final cancelled = <String>[];
  final _answers = <String, Completer<String?>>{};

  @override
  ApprovalPrompt show({required String machineName, required PendingDevice request}) {
    shown.add(request);
    final c = Completer<String?>();
    _answers[request.id] = c;
    return ApprovalPrompt(c.future, () {
      cancelled.add(request.id);
      if (!c.isCompleted) c.complete(null);
    });
  }

  void answer(String id, String? decision) => _answers[id]!.complete(decision);
}

Future<HttpClientResponse> control(int port, String query, {bool header = true, String? origin}) async {
  final client = HttpClient();
  final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/control?$query'));
  if (header) req.headers.set('x-perch-control', '1');
  if (origin != null) req.headers.set('origin', origin);
  final res = await req.close();
  client.close();
  return res;
}

void main() {
  late Directory tmp;
  late SessionManager manager;
  late HostState state;
  late PerchServer server;
  late FakePrompter prompter;
  late List<({Uri uri, Map<String, String> headers, String body})> posts;
  late int port;
  final clients = <TestClient>[];

  Future<void> startServer({Duration pairingWait = const Duration(minutes: 5)}) async {
    server = PerchServer(
      manager: manager,
      state: state,
      machineName: 'test-machine',
      bindAddress: '127.0.0.1',
      port: 0,
      pollInterval: const Duration(minutes: 10),
      approvals: prompter,
      pairingWait: pairingWait,
      relayPoster: (uri, headers, body) async {
        posts.add((uri: uri, headers: headers, body: body));
        return (status: 200, body: '{}');
      },
    );
    port = await server.start();
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_srvd_');
    manager = SessionManager(launcher: fakeLauncher(), external: FakeExternalSessions());
    state = HostState.load('${tmp.path}${Platform.pathSeparator}state')..setRelay('https://relay.example');
    prompter = FakePrompter();
    posts = [];
    await startServer();
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

  Future<TestClient> connect(String deviceId, {List<int>? secret}) async {
    final c = await TestClient.connect(port, state, deviceId: deviceId, secret: secret ?? state.secret);
    clients.add(c);
    return c;
  }

  /// A new app asking to pair: waits for PairingPending.
  Future<TestClient> ask(String deviceId, {String name = 'Pixel'}) async {
    final c = await connect(deviceId);
    c.send(Hello(deviceName: name, pairing: 2));
    await c.next<PairingPending>();
    return c;
  }

  /// A new app that is allowed with [permission]; returns it connected and its key.
  Future<({TestClient c, String key})> allowed(String deviceId, {String permission = DevicePermissions.full}) async {
    final c = await ask(deviceId);
    await server.decideDevice(deviceId, permission);
    final k = await c.next<DeviceKey>();
    await c.next<Sessions>();
    return (c: c, key: k.key);
  }

  Future<TestClient> withKey(String deviceId, String key, {String name = 'Pixel'}) async {
    final c = await connect(deviceId, secret: base64UrlDecodeNoPad(key));
    c.send(Hello(deviceName: name, pairing: 2));
    await c.next<Sessions>();
    return c;
  }

  group('pairing v2', () {
    test('a new device waits, is allowed, gets its key, and the key is what opens later', () async {
      final c = await ask('dev-new1');
      expect(c.received.whereType<Welcome>(), isEmpty);
      expect((c.received.whereType<PairingPending>().single).machineName, 'test-machine');
      expect(server.pendingDevices.single.id, 'dev-new1');
      expect(server.pendingDevices.single.route, '127.0.0.1');
      expect(prompter.shown.single.name, 'Pixel');
      expect(state.everPaired, isFalse, reason: 'set on the first approval, not on hello');

      await server.decideDevice('dev-new1', DeviceDecisions.full);
      final key = await c.next<DeviceKey>();
      expect(key.permission, DevicePermissions.full);
      final w = await c.next<Welcome>();
      expect(w.permission, DevicePermissions.full);
      await c.next<Sessions>();
      final devices = await c.next<DevicesMessage>();
      expect(devices.devices.single.thisDevice, isTrue);
      expect(devices.devices.single.connected, isTrue);
      expect(server.pendingDevices, isEmpty);
      expect(prompter.cancelled, ['dev-new1'], reason: 'the dialog goes when decided another way');
      expect(state.everPaired, isTrue);
      expect(state.device('dev-new1')!.key, key.key);

      final again = await withKey('dev-new1', key.key);
      expect(again.received.whereType<Welcome>().single.permission, DevicePermissions.full);
      expect(state.device('dev-new1')!.keyed, isTrue);

      // From now on the pairing secret only asks again (the device must be allowed again).
      final stranger = await connect('dev-new1');
      stranger.send(const Hello(deviceName: 'Pixel', pairing: 2));
      await stranger.next<PairingPending>();
      expect(state.device('dev-new1')!.key, key.key, reason: 'the record stays until the new request is decided');
      // An older app with the pairing secret is refused outright.
      final old = await connect('dev-new1');
      old.send(const Hello(deviceName: 'Pixel'));
      final e = await old.next<ErrorMessage>();
      expect(e.code, ErrorCodes.updateApp);
      await waitUntil(() => old.closed);
    });

    test('a wrong key fails the handshake like a wrong secret', () async {
      final a = await allowed('dev-k1');
      await withKey('dev-k1', a.key);
      final c = await connect('dev-k1', secret: List.filled(32, 7));
      c.send(const Hello(deviceName: 'x', pairing: 2));
      await waitUntil(() => c.closed);
      expect(c.channelError, ChannelErrors.badKey);
    });

    test('denied: the device is told and closed, nothing is stored', () async {
      final c = await ask('dev-no1');
      await server.decideDevice('dev-no1', DeviceDecisions.deny);
      final e = await c.next<ErrorMessage>();
      expect(e.code, ErrorCodes.pairingDenied);
      await waitUntil(() => c.closed);
      expect(state.devices, isEmpty);
      expect(state.everPaired, isFalse);
    });

    test('a request nobody decides expires', () async {
      await server.close();
      await startServer(pairingWait: const Duration(milliseconds: 300));
      final c = await ask('dev-late');
      final e = await c.next<ErrorMessage>();
      expect(e.code, ErrorCodes.pairingExpired);
      await waitUntil(() => c.closed);
      expect(server.pendingDevices, isEmpty);
      expect(prompter.cancelled, ['dev-late']);
    });

    test('the OS dialog decides', () async {
      final c = await ask('dev-dlg1');
      prompter.answer('dev-dlg1', DeviceDecisions.watch);
      final k = await c.next<DeviceKey>();
      expect(k.permission, DevicePermissions.watch);
      expect((await c.next<Welcome>()).permission, DevicePermissions.watch);
      expect(state.device('dev-dlg1')!.permission, DevicePermissions.watch);
    });

    test('a dialog that gives up leaves the request pending', () async {
      await ask('dev-dlg2');
      prompter.answer('dev-dlg2', null);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(server.pendingDevices.single.id, 'dev-dlg2');
    });

    test('a device allowed while it was away gets its key when it comes back', () async {
      final c = await ask('dev-away');
      await c.close();
      await waitUntil(() => c.closed);
      await server.decideDevice('dev-away', DeviceDecisions.full);
      final back = await connect('dev-away');
      back.send(const Hello(deviceName: 'Pixel', pairing: 2));
      final k = await back.next<DeviceKey>();
      expect(k.key, state.device('dev-away')!.key);
      await back.next<Welcome>();
    });

    test('decisions take a unique prefix of the id', () async {
      await ask('3f9a-aaaa');
      await expectLater(server.decideDevice('3f9', DeviceDecisions.full), throwsArgumentError);
      await server.decideDevice('3f9a', DeviceDecisions.full);
      expect(state.device('3f9a-aaaa'), isNotNull);
      await expectLater(server.decideDevice('zzzz', DeviceDecisions.full), throwsArgumentError);
    });
  });

  group('no keyless access (legacy devices removed 2026-11-19)', () {
    test('an older app is told to update Perch; nothing is asked or stored', () async {
      final c = await connect('dev-old1');
      c.send(const Hello(deviceName: 'Android'));
      final e = await c.next<ErrorMessage>();
      expect(e.code, ErrorCodes.updateApp);
      expect(e.message, contains('Update Perch'));
      await waitUntil(() => c.closed);
      expect(server.pendingDevices, isEmpty);
      expect(prompter.shown, isEmpty);
      expect(state.device('dev-old1'), isNull);
    });

    test('an older app is refused even for an allowed device id', () async {
      final a = await allowed('dev-up1');
      await a.c.close();
      final old = await connect('dev-up1');
      old.send(const Hello(deviceName: 'Android'));
      expect((await old.next<ErrorMessage>()).code, ErrorCodes.updateApp);
      expect(state.device('dev-up1'), isNotNull, reason: 'the allowed device itself is not touched');
    });

    test('once a device has used its key, the pairing secret only asks again', () async {
      final a = await allowed('dev-k2');
      await a.c.close();
      await withKey('dev-k2', a.key);
      expect(state.device('dev-k2')!.keyed, isTrue);
      final again = await connect('dev-k2');
      again.send(const Hello(deviceName: 'Pixel', pairing: 2));
      await again.next<PairingPending>();
      expect(again.received.whereType<DeviceKey>(), isEmpty);
      expect(again.received.whereType<Welcome>(), isEmpty);
    });

    test('a device allowed while away gets its key; after using it the pairing secret only asks', () async {
      final c = await ask('dev-away2');
      await c.close();
      await waitUntil(() => c.closed);
      await server.decideDevice('dev-away2', DeviceDecisions.full);
      expect(state.device('dev-away2')!.keyed, isFalse, reason: 'not handed over yet');
      final back = await connect('dev-away2');
      back.send(const Hello(deviceName: 'Pixel', pairing: 2));
      final k = await back.next<DeviceKey>();
      await back.next<Welcome>();
      expect(state.device('dev-away2')!.keyed, isFalse, reason: 'keyed once it connects with the key');
      await withKey('dev-away2', k.key);
      expect(state.device('dev-away2')!.keyed, isTrue);
      final third = await connect('dev-away2');
      third.send(const Hello(deviceName: 'Pixel', pairing: 2));
      await third.next<PairingPending>();
    });
  });

  group('permissions', () {
    test('a watch-only device can look but not act; syncs are dropped silently', () async {
      final w = await allowed('dev-w1', permission: DevicePermissions.watch);
      expect(w.c.received.whereType<DevicesMessage>(), isEmpty, reason: 'the device list is for full devices');
      final from = w.c.received.length;
      w.c.send(const ListSessions());
      await w.c.next<Sessions>(from: from);
      w.c.send(SyncModelTable(table: ModelTable.starting));
      w.c.send(const SendMessage(sessionId: 's1', text: 'hi'));
      final e = await w.c.next<ErrorMessage>(from: from);
      expect(e.code, ErrorCodes.watchOnly);
      expect(e.message, contains('perch_host devices full dev-'));
      expect(w.c.received.skip(from).whereType<ErrorMessage>(), hasLength(1), reason: 'the sync said nothing');
      expect(w.c.received.skip(from).whereType<ModelTableMessage>(), isEmpty);
      w.c.send(const DecideDevice(deviceId: 'x', decision: 'full'));
      await w.c.next<ErrorMessage>(from: from, where: (m) => m != e);
      w.c.send(const ListDevices());
      final own = await w.c.next<DevicesMessage>(from: from);
      expect(own.devices.single.id, 'dev-w1');
      expect(own.pending, isEmpty);
    });

    test('a permission change applies to a live connection at once', () async {
      final f = await allowed('dev-p1');
      final from = f.c.received.length;
      server.setDevicePermission('dev-p1', DevicePermissions.watch);
      final w = await f.c.next<Welcome>(from: from);
      expect(w.permission, DevicePermissions.watch);
      f.c.send(const KillAll());
      expect((await f.c.next<ErrorMessage>(from: from)).code, ErrorCodes.watchOnly);
    });

    test('a full device manages the others from the app', () async {
      final admin = await allowed('dev-adm1');
      final other = await allowed('dev-oth1', permission: DevicePermissions.watch);
      final pending = await ask('dev-pnd1');

      var from = admin.c.received.length;
      admin.c.send(const ListDevices());
      final list = await admin.c.next<DevicesMessage>(from: from);
      expect(list.devices.map((d) => d.id), ['dev-adm1', 'dev-oth1']);
      expect(list.pending.single.id, 'dev-pnd1');

      admin.c.send(const DecideDevice(deviceId: 'dev-pnd1', decision: DeviceDecisions.full));
      await pending.next<DeviceKey>();
      admin.c.send(const RenameDevice(deviceId: 'dev-oth1', name: 'Tablet'));
      await waitUntil(() => state.device('dev-oth1')!.name == 'Tablet');
      admin.c.send(const SetDevicePermission(deviceId: 'dev-oth1', permission: DevicePermissions.full));
      await waitUntil(() => state.device('dev-oth1')!.full);

      from = admin.c.received.length;
      admin.c.send(const RemoveDevice(deviceId: 'dev-oth1'));
      final e = await other.c.next<ErrorMessage>(where: (m) => m.code == ErrorCodes.deviceRemoved);
      expect(e.message, contains('test-machine'));
      await waitUntil(() => other.c.closed);
      final after = await admin.c.next<DevicesMessage>(from: from, where: (m) => m.devices.length == 2);
      expect(after.devices.map((d) => d.id), ['dev-adm1', 'dev-pnd1']);
      expect(state.device('dev-oth1'), isNull);

      // Its push token is dropped at the relay.
      await waitUntil(() => posts.isNotEmpty);
      expect(posts.single.uri.toString(), endsWith('/devices/dev-oth1/push-token'));
      expect(posts.single.uri.toString(), contains(state.machineId));
      expect(jsonDecode(posts.single.body), {'token': null});
      expect(posts.single.headers['Authorization'], 'Bearer ${state.deviceToken}');

      // Its key no longer opens anything.
      final c = await connect('dev-oth1', secret: base64UrlDecodeNoPad(other.key));
      c.send(const Hello(deviceName: 'x', pairing: 2));
      await waitUntil(() => c.closed);
      expect(c.channelError, ChannelErrors.badKey);
    });

    test('device names are checked', () async {
      final a = await allowed('dev-n1');
      final from = a.c.received.length;
      a.c.raw('{"type":"renameDevice","deviceId":"dev-n1","name":""}');
      expect((await a.c.next<ErrorMessage>(from: from)).code, ErrorCodes.badRequest);
    });
  });

  test('the board page on this machine connects without approval and is not stored', () async {
    final c = await connect(boardPageDeviceId);
    c.send(const Hello(deviceName: 'Board page on this machine', pairing: 2));
    await c.next<Sessions>();
    expect(c.received.whereType<Welcome>().single.permission, DevicePermissions.full);
    expect(state.devices, isEmpty);
    expect(server.pendingDevices, isEmpty);
  });

  group('/control', () {
    test('refuses a request without the header or from another site', () async {
      expect((await control(port, 'action=devices', header: false)).statusCode, 403);
      expect((await control(port, 'action=devices', origin: 'https://evil.example')).statusCode, 403);
      expect((await control(port, 'action=reload')).statusCode, 200);
    });

    test('lists and decides devices', () async {
      await ask('dev-ctl1');
      var res = await control(port, 'action=devices');
      var j = jsonDecode(await utf8.decodeStream(res)) as Map;
      expect((j['pending'] as List).single['id'], 'dev-ctl1');
      res = await control(port, 'action=device-decide&id=dev-ctl1&decision=watch');
      expect(res.statusCode, 200);
      expect(state.device('dev-ctl1')!.permission, DevicePermissions.watch);
      res = await control(port, 'action=device-permission&id=dev-ctl1&permission=full');
      expect(res.statusCode, 200);
      res = await control(port, 'action=device-rename&id=dev-ctl1&name=${Uri.encodeQueryComponent('My phone')}');
      expect(res.statusCode, 200);
      res = await control(port, 'action=devices');
      j = jsonDecode(await utf8.decodeStream(res)) as Map;
      final d = (j['devices'] as List).single as Map;
      expect(d['name'], 'My phone');
      expect(d['permission'], 'full');
      expect(d['connected'], isTrue);
      expect(d.containsKey('key'), isFalse, reason: 'keys never leave the host');
      res = await control(port, 'action=device-remove&id=dev-ctl1');
      expect(res.statusCode, 200);
      expect(state.devices, isEmpty);
      res = await control(port, 'action=device-remove&id=dev-ctl1');
      expect(res.statusCode, 400);
    });
  });

  test('reload picks up devices changed in host.json by another process', () async {
    HostState.load(state.directory).approveDevice('dev-cli1', name: 'CLI', permission: DevicePermissions.watch);
    expect((await control(port, 'action=reload')).statusCode, 200);
    expect(state.device('dev-cli1')?.name, 'CLI');
    // A later save by the host keeps it.
    state.markPaired();
    expect(HostState.load(state.directory).device('dev-cli1'), isNotNull);
  });

  test('reload drops a device removed in host.json', () async {
    final a = await allowed('dev-rl1');
    HostState.load(state.directory).removeDevice('dev-rl1');
    await control(port, 'action=reload');
    expect((await a.c.next<ErrorMessage>(where: (m) => m.code == ErrorCodes.deviceRemoved)), isNotNull);
    await waitUntil(() => a.c.closed);
  });
}
