// Cards for terminal sessions: what Claude Code is asking (from the transcript and the
// screen), and answering it by pressing the keys the owner would press.
import 'dart:async';

import 'package:perch_protocol/perch_protocol.dart';

import 'console_typer.dart';
import 'dialog_screen.dart';

/// The terminal shows something Perch did not expect, so it typed nothing (or stopped).
class CannotAnswerInTerminal implements Exception {
  final String message;
  CannotAnswerInTerminal(this.message);
  @override
  String toString() => message;
}

/// Tool name of the prompt for the folder-trust dialog (it has no tool use).
const trustFolderTool = 'TrustFolder';

/// Tools that run for a long time without asking anything themselves.
const _neverAsking = {'Agent', 'Task'};

/// The last tool use in [events] that has no result yet, or null.
ToolCall? pendingToolUse(List<ConversationEvent> events) {
  final done = {for (final e in events) if (e is ToolResult) e.toolUseId};
  for (final e in events.reversed) {
    if (e is ToolCall && !done.contains(e.toolUseId) && !_neverAsking.contains(e.name)) return e;
  }
  return null;
}

/// A card for [call]. A permission card offers "always" exactly when the terminal offers
/// a "Yes, and …" option ([alwaysLabel]).
PromptRequest promptForToolUse(ToolCall call, {String? alwaysLabel}) {
  final kind = PromptRequest.kindForTool(call.name);
  return PromptRequest(
    promptId: call.toolUseId,
    kind: kind,
    toolName: call.name,
    input: call.input,
    suggestions: kind == PromptKind.permission && alwaysLabel != null
        ? [
            {'type': 'terminalOption', 'label': alwaysLabel}
          ]
        : const [],
    parentToolUseId: call.parentToolUseId,
  );
}

PromptRequest trustPrompt(String sessionId, String cwd) => PromptRequest(
      promptId: 'trust:$sessionId',
      kind: PromptKind.permission,
      toolName: trustFolderTool,
      input: {'path': cwd},
    );

/// A card built from the dialog on [screen], for when the transcript does not hold the tool
/// use yet (Claude Code may write the first turn of a new session only later). A question
/// set shows one question at a time, so each step (and the final review) is its own card.
/// Its input carries `fromScreen: true`. Null when no known dialog is showing.
/// Whether the terminal shows a step after the first of the question set [questions] (the
/// tool use's `questions`), so the steps before were answered there: the review, or a tab
/// row with a ticked question (`←  ☒ Color  ☐ Animal  ✔ Submit  →`). Only when the tab row
/// is out of sight does a later question's text count. Not seeing the first question's
/// text proves nothing: a set with long options is taller than the terminal and its
/// question scrolls off the top (the whole set then came to the phone one step at a time,
/// "1 of 1", and its review could not be answered; 2026-11-25).
bool laterQuestionStep(String screen, Object? questions) {
  if (detectDialog(screen) != DialogKind.question) return false;
  if (isReviewScreen(screen)) return true;
  for (final line in screen.replaceAll('\r', '').split('\n')) {
    final t = line.trim();
    if (t.startsWith('←') && t.contains('Submit')) return t.contains('☒');
  }
  if (questions is! List || questions.length < 2) return false;
  String? text(Object? q) => q is Map && q['question'] is String ? q['question'] as String : null;
  final first = text(questions.first);
  if (first != null && first.isNotEmpty && dialogShows(screen, first)) return false;
  for (final q in questions.skip(1)) {
    final t = text(q);
    if (t != null && t.isNotEmpty && t != first && dialogShows(screen, t)) return true;
  }
  return false;
}

PromptRequest? screenPrompt(String screen, String sessionId) {
  // Menus Perch handles itself are no card ("What do you want to do?" of the usage-limit
  // menu read as a permission question; seen on Windows, 2.1.327).
  if (isUsageLimitMenu(screen) || isModelSwitchConfirm(screen)) return null;
  final kind = detectDialog(screen);
  final options = parseDialogOptions(screen);
  final body = dialogBody(screen);
  final key = '$kind|${body.join('|')}|${options.map((o) => o.label).join('|')}';
  final id = 'screen:$sessionId:${key.hashCode.toRadixString(16)}';
  switch (kind) {
    case DialogKind.question:
      final review = isReviewScreen(screen);
      final shown = [
        for (final o in options)
          if (!o.label.startsWith('Type something') && !o.label.startsWith('Chat about this')) o
      ];
      if (body.isEmpty || shown.isEmpty) return null;
      return PromptRequest(promptId: id, kind: PromptKind.question, toolName: 'AskUserQuestion', input: {
        'questions': [
          {
            'question': body.join(review ? '\n' : ' '),
            'header': '',
            'options': [for (final o in shown) {'label': o.label, 'description': ''}],
            'multiSelect': options.any((o) => o.checked != null),
          }
        ],
        'fromScreen': true,
      });
    case DialogKind.permission:
      if (body.isEmpty) return null;
      var tool = 'Permission';
      String? arg;
      for (final l in aboveDialog(screen, max: 8).reversed) {
        final m = RegExp(r'^\s*●\s*([A-Za-z]\w*)\((.*)\)\s*$').firstMatch(l);
        if (m != null) {
          tool = m.group(1)!;
          arg = m.group(2);
          break;
        }
      }
      final always = alwaysOptionOn(screen);
      return PromptRequest(
        promptId: id,
        kind: PromptKind.permission,
        toolName: tool,
        input: {
          if (arg != null && (tool == 'Bash' || tool == 'PowerShell')) 'command': arg,
          if (arg != null && tool != 'Bash' && tool != 'PowerShell') 'file_path': arg,
          'description': body.join('\n'),
          'fromScreen': true,
        },
        suggestions: always == null
            ? const []
            : [
                {'type': 'terminalOption', 'label': always}
              ],
      );
    case DialogKind.plan:
      final above = aboveDialog(screen);
      final start = above.indexWhere((l) => l.contains("Here is Claude's plan"));
      if (start < 0) {
        // No plan on screen (2.1.327 "Exit plan mode?"): the dialog's own words, never
        // the conversation above it.
        final body = dialogBody(screen).where((l) => !l.endsWith('?')).join('\n');
        return PromptRequest(
            promptId: id,
            kind: PromptKind.plan,
            toolName: 'ExitPlanMode',
            input: {'plan': body, 'fromScreen': true});
      }
      final plan = [
        for (final l in above.sublist(start + 1))
          if (!RegExp(r'^\s*[╌─]{10,}').hasMatch(l)) l.trim()
      ].join('\n');
      return PromptRequest(
          promptId: id, kind: PromptKind.plan, toolName: 'ExitPlanMode', input: {'plan': plan, 'fromScreen': true});
    case DialogKind.trust:
    case DialogKind.none:
      return null;
  }
}

/// The label of the "Yes, and …" option on a permission dialog, or null.
String? alwaysOptionOn(String screen) {
  for (final o in parseDialogOptions(screen)) {
    if (o.label.startsWith('Yes, and')) return o.label;
  }
  return null;
}

/// Answers one prompt by pressing keys in a terminal session. Before every key press it
/// checks that the screen shows what it expects; when it does not, it types nothing more
/// and throws [CannotAnswerInTerminal].
class TerminalAnswerer {
  final TerminalConsole console;
  final int pid;

  /// How often to re-read the screen, and how long to wait for it to change.
  final Duration poll;
  final Duration timeout;

  TerminalAnswerer(this.console, this.pid,
      {this.poll = const Duration(milliseconds: 300), this.timeout = const Duration(seconds: 6)});

  Never _fail(String why) => throw CannotAnswerInTerminal(why);

  Future<String> _screen() async => await console.screen(pid) ?? _fail('Could not read the terminal.');

  /// Re-reads the screen until [ok] holds; null when it never does.
  Future<String?> _waitFor(bool Function(String screen) ok) async {
    final end = DateTime.now().add(timeout);
    while (true) {
      final s = await console.screen(pid);
      if (s != null && ok(s)) return s;
      if (DateTime.now().isAfter(end)) return null;
      await Future<void>.delayed(poll);
    }
  }

  Future<void> _keys(String keys) async {
    if (!await console.keys(pid, keys)) _fail('Could not press keys in the terminal.');
  }

  Future<void> _enter() async {
    if (!await console.pressEnter(pid)) _fail('Could not press Enter in the terminal.');
  }

  /// Presses the number of a numbered option.
  Future<void> _choose(DialogOption o) async {
    if (!o.numbered || o.number > 9) _fail('Unexpected dialog layout.');
    await _keys('${o.number}');
  }

  /// What identifies one dialog: its kind, its options and the lines above them.
  static String _fingerprint(String screen) {
    final options = parseDialogOptions(screen);
    if (options.isEmpty) return '';
    final lines = screen.replaceAll('\r', '').split('\n').where((l) => l.trim().isNotEmpty).toList();
    final first = lines.indexWhere((l) => l.contains(options.first.label));
    final above = first < 0 ? const <String>[] : lines.sublist(first - 3 < 0 ? 0 : first - 3, first);
    return '${detectDialog(screen)}|${above.join('|')}|${options.map((o) => o.label).join('|')}';
  }

  /// Waits until the dialog shown in [before] is gone or replaced.
  Future<String> _movedOn(String before) async {
    final was = _fingerprint(before);
    return await _waitFor((s) => _fingerprint(s) != was) ??
        _fail('The terminal did not take the answer. Answer it in the terminal.');
  }

  static DialogOption? _option(List<DialogOption> options, bool Function(String label) test) {
    for (final o in options) {
      if (test(o.label)) return o;
    }
    return null;
  }

  /// The option for [label]: the same text, or (for a long label cut off on screen) the
  /// only option whose text starts it.
  static DialogOption? _optionFor(List<DialogOption> options, String label) {
    final exact = _option(options, (l) => l == label);
    if (exact != null) return exact;
    final prefix = options.where((o) => o.label.length >= 8 && label.startsWith(o.label)).toList();
    return prefix.length == 1 ? prefix.single : null;
  }

  Future<void> answer(PromptRequest p, PromptAnswer a) async {
    if (!await console.bringForward(pid)) _fail('Could not reach the terminal.');
    switch ((p.kind, a)) {
      case (PromptKind.permission, PermissionAnswer a) when p.toolName == trustFolderTool:
        await _trust(a.allow);
      case (PromptKind.permission, PermissionAnswer a):
        await _permission(a);
      case (PromptKind.question, QuestionAnswer a):
        await _questions(p, a);
      case (PromptKind.plan, PlanAnswer a):
        await _plan(a);
      default:
        _fail('This answer does not fit the question.');
    }
  }

  Future<void> _permission(PermissionAnswer a) async {
    final s = await _screen();
    if (detectDialog(s) != DialogKind.permission) _fail('The terminal is not showing this permission request.');
    final options = parseDialogOptions(s);
    final target = !a.allow
        ? _option(options, (l) => l.startsWith('No'))
        : a.always
            ? _option(options, (l) => l.startsWith('Yes, and'))
            : _option(options, (l) => l == 'Yes' || (l.startsWith('Yes') && !l.contains(' and ')));
    if (target == null) _fail('The terminal does not offer this choice.');
    await _choose(target);
    await _movedOn(s);
    final reason = a.message?.trim() ?? '';
    if (!a.allow && reason.isNotEmpty) {
      // A denial ends the turn; the reason follows as the next message.
      await _waitFor(isPromptReady) ?? _fail('Denied, but the reason could not be sent.');
      if (!await console.type(pid, reason)) _fail('Denied, but the reason could not be typed.');
    }
  }

  Future<void> _trust(bool allow) async {
    final s = await _screen();
    if (detectDialog(s) != DialogKind.trust) _fail('The terminal is not asking to trust this folder.');
    final options = parseDialogOptions(s);
    final target = _option(options, (l) => l.startsWith(allow ? 'Yes' : 'No'));
    final current = options.where((o) => o.selected).firstOrNull;
    if (target == null || current == null) _fail('Unexpected dialog layout.');
    if (target.numbered) {
      await _choose(target);
    } else {
      final delta = target.number - current.number;
      if (delta != 0) await _keys((delta > 0 ? ConsoleKeys.down : ConsoleKeys.up) * delta.abs());
      final now = await _waitFor((x) => parseDialogOptions(x).any((o) => o.selected && o.label == target.label)) ??
          _fail('Could not move to the choice.');
      if (detectDialog(now) != DialogKind.trust) _fail('Unexpected dialog layout.');
      await _enter();
    }
    await _movedOn(s);
  }

  Future<void> _plan(PlanAnswer a) async {
    final s = await _screen();
    if (detectDialog(s) != DialogKind.plan) _fail('The terminal is not showing this plan.');
    final options = parseDialogOptions(s);
    final feedback = a.feedback?.trim() ?? '';
    if (a.approve) {
      final yes = _option(options, (l) => l.startsWith('Yes')) ?? _fail('The terminal does not offer this choice.');
      await _choose(yes);
      await _movedOn(s);
      return;
    }
    final tell = _option(options, (l) => l.startsWith('Tell Claude what to change'));
    if (tell != null) {
      await _choose(tell);
      if (feedback.isEmpty) _fail('Tell Claude what to change.');
      await _waitFor((x) => parseDialogOptions(x).any((o) => o.selected && o.number == tell.number)) ??
          _fail('Could not move to the choice.');
      await _keys(feedback);
      await _enter();
      await _movedOn(s);
      return;
    }
    final no = _option(options, (l) => l.startsWith('No')) ?? _fail('The terminal does not offer this choice.');
    await _choose(no);
    await _movedOn(s);
    if (feedback.isNotEmpty) {
      await _waitFor(isPromptReady) ?? _fail('Kept planning, but the feedback could not be sent.');
      if (!await console.type(pid, feedback)) _fail('Kept planning, but the feedback could not be typed.');
    }
  }

  Future<void> _questions(PromptRequest p, QuestionAnswer a) async {
    final raw = p.input['questions'];
    if (raw is! List || raw.isEmpty) _fail('No questions to answer.');
    final questions = [for (final q in raw) if (q is Map) q.cast<String, dynamic>()];
    // A card from the screen is one step of a set: no review step of its own.
    final multiStep = p.input['fromScreen'] != true &&
        (questions.length > 1 || questions.any((q) => q['multiSelect'] == true));
    var s = await _screen();
    final first = s;
    for (var i = 0; i < questions.length; i++) {
      final q = questions[i];
      final text = '${q['question'] ?? ''}';
      final answer = a.answers[text] ?? _fail('No answer for "$text".');
      if (detectDialog(s) != DialogKind.question || !dialogShows(s, text)) {
        _fail('The terminal is not showing the question "$text".');
      }
      final options = parseDialogOptions(s);
      final labels = [
        for (final o in (q['options'] is List ? q['options'] as List : const []))
          if (o is Map && o['label'] is String) o['label'] as String
      ];
      if (q['multiSelect'] == true) {
        await _multiSelect(s, labels, answer, text);
      } else {
        final o = labels.contains(answer) ? _optionFor(options, answer) : null;
        if (labels.contains(answer) && o == null) _fail('The terminal does not show "$answer".');
        if (o != null) {
          await _choose(o);
        } else {
          // Other: the "Type something" option, then the text, then Enter.
          final other = _option(options, (l) => l.startsWith('Type something')) ??
              _fail('The terminal does not offer a free answer.');
          await _choose(other);
          await _waitFor((x) => parseDialogOptions(x).any((o) => o.selected && o.number == other.number)) ??
              _fail('Could not move to the free answer.');
          await _keys(answer);
          await _enter();
        }
      }
      if (i + 1 < questions.length) {
        final next = '${questions[i + 1]['question'] ?? ''}';
        s = await _waitFor((x) => detectDialog(x) == DialogKind.question && dialogShows(x, next)) ??
            _fail('The terminal did not move on to the question "$next".');
      }
    }
    if (multiStep) {
      final review = await _waitFor(isReviewScreen) ?? _fail('The terminal did not show the answers to submit.');
      final submit = _option(parseDialogOptions(review), (l) => l.toLowerCase().startsWith('submit')) ??
          _fail('Unexpected dialog layout.');
      await _choose(submit);
      await _movedOn(review);
    } else {
      await _movedOn(first);
    }
  }

  /// The screen again, still showing the question [question]; fails otherwise.
  Future<String> _stillAsking(String question) async {
    final s = await _screen();
    if (detectDialog(s) != DialogKind.question || !dialogShows(s, question)) {
      _fail('The terminal is no longer showing the question "$question".');
    }
    return s;
  }

  /// Ticks exactly the chosen boxes and checks them on screen. Without a typed answer it
  /// then moves on (→). With one (seen live, Claude Code 2.1.323): the cursor goes down to
  /// the "Type something" row, whose text box takes the typed keys and ticks itself; one
  /// more ↓ reaches the "Submit" (or "Next") row, and Enter moves on. Claude receives the
  /// ticked labels in option order, then the typed text, joined with ", ".
  Future<void> _multiSelect(String s, List<String> labels, String answer, String question) async {
    final split = splitMultiSelectAnswer(labels, answer);
    final chosen = split.chosen;
    final other = split.other.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    final options = parseDialogOptions(s);
    final boxes = options.where((o) => o.checked != null && labels.contains(o.label)).toList();
    if (boxes.length != labels.length) _fail('The terminal does not show every choice of "$question".');
    final otherNo = labels.length + 1;
    final otherRow = options.where((o) => o.number == otherNo && o.checked != null).firstOrNull;
    if (other.isNotEmpty && (otherRow == null || otherRow.checked == true || !otherRow.label.startsWith('Type something'))) {
      _fail('The terminal does not offer a typed answer for "$question".');
    }
    for (final o in boxes) {
      if (o.checked == chosen.contains(o.label)) continue;
      await _stillAsking(question);
      await _choose(o);
    }
    bool ticked(String x) =>
        dialogShows(x, question) &&
        parseDialogOptions(x)
            .where((o) => o.checked != null && labels.contains(o.label))
            .every((o) => o.checked == chosen.contains(o.label));
    final now = await _waitFor(ticked) ?? _fail('The choices did not come out as sent.');
    if (other.isEmpty) {
      await _keys(ConsoleKeys.right);
      return;
    }
    final cursor = parseDialogOptions(now).where((o) => o.selected).firstOrNull ?? _fail('Unexpected dialog layout.');
    final delta = otherNo - cursor.number;
    if (delta != 0) await _keys((delta > 0 ? ConsoleKeys.down : ConsoleKeys.up) * delta.abs());
    await _waitFor((x) =>
            ticked(x) &&
            parseDialogOptions(x).any((o) => o.selected && o.number == otherNo && o.label.startsWith('Type something'))) ??
        _fail('Could not move to the typed answer.');
    await _keys(other);
    await _waitFor((x) =>
            ticked(x) &&
            parseDialogOptions(x)
                .any((o) => o.selected && o.number == otherNo && o.checked == true && _shows(o.label, other))) ??
        _fail('The typed answer did not appear in the terminal. Answer it in the terminal.');
    await _keys(ConsoleKeys.down);
    await _waitFor((x) => ticked(x) && selectedActionRow(x) != null) ?? _fail('Could not move to Submit.');
    await _enter();
  }

  /// Whether an option row shows [text] (a long text may be cut off at the window's edge).
  static bool _shows(String label, String text) =>
      label == text || (label.length >= 20 && text.startsWith(label));
}

/// Splits a multi-select answer (`"Apple, Cherry, Mango"`: the chosen labels in option
/// order, then any typed text, joined with ", ") into the chosen labels and the typed text.
({Set<String> chosen, String other}) splitMultiSelectAnswer(List<String> labels, String answer) {
  // In option order, as the app sends it.
  var rest = answer.trim();
  final chosen = <String>{};
  for (final l in labels) {
    if (rest == l) {
      chosen.add(l);
      rest = '';
    } else if (rest.startsWith('$l, ')) {
      chosen.add(l);
      rest = rest.substring(l.length + 2);
    }
  }
  if (rest.isEmpty) return (chosen: chosen, other: '');
  // Labels in another order, with no typed text.
  final items = ', $answer, ';
  final anyOrder = {for (final l in labels) if (items.contains(', $l, ')) l};
  var left = answer;
  for (final l in anyOrder) {
    left = left.replaceFirst(l, '');
  }
  if (anyOrder.isNotEmpty && left.replaceAll(',', '').trim().isEmpty) return (chosen: anyOrder, other: '');
  return (chosen: chosen, other: rest.trim());
}
