// The question deck's answers: what is chosen on each question (options, and the typed
// "Other"), which page shows, and what Submit sends. No widgets here.
import 'package:flutter/foundation.dart';
import 'package:perch_protocol/perch_protocol.dart';

/// One of Claude's questions (AskUserQuestion's input).
class DeckQuestion {
  final String question;
  final String header;
  final bool multiSelect;
  final List<({String label, String description})> options;
  const DeckQuestion(this.question, this.header, this.multiSelect, this.options);

  static List<DeckQuestion> fromInput(Map<String, dynamic> input) {
    final raw = input['questions'];
    if (raw is! List) return [];
    return [
      for (final q in raw)
        if (q is Map)
          DeckQuestion(
            '${q['question'] ?? ''}',
            '${q['header'] ?? ''}',
            q['multiSelect'] == true,
            [
              for (final o in (q['options'] is List ? q['options'] as List : const []))
                if (o is Map) (label: '${o['label'] ?? ''}', description: '${o['description'] ?? ''}')
            ],
          )
    ];
  }
}

class QuestionModel extends ChangeNotifier {
  final List<DeckQuestion> questions;
  QuestionModel(Map<String, dynamic> input) : questions = DeckQuestion.fromInput(input);

  late final List<Set<String>> _chosen = [for (final _ in questions) <String>{}];
  late final List<bool> _otherOn = [for (final _ in questions) false];
  late final List<String> _otherText = [for (final _ in questions) ''];

  /// The page shown: a question, or [questions.length] for the review with Submit.
  int page = 0;

  /// A question left unanswered at Submit.
  int? nudge;

  /// Submit sent the answers (it sends them once).
  bool submitted = false;

  int get pages => questions.length + 1;
  bool get onReview => page >= questions.length;

  bool isChosen(int i, String label) => _chosen[i].contains(label);
  bool otherOn(int i) => _otherOn[i];
  String otherText(int i) => _otherText[i];

  /// The answer for question [i] (options in their order, then the typed text), or '' when
  /// unanswered.
  String answerOf(int i) {
    final q = questions[i];
    final parts = [for (final o in q.options) if (_chosen[i].contains(o.label)) o.label];
    final other = _otherText[i].trim();
    if (_otherOn[i] && other.isNotEmpty) parts.add(other);
    return parts.join(', ');
  }

  /// Picks or (multi-select) toggles an option. A single choice moves on by itself.
  void choose(int i, String label) {
    if (nudge == i) nudge = null;
    if (questions[i].multiSelect) {
      if (!_chosen[i].remove(label)) _chosen[i].add(label);
    } else {
      _chosen[i]
        ..clear()
        ..add(label);
      _otherOn[i] = false;
      page = i + 1;
    }
    notifyListeners();
  }

  /// Turns the typed "Other" answer on or off (on a single choice it replaces the option).
  void toggleOther(int i) {
    _otherOn[i] = !_otherOn[i];
    if (_otherOn[i] && !questions[i].multiSelect) _chosen[i].clear();
    if (nudge == i) nudge = null;
    notifyListeners();
  }

  void setOther(int i, String text) {
    _otherText[i] = text;
    notifyListeners();
  }

  void go(int p) {
    if (p == page || p < 0 || p >= pages) return;
    page = p;
    notifyListeners();
  }

  /// The answers for Submit, or null after pointing at the first question left open (or
  /// when they were sent already).
  QuestionAnswer? submit() {
    if (submitted) return null;
    for (var i = 0; i < questions.length; i++) {
      if (answerOf(i).isEmpty) {
        nudge = i;
        page = i;
        notifyListeners();
        return null;
      }
    }
    submitted = true;
    notifyListeners();
    return QuestionAnswer({for (var i = 0; i < questions.length; i++) questions[i].question: answerOf(i)});
  }
}
