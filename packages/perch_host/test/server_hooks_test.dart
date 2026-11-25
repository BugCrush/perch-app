import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'server_test.dart' show TestClient;

const sid = '44444444-5555-4666-8777-888888888888';

const questions = {
  'questions': [
    {
      'question': 'Which color?',
      'header': 'Color',
      'options': [
        {'label': 'Red', 'description': ''},
        {'label': 'Blue', 'description': ''},
      ],
      'multiSelect': false,
    }
  ]
};

Future<({int status, String body})> post(String host, int port, Object body, {String path = 'hook'}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse('http://$host:$port/$path'));
    req.headers.contentType = ContentType.json;
    req.write(body is String ? body : jsonEncode(body));
    final res = await req.close();
    return (status: res.statusCode, body: await utf8.decoder.bind(res).join());
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory tmp;
  late FakeExternalSessions external;
  late FakeConsoleTyper console;
  late SessionManager manager;
  late HostState state;
  late PerchServer server;
  late int port;
  final clients = <TestClient>[];

  Future<void> startServer({String bind = '127.0.0.1', bool hooksInstalled = true, bool Function()? checkHooks}) async {
    server = PerchServer(
      manager: manager,
      state: state,
      machineName: 'test-machine',
      bindAddress: bind,
      port: 0,
      // Minutes: anything that arrives quickly came from the hook, not the poll.
      pollInterval: const Duration(minutes: 10),
      hooksInstalled: hooksInstalled,
      checkHooks: checkHooks,
    );
    port = await server.start();
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_srvh_');
    external = FakeExternalSessions()
      ..entries = [
        FakeExternalSessions().entry(pid: 5151, sessionId: sid, cwd: tmp.path, status: 'busy', name: 'work')
      ];
    console = FakeConsoleTyper();
    manager = SessionManager(
        launcher: fakeLauncher(), external: external, typer: console, claudeConfigDir: '${tmp.path}${Platform.pathSeparator}cfg');
    state = HostState.load('${tmp.path}${Platform.pathSeparator}state');
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
    if (state.device('dev-test') == null) {
      state.approveDevice('dev-test', name: 'Phone', permission: DevicePermissions.full);
    }
    final c = await TestClient.connect(port, state);
    clients.add(c);
    c.send(const Hello(deviceName: 'Phone'));
    await c.next<Sessions>();
    return c;
  }

  test('loopback_hook_gets_an_empty_200_and_reaches_the_app_without_the_poll', () async {
    await startServer();
    final c = await paired();
    final w = c.received.whereType<Welcome>().single;
    expect(w.hooksInstalled, isTrue);

    final sw = Stopwatch()..start();
    final r = await post('127.0.0.1', port, {
      'session_id': sid,
      'cwd': tmp.path,
      'hook_event_name': 'PreToolUse',
      'tool_name': 'AskUserQuestion',
      'tool_input': questions,
      'tool_use_id': 'toolu_H1',
    });
    expect(r.status, 200);
    expect(r.body, isEmpty);
    final opened = await c.next<PromptOpened>();
    sw.stop();
    expect(opened.sessionId, sid);
    expect(opened.prompt.promptId, 'toolu_H1');
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    final up = await c.next<SessionUpdated>(where: (m) => m.session.id == sid && m.session.state == SessionState.waitingQuestion);
    expect(up.session.openPrompts, 1);

    await post('127.0.0.1', port, {'session_id': sid, 'hook_event_name': 'Stop'});
    final closed = await c.next<PromptClosed>();
    expect(closed.promptId, 'toolu_H1');
    await c.next<SessionUpdated>(where: (m) => m.session.id == sid && m.session.state == SessionState.idle);
  });

  test('malformed_hook_bodies_still_get_200', () async {
    await startServer();
    expect((await post('127.0.0.1', port, 'not json')).status, 200);
    expect((await post('127.0.0.1', port, [1, 2])).status, 200);
  });

  test('hook_from_another_address_is_refused', () async {
    expect(PerchServer.acceptsHookFrom(InternetAddress.loopbackIPv4), isTrue);
    expect(PerchServer.acceptsHookFrom(InternetAddress.loopbackIPv6), isTrue);
    expect(PerchServer.acceptsHookFrom(InternetAddress('192.168.1.20')), isFalse);
    expect(PerchServer.acceptsHookFrom(null), isFalse);

    // Over the network too, when this machine has an address other than loopback.
    await startServer(bind: '0.0.0.0');
    final addresses = [
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
        for (final a in i.addresses)
          if (!a.isLoopback) a.address
    ];
    if (addresses.isEmpty) return;
    final r = await post(addresses.first, port, {'session_id': sid, 'hook_event_name': 'Stop'});
    expect(r.status, 403);
  });

  test('compatibility_is_in_welcome_and_pushed_when_it_changes', () async {
    manager.compatibility.setVersion('2.1.323');
    await startServer();
    final c = await paired();
    expect(c.received.whereType<Welcome>().single.compatibility!.status, CompatibilityStatus.ok);
    // A hook without its fields is evidence of a change.
    await post('127.0.0.1', port, {'session_id': sid, 'hook_event_name': 'PermissionRequest'});
    final m = await c.next<CompatibilityMessage>();
    expect(m.compatibility.status, CompatibilityStatus.drifted);
    expect(m.compatibility.claudeVersion, '2.1.323');
    expect(m.compatibility.evidence, contains('tool_name'));
  });

  test('self_test_hooks_reach_neither_the_sessions_nor_the_notifier_nor_the_log', () async {
    final logged = <String>[];
    final ignored = <String>[];
    server = PerchServer(
      manager: manager,
      state: state,
      machineName: 'test-machine',
      bindAddress: '127.0.0.1',
      port: 0,
      pollInterval: const Duration(minutes: 10),
      onHook: (j) => logged.add('${j['hook_event_name']}'),
      onSelfTestHook: ignored.add,
    );
    port = await server.start();
    final c = await paired();
    const stId = '99999999-0000-4000-8000-000000000009';
    for (var i = 0; i < 3; i++) {
      await post('127.0.0.1', port, {
        'session_id': stId,
        'cwd': r'C:\Users\someone\AppData\Roaming\perch\selftest',
        'hook_event_name': 'PreToolUse',
        'tool_name': 'AskUserQuestion',
        'tool_input': questions,
        'tool_use_id': 'toolu_S$i',
      });
    }
    await post('127.0.0.1', port, {'session_id': sid, 'cwd': tmp.path, 'hook_event_name': 'Stop'});
    await waitUntil(() => logged.isNotEmpty);
    expect(logged, ['Stop']);
    expect(ignored, [stId]); // said once
    expect(c.received.whereType<PromptOpened>(), isEmpty);
  });

  test('the_app_turns_the_self_test_on_and_off_and_sees_it', () async {
    manager.compatibility.setVersion('2.1.332');
    await startServer();
    final c = await paired();
    expect(c.received.whereType<Welcome>().single.compatibility!.selfTest!.enabled, isFalse);
    c.send(const SetSelfTest(enabled: true));
    final on = await c.next<CompatibilityMessage>(where: (m) => m.compatibility.selfTest?.enabled == true);
    expect(on.compatibility.status, CompatibilityStatus.untested);
    expect(manager.compatibility.store.selfTestNewVersions, isTrue);
    c.send(const SetSelfTest(enabled: false));
    await c.next<CompatibilityMessage>(where: (m) => m.compatibility.selfTest?.enabled == false);
    // No self-tester on this host: running it is refused with a message.
    c.send(const RunSelfTest());
    final e = await c.next<ErrorMessage>();
    expect(e.message, contains('not available'));
  });

  test('welcome_says_when_hooks_are_not_installed', () async {
    await startServer(hooksInstalled: false);
    final c = await paired();
    expect(c.received.whereType<Welcome>().single.hooksInstalled, isFalse);
  });

  test('hooks_installed_after_start_reach_devices_on_reload', () async {
    var installed = false;
    await startServer(hooksInstalled: false, checkHooks: () => installed);
    final c = await paired();
    expect(c.received.whereType<Welcome>().single.hooksInstalled, isFalse);

    // A reload with nothing changed keeps the device connected.
    await server.reloadState();
    expect(c.closed, isFalse);

    // `hooks install` in another console, then its reload: the device is dropped and its
    // next welcome says instant updates are on.
    installed = true;
    await server.reloadState();
    await waitUntil(() => c.closed);
    expect(server.hooksInstalled, isTrue);
    final again = await paired();
    expect(again.received.whereType<Welcome>().single.hooksInstalled, isTrue);
  });

  test('the_waiting_permission_hook_returns_the_phones_answer_for_a_terminal_perch_cannot_type_into', () async {
    console.operable = false;
    await startServer();
    final c = await paired();
    final reply = post('127.0.0.1', port, path: 'hook?wait=1', {
      'session_id': sid,
      'cwd': tmp.path,
      'hook_event_name': 'PermissionRequest',
      'tool_name': 'AskUserQuestion',
      'tool_input': questions,
    });
    final opened = await c.next<PromptOpened>();
    await waitUntil(() => manager.isHoldingHook(sid), timeout: const Duration(seconds: 5));
    c.send(AnswerPrompt(sessionId: sid, promptId: opened.prompt.promptId, answer: const QuestionAnswer({'Which color?': 'Blue'})));
    final r = await reply.timeout(const Duration(seconds: 5));
    expect(r.status, 200);
    expect(jsonDecode(r.body), {
      'hookSpecificOutput': {
        'hookEventName': 'PermissionRequest',
        'decision': {
          'behavior': 'allow',
          'updatedInput': {...questions, 'answers': {'Which color?': 'Blue'}},
        },
      },
    });
    await c.next<PromptClosed>();
  });

  test('the_waiting_permission_hook_gets_an_empty_200_at_once_for_a_terminal_perch_types_into', () async {
    await startServer();
    final sw = Stopwatch()..start();
    final r = await post('127.0.0.1', port, path: 'hook?wait=1', {
      'session_id': sid,
      'cwd': tmp.path,
      'hook_event_name': 'PermissionRequest',
      'tool_name': 'Bash',
      'tool_input': {'command': 'ls'},
    });
    expect(r.status, 200);
    expect(r.body, isEmpty);
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('the_waiting_hook_for_a_self_test_session_gets_nothing', () async {
    console.operable = false;
    await startServer();
    final r = await post('127.0.0.1', port, path: 'hook?wait=1', {
      'session_id': sid,
      'cwd': '${tmp.path}/perch/selftest',
      'hook_event_name': 'PermissionRequest',
      'tool_name': 'Bash',
      'tool_input': {'command': 'ls'},
    }).timeout(const Duration(seconds: 2));
    expect(r.body, isEmpty);
  });

  test('a_stop_check_is_answered_at_once_and_ends_the_turn_after_stop_from_the_phone', () async {
    console.operable = false;
    await startServer();
    final c = await paired();
    final check = {
      'session_id': sid,
      'cwd': tmp.path,
      'hook_event_name': 'PostToolBatch',
      'tool_calls': [],
    };
    var r = await post('127.0.0.1', port, path: 'hook?check=1', check);
    expect(r.body, isEmpty);
    c.send(const Interrupt(sessionId: sid));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(c.received.whereType<ErrorMessage>(), isEmpty, reason: 'interrupt succeeds');
    final sw = Stopwatch()..start();
    r = await post('127.0.0.1', port, path: 'hook?check=1', check);
    expect(jsonDecode(r.body), {'continue': false, 'stopReason': 'Stopped from Perch'});
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    r = await post('127.0.0.1', port, path: 'hook?check=1', check);
    expect(r.body, isEmpty);
  });
}
