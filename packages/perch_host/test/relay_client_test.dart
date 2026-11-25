import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/relay_client.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// A stand-in for the relay's host endpoint: accepts host WebSockets and lets the test
/// play the devices.
class FakeRelay {
  late HttpServer http;
  final List<WebSocket> hosts = [];
  final List<HttpHeaders> headers = [];
  final List<Uri> uris = [];
  final List<Object> received = [];
  bool refuse = false;

  /// Refuse the host socket and answer `/check` with this error (an invite or pool refusal).
  String? checkError;
  int pings = 0;

  Future<String> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      uris.add(req.uri);
      headers.add(req.headers);
      if (checkError != null) {
        req.response.statusCode = 403;
        if (req.uri.path.endsWith('/check')) req.response.write(jsonEncode({'error': checkError}));
        await req.response.close();
        return;
      }
      if (refuse) {
        req.response.statusCode = 403;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      hosts.add(ws);
      ws.listen((m) {
        if (m == 'ping') {
          pings++;
          ws.add('pong');
          return;
        }
        received.add(m as Object);
      });
    });
    return 'http://127.0.0.1:${http.port}';
  }

  WebSocket get host => hosts.last;

  void open(String device) => host.add(jsonEncode({'t': 'open', 'd': device}));
  void close(String device) => host.add(jsonEncode({'t': 'close', 'd': device}));
  void frame(String device, List<int> f) => host.add(relayEnvelope(device, f));

  /// Frames the host sent to [device].
  List<Uint8List> framesFor(String device) => [
        for (final m in received)
          if (m is List<int>)
            if (openRelayEnvelope(m) case final e? when e.deviceId == device) e.frame
      ];

  List<Map<String, dynamic>> get controls => [
        for (final m in received)
          if (m is String) (jsonDecode(m) as Map).cast<String, dynamic>()
      ];

  Future<void> stop() async {
    for (final h in hosts) {
      await h.close();
    }
    await http.close(force: true);
  }
}

/// One device talking to the host through [relay], with the encrypted channel.
class RelayDevice {
  final FakeRelay relay;
  final String id;
  final ClientHandshake hs;
  SecureSession? session;
  int _seen = 0;
  final List<HostMessage> messages = [];
  RelayDevice(this.relay, this.id, HostState state, {List<int>? secret, bool approved = true})
      : hs = ClientHandshake(secret: secret ?? _secretFor(state, id, approved), machineId: state.machineId, deviceId: id);

  /// An allowed device connects with its own key; one that is not allowed only has the
  /// pairing secret.
  static List<int> _secretFor(HostState state, String id, bool approved) {
    if (!approved) return state.secret;
    final d = state.device(id) ?? state.approveDevice(id, name: id, permission: DevicePermissions.full);
    return d.keyBytes!;
  }

  Future<void> handshake() async {
    relay.open(id);
    relay.frame(id, hs.hello);
    await waitUntil(() => relay.framesFor(id).isNotEmpty);
    _seen = 1;
    session = hs.finish(relay.framesFor(id).first);
  }

  void send(ClientMessage m) {
    for (final f in session!.seal(encodeClient(m))) {
      relay.frame(id, f);
    }
  }

  /// Decrypts what has arrived since last time.
  void pump() {
    final frames = relay.framesFor(id);
    for (; _seen < frames.length; _seen++) {
      final t = session!.open(frames[_seen]);
      if (t != null) messages.add(decodeHost(t)!);
    }
  }

  Future<T> next<T extends HostMessage>() async {
    await waitUntil(() {
      pump();
      return messages.whereType<T>().isNotEmpty;
    });
    return messages.whereType<T>().first;
  }
}

void main() {
  late Directory tmp;
  late HostState state;
  late SessionManager manager;
  late PerchServer server;
  late RelayClient client;
  late FakeRelay relay;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_relay_');
    relay = FakeRelay();
    final url = await relay.start();
    state = HostState.load('${tmp.path}${Platform.pathSeparator}state')..setRelay(url);
    manager = SessionManager(launcher: fakeLauncher(), external: FakeExternalSessions());
    server = PerchServer(manager: manager, state: state, machineName: 'relay-box', bindAddress: '127.0.0.1', port: 0);
    client = RelayClient(state: state, onDevice: server.attach, pingInterval: const Duration(milliseconds: 200));
    server.relay = client;
  });

  tearDown(() async {
    await server.close();
    await client.dispose();
    await manager.dispose();
    await relay.stop();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('relay_socket_uri', () {
    expect(relaySocketUri('https://r.example.workers.dev', 'MID', 'host').toString(),
        'wss://r.example.workers.dev/m/MID/host');
    expect(relaySocketUri('http://127.0.0.1:8789/', 'MID', 'device', {'d': 'p', 't': 'x'}).toString(),
        'ws://127.0.0.1:8789/m/MID/device?d=p&t=x');
  });

  test('connects_with_host_token_and_device_token_hash', () async {
    await server.start();
    await waitUntil(() => client.connected);
    expect(client.status, 'connected');
    expect(relay.uris.single.path, '/m/${state.machineId}/host');
    expect(relay.headers.single.value('authorization'), 'Bearer ${state.hostToken}');
    expect(relay.headers.single.value('x-perch-device-token-hash'), tokenHash(state.deviceToken));
    // The secret itself never goes to the relay.
    expect(relay.headers.single.toString(), isNot(contains(base64UrlNoPad(state.secret))));
  });

  test('a_device_behind_the_relay_pairs_lists_sessions_and_gets_events', () async {
    await server.start();
    await waitUntil(() => client.connected);
    final phone = RelayDevice(relay, 'phone', state);
    await phone.handshake();
    phone.send(const Hello(deviceName: 'Phone via relay'));
    final w = await phone.next<Welcome>();
    expect(w.machineName, 'relay-box');
    expect(w.relayUrl, state.relayUrl);
    await phone.next<Sessions>();
    phone.send(StartSession(cwd: tmp.path, prompt: 'echo through the relay'));
    await waitUntil(() {
      phone.pump();
      return phone.messages.whereType<EventMessage>().any((m) => m.event is TurnEnded);
    });
    // Everything the relay carried after the handshake was ciphertext.
    for (final f in relay.framesFor('phone').skip(1)) {
      expect(f[0], FrameType.data);
      expect(latin1.decode(f, allowInvalid: true), isNot(contains('relay-box')));
    }
    expect(server.connectedDevices, 1);
    relay.close('phone');
    await waitUntil(() => server.connectedDevices == 0);
  });

  test('two_devices_are_kept_apart', () async {
    await server.start();
    await waitUntil(() => client.connected);
    final a = RelayDevice(relay, 'a', state);
    final b = RelayDevice(relay, 'b', state);
    await a.handshake();
    await b.handshake();
    a.send(const Hello(deviceName: 'A'));
    b.send(const Hello(deviceName: 'B'));
    await a.next<Welcome>();
    await b.next<Welcome>();
    expect(server.connectedDevices, 2);
  });

  test('a_new_device_behind_the_relay_waits_for_approval_then_gets_its_key', () async {
    await server.start();
    await waitUntil(() => client.connected);
    final phone = RelayDevice(relay, 'new-phone', state, approved: false);
    await phone.handshake();
    phone.send(const Hello(deviceName: 'Pixel', pairing: 2));
    await phone.next<PairingPending>();
    expect(server.pendingDevices.single.route, 'relay');
    await server.decideDevice('new-phone', DeviceDecisions.full);
    final k = await phone.next<DeviceKey>();
    await phone.next<Welcome>();
    expect(state.device('new-phone')!.key, k.key);
  });

  test('a_device_with_the_wrong_secret_is_closed_through_the_relay', () async {
    await server.start();
    await waitUntil(() => client.connected);
    final bad = RelayDevice(relay, 'bad', state, secret: List.filled(32, 1));
    await bad.handshake();
    bad.send(const Hello(deviceName: 'Bad'));
    await waitUntil(() => relay.controls.any((c) => c['t'] == 'close' && c['d'] == 'bad'));
    final err = relay.framesFor('bad').last;
    expect(err[0], FrameType.error);
    expect(server.connectedDevices, 0);
  });

  test('pings_and_reconnects_after_the_relay_drops', () async {
    await server.start();
    await waitUntil(() => client.connected);
    final phone = RelayDevice(relay, 'phone', state);
    await phone.handshake();
    phone.send(const Hello(deviceName: 'P'));
    await phone.next<Welcome>();
    await waitUntil(() => relay.pings >= 2);
    await relay.host.close();
    await waitUntil(() => server.connectedDevices == 0);
    await waitUntil(() => client.connections == 2, timeout: const Duration(seconds: 10));
    expect(relay.hosts.length, 2);
  });

  test('stop_remote_access_disconnects_from_the_relay_and_resume_reconnects', () async {
    await server.start();
    await waitUntil(() => client.connected);
    await server.stopRemoteAccess();
    expect(client.connected, isFalse);
    expect(client.status, 'stopped');
    await waitUntil(() => relay.host.closeCode != null);
    server.resumeRemoteAccess();
    await waitUntil(() => client.connected);
    expect(relay.hosts.length, 2);
  });

  test('without_a_relay_url_nothing_connects', () async {
    state.setRelay(null);
    await server.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(relay.uris, isEmpty);
    expect(client.status, 'not set');
  });

  test('a_daily_limit_close_waits_until_the_next_utc_day', () async {
    await server.start();
    await waitUntil(() => client.connected);
    await relay.host.close(4029, 'daily limit');
    await waitUntil(() => client.status.startsWith('daily limit'));
    expect(client.status, contains('05:30 IST'));
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(relay.hosts.length, 1, reason: 'no reconnect before the next UTC day');
    expect(client.limitedUntil, isNotNull);
    expect(client.limitedUntil!.isUtc, isTrue);
    expect(client.limitedUntil!.hour, 0);
  });

  test('a_refused_connection_is_retried_with_backoff', () async {
    relay.refuse = true;
    await server.start();
    await waitUntil(() => relay.uris.length >= 2, timeout: const Duration(seconds: 10));
    expect(client.status, startsWith('retrying'));
    expect(client.connected, isFalse);
  });

  test('the invite code goes with every connection; without a valid one the host says so and waits', () async {
    relay.checkError = 'inviteRequired';
    client = RelayClient(state: state, onDevice: server.attach, inviteRetry: const Duration(milliseconds: 300));
    server.relay = client;
    await server.start();
    await waitUntil(() => client.refusal != null, timeout: const Duration(seconds: 10));
    expect(client.refusal, 'inviteRequired');
    expect(client.status, contains('needs an invite code'));
    expect((await server.menuStatus())['relayRefusal'], 'inviteRequired');
    expect(relay.uris.map((u) => u.path.split('/').last), containsAll(['host', 'check']));
    // A restart forgets the old answer at once (/perch reads it right after saving a code).
    await client.stop();
    client.start();
    expect(client.refusal, isNull);
    await waitUntil(() => client.refusal != null, timeout: const Duration(seconds: 10));
    // A code: the next connection carries it, and an accepted one clears the refusal.
    state.setRelayInvite(' perch-abcd-efgh-jkmn ');
    relay.checkError = null;
    await waitUntil(() => client.connected, timeout: const Duration(seconds: 10));
    expect(client.refusal, isNull);
    expect(relay.headers.last.value('x-perch-invite'), 'perch-abcd-efgh-jkmn');
    expect(HostState.load(state.directory).relayInvite, 'perch-abcd-efgh-jkmn', reason: 'kept in host.json');
  });

  test('the shared pool used up: the host waits for the next UTC day', () async {
    relay.checkError = 'poolUsedUp';
    await server.start();
    await waitUntil(() => client.refusal != null, timeout: const Duration(seconds: 10));
    expect(client.refusal, 'poolUsedUp');
    expect(client.status, contains('00:00 UTC'));
    expect(client.limitedUntil, isNotNull);
  });
}
