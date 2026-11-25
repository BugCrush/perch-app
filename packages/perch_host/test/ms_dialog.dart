// A stand-in for Claude Code's multi-select question dialog in a Windows console (conhost
// draws `>` and `[√]`), as observed live with Claude Code 2.1.323. It renders screens in
// the same layout as the fixtures `ms_*.txt` and reacts to key presses the way the real
// dialog did.
import 'package:perch_host/src/console_typer.dart';

class MsQuestion {
  final String question;
  final String header;
  final List<String> labels;
  MsQuestion(this.question, this.header, this.labels);
}

class MsDialog {
  final List<String> top;
  final List<MsQuestion> questions;
  final String nav;
  final String name;

  int step = 0;
  bool reviewing = false;
  bool submitted = false;

  /// Per question: ticked option numbers, the typed text, the cursor row (1-based; n+1 is
  /// Other, n+2 the Submit / Next row).
  late final List<Set<int>> ticks = [for (final _ in questions) <int>{}];
  late final List<String?> other = [for (final _ in questions) null];
  late final List<bool> otherTicked = [for (final _ in questions) false];
  late final List<int> cursor = [for (final _ in questions) 1];

  MsDialog({required this.top, required this.questions, this.nav = '↑/↓ to navigate', this.name = 'perch-live-1'});

  static final rule = '─' * 120;
  String get nameRule => '${'─' * (120 - name.length - 3)} $name ─';

  String _tabs() {
    final parts = <String>[];
    for (var i = 0; i < questions.length; i++) {
      final done = i < step || reviewing || ticks[i].isNotEmpty && i != step;
      parts.add('[${done ? '×' : ' '}] ${questions[i].header}');
    }
    return '←  ${parts.join('  ')}  √ Submit  →';
  }

  String answerOf(int i) {
    final q = questions[i];
    return [
      for (var k = 0; k < q.labels.length; k++)
        if (ticks[i].contains(k + 1)) q.labels[k],
      if (otherTicked[i] && (other[i] ?? '').isNotEmpty) other[i]!,
    ].join(', ');
  }

  String screen() {
    if (submitted) return '${top.join('\n')}\n$rule\n> \n$rule\n  ⏸ manual mode on · ? for shortcuts\n';
    final out = [...top, rule, _tabs()];
    if (reviewing) {
      out.add('Review your answers');
      for (var i = 0; i < questions.length; i++) {
        out
          ..add(' ● ${questions[i].question}')
          ..add('   → ${answerOf(i)}');
      }
      out
        ..add('Ready to submit your answers?')
        ..add('> 1. Submit answers')
        ..add('  2. Cancel')
        ..add(nameRule);
      return '${out.join('\n')}\n';
    }
    final q = questions[step];
    final n = q.labels.length;
    final c = cursor[step];
    out.add(q.question);
    for (var k = 0; k < n; k++) {
      out
        ..add('${c == k + 1 ? '>' : ' '} ${k + 1}. [${ticks[step].contains(k + 1) ? '√' : ' '}] ${q.labels[k]}')
        ..add('         ${q.labels[k]}');
    }
    final text = other[step];
    out.add('${c == n + 1 ? '>' : ' '} ${n + 1}. [${otherTicked[step] ? '√' : ' '}] ${text == null || text.isEmpty ? 'Type something' : text}');
    final action = step + 1 < questions.length ? 'Next' : 'Submit';
    out
      ..add('${c == n + 2 ? '>' : ' '}    $action')
      ..add(rule)
      ..add('  ${n + 2}. Chat about this');
    final editing = c == n + 1 || (c == n + 2 && text != null);
    out
      ..add('Enter to select · $nav · ${editing ? 'ctrl+g to edit in Notepad · ' : ''}Esc to cancel')
      ..add(nameRule);
    return '${out.join('\n')}\n';
  }

  /// Applies one console action (`keys:<k>` or `enter`) as the real dialog did.
  void apply(String action) {
    if (submitted) return;
    if (reviewing) {
      if (action == 'keys:1') submitted = true;
      return;
    }
    final n = questions[step].labels.length;
    if (action == 'enter') {
      if (cursor[step] == n + 2) _advance();
      return;
    }
    if (!action.startsWith('keys:')) return;
    for (final ch in action.substring(5).split('')) {
      final c = cursor[step];
      if (ch == ConsoleKeys.down) {
        if (c < n + 2) cursor[step] = c + 1;
      } else if (ch == ConsoleKeys.up) {
        if (c > 1) cursor[step] = c - 1;
      } else if (ch == ConsoleKeys.right) {
        if (c != n + 1) _advance();
      } else if (c == n + 1) {
        // The text box of the Other row has the focus: typing ticks it.
        other[step] = (other[step] ?? '') + ch;
        otherTicked[step] = true;
      } else {
        final k = int.tryParse(ch);
        if (k == null) continue;
        if (k >= 1 && k <= n) {
          if (!ticks[step].remove(k)) ticks[step].add(k);
        } else if (k == n + 1) {
          otherTicked[step] = !otherTicked[step];
        }
      }
    }
  }

  void _advance() {
    if (step + 1 < questions.length) {
      step++;
    } else {
      reviewing = true;
    }
  }
}
