// Cards of terminal sessions Perch cannot type into are answered through Claude Code's
// PermissionRequest hook, which waits for the phone while the terminal shows its dialog.
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/terminal_prompts.dart' show CannotAnswerInTerminal;
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const sid = '33333333-4444-4555-8666-777777777777';
final sep = Platform.pathSeparator;

const questions = {
  'questions': [
    {
      'question': 'Which colour?',
      'header': 'Colour',
      'options': [
        {'label': 'Red', 'description': 'Choose red'},
        {'label': 'Blue', 'description': 'Choose blue'},
      ],
      'multiSelect': false,
    }
  ]
};
const bash = {'command': 'touch perm-test.txt', 'description': 'Create a file'};
const plan = {'plan': 'Reply DONE\n', 'planFilePath': '/Users/someone/.claude/plans/x.md'};
const suggestions = [
  {
    'type': 'addRules',
    'rules': [
      {'toolName': 'Bash', 'ruleContent': 'touch perm-test.txt'}
    ],
    'behavior': 'allow',
    'destination': 'localSettings',
  }
];

/// A hook input like the ones Claude Code 2.1.325 sent (synthetic values).
Map<String, dynamic> hook(String event, [Map<String, dynamic> extra = const {}]) => {
      'session_id': sid,
      'transcript_path': '/Users/someone/.claude/projects/x/$sid.jsonl',
      'cwd': '/Users/someone/project',
      'hook_event_name': event,
      'permission_mode': 'default',
      ...extra,
    };

Map<String, dynamic>? decisionOf(Map<String, dynamic>? out) {
  if (out == null) return null;
  final h = out['hookSpecificOutput'] as Map;
  expect(h['hookEventName'], 'PermissionRequest');
  return (h['decision'] as Map).cast<String, dynamic>();
}

void main() {
  late Directory tmp;
  late File transcript;
  late FakeExternalSessions external;
  late FakeConsoleTyper console;
  late SessionManager manager;
  late List<String> opened;
  late List<String> closed;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_hka_');
    final project = Directory('${tmp.path}${sep}config${sep}projects${sep}x')..createSync(recursive: true);
    transcript = File('${project.path}$sep$sid.jsonl')
      ..writeAsStringSync('${jsonEncode({
        'type': 'user',
        'message': {'role': 'user', 'content': 'Do the thing.'}
      })}\n');
    external = FakeExternalSessions()
      ..entries = [
        FakeExternalSessions().entry(pid: 4242, sessionId: sid, cwd: '/Users/someone/project', status: 'busy')
      ];
    console = FakeConsoleTyper()..operable = false;
    manager = SessionManager(
      launcher: fakeLauncher(),
      external: external,
      typer: console,
      claudeConfigDir: '${tmp.path}${sep}config',
      answerPoll: const Duration(milliseconds: 5),
      answerTimeout: const Duration(milliseconds: 300),
      hookGrace: const Duration(seconds: 30),
    );
    opened = [];
    closed = [];
    manager.promptsOpened.listen((p) => opened.add(p.prompt.promptId));
    manager.promptsClosed.listen((p) => closed.add(p.promptId));
  });

  tearDown(() async {
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  /// Starts a waiting PermissionRequest hook and returns its pending answer once the card
  /// is open.
  Future<Future<Map<String, dynamic>?>> hold(String tool, Map<String, dynamic> input, [Map<String, dynamic> extra = const {}]) async {
    final f = manager.holdPermissionHook(hook('PermissionRequest', {'tool_name': tool, 'tool_input': input, ...extra}));
    await waitUntil(() => manager.isHoldingHook(sid), timeout: const Duration(seconds: 5));
    return f;
  }

  String openCard() => manager.history(sid).openPrompts.single.promptId;

  test('a question card is answered through the waiting hook with the answers', () async {
    await manager.handleHook(hook('PreToolUse', {'tool_name': 'AskUserQuestion', 'tool_input': questions, 'tool_use_id': 'toolu_Q1'}));
    final pending = await hold('AskUserQuestion', questions);
    expect(openCard(), 'toolu_Q1');
    await manager.answerPrompt(sid, 'toolu_Q1', const QuestionAnswer({'Which colour?': 'Blue'}));
    final d = decisionOf(await pending.timeout(const Duration(seconds: 2)))!;
    expect(d['behavior'], 'allow');
    expect(d['updatedInput'], {...questions, 'answers': {'Which colour?': 'Blue'}});
    await settle();
    expect(manager.history(sid).openPrompts, isEmpty);
    expect(closed, contains('toolu_Q1'));
    expect(console.presses, isEmpty, reason: 'no keys pressed');
    expect(manager.isHoldingHook(sid), isFalse);
  });

  test('a permission card: allow, allow always, deny with a message', () async {
    var pending = await hold('Bash', bash, {'permission_suggestions': suggestions});
    await manager.answerPrompt(sid, openCard(), const PermissionAnswer(allow: true));
    expect(decisionOf(await pending), {'behavior': 'allow', 'updatedInput': bash});

    const bash2 = {'command': 'touch two.txt'};
    pending = await hold('Bash', bash2, {'permission_suggestions': suggestions});
    await manager.answerPrompt(sid, openCard(), const PermissionAnswer(allow: true, always: true));
    expect(decisionOf(await pending), {'behavior': 'allow', 'updatedInput': bash2, 'updatedPermissions': suggestions});

    const bash3 = {'command': 'touch three.txt'};
    pending = await hold('Bash', bash3);
    await manager.answerPrompt(sid, openCard(), const PermissionAnswer(allow: false, message: 'Not now'));
    expect(decisionOf(await pending), {'behavior': 'deny', 'message': 'Not now'});
  });

  test('a plan is approved like the terminal\'s first Yes: as received, then auto mode', () async {
    final pending = await hold('ExitPlanMode', plan);
    await manager.answerPrompt(sid, openCard(), const PlanAnswer(approve: true));
    expect(decisionOf(await pending), {
      'behavior': 'allow',
      'updatedInput': plan,
      'updatedPermissions': [
        {'type': 'setMode', 'mode': 'auto', 'destination': 'session'}
      ],
    });
    await settle();
    expect(manager.history(sid).openPrompts, isEmpty);
  });

  test('a plan can be sent back with feedback', () async {
    final pending = await hold('ExitPlanMode', plan);
    await manager.answerPrompt(sid, openCard(), const PlanAnswer(approve: false, feedback: 'Shorter, please'));
    expect(decisionOf(await pending), {'behavior': 'deny', 'message': 'Shorter, please'});
  });

  test('answered at the desk: the hook is let go with no answer', () async {
    final pending = await hold('Bash', bash);
    await manager.handleHook(hook('PostToolUse', {'tool_name': 'Bash', 'tool_input': bash, 'tool_use_id': 'toolu_B1'}));
    expect(await pending.timeout(const Duration(seconds: 2)), isNull);
    expect(manager.isHoldingHook(sid), isFalse);
  });

  test('the turn ending lets the hook go too', () async {
    final pending = await hold('Bash', bash);
    await manager.handleHook(hook('Stop'));
    expect(await pending.timeout(const Duration(seconds: 2)), isNull);
  });

  test('the hook is let go after the limit', () async {
    final f = manager.holdPermissionHook(hook('PermissionRequest', {'tool_name': 'Bash', 'tool_input': bash}),
        limit: const Duration(milliseconds: 100));
    expect(await f.timeout(const Duration(seconds: 2)), isNull);
    expect(manager.isHoldingHook(sid), isFalse);
  });

  test('a session Perch can type into is not held (its terminal is answered with keys)', () async {
    console.operable = true;
    final out = await manager
        .holdPermissionHook(hook('PermissionRequest', {'tool_name': 'Bash', 'tool_input': bash}))
        .timeout(const Duration(seconds: 2));
    expect(out, isNull);
    expect(opened, isNotEmpty, reason: 'the card still opens');
  });

  test('a background session is not held (it would deny at once without the hook)', () async {
    external.entries = [
      FakeExternalSessions().entry(pid: 4242, sessionId: sid, cwd: '/Users/someone/project', kind: 'background')
    ];
    final out = await manager
        .holdPermissionHook(hook('PermissionRequest', {'tool_name': 'Bash', 'tool_input': bash}))
        .timeout(const Duration(seconds: 2));
    expect(out, isNull);
  });

  test('an unknown session is not held', () async {
    final j = hook('PermissionRequest', {'tool_name': 'Bash', 'tool_input': bash})..['session_id'] = 'nope';
    expect(await manager.holdPermissionHook(j).timeout(const Duration(seconds: 5)), isNull);
  });

  test('without a waiting hook a card of such a terminal must be answered at the machine', () async {
    await manager.handleHook(hook('PreToolUse', {'tool_name': 'AskUserQuestion', 'tool_input': questions, 'tool_use_id': 'toolu_Q2'}));
    await expectLater(manager.answerPrompt(sid, 'toolu_Q2', const QuestionAnswer({'Which colour?': 'Red'})),
        throwsA(isA<CannotAnswerInTerminal>()));
    expect(console.presses, isEmpty);
  });

  test('closing the manager lets every hook go', () async {
    final pending = await hold('Bash', bash);
    await manager.dispose();
    expect(await pending.timeout(const Duration(seconds: 2)), isNull);
    manager = SessionManager(launcher: fakeLauncher(), external: external, typer: console);
  });

  test('the card stays open while its hook waits, even when the listing says idle', () async {
    final pending = await hold('Bash', bash);
    external.entries = [FakeExternalSessions().entry(pid: 4242, sessionId: sid, cwd: '/Users/someone/project', status: 'idle')];
    final m2 = manager;
    await m2.list();
    manager.history(sid);
    await settle();
    expect(manager.history(sid).openPrompts, hasLength(1));
    await manager.answerPrompt(sid, openCard(), const PermissionAnswer(allow: true));
    expect(decisionOf(await pending)!['behavior'], 'allow');
  });

  test('transcript tool result lets the hook go', () async {
    transcript.writeAsStringSync(
        '${jsonEncode({
          'type': 'assistant',
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'tool_use', 'id': 'toolu_T1', 'name': 'Bash', 'input': bash}
            ]
          }
        })}\n',
        mode: FileMode.append);
    final pending = await hold('Bash', bash);
    expect(openCard(), 'toolu_T1');
    transcript.writeAsStringSync(
        '${jsonEncode({
          'type': 'user',
          'message': {
            'role': 'user',
            'content': [
              {'type': 'tool_result', 'tool_use_id': 'toolu_T1', 'content': 'done'}
            ]
          }
        })}\n',
        mode: FileMode.append);
    expect(await pending.timeout(const Duration(seconds: 10)), isNull);
  });

  group('stop from the phone', () {
    Map<String, dynamic> pre() => hook('PreToolUse', {'tool_name': 'Bash', 'tool_input': bash, 'tool_use_id': 'toolu_S1'});
    Map<String, dynamic> batch() => hook('PostToolBatch', {'tool_calls': []});

    test('the next stop check ends the turn once; before a tool it also refuses the tool', () async {
      await manager.list();
      expect(manager.stopCheck(pre()), isNull, reason: 'nothing requested');
      await manager.interrupt(sid);
      expect(manager.stopCheck(pre()), {
        'continue': false,
        'stopReason': 'Stopped from Perch',
        'hookSpecificOutput': {
          'hookEventName': 'PreToolUse',
          'permissionDecision': 'deny',
          'permissionDecisionReason': 'Stopped from Perch',
        },
      });
      expect(manager.stopCheck(pre()), isNull, reason: 'used up');
      expect(manager.summaryOf(sid)!.state, SessionState.idle, reason: 'no Stop hook follows a stop by hook');
      await manager.handleHook(hook('UserPromptSubmit', {'prompt': 'next'})); // working again
      await manager.interrupt(sid);
      expect(manager.stopCheck(batch()), {'continue': false, 'stopReason': 'Stopped from Perch'});
      expect(console.presses, isEmpty);
    });

    test('another session is not stopped', () async {
      await manager.list();
      await manager.interrupt(sid);
      expect(manager.stopCheck(pre()..['session_id'] = 'other'), isNull);
    });

    test('the turn ending drops the request', () async {
      await manager.list();
      await manager.interrupt(sid);
      await manager.handleHook(hook('Stop'));
      expect(manager.stopCheck(pre()), isNull);
    });

    test('an idle session has nothing to stop', () async {
      external.entries = [FakeExternalSessions().entry(pid: 4242, sessionId: sid, cwd: '/Users/someone/project', status: 'idle')];
      await manager.list();
      await manager.interrupt(sid);
      expect(manager.stopCheck(pre()), isNull);
    });

    test('a held permission request is refused with interrupt at once', () async {
      final pending = await hold('Bash', bash);
      await manager.interrupt(sid);
      expect(decisionOf(await pending), {'behavior': 'deny', 'message': 'Stopped from Perch', 'interrupt': true});
      await settle();
      expect(manager.history(sid).openPrompts, isEmpty);
      expect(manager.stopCheck(pre()), isNull, reason: 'already stopped');
    });

    test('without the stop-check hooks Stop says so', () async {
      manager.stopHooks = false;
      await manager.list();
      await expectLater(manager.interrupt(sid), throwsA(isA<CannotType>()));
    });

    test('a terminal Perch can type into still gets Esc', () async {
      console.operable = true;
      await manager.list();
      await manager.interrupt(sid);
      expect(console.presses, ['keys:${String.fromCharCode(0xE000 + 0x1B)}']);
      expect(manager.stopCheck(pre()), isNull);
    });
  });
}
