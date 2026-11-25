// Reads Claude Code's usage-limit wording: the error line ("You've hit your session limit ·
// resets 3:45pm"), the lines under the input box while it waits ("Usage limit reached ·
// limit resets 3:45pm" / "Continuing automatically at 3:45pm · Esc to cancel"), the
// confirmation of a cancel, and the options menu (`/rate-limit-options`). The wording comes
// from Claude Code's docs (interactive mode, "Wait for a usage limit to reset"; errors,
// "You've hit your session limit"). Pure functions.
//
// Words about a limit that Perch cannot read are reported as [LimitScreenKind.unreadable]:
// the caller raises drift instead of guessing a time.
import 'package:perch_protocol/perch_protocol.dart';

import 'dialog_screen.dart';

const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const _weekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

final _clock12 = RegExp(r'\b(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\.?\b', caseSensitive: false);
final _clock24 = RegExp(r'\b(\d{1,2}):(\d{2})\b');
final _weekdayWord = RegExp(r'\b(mon|tue|wed|thu|fri|sat|sun)[a-z]*\b', caseSensitive: false);
final _monthDay = RegExp(r'\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})\b',
    caseSensitive: false);

/// The moment a reset text such as `3:45pm`, `15:45`, `Mon 12:00am` or `Nov 20, 5pm` means,
/// on the machine's clock ([now] is local time); null when it is not a time Perch knows.
/// A time of day already past is tomorrow's; a weekday is the next one with that time.
DateTime? parseResetTime(String text, DateTime now) {
  final t = text.replaceAll(RegExp(r'\([^)]*\)'), ' ').trim();
  if (t.isEmpty) return null;
  int? hour;
  var minute = 0;
  final m12 = _clock12.firstMatch(t);
  if (m12 != null) {
    final h = int.parse(m12.group(1)!);
    final mm = m12.group(2) == null ? 0 : int.parse(m12.group(2)!);
    if (h < 1 || h > 12 || mm > 59) return null;
    final pm = m12.group(3)!.toLowerCase() == 'p';
    hour = (h % 12) + (pm ? 12 : 0);
    minute = mm;
  } else {
    final m24 = _clock24.firstMatch(t);
    if (m24 != null) {
      final h = int.parse(m24.group(1)!);
      final mm = int.parse(m24.group(2)!);
      if (h > 23 || mm > 59) return null;
      hour = h;
      minute = mm;
    }
  }
  final md = _monthDay.firstMatch(t);
  if (md != null) {
    final month = _months.indexOf(md.group(1)!.toLowerCase()) + 1;
    final day = int.parse(md.group(2)!);
    if (day < 1 || day > 31) return null;
    var at = DateTime(now.year, month, day, hour ?? 0, minute);
    // A date well in the past is next year's (a reset is never long ago).
    if (at.isBefore(now.subtract(const Duration(days: 60)))) at = DateTime(now.year + 1, month, day, hour ?? 0, minute);
    return at;
  }
  final wd = _weekdayWord.firstMatch(t);
  if (wd != null) {
    final want = _weekdays.indexOf(wd.group(1)!.toLowerCase()) + 1;
    var days = (want - now.weekday) % 7;
    var at = DateTime(now.year, now.month, now.day + days, hour ?? 0, minute);
    if (at.isBefore(now)) {
      days += 7;
      at = DateTime(now.year, now.month, now.day + days, hour ?? 0, minute);
    }
    return at;
  }
  if (hour == null) return null;
  var at = DateTime(now.year, now.month, now.day, hour, minute);
  if (at.isBefore(now.subtract(const Duration(minutes: 2)))) at = DateTime(now.year, now.month, now.day + 1, hour, minute);
  return at;
}

/// What a usage-limit line says.
class LimitMessage {
  final DateTime? resetsAt;

  /// One of [LimitWindows]; null when the line does not say.
  final String? window;

  /// The line says Claude Code continues by itself (`continuing automatically at …`).
  final bool claudeWaiting;
  const LimitMessage({this.resetsAt, this.window, this.claudeWaiting = false});
}

const _sep = r'\s*[·•|\-]\s*';
final _hitLine = RegExp("you[’']ve hit your (session|weekly|opus|sonnet|usage) limit(?:$_sep(?:limit )?resets? (?:at )?(.+))?",
    caseSensitive: false);
final _reachedLine = RegExp('usage limit reached(?:${_sep}limit resets (?:at )?(.+))?', caseSensitive: false);
final _autoLine = RegExp('continuing automatically at (.+)', caseSensitive: false);

String? _windowWord(String w) => switch (w.toLowerCase()) {
      'session' => LimitWindows.fiveHour,
      'weekly' => LimitWindows.sevenDay,
      'opus' => LimitWindows.opus,
      'sonnet' => LimitWindows.sonnet,
      _ => null,
    };

/// The text up to the next ` · ` (what follows is a help link or another hint).
String _firstPart(String s) => s.split(RegExp(_sep.replaceAll(r'\-', ''))).first.trim();

/// A usage-limit line from Claude Code (the error shown when a limit stops a turn, or the
/// conversation's record of a wait), or null for any other text.
LimitMessage? parseLimitMessage(String text, DateTime now) {
  final t = text.trim();
  final hit = _hitLine.firstMatch(t);
  if (hit != null) {
    final when = hit.group(2);
    return LimitMessage(
        resetsAt: when == null ? null : parseResetTime(_firstPart(when), now), window: _windowWord(hit.group(1)!));
  }
  final reached = _reachedLine.firstMatch(t);
  if (reached != null) {
    final auto = _autoLine.firstMatch(t);
    final when = reached.group(1) ?? auto?.group(1);
    return LimitMessage(
        resetsAt: when == null ? null : parseResetTime(_firstPart(when), now), claudeWaiting: auto != null);
  }
  return null;
}

enum LimitScreenKind {
  /// No usage-limit lines.
  none,

  /// `Continuing automatically at … · Esc to cancel`: Claude Code waits by itself.
  waiting,

  /// `Continuing shortly`: the reset passed, Claude Code is about to continue.
  continuingShortly,

  /// `Your usage limit has reset` / `Press enter to continue`: it waits for Enter.
  stale,

  /// `Automatic continue cancelled`.
  cancelled,

  /// The usage-limit options menu: Claude Code does not wait by itself.
  menu,

  /// Words about a usage limit Perch cannot read (Claude Code changed them).
  unreadable,
}

class LimitScreen {
  final LimitScreenKind kind;
  final DateTime? resetsAt;
  final String? window;
  const LimitScreen(this.kind, {this.resetsAt, this.window});

  /// Whether Claude Code waits to continue by itself; null when the screen does not say.
  bool? get claudeWaiting => switch (kind) {
        LimitScreenKind.waiting || LimitScreenKind.continuingShortly => true,
        LimitScreenKind.cancelled || LimitScreenKind.menu || LimitScreenKind.stale => false,
        _ => null,
      };
}

final _rule = RegExp(r'^[─━╌]{10,}');
final _limitWords = RegExp(r'usage limit|limit reached|limit resets|hit your \w+ limit', caseSensitive: false);

/// The screen in two parts: Claude Code's status lines under its input box (where it shows
/// a usage-limit wait), and the last lines of the conversation just above the box. A
/// screen without an input box (a dialog shows) is all status: its last 12 lines.
({List<String> status, List<String> above}) _regions(String screen) {
  final lines = [for (final l in screen.replaceAll('\r', '').split('\n')) if (l.trim().isNotEmpty) l];
  for (var i = lines.length - 1; i >= 1; i--) {
    final t = lines[i].trimLeft();
    if ((t.startsWith('❯') || t.startsWith('>')) && _rule.hasMatch(lines[i - 1].trim())) {
      var j = i + 1;
      while (j < lines.length && !_rule.hasMatch(lines[j].trim())) {
        j++;
      }
      final status = j < lines.length ? lines.sublist(j + 1) : <String>[];
      final top = i - 1;
      final above = lines.sublist(top - 6 < 0 ? 0 : top - 6, top);
      return (
        status: [for (final l in status) if (!_rule.hasMatch(l.trim())) l.trim()],
        above: [for (final l in above) l.trim()],
      );
    }
  }
  final tail = lines.length <= 12 ? lines : lines.sublist(lines.length - 12);
  return (status: [for (final l in tail) l.trim()], above: const []);
}

/// Words about a usage limit where Claude Code shows its status (under the input box), or
/// in a dialog; Claude's own words in the conversation do not count.
bool mentionsUsageLimit(String screen) => _regions(screen).status.any(_limitWords.hasMatch);

/// What a terminal screen says about a usage limit.
LimitScreen readLimitScreen(String screen, DateTime now) {
  final r = _regions(screen);
  final status = r.status;
  final joined = status.join('\n');
  // The window (and a reset) from the error line of the turn that stopped.
  LimitMessage? hit;
  for (final l in [...r.above, ...status].reversed) {
    final line = l.replaceFirst(RegExp(r'^[\s⎿●]+'), '');
    if (!_hitLine.hasMatch(line)) continue;
    hit = parseLimitMessage(line, now);
    if (hit != null) break;
  }
  DateTime? reset;
  for (final l in status.reversed) {
    final m = _reachedLine.firstMatch(l);
    if (m != null && m.group(1) != null) {
      reset = parseResetTime(_firstPart(m.group(1)!), now);
      break;
    }
  }
  if (isUsageLimitMenu(screen)) {
    return LimitScreen(LimitScreenKind.menu, resetsAt: reset ?? hit?.resetsAt, window: hit?.window);
  }
  final auto = status.map(_autoLine.firstMatch).whereType<RegExpMatch>().lastOrNull;
  final cancelled = [...r.above, ...status].any((l) => RegExp(r'automatic continue cancelled', caseSensitive: false).hasMatch(l));
  if (cancelled && auto == null) {
    return LimitScreen(LimitScreenKind.cancelled, resetsAt: reset ?? hit?.resetsAt, window: hit?.window);
  }
  if (auto != null) {
    final at = parseResetTime(_firstPart(auto.group(1)!), now);
    if (at == null && reset == null) return const LimitScreen(LimitScreenKind.unreadable);
    return LimitScreen(LimitScreenKind.waiting, resetsAt: reset ?? at, window: hit?.window);
  }
  if (RegExp(r'continuing shortly', caseSensitive: false).hasMatch(joined)) {
    return LimitScreen(LimitScreenKind.continuingShortly, resetsAt: reset ?? hit?.resetsAt, window: hit?.window);
  }
  if (RegExp(r'your usage limit has reset', caseSensitive: false).hasMatch(joined)) {
    return LimitScreen(LimitScreenKind.stale, window: hit?.window);
  }
  if (status.any(_limitWords.hasMatch)) return const LimitScreen(LimitScreenKind.unreadable);
  // The turn just stopped on the limit (its error line above the box), with no wait.
  if (hit != null && r.above.isNotEmpty && _hitLine.hasMatch(r.above.last.replaceFirst(RegExp(r'^[\s⎿●]+'), ''))) {
    return LimitScreen(LimitScreenKind.none, resetsAt: hit.resetsAt, window: hit.window);
  }
  return const LimitScreen(LimitScreenKind.none);
}

/// The menu row that cancels Claude Code's own wait.
const dontContinue = "Don't continue automatically";

/// The menu row that starts Claude Code's own wait.
const waitHere = 'Wait here, then continue automatically';

/// The options menu's row whose label starts like [label] (apostrophes compared loosely).
DialogOption? limitMenuOption(String screen, String label) {
  String norm(String s) => s.toLowerCase().replaceAll(RegExp('[’\']'), "'").trim();
  final want = norm(label);
  for (final o in parseDialogOptions(screen)) {
    if (norm(o.label).startsWith(want)) return o;
  }
  return null;
}

/// Whether [screen] confirms a cancelled wait (and no longer shows the waiting lines).
bool confirmsCancel(String screen) => readLimitScreen(screen, DateTime.now()).kind == LimitScreenKind.cancelled;
