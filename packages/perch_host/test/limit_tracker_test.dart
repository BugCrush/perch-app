// The machine's usage limit: grouping, both choices for each session kind, Esc cancel and
// its fallbacks, the reset with and without Claude Code continuing, the 90-second check
// (shortened here), the conditions for please continue, the resumed-differently
// comparison, and the limit surviving a restart. Screens are SYNTHETIC (Claude Code's
// documented wording; see usage_limit_screen_test.dart).
import 'dart:async';
import 'dart:io';

import 'package:perch_host/src/console_typer.dart' show ConsoleKeys;
import 'package:perch_host/src/limit_tracker.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart' show waitUntil;
import 'usage_limit_screen_test.dart' show cancelledScreen, menuScreen, rule, waitingScreen;

const promptScreen = '$rule\n❯\n$rule\n';

class FakeSessions implements LimitSessions {
  final kinds = <String, LimitSessionKind>{};
  final screens = <String, String?>{};
  final atPromptNow = <String, bool>{};
  final owner = <String, int>{};
  final sent = <String>[];
  final notes = <String>[];
  final actions = <String>[];
  final agents = <String, List<AgentRun>>{};
  void Function(String sid, String action)? onAction;
  @override
  UsageSnapshot? usage;

  @override
  LimitSessionKind kindOf(String id) => kinds[id] ?? LimitSessionKind.none;
  @override
  String nameOf(String id) => 'name-$id';
  @override
  String get machineName => 'Desk';
  @override
  Future<String?> screenOf(String id) async => screens[id];
  @override
  Future<bool> keys(String id, String keys) async {
    actions.add('$id keys:$keys');
    onAction?.call(id, 'keys:$keys');
    return true;
  }

  @override
  Future<bool> typeLine(String id, String text) async {
    actions.add('$id type:$text');
    onAction?.call(id, 'type:$text');
    return true;
  }

  @override
  Future<bool> atPrompt(String id) async => atPromptNow[id] ?? true;
  @override
  int? ownerPromptAt(String id) => owner[id];
  @override
  Future<void> send(String id, String text) async => sent.add('$id:$text');
  @override
  void note(String id, String text) => notes.add('$id:$text');
  @override
  List<AgentRun> agentsAt(String id, DateTime hitAt) => agents[id] ?? const [];
}

class MemoryStore implements LimitStore {
  Map<String, dynamic>? saved;
  @override
  Map<String, dynamic>? loadLimits() => saved;
  @override
  void saveLimits(Map<String, dynamic> json) => saved = json;
}

void main() {
  late FakeSessions s;
  late MemoryStore store;
  late UsageLimitTracker t;
  final reports = <ResumeReport>[];
  final backs = <List<String>>[];
  final typedByPerch = <String>[];

  UsageLimitTracker make() => UsageLimitTracker(
        sessions: s,
        store: store,
        continueCheck: const Duration(milliseconds: 250),
        compareWindow: const Duration(milliseconds: 300),
        unknownPoll: const Duration(milliseconds: 50),
        promptRetry: const Duration(milliseconds: 40),
        maxTries: 4,
        confirmTimeout: const Duration(milliseconds: 250),
        poll: const Duration(milliseconds: 20),
      )
        ..perchTyping = typedByPerch.add
        ..start();

  setUp(() {
    s = FakeSessions();
    store = MemoryStore();
    reports.clear();
    backs.clear();
    typedByPerch.clear();
    t = make();
    t.reports.listen(reports.add);
    t.usageBack.listen(backs.add);
  });

  tearDown(() => t.dispose());

  DateTime soon([int ms = 150]) => DateTime.now().add(Duration(milliseconds: ms));
  Future<void> settle([int ms = 50]) => Future<void>.delayed(Duration(milliseconds: ms));

  group('grouping', () {
    test('every session on the machine is in one limit, with the machine choice', () async {
      s.kinds
        ..['a'] = LimitSessionKind.terminal
        ..['b'] = LimitSessionKind.inbox;
      s.screens['a'] = waitingScreen;
      final reset = DateTime.now().add(const Duration(hours: 2));
      t.hit('a', resetsAt: reset, window: LimitWindows.fiveHour, claudeWaiting: true);
      t.hit('b');
      final l = t.current!;
      expect(l.sessions.map((x) => x.id), ['a', 'b']);
      expect(l.sessions.first.claudeWaiting, isTrue);
      expect(l.sessions.last.claudeWaiting, isNull);
      expect(l.choice, LimitChoices.continueWhenAvailable);
      expect(l.window, LimitWindows.fiveHour);
      expect(l.resetsAtMs, reset.millisecondsSinceEpoch);
      expect(t.pausedReason('a'), startsWith('Usage limit · resets '));
      await settle();
      expect(s.actions, isEmpty, reason: 'Continue when available leaves a waiting Claude Code alone');
    });

    test('a session override wins for that session only', () async {
      s.kinds
        ..['a'] = LimitSessionKind.perchRun
        ..['b'] = LimitSessionKind.perchRun;
      t.hit('a', resetsAt: soon(200));
      t.hit('b');
      await t.choose(LimitChoices.wait, sessionId: 'b');
      expect(t.current!.choiceFor('a'), LimitChoices.continueWhenAvailable);
      expect(t.current!.choiceFor('b'), LimitChoices.wait);
      await waitUntil(() => s.sent.isNotEmpty, timeout: const Duration(seconds: 3));
      await settle(100);
      expect(s.sent, ['a:please continue']);
      expect(t.current!.sessions.single.id, 'b', reason: 'b waits for the owner');
      expect(t.current!.back, isTrue);
    });

    test('an override for a session that is not paused is refused', () {
      expect(() => t.choose(LimitChoices.wait, sessionId: 'x'), throwsStateError);
    });
  });

  group('continue when available', () {
    test('Claude Code continues by itself within the check: nothing is sent', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      t.hit('a', resetsAt: soon(), claudeWaiting: true);
      await waitUntil(() => backs.isNotEmpty, timeout: const Duration(seconds: 3));
      expect(backs.single, ['a']);
      expect(t.current!.back, isTrue);
      t.claudeContinued('a');
      expect(t.current, isNull);
      await settle(400);
      expect(s.sent, isEmpty);
      expect(reports.single.changed, isFalse);
      expect(s.notes, ['a:$resumedSameNote']);
    });

    test('new work in the transcript after the reset also counts as continued', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      t.hit('a', resetsAt: soon(), claudeWaiting: true);
      await waitUntil(() => backs.isNotEmpty, timeout: const Duration(seconds: 3));
      t.activity('a', AssistantText('Picking up where I left off.', atMs: DateTime.now().millisecondsSinceEpoch));
      await settle(400);
      expect(s.sent, isEmpty);
      expect(t.current, isNull);
    });

    test('the limit message itself is not new work', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      t.hit('a', resetsAt: soon(5000), claudeWaiting: true);
      t.activity('a', AssistantText("You've hit your session limit · resets 3:45pm", atMs: DateTime.now().millisecondsSinceEpoch));
      t.activity('a', AssistantText('API Error: Rate limit reached', atMs: DateTime.now().millisecondsSinceEpoch));
      expect(t.isPaused('a'), isTrue);
    });

    test('Claude Code does not continue within the check: Perch sends please continue', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      t.hit('a', resetsAt: soon(), claudeWaiting: true);
      await waitUntil(() => backs.isNotEmpty, timeout: const Duration(seconds: 3));
      await settle(100);
      expect(s.sent, isEmpty, reason: 'not before the check');
      await waitUntil(() => s.sent.isNotEmpty, timeout: const Duration(seconds: 3));
      expect(s.sent, ['a:please continue']);
      expect(typedByPerch, [continueText], reason: "the notifier must not take it for the owner's typing");
      expect(t.current, isNull);
    });

    test('quota_auto_resume_stale after the reset: sent at once', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      t.hit('a', resetsAt: soon(), claudeWaiting: true);
      await waitUntil(() => backs.isNotEmpty, timeout: const Duration(seconds: 3));
      t.claudeStopped('a');
      await waitUntil(() => s.sent.isNotEmpty, timeout: const Duration(milliseconds: 200));
      expect(s.sent, ['a:please continue']);
    });

    test('not at its prompt: tried again later, then sent', () async {
      s.kinds['a'] = LimitSessionKind.perchRun;
      s.atPromptNow['a'] = false;
      t.hit('a', resetsAt: soon());
      await waitUntil(() => backs.isNotEmpty, timeout: const Duration(seconds: 3));
      await settle(60);
      expect(s.sent, isEmpty);
      s.atPromptNow['a'] = true;
      await waitUntil(() => s.sent.isNotEmpty, timeout: const Duration(seconds: 2));
    });

    test('never at its prompt: the owner is told', () async {
      s.kinds['a'] = LimitSessionKind.perchRun;
      s.atPromptNow['a'] = false;
      t.hit('a', resetsAt: soon(50));
      await waitUntil(() => t.current?.problem != null, timeout: const Duration(seconds: 3));
      expect(t.current!.problem, contains('not at its prompt'));
      expect(s.sent, isEmpty);
    });

    test('the owner sent something newer: nothing is sent', () async {
      s.kinds['a'] = LimitSessionKind.perchRun;
      t.hit('a', resetsAt: soon());
      s.owner['a'] = DateTime.now().add(const Duration(seconds: 5)).millisecondsSinceEpoch;
      await waitUntil(() => backs.isNotEmpty, timeout: const Duration(seconds: 3));
      await settle(100);
      expect(s.sent, isEmpty);
      expect(t.current, isNull, reason: 'the owner resumed it');
    });

    test('a weekly limit with the options menu: Esc closes it, then please continue at the reset', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      s.screens['a'] = menuScreen;
      s.onAction = (id, a) {
        if (a == 'keys:${ConsoleKeys.escape}') s.screens['a'] = promptScreen;
      };
      t.hit('a', resetsAt: soon(300), menu: true);
      await waitUntil(() => s.actions.isNotEmpty, timeout: const Duration(seconds: 2));
      expect(s.actions, ['a keys:${ConsoleKeys.escape}']);
      await waitUntil(() => s.sent.isNotEmpty, timeout: const Duration(seconds: 3));
      expect(t.current, isNull);
    });

    test('a session Perch runs gets please continue at the reset', () async {
      s.kinds['a'] = LimitSessionKind.perchRun;
      t.hit('a', resetsAt: soon(), claudeWaiting: true);
      expect(t.current!.sessions.single.claudeWaiting, isFalse, reason: '-p sessions never wait');
      await waitUntil(() => s.sent.isNotEmpty, timeout: const Duration(seconds: 3));
    });

    test('hitting the limit again pauses it again with the same choice', () async {
      s.kinds['a'] = LimitSessionKind.perchRun;
      await t.choose(LimitChoices.wait);
      t.hit('a', resetsAt: soon(5000));
      t.ownerPrompt('a', 'go on');
      expect(t.current, isNull);
      t.hit('a', resetsAt: soon(5000));
      expect(t.current!.choice, LimitChoices.wait);
      expect(t.isPaused('a'), isTrue);
    });

    test('Continue now sends to every session still paused', () async {
      s.kinds
        ..['a'] = LimitSessionKind.perchRun
        ..['b'] = LimitSessionKind.inbox;
      await t.choose(LimitChoices.wait);
      t.hit('a', resetsAt: soon());
      t.hit('b', claudeWaiting: false);
      await waitUntil(() => backs.isNotEmpty, timeout: const Duration(seconds: 3));
      expect(s.sent, isEmpty);
      await t.choose(LimitChoices.continueNow);
      await waitUntil(() => s.sent.length == 2, timeout: const Duration(seconds: 2));
      expect(t.current, isNull);
    });
  });

  group('wait', () {
    test('Esc cancels Claude Code\'s wait, confirmed on screen; nothing is sent at the reset', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      s.screens['a'] = waitingScreen;
      s.onAction = (id, a) {
        if (a == 'keys:${ConsoleKeys.escape}') s.screens['a'] = cancelledScreen;
      };
      await t.choose(LimitChoices.wait);
      t.hit('a', resetsAt: soon(300), claudeWaiting: true);
      await waitUntil(() => t.current?.sessions.single.claudeWaiting == false, timeout: const Duration(seconds: 2));
      expect(s.actions, ['a keys:${ConsoleKeys.escape}']);
      await waitUntil(() => backs.isNotEmpty, timeout: const Duration(seconds: 3));
      await settle(400);
      expect(s.sent, isEmpty);
      expect(t.current!.back, isTrue);
      expect(t.current!.problem, isNull);
    });

    test('Esc not confirmed: /rate-limit-options, then Don\'t continue automatically', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      s.screens['a'] = waitingScreen;
      s.onAction = (id, a) {
        if (a == 'type:/rate-limit-options') s.screens['a'] = menuScreen;
        if (a == 'keys:4') s.screens['a'] = cancelledScreen;
      };
      await t.choose(LimitChoices.wait);
      t.hit('a', resetsAt: soon(5000), claudeWaiting: true);
      await waitUntil(() => t.current?.sessions.single.claudeWaiting == false, timeout: const Duration(seconds: 3));
      expect(s.actions, ['a keys:${ConsoleKeys.escape}', 'a type:/rate-limit-options', 'a keys:4']);
      expect(typedByPerch, ['/rate-limit-options']);
      expect(t.current!.problem, isNull);
    });

    test('a menu without the row: closed again with Esc, the owner is told', () async {
      // The REAL menu of an organization account with no limit active (Mac, Claude Code
      // 2.1.326): no "Don't continue automatically" row. Perch must not leave it open.
      final orgMenu = File('test${Platform.pathSeparator}fixtures${Platform.pathSeparator}screens'
              '${Platform.pathSeparator}rate_limit_options_org_real.txt')
          .readAsStringSync();
      s.kinds['a'] = LimitSessionKind.terminal;
      s.screens['a'] = waitingScreen;
      s.onAction = (id, a) {
        if (a == 'type:/rate-limit-options') s.screens['a'] = orgMenu;
        if (a == 'keys:${ConsoleKeys.escape}' && s.screens['a'] == orgMenu) s.screens['a'] = promptScreen;
      };
      await t.choose(LimitChoices.wait);
      t.hit('a', resetsAt: soon(5000), claudeWaiting: true);
      await waitUntil(() => t.current?.problem != null, timeout: const Duration(seconds: 3));
      expect(s.actions, ['a keys:${ConsoleKeys.escape}', 'a type:/rate-limit-options', 'a keys:${ConsoleKeys.escape}']);
      expect(s.screens['a'], promptScreen);
      expect(t.current!.problem, "Couldn't stop Claude Code from continuing on Desk");
    });

    test('neither works: the owner is told, nothing is guessed', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      s.screens['a'] = waitingScreen;
      await t.choose(LimitChoices.wait);
      t.hit('a', resetsAt: soon(5000), claudeWaiting: true);
      await waitUntil(() => t.current?.problem != null, timeout: const Duration(seconds: 3));
      expect(t.current!.problem, "Couldn't stop Claude Code from continuing on Desk");
    });

    test('a terminal reached only through its inbox cannot be stopped: the owner is told', () async {
      s.kinds['a'] = LimitSessionKind.inbox;
      await t.choose(LimitChoices.wait);
      t.hit('a', resetsAt: soon(5000));
      await waitUntil(() => t.current?.problem != null, timeout: const Duration(seconds: 1));
      expect(s.actions, isEmpty);
    });

    test('choosing Wait later cancels the wait then', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      s.screens['a'] = waitingScreen;
      s.onAction = (id, a) {
        if (a == 'keys:${ConsoleKeys.escape}') s.screens['a'] = cancelledScreen;
      };
      t.hit('a', resetsAt: soon(5000), claudeWaiting: true);
      await settle();
      expect(s.actions, isEmpty);
      await t.choose(LimitChoices.wait);
      await waitUntil(() => s.actions.isNotEmpty, timeout: const Duration(seconds: 1));
      expect(t.current!.choice, LimitChoices.wait);
    });
  });

  group('unknown reset', () {
    test('the host\'s usage data says when the window is open again', () async {
      s.kinds['a'] = LimitSessionKind.perchRun;
      s.usage = const UsageSnapshot(fiveHour: UsageWindow(utilization: 1, resetsAt: 0, status: 'rejected'));
      t.hit('a');
      expect(t.current!.resetsAtMs, isNull);
      await settle(120);
      expect(backs, isEmpty);
      s.usage = const UsageSnapshot(fiveHour: UsageWindow(utilization: 0.01, resetsAt: 0, status: 'allowed'));
      await waitUntil(() => s.sent.isNotEmpty, timeout: const Duration(seconds: 2));
      expect(backs.single, ['a']);
    });
  });

  group('resumed differently', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    test('a subagent at the limit and main-session work after it: changed', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      s.agents['a'] = [const AgentRun('general-purpose', 'Write module docs')];
      t.hit('a', resetsAt: soon(5000), claudeWaiting: true);
      t.claudeContinued('a');
      t.activity('a', ToolCall('t1', 'Write', {'file_path': 'docs/a.md'}, atMs: now));
      t.activity('a', TurnEnded(isError: false, text: ''));
      await settle(10);
      expect(reports.single.changed, isTrue);
      expect(reports.single.text, resumedWithoutSubagentNote);
      expect(reports.single.sessionName, 'name-a');
      expect(s.notes, ['a:$resumedWithoutSubagentNote']);
    });

    test('the same kind of agent again: same', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      s.agents['a'] = [const AgentRun('general-purpose', 'Write module docs')];
      t.hit('a', resetsAt: soon(5000));
      t.claudeContinued('a');
      t.activity('a', ToolCall('t1', 'Read', {'file_path': 'a'}, atMs: now));
      t.activity('a', ToolCall('t2', 'Agent', {'subagent_type': 'general-purpose', 'description': 'Write module docs'}, atMs: now));
      await settle(10);
      expect(reports.single.changed, isFalse);
      expect(s.notes, ['a:$resumedSameNote']);
    });

    test('another kind of agent: changed', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      s.agents['a'] = [const AgentRun('general-purpose')];
      t.hit('a', resetsAt: soon(5000));
      t.claudeContinued('a');
      t.agentStarted('a', const AgentRun('Explore'));
      await settle(10);
      expect(reports.single.changed, isTrue);
      expect(reports.single.text, contains('Explore instead of general-purpose'));
    });

    test('nothing done in the first part of the turn: same, when the window ends', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      s.agents['a'] = [const AgentRun('general-purpose')];
      t.hit('a', resetsAt: soon(5000));
      t.claudeContinued('a');
      await settle(100);
      expect(reports, isEmpty);
      await waitUntil(() => reports.isNotEmpty, timeout: const Duration(seconds: 2));
      await settle(10);
      expect(reports.single.changed, isFalse);
    });

    test('no subagent at the limit: a quiet note at once', () async {
      s.kinds['a'] = LimitSessionKind.terminal;
      t.hit('a', resetsAt: soon(5000));
      t.claudeContinued('a');
      await settle(10);
      expect(reports.single.changed, isFalse);
      expect(reports.single.text, resumedSameNote);
    });
  });

  group('a restart', () {
    test('the choice, the limit and the overrides come back', () async {
      s.kinds
        ..['a'] = LimitSessionKind.terminal
        ..['b'] = LimitSessionKind.terminal;
      await t.choose(LimitChoices.wait);
      final reset = DateTime.now().add(const Duration(hours: 1));
      t.hit('a', resetsAt: reset, window: LimitWindows.fiveHour, claudeWaiting: false);
      t.hit('b', claudeWaiting: false);
      await t.choose(LimitChoices.continueWhenAvailable, sessionId: 'b');
      await t.dispose();
      t = make();
      final l = t.current!;
      expect(l.choice, LimitChoices.wait);
      expect(l.resetsAtMs, reset.millisecondsSinceEpoch);
      expect(l.choiceFor('b'), LimitChoices.continueWhenAvailable);
      expect(l.sessions.map((x) => x.id), ['a', 'b']);
    });

    test('a reset that passed while the host was down: usage is back at start', () async {
      s.kinds['a'] = LimitSessionKind.perchRun;
      t.hit('a', resetsAt: DateTime.now().add(const Duration(hours: 1)));
      await t.dispose();
      final saved = store.saved!;
      saved['resetsAtMs'] = DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch;
      t = make();
      await waitUntil(() => s.sent.isNotEmpty, timeout: const Duration(seconds: 2));
    });

    test('without a limit only the choice is kept', () async {
      await t.choose(LimitChoices.wait);
      expect(store.saved, {'choice': 'wait'});
    });
  });

  test('a session that is gone leaves the limit', () async {
    s.kinds['a'] = LimitSessionKind.terminal;
    t.hit('a', resetsAt: soon(5000));
    s.kinds.remove('a');
    t.prune();
    expect(t.current, isNull);
  });

  test('changes are announced', () async {
    final seen = <UsageLimit?>[];
    final sub = t.changes.listen(seen.add);
    s.kinds['a'] = LimitSessionKind.perchRun;
    t.hit('a', resetsAt: soon(5000));
    t.ownerPrompt('a', 'carry on');
    await settle();
    expect(seen.first, isNotNull);
    expect(seen.last, isNull);
    await sub.cancel();
  });

  test('please continue typed by Perch is not the owner', () async {
    s.kinds['a'] = LimitSessionKind.perchRun;
    await t.choose(LimitChoices.wait);
    t.hit('a', resetsAt: soon(5000));
    t.hit('b');
    // Not paused anymore after Perch sent it; a hit again, then Perch's own prompt echo:
    unawaited(t.choose(LimitChoices.continueNow, sessionId: 'a'));
    await waitUntil(() => s.sent.isNotEmpty);
    t.hit('a', resetsAt: soon(5000));
    t.ownerPrompt('a', 'please continue');
    expect(t.isPaused('a'), isTrue);
  });
}
