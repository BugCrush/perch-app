import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/ui/conversation.dart' show laidOut;
import 'package:perch_app/src/ui/session_screen.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'fakes.dart';
import 'glass_harness.dart';

void main() {
  late FakeChannels channels;
  late HostConnection conn;

  setUp(() => channels = FakeChannels());
  tearDown(() => conn.dispose());

  /// Opens the screen for session `s1` with the given state, origin and events.
  Future<void> open(WidgetTester tester,
      {SessionState state = SessionState.idle,
      SessionOrigin origin = SessionOrigin.perch,
      List<ConversationEvent> events = const [],
      bool hasEarlier = false,
      String? alias,
      void Function(BuildContext context, HostConnection connection, String cwd)? openPerch}) async {
    conn = HostConnection(testMachine(id: 'm', label: 'Desk', lan: ['10.0.0.1:8787'], alias: alias),
        channelFactory: channels.factory);
    conn.connect();
    channels.last.send(welcome);
    channels.last.send(Sessions(sessions: [summary('s1', name: 'Fix login', state: state, origin: origin)]));
    await tester.runAsync(() => eventually(() => conn.link.value == LinkState.online && conn.sessions.value.isNotEmpty));
    tallPhone(tester, height: 2340);
    await tester.pumpWidget(glassApp(openPerch == null
        ? SessionScreen(connection: conn, sessionId: 's1')
        : SessionScreen(connection: conn, sessionId: 's1', openPerch: openPerch)));
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<Subscribe>().isNotEmpty));
    channels.last.send(Events(sessionId: 's1', events: events, hasEarlier: hasEarlier));
    await tester.runAsync(() => pump(30));
    await tester.pumpAndSettle();
  }

  List<ClientMessage> sent() => channels.last.messages.where((m) => m is! Hello && m is! Subscribe && m is! FocusSession).toList();

  Future<void> hostSends(WidgetTester tester, HostMessage m) async {
    channels.last.send(m);
    await tester.runAsync(() => pump(30));
    await tester.pumpAndSettle();
  }

  Future<void> settleFrames(WidgetTester tester) async {
    await tester.runAsync(() => pump(30));
    await tester.pumpAndSettle();
  }

  Finder composer() => find.descendant(of: find.byKey(const ValueKey('composer')), matching: find.byType(TextField));

  Future<void> sendText(WidgetTester tester, String text) async {
    await tester.enterText(composer(), text);
    await tester.tap(find.byKey(const ValueKey('send')));
    await settleFrames(tester);
  }


  testWidgets('renders_each_event_kind', (tester) async {
    await open(tester, events: [
      UserMessage('Please list files', seq: 1),
      AssistantText('Here is **the** list', seq: 2),
      ToolCall('t1', 'Bash', {'command': 'ls -la', 'description': 'List'}, seq: 3),
      ToolResult('t1', 'a.txt', seq: 4),
      TurnEnded(isError: true, text: 'Interrupted', seq: 5),
      Notice('Continued on phone. To take it back, run claude --resume in the terminal.', seq: 6),
    ]);
    expect(find.text('Please list files'), findsOneWidget);
    expect(find.textContaining('Here is', findRichText: true), findsWidgets);
    expect(find.text('Bash · ls -la'), findsOneWidget);
    expect(find.textContaining('Interrupted'), findsOneWidget);
    expect(find.text('— Continued on phone. To take it back, run claude --resume in the terminal. —'), findsOneWidget);
    expect(find.text('a.txt'), findsNothing); // collapsed
    expect(find.text('Fix login'), findsOneWidget);
  });

  testWidgets('tool_call_expands_to_show_result', (tester) async {
    await open(tester, events: [
      ToolCall('t1', 'Read', {'file_path': r'D:\x\notes.txt'}, seq: 1),
      ToolResult('t1', 'hello from the file', seq: 2),
    ]);
    expect(find.text(r'Read · D:\x\notes.txt'), findsOneWidget);
    await tester.tap(find.text(r'Read · D:\x\notes.txt'));
    await tester.pumpAndSettle();
    expect(find.text('hello from the file'), findsOneWidget);
    expect(find.textContaining('"file_path"'), findsOneWidget);
  });

  testWidgets('subagent_events_are_grouped_under_their_header', (tester) async {
    await open(tester, events: [
      ToolCall('toolu_A', 'Agent', {'description': 'Count files in current directory'}, seq: 1),
      SubagentStarted('task1', 'toolu_A', 'Count files in current directory', 'general-purpose', seq: 2),
      UserMessage('Count the files.', seq: 3, parentToolUseId: 'toolu_A'),
      AssistantText('Main session text', seq: 4),
      AssistantText('There are 3 files', seq: 5, parentToolUseId: 'toolu_A'),
    ]);
    const header = 'Subagent · general-purpose';
    expect(find.text(header), findsOneWidget);
    expect(find.text('Count files in current directory'), findsOneWidget);
    final headerY = tester.getTopLeft(find.text(header)).dy;
    final subY = tester.getTopLeft(find.text('Count the files.')).dy;
    final sub2Y = tester.getTopLeft(find.textContaining('There are 3 files', findRichText: true).first).dy;
    final mainY = tester.getTopLeft(find.textContaining('Main session text', findRichText: true).first).dy;
    expect(subY, greaterThan(headerY));
    expect(sub2Y, greaterThan(subY));
    expect(mainY, greaterThan(sub2Y)); // the group is kept together where it started
    expect(tester.getTopLeft(find.text('Count the files.')).dx,
        greaterThan(tester.getTopLeft(find.textContaining('Main session text', findRichText: true).first).dx));
    await hostSends(tester, EventMessage(sessionId: 's1', event: SubagentFinished('task1', 'completed', seq: 6)));
    expect(find.text('$header · Finished'), findsOneWidget);
  });

  List<ConversationEvent> messages(int from, int to) => [for (var i = from; i <= to; i++) UserMessage('msg $i', seq: i)];

  testWidgets('latest_message_is_at_the_bottom', (tester) async {
    await open(tester, events: messages(301, 600), hasEarlier: true);
    expect(find.text('msg 600'), findsOneWidget);
    expect(find.text('msg 301'), findsNothing);
    final lastY = tester.getBottomLeft(find.text('msg 600')).dy;
    final composerY = tester.getTopLeft(composer()).dy;
    expect(lastY, lessThan(composerY));
    expect(composerY - lastY, lessThan(60)); // right above the composer, not mid-screen
    expect(find.text('Load earlier messages'), findsNothing);
  });

  testWidgets('load_earlier_prepends_and_keeps_position', (tester) async {
    await open(tester, events: messages(301, 600), hasEarlier: true);
    await tester.dragUntilVisible(find.text('Load earlier messages'), find.byType(Scrollable).first, const Offset(0, 600));
    await settleFrames(tester);
    if (sent().whereType<LoadEarlier>().isEmpty) {
      await tester.tap(find.text('Load earlier messages'));
      await settleFrames(tester);
    }
    final ask = sent().whereType<LoadEarlier>().single; // one request, even with the automatic load
    expect(ask.beforeSeq, 301);
    expect(ask.sessionId, 's1');
    final before = tester.getTopLeft(find.text('msg 301')).dy;

    await hostSends(tester, EarlierEvents(sessionId: 's1', events: messages(1, 300), hasEarlier: false));
    expect(tester.getTopLeft(find.text('msg 301')).dy, before); // did not jump
    expect(find.text('Load earlier messages'), findsNothing);
    await tester.dragUntilVisible(find.text('msg 299'), find.byType(Scrollable).first, const Offset(0, 300));
    expect(find.text('msg 299'), findsOneWidget);
    expect(sent().whereType<LoadEarlier>(), hasLength(1)); // nothing more to load
  });

  testWidgets('send_emits_sendMessage_and_clears_field', (tester) async {
    await open(tester);
    await sendText(tester, 'Now add tests');
    final m = sent().whereType<SendMessage>().single;
    expect(m.text, 'Now add tests');
    expect(m.sessionId, 's1');
    expect(tester.widget<TextField>(composer()).controller!.text, isEmpty);
  });

  testWidgets('stop_button_only_while_working_and_sends_interrupt', (tester) async {
    await open(tester, state: SessionState.idle);
    expect(find.byKey(const ValueKey('stop')), findsNothing);
    await hostSends(tester, SessionUpdated(session: summary('s1', name: 'Fix login', state: SessionState.working)));
    expect(find.text('Claude is working…'), findsOneWidget);
    expect(find.byKey(const ValueKey('stop')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stop')));
    await settleFrames(tester);
    expect(find.text('Stop Claude in Fix login?'), findsOneWidget);
    expect(find.textContaining('cut off mid-step'), findsOneWidget);
    expect(sent().whereType<Interrupt>(), isEmpty, reason: 'only after the confirmation');
    await tapDanger(tester, 'Stop');
    await settleFrames(tester);
    expect(sent().whereType<Interrupt>().single.sessionId, 's1');
  });

  testWidgets('composer_disabled_when_finished', (tester) async {
    await open(tester, state: SessionState.finished);
    expect(find.text('This session has ended'), findsOneWidget);
    expect(tester.widget<TextField>(composer()).enabled, isFalse);
  });

  testWidgets('truncated_result_shows_cut_notice', (tester) async {
    await open(tester, events: [
      ToolCall('t1', 'Bash', {'command': 'cat big.log'}, seq: 1),
      ToolResult('t1', 'x' * 100, truncated: true, seq: 2),
    ]);
    await tester.tap(find.text('Bash · cat big.log'));
    await tester.pumpAndSettle();
    expect(find.text('Output cut at 20,000 characters'), findsOneWidget);
  });

  testWidgets('empty_message_is_not_sent', (tester) async {
    await open(tester);
    await sendText(tester, '   ');
    expect(sent().whereType<SendMessage>(), isEmpty);
  });

  testWidgets('end_session_from_the_menu_asks_first', (tester) async {
    await open(tester, state: SessionState.working);
    await tapKey(tester, 'session-menu-button');
    expect(find.text('Interrupt'), findsOneWidget);
    await tester.tap(find.text('End session…'));
    await tester.pumpAndSettle();
    expect(find.text('End Fix login?'), findsOneWidget);
    expect(sent().whereType<StopSession>(), isEmpty);
    await tester.tap(dangerButton('End session'));
    await settleFrames(tester);
    expect(sent().whereType<StopSession>().single.sessionId, 's1');
  });

  testWidgets('external_send_goes_straight_through', (tester) async {
    await open(tester, origin: SessionOrigin.external, state: SessionState.working);
    await sendText(tester, 'Keep going');
    expect(find.text('Perch cannot type into this terminal'), findsNothing);
    expect(sent().single, isA<SendMessage>());
    expect((sent().single as SendMessage).text, 'Keep going');
    expect(tester.widget<TextField>(composer()).controller!.text, isEmpty);
  });

  testWidgets('cannot_type_offers_take_over', (tester) async {
    await open(tester, origin: SessionOrigin.external);
    await sendText(tester, 'Keep going');
    expect(sent().whereType<SendMessage>().single.text, 'Keep going');

    // Cancel sends nothing more.
    await hostSends(tester, const ErrorMessage(code: ErrorCodes.cannotType, message: 'Could not type'));
    const ask = 'Continue this session on your phone? It will close in the terminal on devbox. '
        'Run claude --resume there to take it back.';
    expect(find.text(ask), findsOneWidget);
    await tester.tap(button('Cancel'));
    await settleFrames(tester);
    expect(sent().length, 1);

    // Continue takes over (not forced) and sends the message again.
    await sendText(tester, 'Second try');
    await hostSends(tester, const ErrorMessage(code: ErrorCodes.cannotType, message: 'Could not type'));
    expect(find.text(ask), findsOneWidget);
    await tester.tap(button('Continue'));
    await settleFrames(tester);
    final after = sent().skip(2).toList();
    expect(after[0], isA<TakeOver>());
    expect((after[0] as TakeOver).force, isFalse);
    expect((after[1] as SendMessage).text, 'Second try');
  });

  testWidgets('take_over_dialog_and_terminal_error_use_the_alias', (tester) async {
    await open(tester, origin: SessionOrigin.external, state: SessionState.waitingPermission, alias: 'Big rig');
    await sendText(tester, 'Keep going');
    await hostSends(tester, const ErrorMessage(code: ErrorCodes.cannotType, message: 'Could not type'));
    expect(
        find.text('Continue this session on your phone? It will close in the terminal on Big rig. '
            'Run claude --resume there to take it back.'),
        findsOneWidget);
    await tester.tap(button('Cancel'));
    await settleFrames(tester);

    const p = PromptRequest(promptId: 'toolu_1', kind: PromptKind.permission, toolName: 'Bash', input: {'command': 'ls'});
    await hostSends(tester, const PromptOpened(sessionId: 's1', prompt: p));
    await tester.tap(find.text('Allow'));
    await settleFrames(tester);
    await hostSends(tester, const ErrorMessage(code: ErrorCodes.cannotAnswerInTerminal, message: 'Unexpected'));
    expect(find.text('Answer this one in the terminal on Big rig'), findsOneWidget);
  });

  testWidgets('session_busy_offers_force_takeover', (tester) async {
    await open(tester, origin: SessionOrigin.external, state: SessionState.working);
    await sendText(tester, 'Do this instead');
    await hostSends(tester, const ErrorMessage(code: ErrorCodes.cannotType, message: 'Could not type'));
    await tester.tap(button('Continue'));
    await settleFrames(tester);
    // The take-over and the message wait on it both report busy; one question is asked.
    await hostSends(tester, const ErrorMessage(code: ErrorCodes.sessionBusy, message: 'Claude is still working in the terminal'));
    await hostSends(tester, const ErrorMessage(code: ErrorCodes.sessionBusy, message: 'Claude is still working in the terminal'));
    expect(find.text('Claude is still working in the terminal. Stop it and continue here?'), findsOneWidget);
    await tester.tap(button('Stop and continue'));
    await settleFrames(tester);
    final after = sent().skip(3).toList();
    expect(after[0], isA<TakeOver>());
    expect((after[0] as TakeOver).force, isTrue);
    expect(after[1], isA<SendMessage>());
    expect((after[1] as SendMessage).text, 'Do this instead');
    expect(after.length, 2);
  });

  testWidgets('waiting_terminal_session_shows_continue_on_phone', (tester) async {
    await open(tester, origin: SessionOrigin.external, state: SessionState.waitingPermission);
    expect(find.text('Waiting for you in the terminal'), findsOneWidget);
    await tester.tap(find.text('Continue on phone'));
    await settleFrames(tester);
    final s = sent();
    expect(s[0], isA<TakeOver>());
    expect((s[0] as TakeOver).force, isTrue);
    expect((s[1] as SendMessage).text, 'please continue');
  });

  testWidgets('open_prompt_shows_its_card_and_answers', (tester) async {
    await open(tester, state: SessionState.waitingPermission);
    const p = PromptRequest(
        promptId: 'r1', kind: PromptKind.permission, toolName: 'Bash', input: {'command': 'rm -rf build'});
    await hostSends(tester, const PromptOpened(sessionId: 's1', prompt: p));
    expect(find.text('Claude wants to use Bash'), findsOneWidget);
    await tester.tap(find.text('Allow'));
    await settleFrames(tester);
    final a = sent().whereType<AnswerPrompt>().single;
    expect(a.promptId, 'r1');
    expect((a.answer as PermissionAnswer).allow, isTrue);
    await hostSends(tester, const PromptClosed(sessionId: 's1', promptId: 'r1'));
    expect(find.text('Claude wants to use Bash'), findsNothing);
  });

  testWidgets('already_answered_elsewhere_removes_the_card', (tester) async {
    await open(tester, state: SessionState.waitingPlan);
    const p = PromptRequest(promptId: 'r2', kind: PromptKind.plan, toolName: 'ExitPlanMode', input: {'plan': 'Do it'});
    await hostSends(tester, const PromptOpened(sessionId: 's1', prompt: p));
    expect(find.text('Approve'), findsOneWidget);
    await tester.tap(find.text('Approve'));
    await settleFrames(tester);
    await hostSends(tester, const ErrorMessage(code: ErrorCodes.promptAlreadyAnswered, message: 'Already answered'));
    expect(find.text('Already answered on another device'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
  });

  testWidgets('terminal_session_with_open_prompt_shows_the_card_not_the_banner', (tester) async {
    await open(tester, origin: SessionOrigin.external, state: SessionState.waitingPermission);
    const p = PromptRequest(
        promptId: 'toolu_1', kind: PromptKind.permission, toolName: 'Write', input: {'file_path': 'color.txt'});
    await hostSends(tester, const PromptOpened(sessionId: 's1', prompt: p));
    expect(find.text('Claude wants to use Write'), findsOneWidget);
    expect(find.text('Waiting for you in the terminal'), findsNothing);
    await tester.tap(find.text('Allow'));
    await settleFrames(tester);
    expect(sent().whereType<AnswerPrompt>().single.promptId, 'toolu_1');
  });

  testWidgets('terminal_question_and_plan_cards_show', (tester) async {
    await open(tester, origin: SessionOrigin.external, state: SessionState.waitingPlan);
    const plan = PromptRequest(promptId: 'toolu_p', kind: PromptKind.plan, toolName: 'ExitPlanMode', input: {'plan': 'Do it'});
    await hostSends(tester, const PromptOpened(sessionId: 's1', prompt: plan));
    expect(find.text('A PLAN TO APPROVE'), findsOneWidget);
    await hostSends(tester, const PromptClosed(sessionId: 's1', promptId: 'toolu_p'));
    const question = PromptRequest(promptId: 'toolu_q', kind: PromptKind.question, toolName: 'AskUserQuestion', input: {
      'questions': [
        {
          'question': 'Which color?',
          'header': 'Color',
          'options': [
            {'label': 'Red', 'description': ''},
            {'label': 'Blue', 'description': ''}
          ],
          'multiSelect': false
        }
      ]
    });
    await hostSends(tester, const PromptOpened(sessionId: 's1', prompt: question));
    expect(find.text('Which color?'), findsWidgets);
  });

  testWidgets('trust_prompt_shows_trust_card', (tester) async {
    await open(tester, origin: SessionOrigin.external, state: SessionState.blocked);
    const p = PromptRequest(
        promptId: 'trust:s1', kind: PromptKind.permission, toolName: 'TrustFolder', input: {'path': r'D:\projects\new'});
    await hostSends(tester, const PromptOpened(sessionId: 's1', prompt: p));
    expect(find.text('Trust this folder?'), findsOneWidget);
    expect(find.text(r'D:\projects\new'), findsOneWidget);
    await tester.tap(find.text("Don't trust"));
    await settleFrames(tester);
    final a = sent().whereType<AnswerPrompt>().single;
    expect((a.answer as PermissionAnswer).allow, isFalse);
  });

  testWidgets('cannot_answer_in_terminal_keeps_the_card_and_says_so', (tester) async {
    await open(tester, origin: SessionOrigin.external, state: SessionState.waitingPermission);
    const p = PromptRequest(
        promptId: 'toolu_1', kind: PromptKind.permission, toolName: 'Bash', input: {'command': 'ls'});
    await hostSends(tester, const PromptOpened(sessionId: 's1', prompt: p));
    await tester.tap(find.text('Allow'));
    await settleFrames(tester);
    await hostSends(tester, const ErrorMessage(code: ErrorCodes.cannotAnswerInTerminal, message: 'Unexpected'));
    expect(find.text('Answer this one in the terminal on devbox'), findsOneWidget);
    expect(find.text('Claude wants to use Bash'), findsOneWidget);
    // The card can be used again.
    await tester.tap(find.text('Allow'));
    await settleFrames(tester);
    expect(sent().whereType<AnswerPrompt>(), hasLength(2));
  });

  testWidgets('slash commands show as the owner\'s command with their output; tables as tables', (tester) async {
    await open(tester, events: [
      SlashCommand('/context', '', seq: 1),
      CommandOutput('## Context Usage\n\n| Category | Tokens |\n|---|---|\n| System prompt | 3.1k |', seq: 2),
      SlashCommand('/model', 'haiku', seq: 3),
      CommandOutput('Set model to haiku', seq: 4),
      CommandOutput('Unknown skill: nope', isError: true, seq: 5),
    ]);
    expect(find.text('/context'), findsOneWidget);
    expect(find.text('/model haiku'), findsOneWidget);
    expect(find.text('Set model to haiku'), findsOneWidget);
    expect(find.text('System prompt'), findsOneWidget, reason: 'the table is drawn as a table');
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('Unknown skill: nope'), findsOneWidget);
    expect(laidOut('Set model to haiku'), isFalse);
    expect(laidOut(List.filled(4, '${'⛶ ' * 20}  ⛁ System tools: 29.7k tokens (3.0%)').join('\n')), isTrue,
        reason: 'the /context grid stays in columns');
  });

  testWidgets('typing @ lists the folder\'s files, filtered as you type; a tap puts @path in the message', (tester) async {
    await open(tester);
    await tester.enterText(composer(), 'Read @');
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<ListFiles>().isNotEmpty));
    final ask = channels.last.messages.whereType<ListFiles>().last;
    expect((ask.sessionId, ask.query), ('s1', ''));
    await hostSends(tester, const FilesMessage(sessionId: 's1', query: '', files: [
      FileMention(path: 'docs', dir: true),
      FileMention(path: 'notes.txt'),
      FileMention(path: 'docs/plan.md'),
    ]));
    expect(find.byKey(const ValueKey('mention-list')), findsOneWidget);
    expect(find.text('docs/'), findsOneWidget, reason: 'folders are marked');
    expect(find.text('notes.txt'), findsOneWidget);
    // Typing narrows what is shown at once and asks the host again.
    await tester.enterText(composer(), 'Read @no');
    await tester.pump();
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('docs/'), findsNothing);
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<ListFiles>().any((m) => m.query == 'no')));
    await hostSends(tester, const FilesMessage(sessionId: 's1', query: 'no', files: [FileMention(path: 'notes.txt')]));
    await tester.tap(find.byKey(const ValueKey('mention-suggestion-notes.txt')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer()).controller!.text, 'Read @notes.txt ');
    expect(find.byKey(const ValueKey('mention-list')), findsNothing, reason: 'closed once a file is chosen');
    // A folder goes in with its slash and the list stays open on its contents.
    await tester.enterText(composer(), 'and @do');
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<ListFiles>().any((m) => m.query == 'do')));
    await hostSends(tester, const FilesMessage(sessionId: 's1', query: 'do', files: [FileMention(path: 'docs', dir: true)]));
    await tester.tap(find.byKey(const ValueKey('mention-suggestion-docs')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer()).controller!.text, 'and @docs/');
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<ListFiles>().any((m) => m.query == 'docs/')));
    await hostSends(tester, const FilesMessage(sessionId: 's1', query: 'docs/', files: [FileMention(path: 'docs/plan.md')]));
    expect(find.text('docs/plan.md'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('send')));
    await settleFrames(tester);
    expect(sent().whereType<SendMessage>().single.text, 'and @docs/');
  });

  testWidgets('an @ inside an address opens no list', (tester) async {
    await open(tester);
    await tester.enterText(composer(), 'mail me@example');
    await tester.runAsync(() => pump(300));
    await tester.pumpAndSettle();
    expect(channels.last.messages.whereType<ListFiles>(), isEmpty);
    expect(find.byKey(const ValueKey('mention-list')), findsNothing);
  });

  testWidgets('/perch_opens_the_apps_board_for_the_session_instead_of_typing_into_the_terminal', (tester) async {
    final opened = <(HostConnection, String)>[];
    await open(tester, origin: SessionOrigin.external, openPerch: (context, c, cwd) => opened.add((c, cwd)));
    await tester.enterText(composer(), '/pe');
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<ListCommands>().isNotEmpty));
    await hostSends(tester, const CommandsMessage(sessionId: 's1', commands: [
      SlashCommandInfo(name: '/perch', description: "Perch task board for this session's project", source: 'perch'),
      SlashCommandInfo(name: '/permissions', description: 'Manage allow and deny tool permission rules'),
    ]));
    await tester.enterText(composer(), '/per');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('command-suggestion-/perch')));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
    expect(opened.single.$1, same(conn));
    expect(opened.single.$2, conn.sessions.value.single.cwd);
    expect(tester.widget<TextField>(composer()).controller!.text, isEmpty);
    // Sent as text it does the same: nothing reaches the terminal.
    await sendText(tester, '/perch');
    expect(opened, hasLength(2));
    expect(sent().whereType<SendMessage>(), isEmpty);
    // Anything else is still sent.
    await sendText(tester, '/perch please');
    expect(sent().whereType<SendMessage>().single.text, '/perch please');
  });

  testWidgets('typing / opens the session\'s commands, filtered as you type; a tap fills the composer', (tester) async {
    await open(tester);
    await tester.enterText(composer(), '/');
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<ListCommands>().isNotEmpty));
    expect(channels.last.messages.whereType<ListCommands>().single.sessionId, 's1');
    await hostSends(tester, const CommandsMessage(sessionId: 's1', commands: [
      SlashCommandInfo(name: '/compact', description: 'Free up context by summarizing'),
      SlashCommandInfo(name: '/context', description: 'Show current context usage', argumentHint: '[all]'),
      SlashCommandInfo(name: '/clear', description: 'Start a new session'),
      SlashCommandInfo(name: '/ship', description: 'Ship it', source: 'project'),
    ]));
    expect(find.byKey(const ValueKey('command-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('command-suggestion-/ship')), findsOneWidget);
    expect(find.text('project'), findsOneWidget, reason: 'where a custom command comes from');
    await tester.enterText(composer(), '/con');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('command-suggestion-/context')), findsOneWidget);
    expect(find.byKey(const ValueKey('command-suggestion-/clear')), findsNothing);
    expect(find.text('Show current context usage'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('command-suggestion-/context')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer()).controller!.text, '/context ');
    expect(find.byKey(const ValueKey('command-list')), findsNothing, reason: 'closed once a command is chosen');
    await tester.tap(find.byKey(const ValueKey('send')));
    await settleFrames(tester);
    expect(sent().whereType<SendMessage>().single.text, '/context');
    expect(channels.last.messages.whereType<ListCommands>(), hasLength(1), reason: 'asked once');
  });
}
