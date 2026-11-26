import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/claude_session.dart' show PromptAlreadyAnswered;
import 'package:perch_host/src/console_typer.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/terminal_prompts.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'ms_dialog.dart';

const sid = '22222222-3333-4444-8555-666666666666';
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

String title(String t) => jsonEncode({'type': 'ai-title', 'aiTitle': t, 'sessionId': sid});

Map<String, dynamic> q(String question, List<String> labels, {bool multi = false}) => {
      'question': question,
      'header': question.split(' ').last,
      'options': [for (final l in labels) {'label': l, 'description': l}],
      'multiSelect': multi,
    };

void main() {
  late Directory tmp;
  late Directory work;
  late File transcript;
  late FakeExternalSessions external;
  late FakeConsoleTyper console;
  late SessionManager manager;
  late List<String> opened;
  late List<String> closed;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_tp_');
    work = Directory('${tmp.path}${sep}work')..createSync();
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

  void append(String line) => transcript.writeAsStringSync('$line\n', mode: FileMode.append);

  void terminal({String status = 'waiting', String? waitingFor = 'permission prompt', String name = 'work-0f'}) {
    external.entries = [
      external.entry(pid: 4242, sessionId: sid, cwd: work.path, status: status, waitingFor: waitingFor, name: name)
    ];
  }

  /// Watches the session and returns its open card (after the host has looked at it).
  Future<PromptRequest?> card() async {
    await manager.list();
    manager.history(sid);
    await manager.list();
    final open = manager.history(sid).openPrompts;
    return open.isEmpty ? null : open.single;
  }

  /// Screens shown after each press, in order.
  void respond(Map<String, String> afterPress) {
    console.onAction = (a) {
      final next = afterPress[a];
      if (next != null) console.currentScreen = next;
    };
  }

  group('cards', () {
    test('permission_card_from_pending_tool_use_offers_always_only_when_the_terminal_does', () async {
      append(toolUse('toolu_W', 'Write', {'file_path': 'color.txt', 'content': 'Blue'}));
      terminal();
      console.currentScreen = screen('permission_create.txt');
      final p = (await card())!;
      expect(p.promptId, 'toolu_W');
      expect(p.kind, PromptKind.permission);
      expect(p.toolName, 'Write');
      expect(p.input['file_path'], 'color.txt');
      expect(p.suggestions, isNotEmpty);
      expect(opened, ['toolu_W']);
      expect((await manager.list()).single.openPrompts, 1);

      // The tool result closes the card.
      append(toolResult('toolu_W', 'File created'));
      await waitUntil(() => closed.contains('toolu_W'));
      expect(manager.history(sid).openPrompts, isEmpty);
    });

    test('permission_without_yes_and_has_no_suggestions', () async {
      append(toolUse('toolu_B', 'Bash', {'command': 'rm x'}));
      terminal();
      console.currentScreen = ' Do you want to proceed?\n ❯ 1. Yes\n   2. No\n Esc to cancel\n';
      expect((await card())!.suggestions, isEmpty);
    });

    test('question_and_plan_cards_and_none_when_not_waiting', () async {
      append(toolUse('toolu_Q', 'AskUserQuestion', {
        'questions': [q('Which color?', ['Red', 'Blue'])]
      }));
      terminal(status: 'idle', waitingFor: null);
      expect(await card(), isNull);
      terminal(waitingFor: 'input needed');
      final p = (await card())!;
      expect(p.kind, PromptKind.question);
      expect(p.input['questions'], hasLength(1));
      // Stops waiting (answered at the machine): closed.
      terminal(status: 'busy', waitingFor: null);
      await manager.list();
      expect(closed, ['toolu_Q']);

      append(toolResult('toolu_Q', 'answered'));
      append(toolUse('toolu_P', 'ExitPlanMode', {'plan': '# Plan'}));
      terminal();
      expect((await card())!.kind, PromptKind.plan);
    });

    test('trust_card_from_the_screen_when_no_tool_use_is_pending', () async {
      terminal();
      console.currentScreen = screen('trust.txt');
      final p = (await card())!;
      expect(p.toolName, trustFolderTool);
      expect(p.input, {'path': work.path});
      expect(p.kind, PromptKind.permission);
    });

    test('terminal_session_uses_ai_title_when_present', () async {
      append(title('Paint the fence blue'));
      append(title('Fence colour change'));
      terminal(status: 'idle', waitingFor: null, name: 'work-0f');
      // Listed only (not watched): the title comes from the end of the transcript.
      expect((await manager.list()).single.name, 'Fence colour change');
      // Without a title: the listing's name.
      transcript.writeAsStringSync('');
      expect((await manager.list()).single.name, 'work-0f');
    });
  });

  group('cards from the screen', () {
    test('question_step_permission_plan_and_review_are_read_from_the_screen', () {
      final first = screenPrompt(screen('question_multi_first.txt'), 's')!;
      expect(first.kind, PromptKind.question);
      final q1 = (first.input['questions'] as List).single as Map;
      expect(q1['question'], 'Which color?');
      expect([for (final o in q1['options'] as List) (o as Map)['label']], ['Red', 'Blue']);
      expect(q1['multiSelect'], isFalse);

      final multi = (screenPrompt(screen('multiselect.txt'), 's')!.input['questions'] as List).single as Map;
      expect(multi['question'], 'Which fruits?');
      expect(multi['multiSelect'], isTrue);
      expect([for (final o in multi['options'] as List) (o as Map)['label']], ['Apple', 'Banana', 'Cherry']);

      final review = (screenPrompt(screen('question_multi_review.txt'), 's')!.input['questions'] as List).single as Map;
      expect(review['question'], contains('Ready to submit your answers?'));
      expect([for (final o in review['options'] as List) (o as Map)['label']], ['Submit answers', 'Cancel']);

      final perm = screenPrompt(screen('permission_real.txt'), 's')!;
      expect(perm.toolName, 'Write');
      expect(perm.input['file_path'], 'hello.txt');
      expect(perm.input['description'], contains('Do you want to create hello.txt?'));
      expect(perm.suggestions, isNotEmpty);

      final plan = screenPrompt(screen('plan.txt'), 's')!;
      expect(plan.kind, PromptKind.plan);
      expect(plan.input['plan'], startsWith('Plan: create hello.txt'));

      // 2.1.327: leaving plan mode without a plan; the card must not take the
      // conversation above the dialog for the plan.
      final noPlan = screenPrompt(screen('plan_exit_no_plan_2_1_327.txt'), 's')!;
      expect(noPlan.kind, PromptKind.plan);
      expect(noPlan.input['plan'], 'Claude wants to exit plan mode');

      expect(screenPrompt(screen('idle_after_deny.txt'), 's'), isNull);
      // The same screen gives the same card id; the next step a new one.
      expect(screenPrompt(screen('question_multi_first.txt'), 's')!.promptId, first.promptId);
      expect(screenPrompt(screen('question_multi_second.txt'), 's')!.promptId, isNot(first.promptId));
    });

    test('waiting_without_tool_use_in_transcript_gets_a_screen_card_answered_step_by_step', () async {
      terminal(waitingFor: 'input needed');
      console.currentScreen = screen('question_multi_first.txt');
      final p = (await card())!;
      expect(p.input['fromScreen'], isTrue);
      respond({'keys:2': screen('question_multi_second.txt')});
      await manager.answerPrompt(sid, p.promptId, const QuestionAnswer({'Which color?': 'Blue'}));
      expect(console.presses, ['keys:2']);
      // The next step is a new card.
      final next = (await card())!;
      expect(((next.input['questions'] as List).single as Map)['question'], 'Which animal?');
    });

    test('a_set_answered_from_the_screen_keeps_screen_cards_when_the_transcript_catches_up', () async {
      terminal(waitingFor: 'input needed');
      console.currentScreen = screen('question_multi_first.txt');
      final p = (await card())!;
      respond({'keys:2': screen('question_multi_second.txt')});
      await manager.answerPrompt(sid, p.promptId, const QuestionAnswer({'Which color?': 'Blue'}));
      // Now the transcript has the whole set; the terminal shows its second question.
      append(toolUse('toolu_Q', 'AskUserQuestion', {
        'questions': [
          q('Which color?', ['Red', 'Blue']),
          q('Which animal?', ['Cat', 'Dog'])
        ]
      }));
      final second = (await card())!;
      expect(second.input['fromScreen'], isTrue);
      expect(((second.input['questions'] as List).single as Map)['question'], 'Which animal?');
      // The review step lists both questions: still the screen's step.
      console.currentScreen = screen('question_multi_review.txt');
      final review = (await card())!;
      expect(review.input['fromScreen'], isTrue);
      expect(((review.input['questions'] as List).single as Map)['question'], contains('Ready to submit'));
      // At the first question the transcript's card (the whole set) is used, as before.
      console.currentScreen = screen('question_multi_first.txt');
      expect((await card())!.promptId, 'toolu_Q');
    });

    test('screen_multi_select_step_ticks_and_moves_right', () async {
      terminal(waitingFor: 'input needed');
      console.currentScreen = screen('multiselect.txt');
      final p = (await card())!;
      console.onAction = (a) {
        if (a == 'keys:3') console.currentScreen = screen('multiselect_checked.txt');
        if (a == 'keys:${ConsoleKeys.right}') console.currentScreen = screen('multiselect_review.txt');
      };
      await manager.answerPrompt(sid, p.promptId, const QuestionAnswer({'Which fruits?': 'Apple, Cherry'}));
      expect(console.presses, ['keys:1', 'keys:3', 'keys:${ConsoleKeys.right}']);
    });
  });

  group('answers', () {
    Future<PromptRequest> permission() async {
      append(toolUse('toolu_W', 'Write', {'file_path': 'color.txt', 'content': 'Blue'}));
      terminal();
      console.currentScreen = screen('permission_create.txt');
      return (await card())!;
    }

    test('allow_presses_yes', () async {
      final p = await permission();
      respond({'keys:1': screen('idle_after_deny.txt')});
      await manager.answerPrompt(sid, p.promptId, const PermissionAnswer(allow: true));
      expect(console.presses, ['keys:1']);
      await waitUntil(() => closed.contains('toolu_W'));
      // Already answered: a second answer is refused.
      await expectLater(manager.answerPrompt(sid, p.promptId, const PermissionAnswer(allow: true)),
          throwsA(isA<PromptAlreadyAnswered>()));
    });

    test('always_presses_yes_and', () async {
      final p = await permission();
      respond({'keys:2': screen('idle_after_deny.txt')});
      await manager.answerPrompt(sid, p.promptId, const PermissionAnswer(allow: true, always: true));
      expect(console.presses, ['keys:2']);
    });

    test('deny_with_reason_presses_no_then_types_the_reason', () async {
      final p = await permission();
      respond({'keys:3': screen('idle_after_deny.txt')});
      await manager.answerPrompt(sid, p.promptId, const PermissionAnswer(allow: false, message: 'Use green'));
      expect(console.presses, ['keys:3', 'type:Use green']);
    });

    test('single_question_presses_the_option_number', () async {
      append(toolUse('toolu_Q', 'AskUserQuestion', {
        'questions': [q('Which color?', ['Red', 'Blue'])]
      }));
      terminal(waitingFor: 'input needed');
      console.currentScreen = screen('question_single.txt');
      final p = (await card())!;
      respond({'keys:2': screen('idle_after_deny.txt')});
      await manager.answerPrompt(sid, p.promptId, const QuestionAnswer({'Which color?': 'Blue'}));
      expect(console.presses, ['keys:2']);
    });

    test('other_answer_chooses_type_something_then_types_and_enters', () async {
      append(toolUse('toolu_S', 'AskUserQuestion', {
        'questions': [q('Which size?', ['Small', 'Large'])]
      }));
      terminal(waitingFor: 'input needed');
      console.currentScreen = screen('question_single_real.txt');
      final p = (await card())!;
      respond({
        'keys:3': screen('question_other_chosen.txt'),
        'keys:Medium': screen('question_other_typed.txt'),
        'enter': screen('idle_after_deny.txt'),
      });
      await manager.answerPrompt(sid, p.promptId, const QuestionAnswer({'Which size?': 'Medium'}));
      expect(console.presses, ['keys:3', 'keys:Medium', 'enter']);
    });

    test('question_set_answers_each_then_submits', () async {
      append(toolUse('toolu_M', 'AskUserQuestion', {
        'questions': [
          q('Which color?', ['Red', 'Blue']),
          q('Which animal?', ['Cat', 'Dog'])
        ]
      }));
      terminal(waitingFor: 'input needed');
      console.currentScreen = screen('question_multi_first.txt');
      final p = (await card())!;
      var reviewShown = false;
      console.onAction = (a) {
        if (a == 'keys:1' && !reviewShown && console.currentScreen == screen('question_multi_first.txt')) {
          console.currentScreen = screen('question_multi_second.txt');
        } else if (a == 'keys:2') {
          console.currentScreen = screen('question_multi_review.txt');
          reviewShown = true;
        } else if (a == 'keys:1' && reviewShown) {
          console.currentScreen = screen('idle_after_deny.txt');
        }
      };
      await manager.answerPrompt(sid, p.promptId, const QuestionAnswer({'Which color?': 'Red', 'Which animal?': 'Dog'}));
      expect(console.presses, ['keys:1', 'keys:2', 'keys:1']);
    });

    // REAL, 2.1.332 Mac: options with long descriptions in a 16-row Terminal window; the
    // question text, the tab row and option 1 have scrolled off the top.
    String tall(List<String> labels) => screen('question_tall_2_1_332.txt')
        .replaceAll('2. Green', '2. ${labels[1]}')
        .replaceAll('3. Red', '3. ${labels[2]}');
    const colours = ['Blue', 'Green', 'Red'];
    const fruits = ['Apple', 'Mango', 'Strawberry'];
    const seasons = ['Spring', 'Summer', 'Autumn'];

    test('a_set_taller_than_the_terminal_is_answered_by_its_options', () async {
      append(toolUse('toolu_T', 'AskUserQuestion', {
        'questions': [
          q('What is your favourite colour?', colours),
          q('What is your favourite fruit?', fruits),
          q('What is your favourite season?', seasons),
        ]
      }));
      terminal(waitingFor: 'input needed');
      console.currentScreen = tall(colours);
      final p = (await card())!;
      var step = 0;
      console.onAction = (a) {
        if (!a.startsWith('keys:')) return;
        step++;
        console.currentScreen = switch (step) {
          1 => tall(fruits),
          2 => tall(seasons),
          3 => screen('question_multi_review.txt'),
          _ => screen('idle_after_deny.txt'),
        };
      };
      await manager.answerPrompt(
          sid,
          p.promptId,
          const QuestionAnswer({
            'What is your favourite colour?': 'Blue', // option 1: out of sight
            'What is your favourite fruit?': 'Mango',
            'What is your favourite season?': 'Autumn',
          }));
      expect(console.presses, ['keys:1', 'keys:2', 'keys:3', 'keys:1']);
    });

    test('a_tall_set_whose_visible_options_fit_two_questions_types_nothing', () async {
      append(toolUse('toolu_U', 'AskUserQuestion', {
        'questions': [
          q('Colour for the walls?', colours),
          q('Colour for the door?', colours),
        ]
      }));
      terminal(waitingFor: 'input needed');
      console.currentScreen = tall(colours);
      final p = (await card())!;
      await expectLater(
          manager.answerPrompt(
              sid, p.promptId, const QuestionAnswer({'Colour for the walls?': 'Red', 'Colour for the door?': 'Blue'})),
          throwsA(isA<CannotAnswerInTerminal>()));
      expect(console.presses, isEmpty);
    });

    test('multi_select_ticks_choices_moves_right_and_submits', () async {
      append(toolUse('toolu_F', 'AskUserQuestion', {
        'questions': [
          q('Which fruits?', ['Apple', 'Banana', 'Cherry'], multi: true)
        ]
      }));
      terminal(waitingFor: 'input needed');
      console.currentScreen = screen('multiselect.txt');
      final p = (await card())!;
      console.onAction = (a) {
        if (a == 'keys:3') console.currentScreen = screen('multiselect_checked.txt');
        if (a == 'keys:${ConsoleKeys.right}') console.currentScreen = screen('multiselect_review.txt');
        if (a == 'keys:1' && console.currentScreen == screen('multiselect_review.txt')) {
          console.currentScreen = screen('idle_after_deny.txt');
        }
      };
      await manager.answerPrompt(sid, p.promptId, const QuestionAnswer({'Which fruits?': 'Apple, Cherry'}));
      expect(console.presses, ['keys:1', 'keys:3', 'keys:${ConsoleKeys.right}', 'keys:1']);
    });

    test('plan_approve_and_keep_planning_with_feedback', () async {
      append(toolUse('toolu_P', 'ExitPlanMode', {'plan': '# Plan'}));
      terminal();
      console.currentScreen = screen('plan.txt');
      var p = (await card())!;
      respond({
        'keys:3': screen('plan.txt').replaceFirst('❯ 1.', '  1.').replaceFirst('   3. Tell', ' ❯ 3. Tell'),
        'keys:Say hello': screen('plan_feedback_typed.txt'),
        'enter': screen('idle_after_deny.txt'),
      });
      await manager.answerPrompt(sid, p.promptId, const PlanAnswer(approve: false, feedback: 'Say hello'));
      expect(console.presses, ['keys:3', 'keys:Say hello', 'enter']);

      append(toolResult('toolu_P', 'rejected'));
      append(toolUse('toolu_P2', 'ExitPlanMode', {'plan': '# Plan 2'}));
      console
        ..actions.clear()
        ..currentScreen = screen('plan.txt');
      p = (await card())!;
      respond({'keys:1': screen('idle_after_deny.txt')});
      await manager.answerPrompt(sid, p.promptId, const PlanAnswer(approve: true));
      expect(console.presses, ['keys:1']);
    });

    test('plan_without_a_plan_2_1_327_approve_presses_yes_and_keep_planning_presses_no_then_types', () async {
      append(toolUse('toolu_Q', 'ExitPlanMode', {}));
      terminal();
      console.currentScreen = screen('plan_exit_no_plan_2_1_327.txt');
      var p = (await card())!;
      respond({'keys:1': screen('idle_after_deny.txt')});
      await manager.answerPrompt(sid, p.promptId, const PlanAnswer(approve: true));
      expect(console.presses, ['keys:1']);

      append(toolResult('toolu_Q', 'ok'));
      append(toolUse('toolu_Q2', 'ExitPlanMode', {}));
      console
        ..actions.clear()
        ..currentScreen = screen('plan_exit_no_plan_2_1_327.txt');
      p = (await card())!;
      respond({'keys:2': screen('idle_after_deny.txt')});
      await manager.answerPrompt(sid, p.promptId, const PlanAnswer(approve: false, feedback: 'Plan more'));
      expect(console.presses.first, 'keys:2');
    });

    test('trust_allow_moves_down_presses_enter_then_types_the_first_instruction', () async {
      console.currentScreen = screen('trust.txt');
      onWindow(l) => external.entries.add(external.entry(pid: 4242, sessionId: sid, cwd: work.path));
      final m = SessionManager(
        launcher: fakeLauncher(),
        external: external,
        typer: console,
        claudeConfigDir: '${tmp.path}${sep}config',
        openWindow: (l) async => onWindow(l),
        terminalStartTimeout: const Duration(milliseconds: 300),
        terminalPoll: const Duration(milliseconds: 5),
        answerPoll: const Duration(milliseconds: 5),
        answerTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(m.dispose);
      final s = await m.start(cwd: work.path, prompt: 'Say hi');
      expect(s.state, SessionState.blocked);
      await m.list();
      final p = m.history(sid).openPrompts.isNotEmpty ? m.history(sid).openPrompts.single : null;
      await m.list();
      final card = p ?? m.history(sid).openPrompts.single;
      expect(card.toolName, trustFolderTool);
      final trusted = screen('trust.txt').replaceFirst(' ❯ No, exit', '   No, exit').replaceFirst(
          '   Yes, I trust this folder', ' ❯ Yes, I trust this folder');
      respond({'keys:${ConsoleKeys.down}': trusted, 'enter': screen('idle_after_deny.txt')});
      await m.answerPrompt(sid, card.promptId, const PermissionAnswer(allow: true));
      expect(console.presses, ['keys:${ConsoleKeys.down}', 'enter', 'type:Say hi']);
      expect((await m.list()).single.state, isNot(SessionState.blocked));
    });
  });

  group('multi-select with a typed answer', () {
    // Without '\r': the fixtures may be checked out with Windows line ends.
    final fruitTop = screen('ms_other_start.txt').replaceAll('\r\n', '\n').split('\n').take(5).toList();
    final setTop = screen('ms_set_first.txt').replaceAll('\r\n', '\n').split('\n').take(3).toList();
    MsDialog fruit() => MsDialog(top: fruitTop, questions: [
          MsQuestion('Which fruits?', 'Fruit', ['Apple', 'Banana', 'Cherry'])
        ]);
    MsDialog fruitAndPets() => MsDialog(top: setTop, nav: 'Tab/Arrow keys to navigate', questions: [
          MsQuestion('Which fruits?', 'Fruit', ['Apple', 'Banana', 'Cherry']),
          MsQuestion('Which pets?', 'Pets', ['Cat', 'Dog', 'Fish']),
        ]);

    /// Lets [d] answer every key press, and shows its screen.
    void drive(MsDialog d) {
      console.currentScreen = d.screen();
      console.onAction = (a) {
        d.apply(a);
        console.currentScreen = d.screen();
      };
    }

    test('the_simulated_dialog_draws_the_screens_seen_live', () {
      // Checked out with Windows line ends or not, the screens compare line by line.
      String screen(String name) => File('test${sep}fixtures${sep}screens$sep$name').readAsStringSync().replaceAll('\r\n', '\n');
      final d = fruit();
      expect(d.screen(), screen('ms_other_start.txt'));
      d.apply('keys:13');
      expect(d.screen(), screen('ms_other_ticked.txt'));
      d.apply('keys:${ConsoleKeys.down * 3}');
      expect(d.screen(), screen('ms_other_cursor.txt'));
      d.apply('keys:Mango');
      expect(d.screen(), screen('ms_other_typed.txt'));
      d.apply('keys:${ConsoleKeys.down}');
      expect(d.screen(), screen('ms_other_submit_row.txt'));
      d.apply('enter');
      expect(d.screen(), screen('ms_other_review.txt'));
      final s = fruitAndPets();
      expect(s.screen(), screen('ms_set_first.txt'));
      s.apply('keys:${ConsoleKeys.down * 3}Kiwi');
      expect(s.screen(), screen('ms_set_first_typed.txt'));
      s.apply('keys:${ConsoleKeys.down}');
      s.apply('enter');
      expect(s.screen(), screen('ms_set_second.txt'));
      s.apply('keys:12${ConsoleKeys.down * 3}Parrot${ConsoleKeys.down}');
      s.apply('enter');
      expect(s.screen(), screen('ms_set_review.txt'));
    });

    test('ticks_then_types_the_other_answer_then_submits', () async {
      append(toolUse('toolu_F', 'AskUserQuestion', {
        'questions': [
          q('Which fruits?', ['Apple', 'Banana', 'Cherry'], multi: true)
        ]
      }));
      terminal(waitingFor: 'input needed');
      final d = fruit();
      drive(d);
      final p = (await card())!;
      await manager.answerPrompt(sid, p.promptId, const QuestionAnswer({'Which fruits?': 'Apple, Cherry, Mango'}));
      final down = ConsoleKeys.down;
      expect(console.presses, ['keys:1', 'keys:3', 'keys:${down * 3}', 'keys:Mango', 'keys:$down', 'enter', 'keys:1']);
      expect(d.submitted, isTrue);
      expect(d.answerOf(0), 'Apple, Cherry, Mango');
    });

    test('other_only_and_ticks_plus_other_in_a_question_set', () async {
      append(toolUse('toolu_S', 'AskUserQuestion', {
        'questions': [
          q('Which fruits?', ['Apple', 'Banana', 'Cherry'], multi: true),
          q('Which pets?', ['Cat', 'Dog', 'Fish'], multi: true),
        ]
      }));
      terminal(waitingFor: 'input needed');
      final d = fruitAndPets();
      drive(d);
      final p = (await card())!;
      await manager.answerPrompt(
          sid, p.promptId, const QuestionAnswer({'Which fruits?': 'Kiwi', 'Which pets?': 'Cat, Dog, Parrot'}));
      expect(d.submitted, isTrue);
      expect([d.answerOf(0), d.answerOf(1)], ['Kiwi', 'Cat, Dog, Parrot']);
      final down = ConsoleKeys.down;
      expect(console.presses, [
        'keys:${down * 3}', 'keys:Kiwi', 'keys:$down', 'enter', //
        'keys:1', 'keys:2', 'keys:${down * 3}', 'keys:Parrot', 'keys:$down', 'enter', //
        'keys:1',
      ]);
    });

    test('a_screen_card_step_with_other_text_is_typed_too', () async {
      terminal(waitingFor: 'input needed');
      final d = fruit();
      drive(d);
      final p = (await card())!;
      expect(p.input['fromScreen'], isTrue);
      await manager.answerPrompt(sid, p.promptId, const QuestionAnswer({'Which fruits?': 'Banana, Mango'}));
      expect(d.reviewing, isTrue);
      expect(d.answerOf(0), 'Banana, Mango');
    });

    test('nothing_is_typed_when_the_terminal_offers_no_typed_answer', () async {
      append(toolUse('toolu_F', 'AskUserQuestion', {
        'questions': [
          q('Which fruits?', ['Apple', 'Banana', 'Cherry'], multi: true)
        ]
      }));
      terminal(waitingFor: 'input needed');
      console.currentScreen = screen('ms_other_start.txt').replaceFirst('4. [ ] Type something', '4. [ ] Something else');
      final p = (await card())!;
      await expectLater(manager.answerPrompt(sid, p.promptId, const QuestionAnswer({'Which fruits?': 'Apple, Mango'})),
          throwsA(isA<CannotAnswerInTerminal>()));
      expect(console.presses, isEmpty);
    });

    test('stops_when_the_text_does_not_appear', () async {
      append(toolUse('toolu_F', 'AskUserQuestion', {
        'questions': [
          q('Which fruits?', ['Apple', 'Banana', 'Cherry'], multi: true)
        ]
      }));
      terminal(waitingFor: 'input needed');
      final d = fruit();
      drive(d);
      final p = (await card())!;
      // The dialog swallows the text: Perch must not press Enter.
      console.onAction = (a) {
        if (!a.startsWith('keys:Mango')) d.apply(a);
        console.currentScreen = d.screen();
      };
      await expectLater(manager.answerPrompt(sid, p.promptId, const QuestionAnswer({'Which fruits?': 'Apple, Mango'})),
          throwsA(isA<CannotAnswerInTerminal>()));
      expect(console.presses, isNot(contains('enter')));
      expect(console.presses.last, 'keys:Mango');
    });

    test('answer_is_split_into_ticked_labels_and_typed_text', () {
      const labels = ['Apple', 'Banana', 'Cherry, ripe'];
      String split(String a) {
        final r = splitMultiSelectAnswer(labels, a);
        return '${([...r.chosen]..sort()).join(' | ')} + ${r.other}';
      }

      expect(split('Apple, Cherry, ripe, Mango'), 'Apple | Cherry, ripe + Mango');
      expect(split('Kiwi'), ' + Kiwi');
      expect(split('Banana'), 'Banana + ');
      expect(split('Banana, Apple'), 'Apple | Banana + ');
      expect(split('Apple, a, b'), 'Apple + a, b');
    });
  });

  group('cannot answer', () {
    Future<PromptRequest> permission() async {
      append(toolUse('toolu_W', 'Write', {'file_path': 'color.txt'}));
      terminal();
      console.currentScreen = screen('permission_create.txt');
      return (await card())!;
    }

    Future<void> expectRefused(PromptRequest p, PromptAnswer a) async {
      await expectLater(manager.answerPrompt(sid, p.promptId, a), throwsA(isA<CannotAnswerInTerminal>()));
    }

    test('unreadable_screen_types_nothing', () async {
      final p = await permission();
      console.currentScreen = null;
      await expectRefused(p, const PermissionAnswer(allow: true));
      expect(console.presses, isEmpty);
      expect(manager.history(sid).openPrompts, hasLength(1)); // the card stays
    });

    test('dialog_already_gone_types_nothing', () async {
      final p = await permission();
      console.currentScreen = screen('idle_after_deny.txt');
      await expectRefused(p, const PermissionAnswer(allow: true));
      expect(console.presses, isEmpty);
    });

    test('unexpected_dialog_types_nothing', () async {
      final p = await permission();
      console.currentScreen = screen('question_single.txt');
      await expectRefused(p, const PermissionAnswer(allow: true));
      expect(console.presses, isEmpty);
    });

    test('option_not_offered_types_nothing', () async {
      final p = await permission();
      console.currentScreen = ' Do you want to proceed?\n ❯ 1. Yes\n   2. No\n Esc to cancel\n';
      await expectRefused(p, const PermissionAnswer(allow: true, always: true));
      expect(console.presses, isEmpty);
    });

    test('wrong_question_on_screen_types_nothing', () async {
      append(toolUse('toolu_Q', 'AskUserQuestion', {
        'questions': [q('Which animal?', ['Cat', 'Dog'])]
      }));
      terminal(waitingFor: 'input needed');
      console.currentScreen = screen('question_multi_first.txt'); // shows "Which color?"
      final p = (await card())!;
      await expectRefused(p, const QuestionAnswer({'Which animal?': 'Cat'}));
      expect(console.presses, isEmpty);
    });

    test('dialog_that_does_not_move_on_is_reported', () async {
      final p = await permission();
      await expectRefused(p, const PermissionAnswer(allow: true)); // screen never changes
      expect(console.presses, ['keys:1']);
      expect(manager.history(sid).openPrompts, hasLength(1));
    });
  });

  group('which step of a question set the terminal shows', () {
    final questions = [
      {'question': 'Which color?'},
      {'question': 'Which animal?'},
    ];
    String without(String s, bool Function(String) drop) =>
        s.replaceAll('\r', '').split('\n').where((l) => !drop(l)).join('\n');

    test('the first step, the second step, the review', () {
      expect(laterQuestionStep(screen('question_multi_first.txt'), questions), isFalse);
      expect(laterQuestionStep(screen('question_multi_second.txt'), questions), isTrue);
      expect(laterQuestionStep(screen('question_multi_review.txt'), questions), isTrue);
    });

    test('a first step whose question scrolled off the top is still the first step (the set comes whole)', () {
      final scrolled = without(screen('question_multi_first.txt'), (l) => l.trim() == 'Which color?');
      expect(laterQuestionStep(scrolled, questions), isFalse);
      // Tab row gone too: nothing proves a later step.
      final more = without(scrolled, (l) => l.trim().startsWith('←'));
      expect(laterQuestionStep(more, questions), isFalse);
    });

    test('with the tab row out of sight, a later question on screen counts', () {
      final second = without(screen('question_multi_second.txt'), (l) => l.trim().startsWith('←'));
      expect(laterQuestionStep(second, questions), isTrue);
    });
  });
}
