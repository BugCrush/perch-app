// Reads Claude Code's dialogs (questions, permission requests, plan approval, folder trust)
// from the visible text of its terminal. Pure functions; tested with fixture screens copied
// from real sessions (Claude Code 2.1.323 on Windows).

class DialogOption {
  /// The number shown in front of the option, or its position (1-based) when the dialog
  /// shows no numbers (the folder-trust dialog).
  final int number;
  final String label;

  /// The option the cursor is on (`❯` / `>` in front of it).
  final bool selected;

  /// Multi-select only: whether its box is ticked (`[✔]`); null when the option has no box.
  final bool? checked;

  /// False when the dialog shows no numbers: choose it with the arrow keys, not its number.
  final bool numbered;

  const DialogOption(
      {required this.number, required this.label, required this.selected, this.checked, this.numbered = true});

  @override
  String toString() => '${selected ? '>' : ' '} $number. ${checked == null ? '' : (checked! ? '[x] ' : '[ ] ')}$label';
}

enum DialogKind { question, permission, trust, plan, none }

const _markers = '>❯›▶';
final _option = RegExp('^\\s*([$_markers])?\\s*(\\d{1,2})\\.\\s+(.*?)\\s*\$');
final _unnumbered = RegExp('^(\\s*)([$_markers])\\s+(\\S.*?)\\s*\$');
// A Windows console window draws the tick as √ (Windows Terminal as ✔).
final _box = RegExp(r'^\[([ ✔✓√xX×])\]\s*(.*)$');
final _actionRow = RegExp('^\\s*[$_markers]\\s+(Submit|Next)\\s*\$');
final _footer = RegExp(r'Esc to (cancel|exit|go back)|Enter to (select|confirm|submit)|ctrl\+g to edit',
    caseSensitive: false);

List<String> _lines(String screen) {
  final lines = screen.replaceAll('\r', '').split('\n');
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  return lines;
}

/// Claude Code's lines under the input box while it waits for a usage limit to reset
/// ("Continuing automatically at 3:45pm · Esc to cancel"): not a dialog footer.
final _limitWaitLine = RegExp(r'Continuing (automatically|shortly)', caseSensitive: false);

/// Index of the last dialog footer line ("Enter to select", "Esc to cancel", …), or -1.
int _footerIndex(List<String> lines) {
  for (var i = lines.length - 1; i >= 0; i--) {
    if (_footer.hasMatch(lines[i]) && !_limitWaitLine.hasMatch(lines[i])) return i;
  }
  return -1;
}

/// The rows of Claude Code's usage-limit options menu (`/rate-limit-options`, or opened by
/// itself when it does not wait): "Wait here, then continue automatically", "Don't
/// continue automatically", …; for an organization account with no limit active (REAL,
/// Mac, 2.1.326): "Stop and wait for limit to reset", "Usage credit requests are turned off …".
final _limitMenuRow = RegExp(
    r"^(wait here, then continue automatically|don.t continue automatically|stop and wait for limit to reset)",
    caseSensitive: false);

/// Whether [screen] shows Claude Code's usage-limit options menu.
bool isUsageLimitMenu(String screen) => parseDialogOptions(screen).any((o) => _limitMenuRow.hasMatch(o.label.trim()));

final _modelSwitchRow = RegExp(r'^yes, switch to ', caseSensitive: false);

/// Whether [screen] shows Claude Code's confirmation after `/model <name>` ("Switch model?",
/// `1. Yes, switch to Sonnet 5.5` / `2. No, go back`; Claude Code 2.1.326, shown when the
/// conversation is cached for the current model).
bool isModelSwitchConfirm(String screen) =>
    screen.contains('Switch model?') && parseDialogOptions(screen).any((o) => _modelSwitchRow.hasMatch(o.label.trim()));

DialogOption? _parseNumbered(String line) {
  final m = _option.firstMatch(line);
  if (m == null) return null;
  var label = m.group(3)!;
  bool? checked;
  final box = _box.firstMatch(label);
  if (box != null) {
    checked = box.group(1)!.trim().isNotEmpty;
    label = box.group(2)!;
  }
  return DialogOption(number: int.parse(m.group(2)!), label: label, selected: m.group(1) != null, checked: checked);
}

/// The dialog's options and the screen line of its first option.
typedef _Dialog = ({List<DialogOption> options, int firstLine});

const _Dialog _noDialog = (options: <DialogOption>[], firstLine: -1);

/// Options of a dialog without numbers: the line with the cursor and the lines next to it
/// whose text starts in the same column.
_Dialog _unnumberedAbove(List<String> lines, int end) {
  for (var i = end - 1; i >= 0; i--) {
    final m = _unnumbered.firstMatch(lines[i]);
    if (m == null) continue;
    final column = lines[i].indexOf(m.group(3)!);
    bool sameColumn(String l) =>
        l.length > column && l.substring(0, column).trim().isEmpty && l[column].trim().isNotEmpty;
    var first = i;
    while (first - 1 >= 0 && sameColumn(lines[first - 1])) {
      first--;
    }
    var last = i;
    while (last + 1 < end && sameColumn(lines[last + 1])) {
      last++;
    }
    if (last == first) return _noDialog; // a lone line with a cursor is the prompt, not a dialog
    return (
      options: [
        for (var k = first; k <= last; k++)
          DialogOption(
            number: k - first + 1,
            label: lines[k].trim().replaceFirst(RegExp('^[$_markers]\\s*'), ''),
            selected: k == i,
            numbered: false,
          ),
      ],
      firstLine: first,
    );
  }
  return _noDialog;
}

_Dialog _parse(List<String> lines) {
  if (lines.isEmpty) return _noDialog;
  var end = _footerIndex(lines);
  if (end < 0) {
    // No footer: only a numbered option on the last line counts (below it there may be
    // the rule that carries the session's name).
    var last = lines.length - 1;
    while (last > 0 && _isRule(lines[last])) {
      last--;
    }
    if (_parseNumbered(lines[last]) == null) return _noDialog;
    end = last + 1;
  }
  final found = <({DialogOption o, int line})>[];
  for (var i = 0; i < end; i++) {
    final o = _parseNumbered(lines[i]);
    if (o != null) found.add((o: o, line: i));
  }
  if (found.isEmpty) return _unnumberedAbove(lines, end);
  // Walk back from the last option: n, n-1, …, 1.
  final out = [found.last];
  for (var i = found.length - 2; i >= 0 && out.first.o.number > 1; i--) {
    if (found[i].o.number == out.first.o.number - 1) out.insert(0, found[i]);
  }
  if (out.first.o.number != 1) return _noDialog;
  return (options: [for (final f in out) f.o], firstLine: out.first.line);
}

/// The options of the dialog at the bottom of [screen]: the last run numbered 1..n above
/// the dialog's footer line ("Esc to cancel", …), or at the very bottom of the screen when
/// the dialog has no footer (the review step of a question set). Description lines under an
/// option and rule lines between options are skipped. Empty when no dialog is showing or
/// the layout is unknown.
List<DialogOption> parseDialogOptions(String screen) => _parse(_lines(screen)).options;

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

/// Whether the dialog shows [text] just above its first option (long text may wrap over
/// several lines).
bool dialogShows(String screen, String text) {
  final lines = _lines(screen);
  final d = _parse(lines);
  if (d.options.isEmpty || text.trim().isEmpty) return false;
  // Up to 8 lines above the first option, stopping at the rule that opens the dialog.
  var from = d.firstLine;
  while (from > 0 && d.firstLine - from < 8 && !_isRule(lines[from - 1])) {
    from--;
  }
  return _norm(lines.sublist(from, d.firstLine).join(' ')).contains(_norm(text));
}

bool _isRule(String line) {
  // A rule may carry the session's name at its end ("──── my-session ─").
  return RegExp(r'^[─━╌]{10,}').hasMatch(line.trim());
}

/// Whether Claude Code shows its input box (a rule, then a line starting with `❯`) and no
/// dialog: it is ready for an instruction.
bool isPromptReady(String screen) {
  final lines = _lines(screen);
  if (_parse(lines).options.isNotEmpty) return false;
  for (var i = 0; i + 1 < lines.length; i++) {
    final next = lines[i + 1].trimLeft();
    if (_isRule(lines[i]) && (next.startsWith('❯') || next.startsWith('>'))) return true;
  }
  return false;
}

/// Whether Claude Code waits for a message with nothing running: its input box shows (it
/// also does while Claude works, for typing ahead) and no "esc to interrupt" line says a
/// turn is running. Only the status lines under the box count: Claude's own words above
/// it may say "esc to interrupt" too (seen live).
bool isIdlePrompt(String screen) {
  if (!isPromptReady(screen)) return false;
  final lines = _lines(screen);
  var box = -1;
  for (var i = lines.length - 1; i >= 1; i--) {
    final t = lines[i].trimLeft();
    if ((t.startsWith('❯') || t.startsWith('>')) && _isRule(lines[i - 1])) {
      box = i;
      break;
    }
  }
  if (box < 0) return false;
  var j = box + 1;
  while (j < lines.length && !_isRule(lines[j])) {
    j++;
  }
  final status = j < lines.length ? lines.sublist(j + 1) : const <String>[];
  return !status.any((l) => RegExp(r'esc to interrupt', caseSensitive: false).hasMatch(l));
}

/// The last step of a question set: "Review your answers … Ready to submit your answers?".
/// Claude Code 2.1.327 dropped the "Ready to submit…" line and keeps only the heading.
bool isReviewScreen(String screen) =>
    (dialogShows(screen, 'Ready to submit your answers?') || dialogBody(screen).contains('Review your answers')) &&
    parseDialogOptions(screen).any((o) => o.label.toLowerCase().startsWith('submit'));

/// In a multi-select question the unnumbered row under the options ("Submit", or "Next"
/// inside a question set): its text when the cursor is on it, else null.
String? selectedActionRow(String screen) {
  final lines = _lines(screen);
  final d = _parse(lines);
  if (d.options.isEmpty) return null;
  for (var i = d.firstLine; i < lines.length; i++) {
    final m = _actionRow.firstMatch(lines[i]);
    if (m != null) return m.group(1);
  }
  return null;
}

/// What kind of dialog [screen] shows, if any.
DialogKind detectDialog(String screen) {
  final lines = _lines(screen);
  final d = _parse(lines);
  if (d.options.isEmpty) return DialogKind.none;
  final labels = d.options.map((o) => o.label.toLowerCase()).toList();
  final footer = _footerIndex(lines);
  // The dialog's own text: a few lines above its options, down to the end.
  final from = d.firstLine - 6 < 0 ? 0 : d.firstLine - 6;
  final text = _norm(lines.sublist(from).join(' '));
  if (labels.any((l) => l.contains('trust this folder'))) return DialogKind.trust;
  // Claude Code 2.1.327 asks "Exit plan mode? Claude wants to exit plan mode" (Yes, and
  // switch to … / No) when Claude leaves plan mode without writing a plan.
  if (text.contains('would you like to proceed') ||
      text.contains('wants to exit plan mode') ||
      labels.any((l) => l.startsWith('tell claude what to change'))) {
    return DialogKind.plan;
  }
  if (labels.any((l) => l.startsWith('type something') || l.startsWith('chat about this')) ||
      isReviewScreen(screen) ||
      (footer >= 0 && lines[footer].contains('Enter to select') && lines[footer].contains('navigate'))) {
    return DialogKind.question;
  }
  if (text.contains('do you want to') || (labels.contains('yes') && labels.any((l) => l.startsWith('no')))) {
    return DialogKind.permission;
  }
  return DialogKind.none;
}

/// Why [screen] looks like a dialog Perch can no longer read (a sign Claude Code changed),
/// or null: options that parse but fit no known dialog, or a dialog footer at the bottom
/// with no options Perch can read above it.
String? screenDrift(String screen) {
  final lines = _lines(screen);
  final d = _parse(lines);
  if (d.options.isNotEmpty) {
    if (isUsageLimitMenu(screen) || isModelSwitchConfirm(screen)) return null;
    return detectDialog(screen) == DialogKind.none ? 'Claude Code shows a dialog Perch cannot recognise.' : null;
  }
  final footer = _footerIndex(lines);
  if (footer >= 0 && footer >= lines.length - 3) return 'Claude Code shows a dialog whose choices Perch cannot read.';
  return null;
}

/// The dialog's text above its options, from the rule that opens it (rules, the tab bar of
/// a question set and blank lines left out), one entry per screen line.
List<String> dialogBody(String screen) {
  final lines = _lines(screen);
  final d = _parse(lines);
  if (d.options.isEmpty) return const [];
  var from = d.firstLine;
  while (from > 0 && !_isRule(lines[from - 1])) {
    from--;
  }
  return [
    for (final l in lines.sublist(from, d.firstLine))
      if (l.trim().isNotEmpty && !_isRule(l) && !RegExp(r'^\s*←.*→\s*$').hasMatch(l) && !RegExp(r'^\s*\[[ ✔√×]\]\s').hasMatch(l))
        l.trim()
  ];
}

/// The lines just above the rule that opens the dialog (the tool line `● Write(x)` of a
/// permission request, or the plan of a plan approval), up to [max] lines.
List<String> aboveDialog(String screen, {int max = 60}) {
  final lines = _lines(screen);
  final d = _parse(lines);
  if (d.options.isEmpty) return const [];
  var rule = d.firstLine;
  while (rule > 0 && !_isRule(lines[rule - 1])) {
    rule--;
  }
  rule--; // the rule itself
  if (rule <= 0) return const [];
  final from = rule - max < 0 ? 0 : rule - max;
  return lines.sublist(from, rule);
}
