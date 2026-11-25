import 'dart:io';

import 'package:perch_host/src/dialog_screen.dart';
import 'package:test/test.dart';

String screen(String name) =>
    File('test${Platform.pathSeparator}fixtures${Platform.pathSeparator}screens${Platform.pathSeparator}$name')
        .readAsStringSync();

void main() {
  test('question_options_include_the_one_after_the_rule_and_skip_descriptions', () {
    final o = parseDialogOptions(screen('question_single.txt'));
    expect(o.map((x) => x.number), [1, 2, 3, 4]);
    expect(o.map((x) => x.label), ['Red', 'Blue', 'Type something.', 'Chat about this']);
    expect(o.map((x) => x.selected), [true, false, false, false]);
    expect(detectDialog(screen('question_single.txt')), DialogKind.question);
  });

  test('console_tick_marks_and_the_submit_row', () {
    // A Windows console window draws ticks as [√] and the cursor as >.
    final o = parseDialogOptions(screen('ms_other_ticked.txt'));
    expect(o.map((x) => x.label), ['Apple', 'Banana', 'Cherry', 'Type something', 'Chat about this']);
    expect(o.map((x) => x.checked), [true, false, true, false, null]);
    expect(detectDialog(screen('ms_other_typed.txt')), DialogKind.question);
    expect(selectedActionRow(screen('ms_other_typed.txt')), isNull);
    expect(selectedActionRow(screen('ms_other_submit_row.txt')), 'Submit');
    expect(parseDialogOptions(screen('ms_other_submit_row.txt')).where((x) => x.selected), isEmpty);
    expect(isReviewScreen(screen('ms_other_review.txt')), isTrue);
  });

  test('permission_options_and_kind', () {
    final s = screen('permission_create.txt');
    final o = parseDialogOptions(s);
    expect(o.map((x) => x.label).toList(), [
      'Yes',
      'Yes, and switch to accept edits (auto-approve file edits and common file commands) for this session (shift+tab)',
      'No',
    ]);
    expect(o.first.selected, isTrue);
    expect(detectDialog(s), DialogKind.permission);
  });

  test('a_numbered_list_in_the_conversation_is_not_a_dialog', () {
    final s = screen('idle.txt');
    expect(parseDialogOptions(s), isEmpty);
    expect(detectDialog(s), DialogKind.none);
    expect(detectDialog(''), DialogKind.none);
  });

  test('the_heavy_arrow_marker_counts_as_selected', () {
    const s = ' Do you want to proceed?\n   1. Yes\n ❯ 2. No\n Esc to cancel\n';
    final o = parseDialogOptions(s);
    expect(o.map((x) => x.selected), [false, true]);
    expect(detectDialog(s), DialogKind.permission);
  });

  // Real screens (sanitised) from Claude Code 2.1.323.

  test('real_trust_dialog_has_unnumbered_options', () {
    final s = screen('trust.txt');
    final o = parseDialogOptions(s);
    expect(o.map((x) => x.label), ['No, exit', 'Yes, I trust this folder']);
    expect(o.map((x) => x.selected), [true, false]);
    expect(o.every((x) => !x.numbered), isTrue);
    expect(detectDialog(s), DialogKind.trust);
  });

  test('real_2_1_331_trust_dialog_with_the_hooks_warning_is_still_a_trust_card', () {
    final s = screen('trust_hooks_warning_2_1_331.txt');
    expect(s, contains('This folder configures hooks'));
    final o = parseDialogOptions(s);
    expect(o.map((x) => x.label), ['No, exit', 'Yes, I trust this folder']);
    expect(o.map((x) => x.selected), [true, false]);
    expect(detectDialog(s), DialogKind.trust);
    expect(screenDrift(s), isNull);
  });

  test('real_question_set_first_second_and_review', () {
    final first = screen('question_multi_first.txt');
    expect(detectDialog(first), DialogKind.question);
    expect(parseDialogOptions(first).map((x) => x.label), ['Red', 'Blue', 'Type something.', 'Chat about this']);
    expect(dialogShows(first, 'Which color?'), isTrue);
    expect(dialogShows(first, 'Which animal?'), isFalse);
    expect(isReviewScreen(first), isFalse);

    final second = screen('question_multi_second.txt');
    expect(dialogShows(second, 'Which animal?'), isTrue);
    expect(parseDialogOptions(second).map((x) => x.label).take(2), ['Cat', 'Dog']);

    final review = screen('question_multi_review.txt');
    expect(detectDialog(review), DialogKind.question);
    expect(isReviewScreen(review), isTrue);
    expect(parseDialogOptions(review).map((x) => x.label), ['Submit answers', 'Cancel']);
  });

  test('real_multiselect_reads_check_boxes', () {
    final s = screen('multiselect.txt');
    expect(detectDialog(s), DialogKind.question);
    final o = parseDialogOptions(s);
    expect(o.map((x) => x.label), ['Apple', 'Banana', 'Cherry', 'Type something', 'Chat about this']);
    expect(o.map((x) => x.checked), [false, false, false, false, null]);
    expect(dialogShows(s, 'Which fruits?'), isTrue);
    final checked = parseDialogOptions(screen('multiselect_checked.txt'));
    expect(checked.map((x) => x.checked), [true, false, true, false, null]);
    expect(isReviewScreen(screen('multiselect_review.txt')), isTrue);
  });

  test('real_review_step_of_2_1_327_without_ready_to_submit', () {
    // Claude Code 2.1.327 dropped the "Ready to submit your answers?" line above the
    // options; the step keeps its "Review your answers" heading (REAL screen, Mac tmux).
    final s = screen('question_review_2_1_327.txt');
    expect(isReviewScreen(s), isTrue);
    expect(detectDialog(s), DialogKind.question);
    expect(screenDrift(s), isNull);
    expect(parseDialogOptions(s).map((o) => o.label), ['Submit answers', 'Cancel']);
    // A question that only mentions reviewing is not the review step.
    final notReview = s.replaceFirst('Review your answers', 'Pick something');
    expect(isReviewScreen(notReview), isFalse);
  });

  test('real_other_answer_moves_cursor_to_type_something', () {
    final chosen = parseDialogOptions(screen('question_other_chosen.txt'));
    expect(chosen.firstWhere((x) => x.selected).label, 'Type something.');
    final typed = parseDialogOptions(screen('question_other_typed.txt'));
    expect(typed.firstWhere((x) => x.selected).label, 'Medium');
  });

  test('real_plan_and_permission_and_idle', () {
    final plan = screen('plan.txt');
    expect(detectDialog(plan), DialogKind.plan);
    expect(parseDialogOptions(plan).map((x) => x.label),
        ['Yes, and use auto mode', 'Yes, manually approve edits', 'Tell Claude what to change']);
    final perm = screen('permission_real.txt');
    expect(detectDialog(perm), DialogKind.permission);
    expect(parseDialogOptions(perm).map((x) => x.number), [1, 2, 3]);
    expect(detectDialog(screen('idle_after_deny.txt')), DialogKind.none);
    expect(parseDialogOptions(screen('idle_after_deny.txt')), isEmpty);
  });

  test('real_2_1_327_exit_plan_mode_without_a_plan_is_a_plan_dialog_not_drift', () {
    final s = screen('plan_exit_no_plan_2_1_327.txt');
    expect(detectDialog(s), DialogKind.plan);
    expect(screenDrift(s), isNull);
    expect(parseDialogOptions(s).map((x) => x.label),
        ['Yes, and switch to default (ask each time) for this session', 'No']);
  });

  test('prompt_ready_only_when_the_input_box_shows_and_no_dialog', () {
    expect(isPromptReady(screen('idle_after_deny.txt')), isTrue);
    expect(isPromptReady(screen('trust.txt')), isFalse);
    expect(isPromptReady(screen('permission_real.txt')), isFalse);
    expect(isPromptReady(''), isFalse);
  });

  test('review_step_above_the_session_name_rule', () {
    final s = screen('question_review_named.txt');
    expect(isReviewScreen(s), isTrue);
    expect(detectDialog(s), DialogKind.question);
    expect(parseDialogOptions(s).map((x) => x.label), ['Submit answers', 'Cancel']);
  });

  test('only_the_last_numbered_block_is_taken', () {
    const s = '● Plan:\n  1. Alpha\n  2. Beta\n  3. Gamma\n\n Do you want to proceed?\n > 1. Yes\n   2. No\n Esc to cancel\n';
    expect(parseDialogOptions(s).map((x) => x.label), ['Yes', 'No']);
  });
}
