import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/ui/cards/prompt_cards.dart';
import 'package:perch_app/src/ui/glass/widgets.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'glass_harness.dart';

const shell = PromptRequest(
  promptId: 'p1',
  kind: PromptKind.permission,
  toolName: 'PowerShell',
  input: {'command': 'Remove-Item build -Recurse', 'description': 'Clean the build folder'},
  suggestions: [
    {'type': 'addRules', 'behavior': 'allow'}
  ],
  parentToolUseId: 'toolu_1',
);

const write = PromptRequest(
  promptId: 'p2',
  kind: PromptKind.permission,
  toolName: 'Write',
  input: {'file_path': r'D:\x\notes.txt', 'content': 'Blue\nLarge'},
);

void main() {
  late List<PermissionAnswer> answers;

  Future<void> show(WidgetTester tester, PromptRequest p) async {
    answers = [];
    await tester.pumpWidget(glassApp(GlassScaffold(child: ListView(children: [PermissionCard(prompt: p, onAnswer: answers.add)]))));
    await tester.pumpAndSettle();
  }

  testWidgets('shows_command_for_shell_tool', (tester) async {
    await show(tester, shell);
    expect(find.text('Claude wants to use PowerShell'), findsOneWidget);
    expect(find.text('PERMISSION · POWERSHELL'), findsOneWidget);
    expect(find.text('Clean the build folder'), findsOneWidget);
    expect(find.text('Remove-Item build -Recurse'), findsOneWidget);
    expect(find.text('From a subagent'), findsOneWidget);
  });

  testWidgets('shows_file_and_preview_for_file_tool', (tester) async {
    await show(tester, write);
    expect(find.text('Claude wants to use Write'), findsOneWidget);
    expect(find.text(r'D:\x\notes.txt'), findsOneWidget);
    expect(find.text('Blue\nLarge'), findsOneWidget);
    expect(find.text('From a subagent'), findsNothing);
  });

  testWidgets('always_allow_hidden_without_suggestions', (tester) async {
    await show(tester, write);
    expect(find.text('Always allow'), findsNothing);
    await show(tester, shell);
    expect(find.text('Always allow'), findsOneWidget);
  });

  testWidgets('allow_sends_allow_true_always_false', (tester) async {
    await show(tester, shell);
    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();
    expect(answers.single.allow, isTrue);
    expect(answers.single.always, isFalse);
    // Answered once: the card's buttons are off until the host says otherwise.
    expect(enabled(tester, 'Allow'), isFalse);
  });

  testWidgets('always_allow_sends_always_true', (tester) async {
    await show(tester, shell);
    await tester.tap(find.text('Always allow'));
    await tester.pumpAndSettle();
    expect(answers.single.allow, isTrue);
    expect(answers.single.always, isTrue);
  });

  testWidgets('deny_sends_reason', (tester) async {
    await show(tester, shell);
    await tester.tap(find.text('Deny'));
    await tester.pumpAndSettle();
    expect(answers, isEmpty);
    await tester.enterText(field('Reason (optional)'), 'too risky');
    await tester.tap(find.text('Send denial'));
    await tester.pumpAndSettle();
    expect(answers.single.allow, isFalse);
    expect(answers.single.message, 'too risky');
  });
}
