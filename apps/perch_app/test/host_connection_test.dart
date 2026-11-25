import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/connection/machine_store.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'fakes.dart';

void main() {
  final machine = testMachine(id: 'm1', label: 'Desk');
  late FakeChannels channels;
  late HostConnection conn;

  setUp(() {
    channels = FakeChannels();
    conn = HostConnection(machine, channelFactory: channels.factory, deviceName: 'Pixel', deviceId: 'dev-7');
  });
  tearDown(() => conn.dispose());

  test('handshake_then_encrypted_hello', () async {
    conn.connect();
    await eventually(() => channels.last.frames.isNotEmpty);
    expect(channels.last.uri.toString(), 'ws://192.168.1.20:8787/ws');
    final first = channels.last.raw.first as List<int>;
    expect(first[0], FrameType.clientHello);
    expect(channels.last.deviceId, 'dev-7');
    // Everything after the client hello is ciphertext.
    for (final f in channels.last.raw.skip(1)) {
      expect(f, isA<List<int>>());
      expect((f as List<int>)[0], FrameType.data);
    }
    final hello = channels.last.messages.first as Hello;
    expect(hello.deviceName, 'Pixel');
    expect(hello.code, '');
    expect(conn.link.value, LinkState.connecting);
  });

  test('welcome_sets_online_route_and_machine_name', () async {
    conn.connect();
    channels.last.send(welcome);
    channels.last.send(Sessions(sessions: [summary('s1')], usage: const UsageSnapshot()));
    await eventually(() => conn.sessions.value.isNotEmpty);
    expect(conn.link.value, LinkState.online);
    expect(conn.route.value, LinkRoute.lan);
    expect(conn.machineName.value, 'devbox');
    expect(conn.usage.value, isNotNull);
    channels.last.send(SessionUpdated(session: summary('s1', state: SessionState.working)));
    channels.last.send(SessionUpdated(session: summary('s2')));
    await eventually(() => conn.sessions.value.length == 2);
    expect(conn.sessions.value.first.state, SessionState.working);
  });

  test('a_phase_1_machine_needs_pairing_and_does_not_connect', () async {
    final legacy = Machine.fromJson({'id': 'old', 'label': 'Desk', 'host': '10.0.0.1', 'port': 8787, 'code': 'ABCD2345'})!;
    final c = HostConnection(legacy, channelFactory: channels.factory);
    c.connect();
    expect(c.link.value, LinkState.needsPairing);
    await pump(50);
    expect(channels.hosts, isEmpty);
    c.dispose();
  });

  test('wrong_secret_asks_to_pair_again_and_does_not_retry', () async {
    channels.modeFor = (_) => FakeMode.wrongSecret;
    conn.connect();
    await eventually(() => conn.link.value == LinkState.needsPairing);
    await pump(1500);
    expect(channels.hosts.length, 1);
    expect(conn.link.value, LinkState.needsPairing);
    expect(conn.lastError.value, contains('Pair again'));
  });

  test('a_phase_1_host_answering_in_the_clear_is_refused', () async {
    channels.modeFor = (_) => FakeMode.silent;
    conn.connect();
    await eventually(() => channels.hosts.isNotEmpty);
    channels.last.sendRaw('{"type":"error","code":"badCode","message":"Send the pairing code first."}');
    await channels.last.close();
    await eventually(() => conn.link.value == LinkState.refused);
    expect(conn.lastError.value, olderHostMessage);
    await pump(1500);
    expect(channels.hosts.length, 1);
  });

  test('every_lan_address_is_tried_and_the_one_that_answers_wins', () async {
    channels.modeFor = (uri) => uri.host == '10.0.0.9' ? FakeMode.host : FakeMode.silent;
    final c = HostConnection(testMachine(lan: ['192.168.1.20:8787', '10.0.0.9:8790']), channelFactory: channels.factory);
    c.connect();
    expect(channels.hosts.map((h) => h.uri.toString()), ['ws://192.168.1.20:8787/ws', 'ws://10.0.0.9:8790/ws']);
    channels.lastTo('ws://10.0.0.9').send(welcome);
    await eventually(() => c.link.value == LinkState.online);
    await eventually(() => channels.hosts.first.closedByClient);
    expect(c.route.value, LinkRoute.lan);
    c.dispose();
  });

  test('no_answer_within_the_lan_timeout_goes_offline_and_retries', () async {
    channels.modeFor = (_) => FakeMode.silent;
    final c = HostConnection(testMachine(), channelFactory: channels.factory, lanTimeout: const Duration(milliseconds: 100));
    c.connect();
    await eventually(() => c.link.value == LinkState.offline);
    await eventually(() => channels.hosts.first.closedByClient);
    await eventually(() => channels.hosts.length == 2, timeout: const Duration(seconds: 3));
    c.dispose();
  });

  test('the board page keeps its localhost route when the host tells its addresses', () async {
    // The host lets the board page in without approval only over loopback: taking the
    // machine's Wi-Fi address from the welcome made it ask to pair (found 2026-11-19).
    final local = testMachine(lan: ['localhost:8787']);
    final c = HostConnection(local, channelFactory: channels.factory, deviceId: boardPageDeviceId);
    c.connect();
    channels.last.send(const Welcome(
        machineName: 'devbox',
        os: 'macos',
        hostVersion: '0.2.0',
        relayUrl: 'https://relay.example',
        lanAddresses: ['192.168.1.30:8787']));
    await eventually(() => c.link.value == LinkState.online);
    expect(c.machine.lan, ['localhost:8787']);
    expect(c.machine.relayUrl, local.relayUrl);
    c.dispose();
  });

  test('welcome_reports_new_relay_and_lan_addresses', () async {
    Machine? updated;
    final c = HostConnection(testMachine(), channelFactory: channels.factory, onMachineUpdated: (m) => updated = m);
    c.connect();
    channels.last.send(const Welcome(
        machineName: 'devbox',
        os: 'windows',
        hostVersion: '0.2.0',
        relayUrl: 'https://relay.example',
        lanAddresses: ['192.168.1.30:8787']));
    await eventually(() => updated != null);
    expect(updated!.relayUrl, 'https://relay.example');
    expect(updated!.lan, ['192.168.1.30:8787']);
    expect(updated!.secret, testMachine().secret);
    expect(c.machine.relayUrl, 'https://relay.example');
    c.dispose();
  });

  test('the_hosts_own_name_from_welcome_and_machine_renamed_is_saved_and_the_alias_kept', () async {
    final updates = <Machine>[];
    final c = HostConnection(testMachine(label: 'Desk', alias: 'Big rig'),
        channelFactory: channels.factory, onMachineUpdated: updates.add);
    expect(c.displayName.value, 'Big rig');
    expect(c.ownName, 'Desk');
    c.connect();
    channels.last.send(welcome);
    await eventually(() => updates.isNotEmpty);
    expect(updates.last.label, 'devbox');
    expect(updates.last.alias, 'Big rig');
    expect(c.ownName, 'devbox');
    expect(c.displayName.value, 'Big rig');
    channels.last.send(const MachineRenamed(machineName: 'Studio'));
    await eventually(() => updates.length == 2);
    expect(updates.last.label, 'Studio');
    expect(c.machineName.value, 'Studio');
    expect(c.displayName.value, 'Big rig');
    // Clearing the alias: the host's name shows.
    c.machine = c.machine.copyWith(clearAlias: true);
    expect(c.displayName.value, 'Studio');
    c.dispose();
  });

  group('relay', () {
    const relay = 'https://relay.example';
    const relayWelcome = Welcome(machineName: 'devbox', os: 'windows', hostVersion: '0.2.0', relayUrl: relay);
    bool isRelay(Uri u) => u.scheme == 'wss';
    late HostConnection c;
    tearDown(() => c.dispose());

    HostConnection make({List<String> lan = const ['192.168.1.20:8787'], Duration retry = const Duration(seconds: 60)}) =>
        c = HostConnection(testMachine(lan: lan, relayUrl: relay),
            channelFactory: channels.factory,
            deviceId: 'dev-7',
            lanTimeout: const Duration(milliseconds: 100),
            lanRetryInterval: retry);

    test('lan_first_then_the_relay_with_the_device_token', () async {
      channels.modeFor = (u) => isRelay(u) ? FakeMode.host : FakeMode.silent;
      make().connect();
      expect(channels.hosts.single.uri.scheme, 'ws');
      await eventually(() => channels.hosts.length == 2);
      final r = channels.last.uri;
      expect(r.toString(), startsWith('wss://relay.example/m/m1/device?'));
      expect(r.queryParameters['d'], 'dev-7');
      expect(r.queryParameters['t'], relayDeviceToken(testSecret));
      channels.last.send(relayWelcome);
      await eventually(() => c.link.value == LinkState.online);
      expect(c.route.value, LinkRoute.relay);
      expect(channels.last.messages.first, isA<Hello>());
    });

    test('without_lan_addresses_it_goes_straight_to_the_relay', () async {
      make(lan: const []).connect();
      expect(channels.hosts.single.uri.scheme, 'wss');
      channels.last.send(relayWelcome);
      await eventually(() => c.route.value == LinkRoute.relay);
    });

    test('host_offline_waits_for_host_online_without_retrying', () async {
      channels.modeFor = (u) => isRelay(u) ? FakeMode.silent : FakeMode.refuse;
      make().connect();
      await eventually(() => channels.hosts.any((h) => isRelay(h.uri)));
      channels.lastTo('wss://').sendRaw('{"t":"hostOffline"}');
      await eventually(() => c.link.value == LinkState.offline);
      final n = channels.hosts.length;
      await pump(1500);
      expect(channels.hosts.length, n); // waits, no reconnect loop
      channels.modeFor = (u) => isRelay(u) ? FakeMode.host : FakeMode.refuse;
      channels.lastTo('wss://').sendRaw('{"t":"hostOnline"}');
      await eventually(() => channels.hosts.where((h) => isRelay(h.uri)).length == 2);
      channels.lastTo('wss://').send(relayWelcome);
      await eventually(() => c.link.value == LinkState.online);
      expect(c.route.value, LinkRoute.relay);
    });

    test('host_going_offline_while_connected_sets_offline', () async {
      channels.modeFor = (u) => isRelay(u) ? FakeMode.host : FakeMode.refuse;
      make().connect();
      await eventually(() => channels.hosts.any((h) => isRelay(h.uri)));
      channels.lastTo('wss://').send(relayWelcome);
      await eventually(() => c.link.value == LinkState.online);
      channels.lastTo('wss://').sendRaw('{"t":"hostOffline"}');
      await eventually(() => c.link.value == LinkState.offline);
      expect(c.route.value, isNull);
    });

    test('while_on_the_relay_lan_is_retried_and_taken_quietly', () async {
      var lanUp = false;
      channels.modeFor = (u) => isRelay(u) ? FakeMode.host : (lanUp ? FakeMode.host : FakeMode.silent);
      make(retry: const Duration(milliseconds: 300)).connect();
      await eventually(() => channels.hosts.any((h) => isRelay(h.uri)));
      final viaRelay = channels.lastTo('wss://');
      viaRelay.send(relayWelcome);
      await eventually(() => c.link.value == LinkState.online);
      final feed = c.feed('s1');
      await eventually(() => viaRelay.messages.whereType<Subscribe>().isNotEmpty);
      viaRelay.send(Events(sessionId: 's1', events: [UserMessage('hi', seq: 4, atMs: 1)]));
      await eventually(() => feed.lastSeq == 4);

      lanUp = true; // the phone is back on the home network
      await eventually(() => c.route.value == LinkRoute.lan, timeout: const Duration(seconds: 5));
      final lan = channels.lastTo('ws://');
      lan.send(relayWelcome);
      await eventually(() => lan.messages.whereType<Subscribe>().isNotEmpty);
      expect(lan.messages.first, isA<Hello>());
      expect(lan.messages.whereType<Subscribe>().single.afterSeq, 4);
      await eventually(() => viaRelay.closedByClient);
      expect(c.link.value, LinkState.online);
    });

    test('a_wrong_secret_through_the_relay_asks_to_pair_again', () async {
      channels.modeFor = (u) => isRelay(u) ? FakeMode.wrongSecret : FakeMode.refuse;
      make().connect();
      await eventually(() => c.link.value == LinkState.needsPairing);
    });
  });

  test('a_tampered_frame_from_the_host_drops_the_link', () async {
    conn.connect();
    channels.last.send(welcome);
    await eventually(() => conn.link.value == LinkState.online);
    final f = channels.last.session!.seal(encodeHost(const Sessions(sessions: [])));
    f.single[5] ^= 1;
    channels.last.sendRaw(Uint8List.fromList(f.single));
    await eventually(() => conn.link.value == LinkState.offline);
    await eventually(() => channels.hosts.length == 2, timeout: const Duration(seconds: 3));
  });

  test('reconnects_and_resubscribes', () async {
    conn.connect();
    channels.last.send(welcome);
    await eventually(() => conn.link.value == LinkState.online);
    final feed = conn.feed('s1');
    await eventually(() => channels.last.messages.whereType<Subscribe>().isNotEmpty);
    expect(channels.last.messages.whereType<Subscribe>().single.afterSeq, 0);
    channels.last.send(Events(sessionId: 's1', events: [
      for (var i = 1; i <= 7; i++) UserMessage('m$i', seq: i, atMs: i),
    ]));
    await eventually(() => feed.lastSeq == 7);

    await channels.last.close(); // the phone drops off the network
    await eventually(() => conn.link.value == LinkState.offline);
    await eventually(() => channels.hosts.length == 2, timeout: const Duration(seconds: 5));
    final second = channels.last;
    second.send(welcome);
    await eventually(() => second.messages.length >= 2);
    expect(second.messages[0], isA<Hello>());
    expect(second.messages[1], isA<Subscribe>());
    expect((second.messages[1] as Subscribe).afterSeq, 7);
    expect((second.messages[1] as Subscribe).sessionId, 's1');

    // A replayed event with seq 7 does not appear twice; a new one is added.
    second.send(Events(sessionId: 's1', events: [UserMessage('m7', seq: 7, atMs: 7), UserMessage('m8', seq: 8, atMs: 8)]));
    second.send(EventMessage(sessionId: 's1', event: UserMessage('m8', seq: 8, atMs: 8)));
    await eventually(() => feed.lastSeq == 8);
    await pump(50);
    expect(feed.events.value.map((e) => e.seq).toList(), [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(conn.link.value, LinkState.online);
  });

  test('remote_access_stopped_sets_stopped_and_does_not_retry', () async {
    conn.connect();
    channels.last.send(welcome);
    await eventually(() => conn.link.value == LinkState.online);
    channels.last.send(const RemoteAccessStopped());
    await channels.last.close();
    await eventually(() => conn.link.value == LinkState.stopped);
    await pump(1500);
    expect(channels.hosts.length, 1);
  });

  test('prompts_open_and_close_in_the_feed', () async {
    conn.connect();
    channels.last.send(welcome);
    final feed = conn.feed('s1');
    const p = PromptRequest(promptId: 'p1', kind: PromptKind.permission, toolName: 'Write', input: {});
    channels.last.send(const Events(sessionId: 's1', events: [], openPrompts: [p]));
    await eventually(() => feed.openPrompts.value.length == 1);
    channels.last.send(const PromptClosed(sessionId: 's1', promptId: 'p1'));
    await eventually(() => feed.openPrompts.value.isEmpty);
    channels.last.send(const PromptOpened(sessionId: 's1', prompt: p));
    await eventually(() => feed.openPrompts.value.length == 1);
  });

  test('commands_send_the_right_frames', () async {
    conn.connect();
    channels.last.send(welcome);
    await eventually(() => conn.link.value == LinkState.online);
    conn.startSession(cwd: r'D:\x', prompt: 'go');
    conn.send('s1', 'more');
    conn.answer('s1', 'p1', const PermissionAnswer(allow: true));
    conn.interrupt('s1');
    conn.stopSession('s1');
    conn.takeOver('s1', force: true);
    conn.killAll();
    await eventually(() => channels.last.messages.length >= 8);
    expect(channels.last.messages.skip(1).map((m) => m.runtimeType.toString()).toList(),
        ['StartSession', 'SendMessage', 'AnswerPrompt', 'Interrupt', 'StopSession', 'TakeOver', 'KillAll']);
    expect((channels.last.messages[1] as StartSession).model, isNull);
  });

  test('reports_the_session_shown_in_the_foreground_and_none_in_the_background', () async {
    List<String?> focus() => [for (final m in channels.last.messages.whereType<FocusSession>()) m.sessionId];
    conn.focusSession('s1'); // not connected yet: told after welcome
    conn.connect();
    channels.last.send(welcome);
    await eventually(() => focus().isNotEmpty);
    expect(focus(), ['s1']);
    conn.appInForeground = false;
    conn.appInForeground = false;
    conn.appInForeground = true;
    conn.unfocusSession('s2'); // another screen closing changes nothing
    conn.unfocusSession('s1');
    await eventually(() => focus().length == 4);
    await pump(50);
    expect(focus(), ['s1', null, 's1', null]);

    // A new connection with nothing in the foreground says nothing.
    final c2 = HostConnection(machine, channelFactory: channels.factory, deviceId: 'dev-8');
    c2.connect();
    channels.last.send(welcome);
    await eventually(() => c2.link.value == LinkState.online);
    await pump(50);
    expect(focus(), isEmpty);
    c2.dispose();
  });
}
