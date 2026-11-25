import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/ui/cards/prompt_cards.dart';
import 'package:perch_app/src/ui/glass/widgets.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'glass_harness.dart';

const plan = PromptRequest(
  promptId: 'p1',
  kind: PromptKind.plan,
  toolName: 'ExitPlanMode',
  input: {'plan': '# The plan\n\n1. Write tests\n2. Make them pass'},
);

void main() {
  late List<PlanAnswer> answers;

  Future<void> show(WidgetTester tester) async {
    answers = [];
    await tester.pumpWidget(glassApp(GlassScaffold(child: ListView(children: [PlanCard(prompt: plan, onAnswer: answers.add)]))));
    await tester.pumpAndSettle();
  }

  testWidgets('approve_sends_approve_true', (tester) async {
    await show(tester);
    expect(find.textContaining('Write tests', findRichText: true), findsWidgets);
    expect(find.text('A PLAN TO APPROVE'), findsOneWidget);
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(answers.single.approve, isTrue);
  });

  testWidgets('keep_planning_requires_feedback', (tester) async {
    await show(tester);
    await tester.tap(find.text('Keep planning'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send feedback'));
    await tester.pumpAndSettle();
    expect(answers, isEmpty);
    expect(find.text('Tell Claude what to change'), findsOneWidget);
    await tester.enterText(field('What should change?'), 'Add a migration step');
    await tester.tap(find.text('Send feedback'));
    await tester.pumpAndSettle();
    expect(answers.single.approve, isFalse);
    expect(answers.single.feedback, 'Add a migration step');
  });
}

