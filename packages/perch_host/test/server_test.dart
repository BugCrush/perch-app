import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'helpers.dart';

/// A WebSocket client that runs the encrypted channel and records decoded host messages.
class TestClient {
  final WebSocketChannel channel;
  final List<HostMessage> received = [];

  /// Raw frames that arrived before the handshake finished (or instead of it).
  final List<Object> rawFrames = [];
  final ClientHandshake? _hs;
  SecureSession? session;
  String? channelError;
  bool closed = false;
  final _ready = Completer<void>();

  TestClient(this.channel, {ClientHandshake? handshake}) : _hs = handshake {
    channel.stream.listen((f) {
      final s = session;
      if (s == null) {
        rawFrames.add(f as Object);
        final hs = _hs;
        if (hs != null && f is List<int>) {
          try {
            session = hs.finish(Uint8List.fromList(f));
            if (!_ready.isCompleted) _ready.complete();
          } on ChannelError catch (e) {
            channelError = e.reason;
          }
        }
        return;
      }
      try {
        final text = s.open(Uint8List.fromList(f as List<int>));
        if (text == null) return;
        final m = decodeHost(text);
        if (m != null) received.add(m);
      } on ChannelError catch (e) {
        channelError = e.reason;
      }
    }, onDone: () {
      closed = true;
      if (!_ready.isCompleted) _ready.complete();
    }, onError: (_) => closed = true);
  }

  static Future<WebSocketChannel> _open(int port) async {
    final ch = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
    await ch.ready;
    return ch;
  }

  /// Connects and completes the handshake with [state]'s identity (or [secret]/[machineId]).
  static Future<TestClient> connect(int port, HostState state,
      {List<int>? secret, String? machineId, String deviceId = 'dev-test'}) async {
    // An allowed device connects with its own key (the pairing secret only asks to pair).
    final hs = ClientHandshake(
        secret: secret ?? state.device(deviceId)?.keyBytes ?? state.secret,
        machineId: machineId ?? state.machineId,
        deviceId: deviceId);
    final c = TestClient(await _open(port), handshake: hs);
    c.channel.sink.add(hs.hello);
    await c._ready.future.timeout(const Duration(seconds: 10));
    return c;
  }

  /// Connects without a handshake.
  static Future<TestClient> connectRaw(int port) async => TestClient(await _open(port));

  void send(ClientMessage m) => raw(encodeClient(m));
  void raw(String s) {
    for (final f in session!.seal(s)) {
      channel.sink.add(f);
    }
  }

  /// Waits for a message of type [T] (matching [where]) after index [from].
  Future<T> next<T extends HostMessage>({bool Function(T)? where, int from = 0}) async {
    await waitUntil(() => received.skip(from).whereType<T>().any((m) => where == null || where(m)));
    return received.skip(from).whereType<T>().firstWhere((m) => where == null || where(m));
  }

  Future<void> close() => channel.sink.close();
}

void main() {
  late Directory tmp;
  late SessionManager manager;
  late HostState state;
  late PerchServer server;
  late int port;
  final clients = <TestClient>[];

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_srv_');
    manager = SessionManager(launcher: fakeLauncher(), external: FakeExternalSessions());
    state = HostState.load('${tmp.path}${Platform.pathSeparator}state')
      ..approveDevice('dev-test', name: 'Phone', permission: DevicePermissions.full);
    server = PerchServer(
        manager: manager,
        state: state,
        machineName: 'test-machine',
        bindAddress: '127.0.0.1',
        port: 0,
        lanAddresses: const ['192.168.1.20:8787']);
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

  Future<TestClient> paired() async {
    final c = await TestClient.connect(port, state);
    clients.add(c);
    c.send(const Hello(deviceName: 'Phone'));
    await c.next<Sessions>();
    return c;
  }

  test('wrong_secret_fails_the_handshake', () async {
    final c = await TestClient.connect(port, state, secret: List.filled(32, 9));
    clients.add(c);
    c.send(const Hello(deviceName: 'Phone'));
    await waitUntil(() => c.closed);
    expect(c.channelError, ChannelErrors.badKey);
    expect(c.received, isEmpty);
    expect(server.connectedDevices, 0);
    expect(HostState.load(state.directory).everPaired, isFalse);
  });

  test('wrong_machine_id_is_refused_before_keys', () async {
    final c = await TestClient.connect(port, state, machineId: 'someone-else');
    clients.add(c);
    await waitUntil(() => c.closed);
    expect(c.session, isNull);
    expect(c.channelError, ChannelErrors.badKey);
  });

  test('a_tampered_frame_closes_the_connection', () async {
    final c = await paired();
    final f = c.session!.seal(encodeClient(const ListSessions())).single;
    f[f.length - 1] ^= 0x40;
    c.channel.sink.add(f);
    await waitUntil(() => c.closed);
    expect(server.connectedDevices, 0);
  });

  test('a_replayed_frame_closes_the_connection', () async {
    final c = await paired();
    final f = c.session!.seal(encodeClient(const ListSessions())).single;
    c.channel.sink.add(f);
    await c.next<Sessions>(from: c.received.length);
    c.channel.sink.add(Uint8List.fromList(f));
    await waitUntil(() => c.closed);
  });

  test('a_phase_1_plaintext_hello_is_told_to_pair_again', () async {
    final c = await TestClient.connectRaw(port);
    clients.add(c);
    c.channel.sink.add('{"type":"hello","code":"ABCD2345","deviceName":"Old"}');
    await waitUntil(() => c.closed);
    final m = decodeHost(c.rawFrames.single as String) as ErrorMessage;
    expect(m.code, ErrorCodes.badCode);
    expect(m.message, contains('pair again'));
  });

  test('garbage_instead_of_a_client_hello_closes', () async {
    final c = await TestClient.connectRaw(port);
    clients.add(c);
    c.channel.sink.add(Uint8List.fromList([9, 9, 9]));
    await waitUntil(() => c.closed);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('first_frame_must_be_hello', () async {
    final c = await TestClient.connect(port, state);
    clients.add(c);
    c.send(const ListSessions());
    expect((await c.next<ErrorMessage>()).code, ErrorCodes.badCode);
    await waitUntil(() => c.closed);
  });

  test('hello_then_welcome_and_sessions', () async {
    final connected = <String>[];
    server.deviceConnected.listen(connected.add);
    expect(state.everPaired, isFalse);
    final c = await TestClient.connect(port, state);
    clients.add(c);
    c.send(const Hello(deviceName: 'Pixel'));
    final w = await c.next<Welcome>();
    expect(w.machineName, 'test-machine');
    expect(w.os, Platform.operatingSystem);
    expect(w.lanAddresses, ['192.168.1.20:8787']);
    expect(w.relayUrl, isNull);
    await c.next<Sessions>();
    expect(c.received.indexWhere((m) => m is Welcome), lessThan(c.received.indexWhere((m) => m is Sessions)));
    await waitUntil(() => connected.isNotEmpty);
    expect(connected.single, 'Pixel');
    expect(server.connectedDevices, 1);
    expect(w.permission, DevicePermissions.full);
  });

  test('forget_devices_then_reload_drops_connections_and_old_secret', () async {
    final c = await paired();
    final old = List<int>.from(state.secret);
    final oldId = state.machineId;
    HostState.load(state.directory).forgetDevices(); // as `perch_host forget-devices` would
    final client = HttpClient();
    final res = await ((await client.postUrl(Uri.parse('http://127.0.0.1:$port/control?action=reload')))..headers.set('x-perch-control', '1')).close();
    expect(res.statusCode, 200);
    client.close();
    await waitUntil(() => c.closed);
    final stale = await TestClient.connect(port, state, secret: old, machineId: oldId);
    clients.add(stale);
    await waitUntil(() => stale.closed);
    expect(stale.channelError, ChannelErrors.badKey);
    expect(state.devices, isEmpty, reason: 'forget-devices forgets the devices too');
    state.approveDevice('dev-test', name: 'Phone', permission: DevicePermissions.full);
    final fresh = await paired();
    expect(fresh.received.whereType<Welcome>(), isNotEmpty);
  });

  Future<String> reload() async {
    final client = HttpClient();
    try {
      final res = await ((await client.postUrl(Uri.parse('http://127.0.0.1:$port/control?action=reload')))..headers.set('x-perch-control', '1')).close();
      expect(res.statusCode, 200);
      return await res.transform(const SystemEncoding().decoder).join();
    } finally {
      client.close();
    }
  }

  test('name_set_then_reload_renames_and_tells_connected_devices', () async {
    final c = await paired();
    HostState.load(state.directory).setMachineName('Studio desk'); // as `perch_host name set` would
    final body = await reload();
    expect(body, contains('Machine name: Studio desk'));
    final renamed = await c.next<MachineRenamed>();
    expect(renamed.machineName, 'Studio desk');
    expect(server.machineName, 'Studio desk');
    expect(state.machineName, 'Studio desk');
    expect(HostState.load(state.directory).lastName, 'Studio desk');
    expect(c.closed, isFalse);
    // A device connecting later hears it in welcome.
    final later = await TestClient.connect(port, state);
    clients.add(later);
    later.send(const Hello(deviceName: 'Tablet'));
    expect((await later.next<Welcome>()).machineName, 'Studio desk');
  });

  test('a_name_from_the_command_line_wins_over_name_set_until_restart', () async {
    final fixed = PerchServer(
        manager: manager, state: state, machineName: 'From flag', nameFixed: true, bindAddress: '127.0.0.1', port: 0);
    final fixedPort = await fixed.start();
    try {
      HostState.load(state.directory).setMachineName('Studio desk');
      final client = HttpClient();
      final res = await ((await client.postUrl(Uri.parse('http://127.0.0.1:$fixedPort/control?action=reload')))..headers.set('x-perch-control', '1')).close();
      final body = await res.transform(const SystemEncoding().decoder).join();
      client.close();
      expect(body, contains('Machine name: From flag'));
      expect(fixed.machineName, 'From flag');
      expect(state.machineName, 'Studio desk');
    } finally {
      await fixed.close();
    }
  });

  test('reload_without_a_name_change_keeps_the_name', () async {
    final c = await paired();
    HostState.load(state.directory).setRelay('https://relay.example');
    await reload();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(c.received.whereType<MachineRenamed>(), isEmpty);
    expect(server.machineName, 'test-machine');
  });

  test('start_send_and_receive_events', () async {
    final c = await paired();
    c.send(StartSession(cwd: tmp.path, prompt: 'echo first'));
    final up = await c.next<SessionUpdated>();
    final id = up.session.id;
    await c.next<EventMessage>(where: (m) => m.sessionId == id && m.event is TurnEnded);
    c.send(SendMessage(sessionId: id, text: 'second'));
    final ev = await c.next<EventMessage>(where: (m) => m.event is AssistantText && (m.event as AssistantText).text == 'echo: second');
    expect(ev.sessionId, id);
  });

  test('start_in_missing_folder_reports_error', () async {
    final c = await paired();
    c.send(const StartSession(cwd: 'Z:/definitely/not/here', prompt: 'echo'));
    final e = await c.next<ErrorMessage>();
    expect(e.code, ErrorCodes.badRequest);
    expect(e.message, contains('Folder'));
  });

  test('prompt_round_trip_over_the_wire', () async {
    final c = await paired();
    c.send(StartSession(cwd: tmp.path, prompt: 'question'));
    final opened = await c.next<PromptOpened>();
    expect(opened.prompt.kind, PromptKind.question);
    c.send(AnswerPrompt(
        sessionId: opened.sessionId,
        promptId: opened.prompt.promptId,
        answer: const QuestionAnswer({'Which color?': 'Blue'})));
    final closed = await c.next<PromptClosed>();
    expect(closed.promptId, opened.prompt.promptId);
    await c.next<EventMessage>(where: (m) => m.event is AssistantText && (m.event as AssistantText).text.contains('Blue'));
  });

  test('prompt_closed_is_broadcast_to_all_clients', () async {
    final a = await paired();
    final b = await paired();
    a.send(StartSession(cwd: tmp.path, prompt: 'permission'));
    final opened = await b.next<PromptOpened>();
    a.send(AnswerPrompt(sessionId: opened.sessionId, promptId: opened.prompt.promptId, answer: const PermissionAnswer(allow: true)));
    await a.next<PromptClosed>();
    await b.next<PromptClosed>();
    final mark = b.received.length;
    b.send(AnswerPrompt(sessionId: opened.sessionId, promptId: opened.prompt.promptId, answer: const PermissionAnswer(allow: false)));
    final e = await b.next<ErrorMessage>(from: mark);
    expect(e.code, ErrorCodes.promptAlreadyAnswered);
    await a.next<EventMessage>(where: (m) => m.event is TurnEnded && (m.event as TurnEnded).text == 'allowed');
  });

  test('resubscribe_after_seq_returns_only_missed_events', () async {
    final a = await paired();
    a.send(StartSession(cwd: tmp.path, prompt: 'echo one'));
    final id = (await a.next<SessionUpdated>()).session.id;
    await a.next<EventMessage>(where: (m) => m.event is TurnEnded);
    final n = manager.history(id).events.last.seq;
    expect(n, 3);
    final b = await paired();
    b.send(Subscribe(sessionId: id, afterSeq: n - 2));
    final ev = await b.next<Events>();
    expect(ev.sessionId, id);
    expect(ev.events.map((e) => e.seq).toList(), [n - 1, n]);
    expect(ev.openPrompts, isEmpty);

    // With an open prompt, the reply carries it.
    a.send(StartSession(cwd: tmp.path, prompt: 'question'));
    final opened = await a.next<PromptOpened>();
    b.send(Subscribe(sessionId: opened.sessionId, afterSeq: 0));
    final ev2 = await b.next<Events>(where: (e) => e.sessionId == opened.sessionId);
    expect(ev2.openPrompts.single.promptId, opened.prompt.promptId);
  });

  test('stop_remote_access_disconnects_and_refuses', () async {
    final c = await paired();
    await server.stopRemoteAccess();
    expect(server.remoteAccessLive, isFalse);
    await c.next<RemoteAccessStopped>();
    await waitUntil(() => c.closed);
    await expectLater(TestClient.connect(port, state), throwsA(anything));
    server.resumeRemoteAccess();
    expect(server.remoteAccessLive, isTrue);
    final again = await paired();
    expect(again.received.whereType<Welcome>(), isNotEmpty);
  });

  test('control_path_stops_remote_access_from_loopback', () async {
    final c = await paired();
    final client = HttpClient();
    final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/control?action=stop-remote'))
      ..headers.set('x-perch-control', '1');
    final res = await req.close();
    expect(res.statusCode, 200);
    client.close();
    await c.next<RemoteAccessStopped>();
    expect(server.remoteAccessLive, isFalse);
  });

  test('bad_frames_do_not_kill_the_connection', () async {
    final c = await paired();
    final mark = c.received.length;
    c.raw('not json');
    c.raw('{"type":"zzz"}');
    await waitUntil(() => c.received.skip(mark).whereType<ErrorMessage>().length == 2);
    expect(c.received.skip(mark).whereType<ErrorMessage>().every((e) => e.code == ErrorCodes.badRequest), isTrue);
    final mark2 = c.received.length;
    c.send(const ListSessions());
    await c.next<Sessions>(from: mark2);
    expect(c.closed, isFalse);
  });

  test('unknown_session_errors', () async {
    final c = await paired();
    c.send(const SendMessage(sessionId: 'nope', text: 'x'));
    expect((await c.next<ErrorMessage>()).code, ErrorCodes.noSuchSession);
  });

  test('send_that_cannot_be_typed_reports_cannot_type', () async {
    final ext = manager.external as FakeExternalSessions;
    ext.entries = [ext.entry(sessionId: 'bg-1', cwd: tmp.path, kind: 'background', state: 'done')];
    final c = await paired();
    final mark = c.received.length;
    c.send(const SendMessage(sessionId: 'bg-1', text: 'hello'));
    final e = await c.next<ErrorMessage>(from: mark);
    expect(e.code, ErrorCodes.cannotType);
    expect(ext.kills, isEmpty);
  });

  test('list_dir_round_trip', () async {
    final sep = Platform.pathSeparator;
    final base = Directory('${tmp.path}${sep}tree')..createSync();
    Directory('${base.path}${sep}one').createSync();
    Directory('${base.path}${sep}Two').createSync();
    File('${base.path}${sep}file.txt').writeAsStringSync('x');
    final ext = manager.external as FakeExternalSessions;
    ext.entries = [ext.entry(pid: 31, sessionId: 'ext-1', cwd: '${base.path}${sep}one')];
    final c = await paired();
    final mark = c.received.length;
    c.send(ListDir(path: base.path));
    final l = await c.next<DirListing>(from: mark);
    final resolved = base.resolveSymbolicLinksSync();
    expect(l.path, resolved);
    expect(l.parent, isNotNull);
    expect(l.entries.map((e) => e.name).toList(), ['one', 'Two']);
    expect(l.suggested.first.path, '${base.path}${sep}one');
    expect(l.suggested.last.name, 'Home');

    final mark2 = c.received.length;
    c.send(ListDir(path: '${base.path}${sep}missing'));
    final e = await c.next<ErrorMessage>(from: mark2);
    expect(e.code, ErrorCodes.badRequest);
    expect(e.message, contains('does not exist'));
  });

  test('kill_all_over_the_wire', () async {
    final c = await paired();
    c.send(StartSession(cwd: tmp.path, prompt: 'slow'));
    final id = (await c.next<SessionUpdated>()).session.id;
    c.send(const KillAll());
    await c.next<SessionUpdated>(where: (m) => m.session.id == id && m.session.state == SessionState.stopped);
  });

  test('session menu actions over the wire: an error for an unknown session, done for a rename', () async {
    final c = await paired();
    c.send(const RenameSession(sessionId: 'nope', name: 'X'));
    final e = await c.next<ErrorMessage>();
    expect(e.code, ErrorCodes.noSuchSession);
    c.send(const DeleteSession(sessionId: 'nope'));
    expect((await c.next<ErrorMessage>(where: (m) => !identical(m, e))).code, ErrorCodes.noSuchSession);

    // A Perch-run session that ended: renamed through its transcript is not possible
    // without one, so the host says so.
    c.send(StartSession(cwd: tmp.path, prompt: 'quick'));
    final id = (await c.next<SessionUpdated>()).session.id;
    c.send(RenameSession(sessionId: id, name: 'Y'));
    final r = await c.next<HostMessage>(where: (m) => m is SessionActionDone || (m is ErrorMessage && m.code != ErrorCodes.noSuchSession));
    expect(r, isA<ErrorMessage>());
  });

  test('an unknown message type is answered with the unknown-message error (what older hosts say)', () async {
    final c = await paired();
    c.raw('{"type":"somethingNew","sessionId":"s1"}');
    final e = await c.next<ErrorMessage>();
    expect(isUnknownMessageError(e), isTrue);
  });
}
