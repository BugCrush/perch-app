import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const sid = '33333333-4444-4555-8666-777777777777';
final sep = Platform.pathSeparator;

String screen(String name) => File('test${sep}fixtures${sep}screens$sep$name').readAsStringSync();

String toolUse(String id, String name, Map<String, dynamic> input) => jsonEncode({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'tool_use', 'id': id, 'name': name, 'input': input}
        ]
      }
    });

String toolResult(String id, String text) => jsonEncode({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': id, 'content': text}
        ]
      }
    });

const questions = {
  'questions': [
    {
      'question': 'Which fruits?',
      'header': 'Fruit',
      'options': [
        {'label': 'Apple', 'description': 'Apple'},
        {'label': 'Banana', 'description': 'Banana'},
      ],
      'multiSelect': true,
    }
  ]
};

const write = {'file_path': r'D:\projects\example\note.txt', 'content': 'hello'};

/// A hook input like the ones Claude Code 2.1.323 sent (synthetic values).
Map<String, dynamic> hook(String event, [Map<String, dynamic> extra = const {}]) => {
      'session_id': sid,
      'transcript_path': r'C:\Users\someone\.claude\projects\x\s.jsonl',
      'cwd': r'D:\projects\example',
      'hook_event_name': event,
      ...extra,
    };

void main() {
  late Directory tmp;
  late File transcript;
  late FakeExternalSessions external;
  late FakeConsoleTyper console;
  late SessionManager manager;
  late List<String> opened;
  late List<PromptRequest> openedCards;
  late List<String> closed;
  late List<SessionSummary> updates;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_hk_');
    final project = Directory('${tmp.path}${sep}config${sep}projects${sep}D--projects-example')
      ..createSync(recursive: true);
    transcript = File('${project.path}$sep$sid.jsonl')
      ..writeAsStringSync('${jsonEncode({
        'type': 'user',
        'message': {'role': 'user', 'content': 'Do the thing.'}
      })}\n');
    external = FakeExternalSessions();
    console = FakeConsoleTyper();
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
    openedCards = [];
    closed = [];
    updates = [];
    manager.promptsOpened.listen((p) {
      opened.add(p.prompt.promptId);
      openedCards.add(p.prompt);
    });
    manager.promptsClosed.listen((p) => closed.add(p.promptId));
    manager.sessionUpdates.listen(updates.add);
  });

  tearDown(() async {
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void append(String line) => transcript.writeAsStringSync('$line\n', mode: FileMode.append);

  /// The listing (which may lag behind what the hooks say).
  void listing({String status = 'busy', String? waitingFor}) {
    external.entries = [
      external.entry(pid: 4242, sessionId: sid, cwd: r'D:\projects\example', status: status, waitingFor: waitingFor)
    ];
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  /// Hands a hook to the manager and lets its messages arrive.
  Future<void> fire(Map<String, dynamic> j) async {
    await manager.handleHook(j);
    await settle();
  }

  SessionState lastState() => updates.where((u) => u.id == sid).last.state;

  test('question_hook_opens_the_full_card_at_once_without_reading_the_screen', () async {
    listing();
    await manager.list();
    console.actions.clear();
    await fire(hook('PreToolUse', {'tool_name': 'AskUserQuestion', 'tool_input': questions, 'tool_use_id': 'toolu_Q'}));
    expect(opened, ['toolu_Q']);
    expect(openedCards.single.kind, PromptKind.question);
    expect(openedCards.single.input, questions);
    expect(lastState(), SessionState.waitingQuestion);
    expect(console.actions, isEmpty);

    // The permission request Claude Code sends for the same question adds nothing.
    await fire(hook('PermissionRequest', {'tool_name': 'AskUserQuestion', 'tool_input': questions}));
    expect(opened, ['toolu_Q']);
    expect(closed, isEmpty);

    // Answered at the machine: PostToolUse closes it, and the poll does not bring it back.
    await fire(hook('PostToolUse', {
      'tool_name': 'AskUserQuestion',
      'tool_input': questions,
      'tool_use_id': 'toolu_Q',
      'tool_response': {'answers': {}}
    }));
    expect(closed, ['toolu_Q']);
    expect(lastState(), SessionState.working);
    append(toolUse('toolu_Q', 'AskUserQuestion', questions));
    listing(status: 'waiting', waitingFor: 'input needed');
    await manager.list();
    expect(opened, ['toolu_Q']);
  });

  test('a_hook_for_an_unknown_session_looks_it_up_once', () async {
    listing();
    final before = external.listCalls;
    await fire(hook('PreToolUse', {'tool_name': 'ExitPlanMode', 'tool_input': {'plan': '# Plan'}, 'tool_use_id': 'toolu_P'}));
    expect(external.listCalls, before + 1);
    expect(openedCards.single.kind, PromptKind.plan);
    expect(lastState(), SessionState.waitingPlan);

    // A session nobody lists: looked up once, then ignored for a moment.
    final calls = external.listCalls;
    await fire({...hook('Stop'), 'session_id': 'aaaaaaaa-0000-4000-8000-00000000000f'});
    await fire({...hook('Stop'), 'session_id': 'aaaaaaaa-0000-4000-8000-00000000000f'});
    expect(external.listCalls, calls + 1);
  });

  test('permission_hook_takes_the_transcript_id_and_the_always_option_from_the_screen', () async {
    listing();
    await manager.list();
    append(toolUse('toolu_W', 'Write', write));
    console.currentScreen = screen('permission_create.txt');
    await fire(hook('PermissionRequest', {
      'tool_name': 'Write',
      'tool_input': write,
      'permission_suggestions': [
        {'type': 'setMode', 'mode': 'acceptEdits', 'destination': 'session'}
      ]
    }));
    expect(opened, ['toolu_W']);
    expect(openedCards.single.kind, PromptKind.permission);
    expect(openedCards.single.suggestions, isNotEmpty);
    expect(console.actions.where((a) => a == 'screen'), hasLength(1));
    expect(lastState(), SessionState.waitingPermission);

    // The poll sees the same thing: no second card, nothing closed.
    listing(status: 'waiting', waitingFor: 'permission prompt');
    await manager.list();
    expect(opened, ['toolu_W']);
    expect(closed, isEmpty);

    // The tool result in the transcript closes it.
    append(toolResult('toolu_W', 'File created'));
    await waitUntil(() => closed.contains('toolu_W'));
  });

  test('permission_hook_before_the_transcript_has_the_tool_use_keeps_its_card', () async {
    listing();
    await manager.list();
    console.currentScreen = screen('idle.txt'); // not drawn yet
    await fire(hook('PermissionRequest', {'tool_name': 'Write', 'tool_input': write, 'permission_suggestions': []}));
    final id = opened.single;
    expect(id, startsWith('hook:'));
    expect(openedCards.single.suggestions, isEmpty);

    // The listing still says busy: the card stays (within the grace period).
    await manager.list();
    expect(closed, isEmpty);
    // The transcript catches up and the listing says waiting: still the same card.
    append(toolUse('toolu_W2', 'Write', write));
    listing(status: 'waiting', waitingFor: 'permission prompt');
    await manager.list();
    expect(opened, [id]);
    expect(closed, isEmpty);
    // Its tool result closes it.
    append(toolResult('toolu_W2', 'File created'));
    await waitUntil(() => closed.contains(id));
  });

  test('suggestions_from_claude_code_offer_always_when_the_dialog_is_not_drawn_yet', () async {
    listing();
    await manager.list();
    console.currentScreen = null;
    await fire(hook('PermissionRequest', {
      'tool_name': 'Bash',
      'tool_input': {'command': 'npm test'},
      'permission_suggestions': [
        {'type': 'addRules', 'behavior': 'allow', 'destination': 'localSettings'}
      ]
    }));
    expect(openedCards.single.suggestions, isNotEmpty);
  });

  test('another_tool_finishing_does_not_close_a_waiting_permission', () async {
    listing();
    await manager.list();
    append(toolUse('toolu_W', 'Write', write));
    await fire(hook('PermissionRequest', {'tool_name': 'Write', 'tool_input': write}));
    await fire(hook('PostToolUse', {
      'tool_name': 'Read',
      'tool_input': {'file_path': 'a.txt'},
      'tool_use_id': 'toolu_R',
      'tool_response': 'x'
    }));
    expect(closed, isEmpty);
    expect(lastState(), SessionState.waitingPermission);
  });

  test('stop_prompt_submit_and_session_end_close_the_card_and_set_the_state', () async {
    listing();
    await manager.list();
    await fire(hook('PreToolUse', {'tool_name': 'AskUserQuestion', 'tool_input': questions, 'tool_use_id': 'toolu_1'}));
    await fire(hook('Stop', {'stop_hook_active': false}));
    expect(closed, ['toolu_1']);
    expect(lastState(), SessionState.idle);

    await fire(hook('PreToolUse', {'tool_name': 'AskUserQuestion', 'tool_input': questions, 'tool_use_id': 'toolu_2'}));
    await fire(hook('UserPromptSubmit', {'prompt': 'never mind'}));
    expect(closed, ['toolu_1', 'toolu_2']);
    expect(lastState(), SessionState.working);

    await fire(hook('SubagentStart', {'agent_id': 'a1', 'agent_type': 'Explore'}));
    expect(lastState(), SessionState.working);
    // Seen live: a SubagentStop can follow the Stop of the turn; the session stays idle.
    await fire(hook('Stop'));
    await fire(hook('SubagentStop', {'agent_id': 'a1'}));
    expect(lastState(), SessionState.idle);

    await fire(hook('PreToolUse', {'tool_name': 'AskUserQuestion', 'tool_input': questions, 'tool_use_id': 'toolu_3'}));
    await fire(hook('SessionEnd', {'reason': 'other'}));
    expect(closed.last, 'toolu_3');
    final last = updates.where((u) => u.id == sid).last;
    expect(last.live, isFalse);
  });

  test('notifications_update_the_state', () async {
    listing();
    await manager.list();
    await fire(hook('Notification', {'notification_type': 'idle_prompt', 'message': 'Claude is waiting for your input'}));
    expect(lastState(), SessionState.idle);
    await fire(hook('Notification', {'notification_type': 'quota_exceeded', 'message': 'Usage limit reached'}));
    expect(lastState(), SessionState.blocked);
    // Paused by the machine's usage limit (its reset is not known from this message).
    expect(updates.last.reason, 'Usage limit');
    expect(manager.limits.current!.sessions.single.id, sid);
    expect(manager.history(sid).events.whereType<Notice>().map((n) => n.text), contains('Usage limit reached'));
  });

  test('poll_first_then_hook_gives_one_card', () async {
    append(toolUse('toolu_Q', 'AskUserQuestion', questions));
    listing(status: 'waiting', waitingFor: 'input needed');
    await manager.list();
    manager.history(sid);
    await manager.list();
    expect(opened, ['toolu_Q']);
    await fire(hook('PreToolUse', {'tool_name': 'AskUserQuestion', 'tool_input': questions, 'tool_use_id': 'toolu_Q'}));
    await settle();
    expect(opened, ['toolu_Q']);
    expect(closed, isEmpty);
  });

  test('a_card_opened_by_a_hook_is_answered_like_any_other', () async {
    listing();
    await manager.list();
    append(toolUse('toolu_W', 'Write', write));
    console.currentScreen = screen('permission_create.txt');
    await fire(hook('PermissionRequest', {'tool_name': 'Write', 'tool_input': write}));
    console.onAction = (a) {
      if (a == 'keys:1') console.currentScreen = screen('idle_after_deny.txt');
    };
    await manager.answerPrompt(sid, 'toolu_W', const PermissionAnswer(allow: true));
    await settle();
    expect(console.presses, ['keys:1']);
    expect(closed, ['toolu_W']);
    // A late duplicate of the hook does not reopen it.
    await fire(hook('PermissionRequest', {'tool_name': 'Write', 'tool_input': write}));
    expect(opened, ['toolu_W']);
  });

  test('hooks_without_required_fields_or_for_unknown_events_do_nothing', () async {
    listing();
    await manager.list();
    final n = updates.length;
    await fire({'hook_event_name': 'Stop'});
    await fire(hook('PreToolUse', {'tool_name': 'AskUserQuestion', 'tool_input': questions}));
    await fire(hook('SomethingNew'));
    expect(opened, isEmpty);
    expect(updates.length, n);
  });

  test('the_self_test_session_is_not_listed_and_its_hooks_do_nothing', () async {
    const stId = '99999999-0000-4000-8000-000000000009';
    final folder = r'C:\Users\someone\AppData\Roaming\perch\selftest';
    external.entries = [
      external.entry(pid: 4242, sessionId: sid, cwd: r'D:\projects\example', status: 'busy'),
      external.entry(pid: 5353, sessionId: stId, cwd: folder, status: 'busy', name: 'Perch self-test'),
    ];
    final listed = await manager.list();
    expect([for (final s in listed) s.id], [sid]);
    final n = updates.length;
    // By its folder, and by its session id even when a hook lacks the folder.
    await fire({...hook('PreToolUse', {'tool_name': 'AskUserQuestion', 'tool_input': questions, 'tool_use_id': 'toolu_S'}), 'session_id': stId, 'cwd': folder});
    await fire({'session_id': stId, 'hook_event_name': 'PermissionRequest'}); // fields missing: still not drift
    await fire({...hook('Notification', {'notification_type': 'quota_exceeded', 'message': 'limit'}), 'session_id': stId, 'cwd': folder});
    expect(opened, isEmpty);
    expect(updates.length, n);
    expect(manager.compatibility.current.status, isNot(CompatibilityStatus.drifted));
    expect(manager.summaryOf(stId), isNull);
  });

  test('answered_cards_and_a_clean_transcript_are_evidence_for_an_unchecked_version', () async {
    manager.compatibility.setVersion('2.1.340');
    listing();
    await manager.list();
    manager.history(sid); // reads the transcript: no unreadable lines
    expect(manager.compatibility.current.seenWorking, ['transcript']);
    append(toolUse('toolu_W', 'Write', write));
    console.currentScreen = screen('permission_create.txt');
    await fire(hook('PermissionRequest', {'tool_name': 'Write', 'tool_input': write}));
    console.onAction = (a) {
      if (a == 'keys:1') console.currentScreen = screen('idle_after_deny.txt');
    };
    await manager.answerPrompt(sid, 'toolu_W', const PermissionAnswer(allow: true));
    expect(manager.compatibility.current.seenWorking, ['permission', 'transcript']);
    // A card that could not be answered is no evidence.
    console.currentScreen = screen('idle_after_deny.txt');
    append(toolUse('toolu_P', 'ExitPlanMode', {'plan': 'x'}));
    await fire(hook('PreToolUse', {'tool_name': 'ExitPlanMode', 'tool_input': {'plan': 'x'}, 'tool_use_id': 'toolu_P'}));
    await expectLater(manager.answerPrompt(sid, 'toolu_P', const PlanAnswer(approve: true)), throwsA(anything));
    expect(manager.compatibility.current.seenWorking, isNot(contains('plan')));
  });

  test('hooks_for_a_session_perch_runs_itself_are_ignored', () async {
    console.supported = false;
    final s = await manager.start(cwd: tmp.path, prompt: 'slow');
    await waitUntil(() => manager.claudeSessionIdOf(s.id) != null);
    final claudeId = manager.claudeSessionIdOf(s.id)!;
    final calls = external.listCalls;
    await fire({...hook('Stop'), 'session_id': claudeId});
    expect(external.listCalls, calls);
    await manager.stop(s.id);
  });
}
