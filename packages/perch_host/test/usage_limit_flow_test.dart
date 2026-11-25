// A usage limit end to end through the session manager and the server, with the fake
// `claude`, a fake console with SYNTHETIC screens (Claude Code's documented wording) and
// synthetic transcripts: each detection path, Wait's Esc, please continue only at the
// prompt and only when the owner sent nothing newer, Claude Code continuing by itself, the
// resumed-differently note, the wire messages and the notifications.
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/console_typer.dart' show ConsoleKeys;
import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/limit_tracker.dart';
import 'package:perch_host/src/push_notifier.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'server_hooks_test.dart' show post;
import 'server_test.dart' show TestClient;
import 'usage_limit_screen_test.dart' show cancelledScreen, rule, strangeScreen, waitingScreen;

const sid = '77777777-8888-4999-8aaa-bbbbbbbbbbbb';
final sep = Platform.pathSeparator;
const promptScreen = '$rule\n❯\n$rule\n';

/// A permission dialog: not at the input prompt.
const dialogScreen = '''
● Write(notes.txt)

$rule
 Do you want to create notes.txt?
 ❯ 1. Yes
   2. No

 Esc to cancel
''';

String line(String type, Object content, {DateTime? at}) => jsonEncode({
      'type': type,
      'timestamp': (at ?? DateTime.now()).toUtc().toIso8601String(),
      'message': {'role': type, 'content': content},
    });

UsageLimitTracker fastTracker(LimitSessions s, {LimitStore? store}) => UsageLimitTracker(
      sessions: s,
      store: store,
      continueCheck: const Duration(milliseconds: 300),
      compareWindow: const Duration(milliseconds: 500),
      unknownPoll: const Duration(milliseconds: 100),
      promptRetry: const Duration(milliseconds: 60),
      maxTries: 3,
      confirmTimeout: const Duration(milliseconds: 300),
      poll: const Duration(milliseconds: 20),
    );

void main() {
  group('a terminal session', () {
    late Directory tmp;
    late File transcript;
    late FakeExternalSessions external;
    late FakeConsoleTyper console;
    late SessionManager manager;
    late List<String> limited;
    late List<ResumeReport> reports;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('perch_lim_');
      final project = Directory('${tmp.path}${sep}config${sep}projects${sep}D--work')..createSync(recursive: true);
      transcript = File('${project.path}$sep$sid.jsonl')
        ..writeAsStringSync('${line('user', 'Write the docs for every module.', at: DateTime.now().subtract(const Duration(minutes: 5)))}\n');
      external = FakeExternalSessions()
        ..entries = [FakeExternalSessions().entry(pid: 4343, sessionId: sid, cwd: r'D:\work', status: 'idle', name: 'docs')];
      console = FakeConsoleTyper(currentScreen: promptScreen);
      manager = SessionManager(
        launcher: fakeLauncher(),
        external: external,
        typer: console,
        claudeConfigDir: '${tmp.path}${sep}config',
        answerPoll: const Duration(milliseconds: 10),
        hookGrace: const Duration(milliseconds: 200),
        limitTracker: fastTracker,
      );
      limited = [];
      reports = [];
      manager.usageLimits.listen(limited.add);
      manager.limits.reports.listen(reports.add);
      await manager.list();
      manager.history(sid);
      console.actions.clear();
    });

    tearDown(() async {
      await manager.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    void append(String l) => transcript.writeAsStringSync('$l\n', mode: FileMode.append);
    Future<void> fire(Map<String, dynamic> extra) => manager.handleHook({'session_id': sid, 'cwd': r'D:\work', ...extra});
    Future<void> stopFailure([String text = 'API Error: Rate limit reached']) =>
        fire({'hook_event_name': 'StopFailure', 'error': 'rate_limit', 'last_assistant_message': text});
    List<String> notes() => [for (final e in manager.history(sid).events) if (e is Notice) e.text];
    List<String> typed() => [for (final c in console.calls) c.text];

    test('StopFailure: paused, with the reset and the wait read from the screen', () async {
      console.currentScreen = waitingScreen;
      await stopFailure();
      await waitUntil(() => manager.limits.current?.resetsAtMs != null);
      final l = manager.limits.current!;
      expect(l.sessions.single.id, sid);
      expect(l.sessions.single.claudeWaiting, isTrue);
      expect(l.window, LimitWindows.fiveHour);
      final at = DateTime.fromMillisecondsSinceEpoch(l.resetsAtMs!);
      expect((at.hour, at.minute), (15, 45));
      final s = manager.summaryOf(sid)!;
      expect(s.state, SessionState.blocked);
      expect(s.reason, startsWith('Usage limit · resets'));
      await waitUntil(() => limited.isNotEmpty);
      expect(limited, [sid], reason: 'the existing "hit a usage limit" notification');
      expect(typed(), isEmpty);
    });

    test('a StopFailure that is not a usage limit pauses nothing', () async {
      await fire({'hook_event_name': 'StopFailure', 'error': 'overloaded'});
      expect(manager.limits.current, isNull);
    });

    test("the transcript's limit line alone pauses it", () async {
      console.supported = false;
      append(line('assistant', [
        {'type': 'text', 'text': "You've hit your session limit · resets 3:45pm"}
      ]));
      await manager.list();
      await waitUntil(() => manager.limits.current != null);
      expect(manager.limits.current!.window, LimitWindows.fiveHour);
    });

    test('a turn that ended with the waiting lines on screen and no hook is paused too', () async {
      external.entries = [external.entry(pid: 4343, sessionId: sid, cwd: r'D:\work', status: 'busy', name: 'docs')];
      await manager.list();
      console.currentScreen = waitingScreen;
      external.entries = [external.entry(pid: 4343, sessionId: sid, cwd: r'D:\work', status: 'idle', name: 'docs')];
      await manager.list();
      await waitUntil(() => manager.limits.current != null);
      expect(manager.limits.current!.sessions.single.claudeWaiting, isTrue);
    });

    test('limit words Perch cannot read raise drift instead of a guess', () async {
      console.currentScreen = strangeScreen;
      await stopFailure();
      await waitUntil(() => manager.compatibility.current.status == CompatibilityStatus.drifted,
          timeout: const Duration(seconds: 5));
      expect(manager.compatibility.current.reason, contains('usage limit'));
      expect(manager.limits.current!.resetsAtMs, isNull);
    });

    test('Wait: Esc at the prompt, confirmed on screen', () async {
      await manager.limits.choose(LimitChoices.wait);
      console.currentScreen = waitingScreen;
      console.onAction = (a) {
        if (a == 'keys:${ConsoleKeys.escape}') console.currentScreen = cancelledScreen;
      };
      await stopFailure();
      await waitUntil(() => manager.limits.current?.sessions.single.claudeWaiting == false);
      expect(console.presses, ['keys:${ConsoleKeys.escape}']);
      expect(manager.limits.current!.problem, isNull);
    });

    test('Continue: Claude Code does not continue after the reset, so Perch types please continue', () async {
      await stopFailure();
      manager.limits.hit(sid, resetsAt: DateTime.now().add(const Duration(milliseconds: 100)), claudeWaiting: true);
      await waitUntil(() => typed().isNotEmpty, timeout: const Duration(seconds: 5));
      expect(typed(), ['please continue']);
      expect(manager.limits.current, isNull);
      await waitUntil(() => notes().contains(resumedSameNote));
    });

    test('Continue: Claude Code continues by itself (quota_auto_resume_fired): nothing is typed', () async {
      await stopFailure();
      manager.limits.hit(sid, resetsAt: DateTime.now().add(const Duration(milliseconds: 50)), claudeWaiting: true);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await fire({
        'hook_event_name': 'Notification',
        'notification_type': 'quota_auto_resume_fired',
        'message': 'Usage limit reset · Continuing automatically'
      });
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(typed(), isEmpty);
      expect(manager.limits.current, isNull);
      expect(notes(), contains('Usage limit reset · Continuing automatically'));
    });

    test('not at the input prompt: nothing is typed, and the owner is told', () async {
      await stopFailure();
      console.currentScreen = dialogScreen;
      manager.limits.hit(sid, resetsAt: DateTime.now().add(const Duration(milliseconds: 50)), claudeWaiting: false);
      await waitUntil(() => manager.limits.current?.problem != null, timeout: const Duration(seconds: 5));
      expect(typed(), isEmpty);
      expect(manager.limits.current!.problem, contains('not at its prompt'));
    });

    test('Claude still working (its input box shows for typing ahead): nothing is typed', () async {
      await stopFailure();
      // As seen live (2.1.325): the box is drawn mid-turn, the status line under it says so.
      console.currentScreen = '● Writing docs/a.md…\n\n✻ Pondering…\n$promptScreen'
          '  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt\n';
      manager.limits.hit(sid, resetsAt: DateTime.now().add(const Duration(milliseconds: 50)), claudeWaiting: false);
      await waitUntil(() => manager.limits.current?.problem != null, timeout: const Duration(seconds: 5));
      expect(typed(), isEmpty);
    });

    test('the owner sent something newer: nothing is typed', () async {
      await stopFailure();
      manager.limits.hit(sid, resetsAt: DateTime.now().add(const Duration(milliseconds: 150)), claudeWaiting: false);
      append(line('user', 'Skip the docs, fix the build instead.', at: DateTime.now().add(const Duration(seconds: 1))));
      await manager.list();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(typed(), isEmpty);
      expect(manager.limits.current, isNull, reason: 'the owner resumed it');
    });

    test('resumed without the subagent: a lasting note and a report', () async {
      append(line('assistant', [
        {
          'type': 'tool_use',
          'id': 'toolu_A',
          'name': 'Agent',
          'input': {'subagent_type': 'general-purpose', 'description': 'Write module docs', 'prompt': 'x'}
        }
      ]));
      await manager.list();
      await stopFailure();
      await fire({'hook_event_name': 'Notification', 'notification_type': 'quota_auto_resume_fired', 'message': ''});
      append(line('assistant', [
        {'type': 'tool_use', 'id': 'toolu_W', 'name': 'Write', 'input': {'file_path': 'docs/a.md', 'content': 'x'}}
      ]));
      await manager.list();
      await fire({'hook_event_name': 'Stop'});
      await waitUntil(() => reports.isNotEmpty);
      expect(reports.single.changed, isTrue);
      expect(reports.single.text, resumedWithoutSubagentNote);
      expect(notes(), contains(resumedWithoutSubagentNote));
    });

    test('resumed with the same kind of subagent: a quiet note', () async {
      append(line('assistant', [
        {
          'type': 'tool_use',
          'id': 'toolu_A',
          'name': 'Agent',
          'input': {'subagent_type': 'general-purpose', 'description': 'Write module docs', 'prompt': 'x'}
        }
      ]));
      await manager.list();
      await stopFailure();
      await fire({'hook_event_name': 'Notification', 'notification_type': 'quota_auto_resume_fired', 'message': ''});
      await fire({'hook_event_name': 'SubagentStart', 'agent_id': 'ag1', 'agent_type': 'general-purpose'});
      await waitUntil(() => reports.isNotEmpty);
      expect(reports.single.changed, isFalse);
      expect(notes(), contains(resumedSameNote));
    });

    test("please continue that Perch typed is not taken for the owner's prompt", () async {
      await manager.limits.choose(LimitChoices.wait);
      await stopFailure();
      await fire({'hook_event_name': 'UserPromptSubmit', 'prompt': 'please continue'});
      expect(manager.limits.isPaused(sid), isFalse, reason: 'nothing was sent by Perch: that one was the owner');
    });
  });

  group('a session Perch runs', () {
    late Directory tmp;
    late SessionManager manager;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('perch_limp_');
      manager = SessionManager(
        launcher: fakeLauncher(),
        external: FakeExternalSessions(),
        typer: FakeConsoleTyper(supported: false),
        claudeConfigDir: '${tmp.path}${sep}config',
        limitTracker: fastTracker,
      );
    });

    tearDown(() async {
      await manager.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('the rejected window pauses it, and at the reset Perch sends please continue', () async {
      final s = await manager.start(cwd: tmp.path, prompt: 'limit 2');
      await waitUntil(() => manager.limits.current != null, timeout: const Duration(seconds: 30));
      final l = manager.limits.current!;
      expect(l.window, LimitWindows.fiveHour);
      expect(l.resetsAtMs, isNotNull);
      expect(l.sessions.single.claudeWaiting, isFalse);
      await waitUntil(
          () => manager.history(s.id).events.any((e) => e is AssistantText && e.text == 'echo: please continue'),
          timeout: const Duration(seconds: 30));
      expect(manager.limits.current, isNull);
    });
  });

  group('the server and the phone', () {
    late Directory tmp;
    late SessionManager manager;
    late HostState state;
    late PerchServer server;
    late int port;
    late FakeConsoleTyper console;
    late List<PushNote> pushed;
    final clients = <TestClient>[];

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('perch_lims_');
      console = FakeConsoleTyper(currentScreen: promptScreen);
      state = HostState.load('${tmp.path}${sep}state')..setRelay('https://relay.example');
      manager = SessionManager(
        launcher: fakeLauncher(),
        external: FakeExternalSessions()
          ..entries = [FakeExternalSessions().entry(pid: 5353, sessionId: sid, cwd: tmp.path, status: 'idle', name: 'docs')],
        typer: console,
        claudeConfigDir: '${tmp.path}${sep}cfg',
        answerPoll: const Duration(milliseconds: 10),
        limitTracker: (s) => fastTracker(s, store: state),
      );
      pushed = [];
      final notifier = PushNotifier(
        source: manager,
        state: state,
        machineName: 'Desk',
        settle: const Duration(milliseconds: 50),
        poster: (uri, headers, body) async {
          final j = jsonDecode(body) as Map<String, dynamic>;
          pushed.add((() {
          for (final d in state.devices) {
            final n = openPush(d.keyBytes!, state.machineId, j['payload'] as String);
            if (n != null) return n;
          }
          return null;
        })()!);
          return (status: 200, body: '{"sent":1,"failed":0}');
        },
      );
      server = PerchServer(
        manager: manager,
        state: state,
        machineName: 'Desk',
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

    Future<void> hit() => post('127.0.0.1', port,
        {'session_id': sid, 'cwd': tmp.path, 'hook_event_name': 'StopFailure', 'error': 'rate_limit'});

    test('the phone gets the limit, chooses Wait, and a new device is told the limit on connect', () async {
      final phone = await paired();
      await hit();
      final m = await phone.next<UsageLimitMessage>(where: (m) => m.limit != null);
      expect(m.limit!.sessions.single.id, sid);
      expect(m.limit!.sessions.single.name, 'docs');
      expect(m.limit!.choice, LimitChoices.continueWhenAvailable);
      final from = phone.received.length;
      phone.send(const UsageLimitChoice(choice: LimitChoices.wait));
      final chosen = await phone.next<UsageLimitMessage>(from: from, where: (m) => m.limit?.choice == LimitChoices.wait);
      expect(chosen.limit!.choice, LimitChoices.wait);
      expect(state.usageLimits!['choice'], LimitChoices.wait, reason: 'the choice survives a restart');
      final tablet = await paired();
      final told = await tablet.next<UsageLimitMessage>();
      expect(told.limit!.choice, LimitChoices.wait);
      await waitUntil(() => pushed.any((p) => p.kind == PushKinds.usageLimit));
    });

    test('a per-session override for a session that is not paused is an error', () async {
      final phone = await paired();
      phone.send(const UsageLimitChoice(choice: LimitChoices.wait, sessionId: sid));
      final e = await phone.next<ErrorMessage>();
      expect(e.message, contains('not paused'));
    });

    test('usage is back: one notification for the machine, then withdrawn when the session resumes', () async {
      await paired();
      await hit();
      await waitUntil(() => manager.limits.current != null);
      await manager.limits.choose(LimitChoices.wait);
      manager.limits.hit(sid, resetsAt: DateTime.now().add(const Duration(milliseconds: 50)), claudeWaiting: false);
      await waitUntil(() => pushed.any((p) => p.kind == PushKinds.usageBack));
      final back = pushed.firstWhere((p) => p.kind == PushKinds.usageBack);
      expect(back.title, 'Desk');
      expect(back.body, 'Usage is back · 1 session paused');
      expect(back.sessionId, usageLimitPushId);
      expect(back.sessionIds, [sid]);
      // Continue from the notification: please continue goes to the paused session.
      await manager.limits.choose(LimitChoices.continueNow);
      await waitUntil(() => console.calls.isNotEmpty);
      expect(console.calls.single.text, 'please continue');
      await waitUntil(() => pushed.any((p) => p.kind == PushKinds.withdraw && p.sessionId == usageLimitPushId));
    });

    test('resumed differently reaches the phone as a report and a notification', () async {
      final phone = await paired();
      await hit();
      await waitUntil(() => manager.limits.current != null);
      manager.limits.hit(sid); // no agents known: a quiet report
      await post('127.0.0.1', port, {
        'session_id': sid,
        'hook_event_name': 'Notification',
        'notification_type': 'quota_auto_resume_fired',
        'message': ''
      });
      final r = await phone.next<ResumeReport>();
      expect(r.changed, isFalse);
      expect(pushed.where((p) => p.kind == PushKinds.resumedChanged), isEmpty);
    });
  });

  test('the host state keeps the limit and leaves it out when there is none', () {
    final tmp = Directory.systemTemp.createTempSync('perch_limst_');
    try {
      final s = HostState.load(tmp.path)..saveLimits({'choice': 'wait'});
      expect(HostState.load(tmp.path).usageLimits, {'choice': 'wait'});
      s.usageLimits = null;
      s.save();
      expect(jsonDecode(File('${tmp.path}${sep}host.json').readAsStringSync()), isNot(contains('usageLimits')));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
