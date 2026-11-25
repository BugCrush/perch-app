import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/inbox.dart' show wrapInboxText;
import 'package:perch_host/src/input_idle.dart' show PerchKeyLog;
import 'package:perch_host/src/push_notifier.dart';
import 'package:perch_host/src/session_manager.dart' show trustReason;
import 'package:perch_host/src/terminal_prompts.dart' show trustFolderTool;
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

const sid = 'a1b2c3d4-0000-4000-8000-000000000001';
const other = 'a1b2c3d4-0000-4000-8000-000000000002';

class FakeSource implements PushSource {
  final opened = StreamController<({String sessionId, PromptRequest prompt})>.broadcast(sync: true);
  final closed = StreamController<({String sessionId, String promptId})>.broadcast(sync: true);
  final updates = StreamController<SessionSummary>.broadcast(sync: true);
  final limits = StreamController<String>.broadcast(sync: true);
  final Map<String, SessionSummary> summaries = {};

  @override
  Stream<({String sessionId, PromptRequest prompt})> get promptsOpened => opened.stream;
  @override
  Stream<({String sessionId, String promptId})> get promptsClosed => closed.stream;
  @override
  Stream<SessionSummary> get sessionUpdates => updates.stream;
  @override
  Stream<String> get usageLimits => limits.stream;
  @override
  SessionSummary? summaryOf(String sessionId) => summaries[sessionId];

  /// Subagents still running per session (their descriptions).
  final Map<String, List<String>> subagents = {};
  @override
  List<String> runningSubagents(String sessionId) => subagents[sessionId] ?? const [];

  void state(String id, SessionState s, {String? reason}) {
    final sum = SessionSummary(
        id: id,
        name: summaries[id]?.name ?? 'Fix login',
        cwd: 'C:\\x',
        origin: SessionOrigin.external,
        state: s,
        startedAtMs: 1,
        reason: reason);
    summaries[id] = sum;
    updates.add(sum);
  }
}

PromptRequest question(String id, {int n = 1}) => PromptRequest(
      promptId: id,
      kind: PromptKind.question,
      toolName: 'AskUserQuestion',
      input: {
        'questions': [
          for (var i = 0; i < n; i++) {'question': 'Secret question $i?', 'options': []}
        ]
      },
    );

PromptRequest permission(String id, String tool) =>
    PromptRequest(promptId: id, kind: PromptKind.permission, toolName: tool, input: {'command': 'rm -rf secret-dir'});

PromptRequest plan(String id) =>
    PromptRequest(promptId: id, kind: PromptKind.plan, toolName: 'ExitPlanMode', input: {'plan': 'The secret plan'});

class Sent {
  final Uri uri;
  final Map<String, String> headers;
  final String raw;
  final Map<String, dynamic> body;
  final PushNote note;
  Sent(this.uri, this.headers, this.raw, this.body, this.note);
}

void main() {
  late Directory tmp;
  late HostState state;
  List<int> phoneKey() => state.device('phone')!.keyBytes!;
  late FakeSource source;
  late PushNotifier notifier;
  late List<Sent> sent;
  late DateTime now;
  const settle = Duration(milliseconds: 30);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_push_');
    state = HostState.load(tmp.path)
      ..setRelay('https://relay.example')
      ..approveDevice('phone', name: 'Phone', permission: DevicePermissions.full)
      ..confirmKey('phone');
    source = FakeSource();
    sent = [];
    now = DateTime(2026, 11, 14, 12);
    notifier = PushNotifier(
      source: source,
      state: state,
      machineName: 'Desk',
      settle: settle,
      clock: () => now,
      poster: (uri, headers, body) async {
        final j = jsonDecode(body) as Map<String, dynamic>;
        var note = openPush(phoneKey(), state.machineId, j['payload'] as String);
        for (final d in state.devices) {
          final k = d.keyBytes;
          if (note == null && k != null) note = openPush(k, state.machineId, j['payload'] as String);
        }
        sent.add(Sent(uri, headers, body, j, note!));
        return (status: 200, body: '{"sent":1,"failed":0}');
      },
    )..start();
    source.summaries[sid] = SessionSummary(
        id: sid, name: 'Fix login', cwd: 'C:\\x', origin: SessionOrigin.external, state: SessionState.idle, startedAtMs: 1);
  });

  tearDown(() async {
    await notifier.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> settled() async {
    await Future<void>.delayed(settle * 3);
    await notifier.idle;
  }

  test('a question is sealed and posted to the relay with the host token', () async {
    source.opened.add((sessionId: sid, prompt: question('toolu_1')));
    await settled();
    expect(sent, hasLength(1));
    final s = sent.single;
    expect(s.uri.toString(), 'https://relay.example/m/${state.machineId}/push');
    expect(s.headers['Authorization'], 'Bearer ${state.hostToken}');
    expect(s.body['priority'], 'high');
    expect(s.body['collapseKey'], pushTag(phoneKey(), sid));
    expect(s.body.containsKey('withdraw'), isFalse);
    expect(s.note.toJson(), {
      'title': 'Desk',
      'body': 'Fix login: asked a question',
      'machineId': state.machineId,
      'sessionId': sid,
      'kind': 'question',
      'promptId': 'toolu_1',
    });
  });

  test('nothing readable leaves the host', () async {
    source.opened.add((sessionId: sid, prompt: permission('toolu_2', 'Bash')));
    await settled();
    final raw = sent.single.raw;
    for (final s in ['Desk', 'Fix login', sid, 'toolu_2', 'Bash', 'permission', 'secret', state.machineId]) {
      expect(raw.contains(s), isFalse, reason: s);
    }
    expect(raw.contains(base64UrlNoPad(state.secret)), isFalse);
    expect(sent.single.note.body, 'Fix login: wants permission to use Bash');
  });

  test('wording for each reason', () async {
    expect(pushWhat(PushKinds.question, prompt: question('a', n: 2)), 'asked 2 questions');
    expect(pushWhat(PushKinds.question, prompt: question('a')), 'asked a question');
    expect(pushWhat(PushKinds.permission, prompt: permission('a', 'Edit')), 'wants permission to use Edit');
    expect(pushWhat(PushKinds.plan), 'has a plan to approve');
    expect(pushWhat(PushKinds.blocked), 'is blocked');
    expect(pushWhat(PushKinds.usageLimit), 'hit a usage limit');
    expect(pushWhat(PushKinds.finished), 'finished');
  });

  test('two questions, a plan', () async {
    source.opened.add((sessionId: sid, prompt: question('toolu_1', n: 2)));
    await settled();
    source.summaries[other] = source.summaries[sid]!.copyWith(name: 'Docs');
    source.opened.add((sessionId: other, prompt: plan('toolu_3')));
    await settled();
    expect(sent.map((s) => s.note.body), ['Fix login: asked 2 questions', 'Docs: has a plan to approve']);
    expect(sent.map((s) => s.note.kind), ['question', 'plan']);
    expect(sent[0].body['collapseKey'], isNot(sent[1].body['collapseKey']));
  });

  test('withdrawn when the card is answered anywhere', () async {
    source.opened.add((sessionId: sid, prompt: question('toolu_1')));
    await settled();
    source.closed.add((sessionId: sid, promptId: 'toolu_1'));
    await settled();
    expect(sent, hasLength(2));
    final w = sent[1];
    expect(w.body['withdraw'], isTrue);
    expect(w.body['priority'], 'normal');
    expect(w.body['collapseKey'], pushTag(phoneKey(), sid));
    expect(w.note.kind, PushKinds.withdraw);
    expect(w.note.sessionId, sid);
    expect(w.note.body, '');
  });

  test('a card answered at once is never notified (nor withdrawn)', () async {
    source.opened.add((sessionId: sid, prompt: question('toolu_1')));
    source.closed.add((sessionId: sid, promptId: 'toolu_1'));
    await settled();
    expect(sent, isEmpty);
  });

  test('the same card reopened under a new id does not buzz again', () async {
    source.opened.add((sessionId: sid, prompt: question('hook:1')));
    await settled();
    source.closed.add((sessionId: sid, promptId: 'hook:1'));
    source.opened.add((sessionId: sid, prompt: question('toolu_1')));
    await settled();
    expect(sent, hasLength(1));
    // And answering the new one withdraws it.
    source.closed.add((sessionId: sid, promptId: 'toolu_1'));
    await settled();
    expect(sent.last.note.kind, PushKinds.withdraw);
  });

  test('blocked, then moving on withdraws', () async {
    source.state(sid, SessionState.working);
    source.state(sid, SessionState.blocked, reason: 'Something went wrong');
    await settled();
    expect(sent.single.note.body, 'Fix login: is blocked');
    expect(sent.single.note.kind, PushKinds.blocked);
    source.state(sid, SessionState.working);
    await settled();
    expect(sent.last.note.kind, PushKinds.withdraw);
  });

  test('the folder-trust wait is told once, as blocked, by its card', () async {
    final trust = PromptRequest(promptId: 'trust:1', kind: PromptKind.permission, toolName: trustFolderTool, input: {});
    source.opened.add((sessionId: sid, prompt: trust));
    source.state(sid, SessionState.blocked, reason: trustReason);
    await settled();
    expect(sent.single.note.body, 'Fix login: is blocked');
    expect(sent.single.note.promptId, 'trust:1');
  });

  test('a usage limit has its own words and is not also told as blocked', () async {
    source.state(sid, SessionState.working);
    source.limits.add(sid);
    source.state(sid, SessionState.blocked, reason: 'Claude usage limit reached');
    await settled();
    expect(sent.single.note.body, 'Fix login: hit a usage limit');
    expect(sent.single.note.kind, PushKinds.usageLimit);
  });

  test('a finished turn is told for every session', () async {
    source.state(sid, SessionState.working);
    source.state(sid, SessionState.idle);
    await settled();
    expect(sent.single.note.body, 'Fix login: finished');

    // The next turn starts: the old notification goes.
    source.state(sid, SessionState.working);
    await settled();
    expect(sent.last.note.kind, PushKinds.withdraw);

    // Hours later, still told.
    now = now.add(const Duration(hours: 5));
    source.state(sid, SessionState.idle);
    await settled();
    expect(sent.last.note.kind, PushKinds.finished);
  });

  test('a turn that handed work to a subagent says so, not finished', () async {
    source.subagents[sid] = ['Research the login flow in the auth module'];
    source.state(sid, SessionState.working);
    source.state(sid, SessionState.idle);
    await settled();
    expect(sent.single.note.body, 'Fix login: handed work to a subagent · Research the login flow…');
    expect(sent.single.note.kind, PushKinds.finished);

    // Two at once, one without a description.
    source.subagents[sid] = ['Check tests', ''];
    source.state(sid, SessionState.working);
    source.state(sid, SessionState.idle);
    await settled();
    expect(sent.last.note.body, 'Fix login: handed work to 2 subagents · Check tests');

    // When the subagents are done and the turn ends again: finished.
    source.subagents.remove(sid);
    source.state(sid, SessionState.working);
    source.state(sid, SessionState.idle);
    await settled();
    expect(sent.last.note.body, 'Fix login: finished');
  });

  group('the owner at the machine', () {
    late Duration? idle;
    late PushNotifier atDesk;
    late int reads;

    setUp(() async {
      await notifier.dispose();
      idle = const Duration(seconds: 5);
      reads = 0;
      atDesk = PushNotifier(
        source: source,
        state: state,
        machineName: 'Desk',
        settle: settle,
        clock: () => now,
        inputIdle: () async {
          reads++;
          return idle;
        },
        poster: (uri, headers, body) async {
          final j = jsonDecode(body) as Map<String, dynamic>;
          sent.add(Sent(uri, headers, body, j, openPush(phoneKey(), state.machineId, j['payload'] as String)!));
          return (status: 200, body: '{}');
        },
      )..start();
      notifier = atDesk;
    });

    test('keyboard or mouse used in the last 60 seconds: nothing is sent', () async {
      source.opened.add((sessionId: sid, prompt: question('toolu_1')));
      source.state(sid, SessionState.working);
      source.state(sid, SessionState.idle);
      await settled();
      expect(sent, isEmpty);
      expect(reads, greaterThan(0));

      idle = const Duration(seconds: 61);
      source.state(sid, SessionState.working);
      source.state(sid, SessionState.idle);
      await settled();
      expect(sent.single.note.kind, PushKinds.finished);
    });

    test('when the idle time is known, typing at the terminal no longer decides', () async {
      idle = const Duration(minutes: 3);
      notifier.onHook({'hook_event_name': 'UserPromptSubmit', 'session_id': sid, 'prompt': 'typed by hand'});
      source.opened.add((sessionId: sid, prompt: question('toolu_1')));
      await settled();
      expect(sent.single.note.kind, 'question');
    });

    test('input that was Perch typing a phone message is not the owner', () async {
      await notifier.dispose();
      final keys = PerchKeyLog(clock: () => now);
      notifier = PushNotifier(
        source: source,
        state: state,
        machineName: 'Desk',
        settle: settle,
        clock: () => now,
        perchKeys: keys,
        // The last input was 2 s ago: when Perch pressed Enter.
        inputIdle: () async => const Duration(seconds: 2),
        poster: (uri, headers, body) async {
          final j = jsonDecode(body) as Map<String, dynamic>;
          sent.add(Sent(uri, headers, body, j, openPush(phoneKey(), state.machineId, j['payload'] as String)!));
          return (status: 200, body: '{}');
        },
      )..start();
      source.state(sid, SessionState.working);
      source.state(sid, SessionState.idle);
      await settled();
      expect(sent, isEmpty, reason: 'no Perch keys: that input was the owner');

      now = now.subtract(const Duration(seconds: 2));
      keys
        ..began()
        ..ended();
      now = now.add(const Duration(seconds: 2));
      source.state(sid, SessionState.working);
      source.state(sid, SessionState.idle);
      await settled();
      expect(sent.single.note.kind, PushKinds.finished);
    });

    test('an unreadable idle time falls back to the terminal rule', () async {
      idle = null;
      notifier.onHook({'hook_event_name': 'UserPromptSubmit', 'session_id': sid, 'prompt': 'typed by hand'});
      source.opened.add((sessionId: sid, prompt: question('toolu_1')));
      await settled();
      expect(sent, isEmpty);
      source.opened.add((sessionId: other, prompt: question('toolu_9')));
      await settled();
      expect(sent.single.note.sessionId, other);
    });
  });

  test('a new session started from Perch is matched by its first prompt hook', () async {
    notifier.perchTyping('Write the  report\n');
    notifier.onHook({'hook_event_name': 'UserPromptSubmit', 'session_id': sid, 'prompt': 'Write the report'});
    source.state(sid, SessionState.working);
    source.state(sid, SessionState.idle);
    await settled();
    expect(sent.single.note.body, 'Fix login: finished');
  });

  test('without an idle time, typing at the terminal silences that session for two minutes', () async {
    notifier.onHook({'hook_event_name': 'UserPromptSubmit', 'session_id': sid, 'prompt': 'typed by hand'});
    source.opened.add((sessionId: sid, prompt: question('toolu_1')));
    source.state(sid, SessionState.working);
    source.state(sid, SessionState.idle);
    await settled();
    expect(sent, isEmpty);

    // Another session is not silenced.
    source.opened.add((sessionId: other, prompt: question('toolu_9')));
    await settled();
    expect(sent.single.note.sessionId, other);

    now = now.add(const Duration(minutes: 2, seconds: 1));
    source.opened.add((sessionId: sid, prompt: question('toolu_2')));
    await settled();
    expect(sent.last.note.sessionId, sid);
  });

  test('what Perch typed is not the owner at the terminal', () async {
    notifier.perchTyping('from the phone');
    notifier.onHook({'hook_event_name': 'UserPromptSubmit', 'session_id': sid, 'prompt': 'from the phone'});
    source.opened.add((sessionId: sid, prompt: question('toolu_1')));
    await settled();
    expect(sent, hasLength(1));
  });

  test('a phone message delivered through the inbox is not the owner at the terminal', () async {
    // Claude Code fires UserPromptSubmit for inbox messages too, with the wrapper and its
    // own notice around the text (VS Code, Cursor, iTerm2 sessions).
    notifier.perchTyping('from the phone');
    notifier.onHook({
      'hook_event_name': 'UserPromptSubmit',
      'session_id': sid,
      'prompt': 'Another Claude session sent a message:\n${wrapInboxText('from the phone')}\n\nThis came from another Claude session.',
    });
    source.opened.add((sessionId: sid, prompt: question('toolu_1')));
    source.state(sid, SessionState.working);
    await settled();
    expect(sent.single.note.kind, 'question');
    source.closed.add((sessionId: sid, promptId: 'toolu_1'));
    source.state(sid, SessionState.idle);
    await settled();
    // The finished turn is told too.
    expect(sent.map((x) => x.note.kind), contains('finished'));
  });

  test('a device showing the session in the foreground is excepted', () async {
    state.approveDevice('tablet', name: 'Tablet', permission: DevicePermissions.full);
    notifier.focusedDevices = (id) => id == sid ? ['phone'] : const [];
    source.opened.add((sessionId: sid, prompt: question('toolu_1')));
    source.summaries[other] = source.summaries[sid]!.copyWith(name: 'Docs');
    source.opened.add((sessionId: other, prompt: question('toolu_2')));
    await settled();
    // One post per device, each sealed with that device's key.
    expect(sent[0].body['except'], ['phone']);
    expect(sent[0].body['devices'], ['tablet']);
    expect(sent.skip(1).map((s) => s.body.containsKey('except')), [false, false]);
    expect(sent.skip(1).map((s) => (s.body['devices'] as List).single), ['phone', 'tablet']);
  });

  test('nothing is sent while remote access is stopped or without a relay', () async {
    notifier.enabled = false;
    source.opened.add((sessionId: sid, prompt: question('toolu_1')));
    await settled();
    notifier.enabled = true;
    state.setRelay(null);
    source.opened.add((sessionId: other, prompt: question('toolu_2')));
    await settled();
    expect(sent, isEmpty);
  });

  test('relay URLs become the push endpoint', () {
    expect(relayHttpUri('https://r.example', 'm1', 'push').toString(), 'https://r.example/m/m1/push');
    expect(relayHttpUri('wss://r.example/base/', 'm1', 'push').toString(), 'https://r.example/base/m/m1/push');
    expect(relayHttpUri('http://127.0.0.1:8799', 'm1', 'push').toString(), 'http://127.0.0.1:8799/m/m1/push');
  });

  group('per-device sealing', () {
    test('every device with its key gets its own sealed copy; nothing is sealed with the pairing secret', () async {
      final keyed = state.approveDevice('pixel', name: 'Pixel', permission: DevicePermissions.watch);
      state.confirmKey('pixel');
      source.opened.add((sessionId: sid, prompt: question('toolu_k')));
      await settled();
      expect(sent, hasLength(2));
      for (final post in sent) {
        expect(post.body['devices'], hasLength(1));
        expect(openPush(state.secret, state.machineId, post.body['payload'] as String), isNull,
            reason: 'the pairing secret opens no notification');
        expect(post.body['collapseKey'], isNot(pushTag(state.secret, sid)));
      }
      final own = sent.firstWhere((s) => (s.body['devices'] as List).contains('pixel'));
      expect(openPush(keyed.keyBytes!, state.machineId, own.body['payload'] as String)!.body,
          'Fix login: asked a question');
      expect(own.body['collapseKey'], pushTag(keyed.keyBytes!, sid));
    });

    test('a device that has not used its key yet gets its copy sealed with that key too', () async {
      final d = state.approveDevice('pixel', name: 'Pixel', permission: DevicePermissions.full);
      source.opened.add((sessionId: sid, prompt: question('toolu_u')));
      await settled();
      expect(sent.map((s) => (s.body['devices'] as List).single), ['phone', 'pixel']);
      expect(openPush(d.keyBytes!, state.machineId, sent[1].body['payload'] as String), isNotNull);
    });

    test('no approved device: nothing is posted', () async {
      state.removeDevice('phone');
      source.opened.add((sessionId: sid, prompt: question('toolu_n')));
      await settled();
      expect(sent, isEmpty);
    });

    test('a focused keyed device is left out', () async {
      state.approveDevice('pixel', name: 'Pixel', permission: DevicePermissions.full);
      state.confirmKey('pixel');
      notifier.focusedDevices = (_) => ['pixel'];
      source.opened.add((sessionId: sid, prompt: question('toolu_f')));
      await settled();
      expect(sent.single.body['devices'], ['phone']);
      expect(sent.single.body['except'], ['pixel']);
    });
  });
}
