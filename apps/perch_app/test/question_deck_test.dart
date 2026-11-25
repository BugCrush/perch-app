import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/ui/cards/question_deck.dart';
import 'package:perch_app/src/ui/cards/question_model.dart';
import 'package:perch_app/src/ui/glass/widgets.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'glass_harness.dart';

PromptRequest prompt(List<Map<String, dynamic>> questions) => PromptRequest(
      promptId: 'p1',
      kind: PromptKind.question,
      toolName: 'AskUserQuestion',
      input: {'questions': questions},
    );

Map<String, dynamic> q(String question, String header, List<String> labels, {bool multi = false}) => {
      'question': question,
      'header': header,
      'multiSelect': multi,
      'options': [
        for (final l in labels) {'label': l, 'description': 'Choose ${l.toLowerCase()}'}
      ],
    };

final twoQuestions = prompt([
  q('Which color?', 'Color', ['Red', 'Blue']),
  q('Which size?', 'Size', ['Small', 'Large']),
]);

void main() {
  late List<QuestionAnswer> submitted;

  Future<void> show(WidgetTester tester, PromptRequest p) async {
    submitted = [];
    await tester.pumpWidget(glassApp(GlassScaffold(
      child: ListView(padding: const EdgeInsets.all(12), children: [QuestionDeck(prompt: p, onSubmit: submitted.add)]),
    )));
    await tester.pumpAndSettle();
  }

  test('the model sends options in order, the typed answer last, and points at a gap', () {
    final m = QuestionModel({
      'questions': [
        q('Which colors?', 'Colors', ['Red', 'Green', 'Blue'], multi: true),
        q('Which size?', 'Size', ['Small', 'Large']),
      ]
    });
    m.choose(0, 'Blue');
    m.choose(0, 'Red');
    m.toggleOther(0);
    m.setOther(0, ' Teal ');
    expect(m.answerOf(0), 'Red, Blue, Teal');
    expect(m.page, 0, reason: 'multi-select stays');
    expect(m.submit(), isNull);
    expect((m.nudge, m.page), (1, 1));
    m.choose(1, 'Large');
    expect(m.page, 2);
    expect(m.submit()!.answers, {'Which colors?': 'Red, Blue, Teal', 'Which size?': 'Large'});
    expect(m.submit(), isNull, reason: 'sent once');
  });

  int dots(WidgetTester tester) => find
      .byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('deck-dot-'))
      .evaluate()
      .length;

  testWidgets('shows_one_dot_per_question_plus_submit', (tester) async {
    await show(tester, twoQuestions);
    expect(dots(tester), 3);
    expect(find.text('CLAUDE ASKS · 1 OF 2'), findsOneWidget);
    expect(find.text('Color'), findsOneWidget);
    expect(find.text('Which color?'), findsOneWidget);
    expect(find.text('Choose red'), findsOneWidget);
    expect(find.text('Other'), findsWidgets);
  });

  testWidgets('single_choice_advances', (tester) async {
    await show(tester, twoQuestions);
    await tester.tap(find.text('Red'));
    await tester.pumpAndSettle();
    expect(find.text('CLAUDE ASKS · 2 OF 2'), findsOneWidget);
    expect(find.text('Which size?'), findsOneWidget);
  });

  testWidgets('swiping_moves_between_cards', (tester) async {
    await show(tester, twoQuestions);
    await tester.fling(find.byType(QuestionDeck), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('CLAUDE ASKS · 2 OF 2'), findsOneWidget);
    await tester.fling(find.byType(QuestionDeck), const Offset(400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('CLAUDE ASKS · 1 OF 2'), findsOneWidget);
  });

  testWidgets('submit_with_gap_returns_to_first_unanswered', (tester) async {
    await show(tester, twoQuestions);
    await tester.fling(find.byType(QuestionDeck), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Large'));
    await tester.pumpAndSettle();
    expect(find.text('YOUR ANSWERS'), findsOneWidget);
    expect(find.text('Not answered'), findsOneWidget);
    await tester.tap(button('Submit'));
    await tester.pumpAndSettle();
    expect(find.text('CLAUDE ASKS · 1 OF 2'), findsOneWidget);
    expect(find.text('Which color?'), findsOneWidget);
    expect(find.text('Answer this one to continue'), findsOneWidget);
    expect(submitted, isEmpty);
  });

  testWidgets('submit_with_all_answered_sends_map', (tester) async {
    await show(tester, twoQuestions);
    await tester.tap(find.text('Blue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Large'));
    await tester.pumpAndSettle();
    expect(find.text('YOUR ANSWERS'), findsOneWidget);
    expect(find.text('Which color?'), findsOneWidget);
    expect(find.text('Blue'), findsOneWidget);
    await tester.tap(button('Submit'));
    await tester.pumpAndSettle();
    expect(submitted.single.answers, {'Which color?': 'Blue', 'Which size?': 'Large'});
  });

  testWidgets('multi_select_joins_labels', (tester) async {
    await show(tester, prompt([q('Which colors?', 'Colors', ['Red', 'Green', 'Blue'], multi: true)]));
    await tester.tap(find.text('Red'));
    await tester.tap(find.text('Blue'));
    await tester.pumpAndSettle();
    expect(find.text('CLAUDE ASKS · 1 OF 1'), findsOneWidget); // multi-select does not advance by itself
    expect(find.text('Choose any'), findsOneWidget);
    await tester.tap(button('Next'));
    await tester.pumpAndSettle();
    await tester.tap(button('Submit'));
    await tester.pumpAndSettle();
    expect(submitted.single.answers, {'Which colors?': 'Red, Blue'});
  });

  testWidgets('other_sends_typed_text', (tester) async {
    await show(tester, prompt([q('Which color?', 'Color', ['Red', 'Blue'])]));
    await tester.tap(find.text('Other'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Your answer'), 'Purple');
    await tester.tap(button('Next'));
    await tester.pumpAndSettle();
    await tester.tap(button('Submit'));
    await tester.pumpAndSettle();
    expect(submitted.single.answers, {'Which color?': 'Purple'});
  });

  testWidgets('submit_fires_once_on_double_tap', (tester) async {
    await show(tester, prompt([q('Which color?', 'Color', ['Red', 'Blue'])]));
    await tester.tap(find.text('Red'));
    await tester.pumpAndSettle();
    final submit = button('Submit');
    await tester.tap(submit);
    await tester.tap(submit, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(submitted.length, 1);
    expect(enabled(tester, 'Submit'), isFalse);
  });

  testWidgets('every page slides in like a deck, the answers with Submit too; Submit only there', (tester) async {
    await show(tester, twoQuestions);
    expect(find.text('Submit'), findsNothing, reason: 'no Submit on a question');
    await tester.tap(find.byKey(const ValueKey('option-0-Red')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SlideTransition), findsWidgets);
    final ahead = tester.getTopLeft(find.byKey(const ValueKey('q1'))).dx;
    expect(ahead, greaterThan(tester.getTopLeft(find.byKey(const ValueKey('q0'))).dx), reason: 'the next comes from the right');
    await tester.pumpAndSettle();
    expect(find.text('Submit'), findsNothing, reason: 'still no Submit on the last question');
    await tester.tap(find.byKey(const ValueKey('option-1-Large')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('review')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('review'))).dx, greaterThan(tester.getTopLeft(find.byKey(const ValueKey('q1'))).dx));
    await tester.pumpAndSettle();
    expect(find.text('YOUR ANSWERS'), findsOneWidget);
    expect(find.text('Red'), findsOneWidget);
    expect(find.text('Large'), findsOneWidget);
    expect(find.text('Submit'), findsOneWidget);
  });
}
