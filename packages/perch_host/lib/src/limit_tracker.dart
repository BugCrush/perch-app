// A machine's usage limit (PRD 7.6, docs/superpowers/specs/2026-11-15-phase3-usage-limits-design.md).
//
// The limit is per account, so every session on the machine hits it together: one limit
// per machine, listing the sessions it paused. The owner's choice (Continue when available,
// or Wait) applies to all of them; a session can override it for itself. The choice and
// the limit survive a host restart.
//
// Continue when available: a session Claude Code waits in by itself is left alone; at the
// reset Perch watches for Claude Code's `quota_auto_resume_fired` or new work for
// [continueCheck] (90 s), then sends `please continue` itself. A session Claude Code does
// not wait in (a weekly limit, its options menu, a `-p` session Perch runs) gets
// `please continue` at the reset. Perch sends only while the session is at its input
// prompt and the owner has not sent anything since the limit.
//
// Wait: Claude Code's own wait is cancelled (Esc at the prompt, confirmed on screen; else
// `/rate-limit-options` → "Don't continue automatically"; else the owner is told). Nothing
// is sent at the reset.
//
// After a session resumes, the first part of the resumed turn is compared with what ran
// when the limit hit: a subagent then and none now (the work done in the main session), or
// another kind of agent, is "changed".
import 'dart:async';

import 'package:perch_protocol/perch_protocol.dart';

import 'console_typer.dart' show ConsoleKeys;
import 'dialog_screen.dart' show DialogOption, isPromptReady, isUsageLimitMenu, parseDialogOptions;
import 'usage_limits.dart';

/// What Perch sends when Claude does not pick the work up by itself.
const continueText = 'please continue';

const resumedSameNote = 'Resumed after the usage limit';
const resumedWithoutSubagentNote = 'Resumed without the subagent';

/// How Perch reaches a session.
enum LimitSessionKind {
  /// A `-p` session Perch runs itself.
  perchRun,

  /// A terminal Perch can type into and whose screen it reads.
  terminal,

  /// A terminal Perch reaches only through Claude Code's session inbox (no screen, no keys).
  inbox,

  /// Running, but Perch can neither type into it nor reach its inbox: it is only watched.
  watchOnly,

  /// Gone.
  none,
}

/// A subagent: its type (`general-purpose`, `Explore`, …) and its task.
class AgentRun {
  final String type;
  final String description;
  const AgentRun(this.type, [this.description = '']);

  Map<String, dynamic> toJson() => {'type': type, if (description.isNotEmpty) 'description': description};
  static AgentRun? fromJson(Object? j) =>
      j is Map && j['type'] is String ? AgentRun(j['type'] as String, j['description'] is String ? j['description'] as String : '') : null;

  bool sameAs(AgentRun o) {
    final a = type.trim().toLowerCase(), b = o.type.trim().toLowerCase();
    if (a.isNotEmpty && b.isNotEmpty) return a == b;
    return description.trim().toLowerCase() == o.description.trim().toLowerCase();
  }

  @override
  String toString() => description.isEmpty ? type : '$type ($description)';
}

/// What the tracker needs from the session manager.
abstract interface class LimitSessions {
  LimitSessionKind kindOf(String sessionId);
  String nameOf(String sessionId);
  String get machineName;

  /// The terminal's screen (terminal sessions), or null.
  Future<String?> screenOf(String sessionId);

  /// Presses keys in the terminal ([ConsoleKeys] for special ones).
  Future<bool> keys(String sessionId, String keys);

  /// Types [text] and Enter into the terminal (a slash command).
  Future<bool> typeLine(String sessionId, String text);

  /// Whether the session waits for a message now (at its input prompt, no dialog, not
  /// working).
  Future<bool> atPrompt(String sessionId);

  /// When the owner last sent the session a message (ms since the epoch), if known.
  int? ownerPromptAt(String sessionId);

  /// Sends [text] to the session as the phone would; throws when it cannot.
  Future<void> send(String sessionId, String text);

  /// Writes a lasting note into the session's conversation (every device sees it).
  void note(String sessionId, String text);

  /// The subagents that were running in the session's turn that stopped at [hitAt].
  List<AgentRun> agentsAt(String sessionId, DateTime hitAt);

  /// The host's usage data (from sessions it runs), if any.
  UsageSnapshot? get usage;
}

/// Where the limit and the choice are kept between runs (host.json).
abstract interface class LimitStore {
  Map<String, dynamic>? loadLimits();
  void saveLimits(Map<String, dynamic> json);
}

class _Paused {
  final String id;
  DateTime hitAt;
  bool? claudeWaiting;
  String? override;
  List<AgentRun> agents;
  bool menu = false;
  Timer? timer;
  int tries = 0;
  bool busy = false;
  _Paused(this.id, this.hitAt, {this.claudeWaiting, this.override, this.agents = const []});

  Map<String, dynamic> toJson() => {
        'id': id,
        'hitAtMs': hitAt.millisecondsSinceEpoch,
        if (claudeWaiting != null) 'claudeWaiting': claudeWaiting,
        if (override != null) 'override': override,
        if (agents.isNotEmpty) 'agents': [for (final a in agents) a.toJson()],
      };
}

class _Compare {
  final String id;
  final List<AgentRun> atLimit;
  final List<AgentRun> started = [];
  int mainTools = 0;
  Timer? timer;
  _Compare(this.id, this.atLimit);
}

class UsageLimitTracker {
  final LimitSessions sessions;
  final LimitStore? store;
  final DateTime Function() clock;

  /// How long Claude Code gets to continue by itself after the reset.
  final Duration continueCheck;

  /// How much of the resumed turn is compared at most.
  final Duration compareWindow;

  /// How often an unknown reset is looked up in the host's usage data.
  final Duration unknownPoll;

  /// How long to wait between tries when the session is not at its prompt, and how often.
  final Duration promptRetry;
  final int maxTries;

  /// How long a key press gets to show on screen, and how often the screen is read.
  final Duration confirmTimeout;
  final Duration poll;

  /// Called before Perch types or sends text (its UserPromptSubmit is not the owner's).
  void Function(String text)? perchTyping;

  /// One line per thing done, for the host's console.
  void Function(String line)? log;

  UsageLimitTracker({
    required this.sessions,
    this.store,
    DateTime Function()? clock,
    this.continueCheck = const Duration(seconds: 90),
    this.compareWindow = const Duration(minutes: 3),
    this.unknownPoll = const Duration(minutes: 10),
    this.promptRetry = const Duration(seconds: 30),
    this.maxTries = 10,
    this.confirmTimeout = const Duration(seconds: 3),
    this.poll = const Duration(milliseconds: 300),
  }) : clock = clock ?? DateTime.now {
    _load();
  }

  String _choice = LimitChoices.continueWhenAvailable;
  DateTime? _resetsAt;
  String? _window;
  bool _back = false;
  String? _problem;
  final Map<String, _Paused> _paused = {};
  final Map<String, _Compare> _comparing = {};
  final Set<String> _sending = {};
  final Map<String, DateTime> _sentAt = {};
  Timer? _resetTimer;
  Timer? _unknownTimer;
  bool _disposed = false;

  final _changes = StreamController<UsageLimit?>.broadcast();
  final _backs = StreamController<List<String>>.broadcast();
  final _reports = StreamController<ResumeReport>.broadcast();
  final _hits = StreamController<String>.broadcast();

  /// The limit as it is now, after each change (null: none).
  Stream<UsageLimit?> get changes => _changes.stream;

  /// At the reset: the sessions still paused.
  Stream<List<String>> get usageBack => _backs.stream;

  /// A session resumed and was compared.
  Stream<ResumeReport> get reports => _reports.stream;

  /// A session newly paused by the limit.
  Stream<String> get hits => _hits.stream;

  String get choice => _choice;

  /// The machine's limit now, or null.
  UsageLimit? get current => _paused.isEmpty
      ? null
      : UsageLimit(
          resetsAtMs: _resetsAt?.millisecondsSinceEpoch,
          window: _window,
          choice: _choice,
          back: _back,
          problem: _problem,
          sessions: [
            for (final p in _paused.values)
              LimitedSession(id: p.id, name: sessions.nameOf(p.id), claudeWaiting: p.claudeWaiting, override: p.override)
          ],
        );

  bool isPaused(String sessionId) => _paused.containsKey(sessionId);

  /// The words for a paused session's state: `Usage limit · resets 15:45`.
  String? pausedReason(String sessionId) {
    if (!_paused.containsKey(sessionId)) return null;
    if (_back) return 'Usage is back';
    final at = _resetsAt;
    if (at == null) return 'Usage limit';
    String two(int n) => n.toString().padLeft(2, '0');
    final clockText = '${two(at.hour)}:${two(at.minute)}';
    final far = at.difference(clock()) > const Duration(hours: 20);
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return 'Usage limit · resets ${far ? '${days[at.weekday - 1]} ' : ''}$clockText';
  }

  String _choiceFor(_Paused p) => p.override ?? _choice;

  // ------------------------------------------------------------ persistence

  void _load() {
    final j = store?.loadLimits();
    if (j == null) return;
    if (LimitChoices.lasting.contains(j['choice'])) _choice = j['choice'] as String;
    final r = j['resetsAtMs'];
    _resetsAt = r is num && r > 0 ? DateTime.fromMillisecondsSinceEpoch(r.toInt()) : null;
    _window = j['window'] is String ? j['window'] as String : null;
    _back = j['back'] == true;
    for (final s in (j['sessions'] is List ? j['sessions'] as List : const [])) {
      if (s is! Map || s['id'] is! String) continue;
      final hit = s['hitAtMs'];
      _paused[s['id'] as String] = _Paused(
        s['id'] as String,
        hit is num ? DateTime.fromMillisecondsSinceEpoch(hit.toInt()) : clock(),
        claudeWaiting: s['claudeWaiting'] is bool ? s['claudeWaiting'] as bool : null,
        override: LimitChoices.lasting.contains(s['override']) ? s['override'] as String : null,
        agents: [for (final a in (s['agents'] is List ? s['agents'] as List : const [])) ?AgentRun.fromJson(a)],
      );
    }
    if (_paused.isEmpty) {
      _resetsAt = null;
      _back = false;
    }
  }

  /// Picks the limit up again after a restart (timers; a reset that passed meanwhile).
  void start() {
    if (_paused.isEmpty) return;
    if (_back) {
      _atReset(announce: false);
    } else {
      _arm();
    }
  }

  void _save() {
    final s = store;
    if (s == null) return;
    try {
      s.saveLimits({
        'choice': _choice,
        if (_paused.isNotEmpty) ...{
          if (_resetsAt != null) 'resetsAtMs': _resetsAt!.millisecondsSinceEpoch,
          if (_window != null) 'window': _window,
          'back': _back,
          'sessions': [for (final p in _paused.values) p.toJson()],
        },
      });
    } catch (_) {}
  }

  void _changed() {
    if (_disposed) return;
    _save();
    _changes.add(current);
  }

  void _say(String line) => log?.call(line);

  // ------------------------------------------------------------ a limit hits

  /// A session hit the limit (a hook, the stream, the transcript or the screen said so).
  /// Later calls for the same session add what they know (the reset, whether Claude Code
  /// waits, its menu). [refine]: only add to a pause that is still on (a screen read late
  /// must not pause a session that resumed meanwhile).
  void hit(String sessionId,
      {DateTime? resetsAt, String? window, bool? claudeWaiting, bool menu = false, DateTime? at, bool refine = false}) {
    if (_disposed || (refine && !_paused.containsKey(sessionId))) return;
    final now = clock();
    _comparing.remove(sessionId)?.timer?.cancel();
    var p = _paused[sessionId];
    final isNew = p == null;
    if (isNew && _back) {
      // A new limit after the last one reset: start over (the choice stands).
      _back = false;
      _problem = null;
      _resetsAt = null;
    }
    if (p == null) {
      final hitAt = at ?? now;
      p = _Paused(sessionId, hitAt, agents: sessions.agentsAt(sessionId, hitAt));
      _paused[sessionId] = p;
      _say('Usage limit: ${sessions.nameOf(sessionId)} is paused');
    }
    final wasWaiting = p.claudeWaiting;
    final wasMenu = p.menu;
    if (claudeWaiting != null) p.claudeWaiting = claudeWaiting;
    if (menu) {
      p.menu = true;
      p.claudeWaiting = false;
    }
    if (sessions.kindOf(sessionId) == LimitSessionKind.perchRun) p.claudeWaiting = false;
    if (resetsAt != null && resetsAt.isAfter(now.subtract(const Duration(minutes: 1)))) {
      if (_resetsAt == null || resetsAt.isAfter(_resetsAt!)) _resetsAt = resetsAt;
    }
    if (window != null) _window = window;
    _arm();
    if (isNew && !_hits.isClosed) _hits.add(sessionId);
    _changed();
    if (isNew || wasWaiting != p.claudeWaiting || wasMenu != p.menu) unawaited(_apply(p));
  }

  /// Carries out the choice that applies to [p] now (before the reset).
  Future<void> _apply(_Paused p) async {
    if (p.busy || _disposed || !_paused.containsKey(p.id)) return;
    p.busy = true;
    try {
      if (_choiceFor(p) == LimitChoices.wait) {
        if (p.claudeWaiting != false || p.menu) await _cancelWait(p);
      } else if (p.menu) {
        await _closeMenu(p);
      }
    } finally {
      p.busy = false;
    }
    if (_back && _choiceFor(p) == LimitChoices.continueWhenAvailable && _paused.containsKey(p.id)) {
      p.tries = 0;
      unawaited(_tryContinue(p));
    }
  }

  Future<String?> _waitForScreen(String sid, bool Function(String screen) ok) async {
    final end = clock().add(confirmTimeout);
    while (true) {
      final s = await sessions.screenOf(sid);
      if (s != null && ok(s)) return s;
      if (_disposed || !clock().isBefore(end)) return null;
      await Future<void>.delayed(poll);
    }
  }

  void _problemFor(String text) {
    _problem = text;
    _say(text);
    _changed();
  }

  /// Wait: stops Claude Code's own automatic continue for [p].
  Future<void> _cancelWait(_Paused p) async {
    final sid = p.id;
    final where = sessions.machineName;
    final couldNot = "Couldn't stop Claude Code from continuing on $where";
    switch (sessions.kindOf(sid)) {
      case LimitSessionKind.perchRun:
        p.claudeWaiting = false;
        return;
      case LimitSessionKind.inbox:
      case LimitSessionKind.watchOnly:
      case LimitSessionKind.none:
        // No keys and no screen: Perch cannot cancel it and does not guess.
        if (p.claudeWaiting != false) _problemFor(couldNot);
        return;
      case LimitSessionKind.terminal:
        break;
    }
    final screen = await sessions.screenOf(sid);
    final now = clock();
    final r = screen == null ? null : readLimitScreen(screen, now);
    if (r?.kind == LimitScreenKind.cancelled) {
      _cancelled(p);
      return;
    }
    if (r?.kind == LimitScreenKind.menu) {
      if (await _pickMenu(p, dontContinue)) {
        _cancelled(p);
      } else {
        _problemFor(couldNot);
      }
      return;
    }
    final waiting = r?.kind == LimitScreenKind.waiting || r?.kind == LimitScreenKind.continuingShortly;
    if (!waiting) {
      if (r != null && r.kind != LimitScreenKind.unreadable) {
        // The screen shows no wait: there is nothing to cancel.
        p.claudeWaiting = false;
        _changed();
        return;
      }
      if (p.claudeWaiting == false) return;
    }
    if (waiting) {
      await sessions.keys(sid, ConsoleKeys.escape);
      if (await _waitForScreen(sid, confirmsCancel) != null) {
        _cancelled(p);
        return;
      }
    }
    // Claude Code's own command for it.
    final now2 = await sessions.screenOf(sid);
    if (now2 != null && isPromptReady(now2)) {
      perchTyping?.call('/rate-limit-options');
      if (await sessions.typeLine(sid, '/rate-limit-options') && await _waitForScreen(sid, isUsageLimitMenu) != null) {
        if (await _pickMenu(p, dontContinue)) {
          _cancelled(p);
          return;
        }
        // A menu without that row (an organization account): do not leave it open.
        final still = await sessions.screenOf(sid);
        if (still != null && isUsageLimitMenu(still)) {
          await sessions.keys(sid, ConsoleKeys.escape);
          await _waitForScreen(sid, (s) => !isUsageLimitMenu(s));
        }
      }
    }
    _problemFor(couldNot);
  }

  void _cancelled(_Paused p) {
    p
      ..claudeWaiting = false
      ..menu = false;
    _say('Usage limit: Claude Code will not continue ${sessions.nameOf(p.id)} by itself');
    _changed();
  }

  /// Chooses the menu row starting with [label] and waits for Claude Code's confirmation.
  Future<bool> _pickMenu(_Paused p, String label) async {
    final screen = await sessions.screenOf(p.id);
    if (screen == null) return false;
    final o = limitMenuOption(screen, label);
    if (o == null) return false;
    if (o.numbered) {
      if (!await sessions.keys(p.id, '${o.number}')) return false;
    } else {
      final at = limitMenuOptionIndex(screen, o);
      final moves = at.target - at.selected;
      final key = moves > 0 ? ConsoleKeys.down : ConsoleKeys.up;
      if (!await sessions.keys(p.id, '${key * moves.abs()}${ConsoleKeys.enter}')) return false;
    }
    return await _waitForScreen(p.id, (s) => !isUsageLimitMenu(s) && (label != dontContinue || confirmsCancel(s))) != null;
  }

  /// Continue when available with the options menu showing: closes it (Esc, checked on
  /// screen); Perch sends `please continue` itself at the reset.
  Future<void> _closeMenu(_Paused p) async {
    if (sessions.kindOf(p.id) != LimitSessionKind.terminal) return;
    final screen = await sessions.screenOf(p.id);
    if (screen == null || !isUsageLimitMenu(screen)) {
      p.menu = false;
      return;
    }
    await sessions.keys(p.id, ConsoleKeys.escape);
    if (await _waitForScreen(p.id, (s) => !isUsageLimitMenu(s)) != null) {
      p.menu = false;
      _changed();
    } else {
      _problemFor("Couldn't close Claude Code's usage-limit menu on ${sessions.machineName}");
    }
  }

  // ------------------------------------------------------------ the reset

  void _arm() {
    _resetTimer?.cancel();
    _unknownTimer?.cancel();
    _resetTimer = _unknownTimer = null;
    if (_paused.isEmpty || _back || _disposed) return;
    final at = _resetsAt;
    if (at != null) {
      final wait = at.difference(clock());
      _resetTimer = Timer(wait.isNegative ? Duration.zero : wait, _reached);
    } else {
      _unknownTimer = Timer.periodic(unknownPoll, (_) => _checkUsage());
    }
  }

  UsageWindow? _windowOf(UsageSnapshot u) => _window == LimitWindows.sevenDay ? u.sevenDay : u.fiveHour;

  /// An unknown reset: the host's usage data, when it has any, says when usage is back.
  void _checkUsage() {
    final u = sessions.usage;
    if (u == null || _paused.isEmpty) return;
    final w = _windowOf(u);
    if (w == null) return;
    final resets = w.resetsAt > 0 ? DateTime.fromMillisecondsSinceEpoch(w.resetsAt * 1000) : null;
    if (w.status == 'rejected') {
      if (resets != null && resets.isAfter(clock())) {
        _resetsAt = resets;
        _arm();
        _changed();
      }
      return;
    }
    _atReset();
  }

  /// The host's usage data changed (a session Perch runs reported it).
  void usageChanged(UsageSnapshot u) {
    if (_paused.isEmpty || _back) return;
    if (_resetsAt == null) _checkUsage();
  }

  void _reached() {
    // The host's usage data, where it has any, must agree that the window is open again.
    final u = sessions.usage;
    final w = u == null ? null : _windowOf(u);
    if (w != null && w.status == 'rejected' && w.resetsAt > 0) {
      final later = DateTime.fromMillisecondsSinceEpoch(w.resetsAt * 1000);
      if (later.isAfter(clock().add(const Duration(seconds: 5)))) {
        _resetsAt = later;
        _arm();
        _changed();
        return;
      }
    }
    _atReset();
  }

  void _atReset({bool announce = true}) {
    if (_disposed || _paused.isEmpty) return;
    _resetTimer?.cancel();
    _unknownTimer?.cancel();
    for (final id in _paused.keys.toList()) {
      if (sessions.kindOf(id) == LimitSessionKind.none) _drop(id);
    }
    if (_paused.isEmpty) {
      _clear();
      return;
    }
    _back = true;
    _say('Usage is back on ${sessions.machineName}');
    _changed();
    if (announce && !_backs.isClosed) _backs.add(_paused.keys.toList());
    for (final p in _paused.values.toList()) {
      if (_choiceFor(p) != LimitChoices.continueWhenAvailable) continue;
      p.tries = 0;
      final kind = sessions.kindOf(p.id);
      if (kind != LimitSessionKind.perchRun && p.claudeWaiting != false) {
        // Claude Code continues by itself: give it [continueCheck].
        p.timer?.cancel();
        p.timer = Timer(continueCheck, () => _tryContinue(p));
      } else {
        unawaited(_tryContinue(p));
      }
    }
  }

  /// Sends `please continue` to [p] when it is at its prompt and the owner has sent
  /// nothing since the limit; else tries again later. [now]: the owner asked for it.
  Future<void> _tryContinue(_Paused p, {bool now = false}) async {
    if (_disposed || _paused[p.id] != p || p.busy) return;
    p.timer?.cancel();
    final sid = p.id;
    if (!now) {
      final last = sessions.ownerPromptAt(sid);
      if (last != null && last > p.hitAt.millisecondsSinceEpoch + 1000 && !_ours(sid, last)) {
        _resumed(p, 'owner');
        return;
      }
    }
    if (sessions.kindOf(sid) == LimitSessionKind.watchOnly) {
      _problemFor("Perch cannot send please continue to ${sessions.nameOf(sid)} on ${sessions.machineName}");
      return;
    }
    if (!await sessions.atPrompt(sid)) {
      if (_paused[sid] != p) return;
      if (++p.tries < maxTries) {
        p.timer = Timer(promptRetry, () => _tryContinue(p, now: now));
      } else {
        _problemFor("Couldn't send please continue to ${sessions.nameOf(sid)}: it is not at its prompt");
      }
      return;
    }
    if (_paused[sid] != p) return;
    perchTyping?.call(continueText);
    _sending.add(sid);
    _sentAt[sid] = clock();
    try {
      await sessions.send(sid, continueText);
    } catch (e) {
      _problemFor("Couldn't send please continue to ${sessions.nameOf(sid)} on ${sessions.machineName}");
      return;
    } finally {
      _sending.remove(sid);
    }
    _say('Usage limit: sent please continue to ${sessions.nameOf(sid)}');
    _resumed(p, 'perch');
  }

  /// Whether the owner prompt at [atMs] is Perch's own `please continue`.
  bool _ours(String sid, int atMs) {
    final sent = _sentAt[sid];
    return sent != null && (atMs - sent.millisecondsSinceEpoch).abs() < 120000;
  }

  // ------------------------------------------------------------ the owner's choice

  /// The owner's choice: for the machine, or with [sessionId] for that session only.
  /// [LimitChoices.continueNow] sends `please continue` now.
  Future<void> choose(String choice, {String? sessionId}) async {
    if (sessionId != null && !_paused.containsKey(sessionId)) {
      throw StateError('This session is not paused by a usage limit.');
    }
    if (choice == LimitChoices.continueNow) {
      final targets = sessionId == null ? _paused.values.toList() : [_paused[sessionId]!];
      if (targets.isEmpty) throw StateError('No session is paused by a usage limit.');
      for (final p in targets) {
        p.tries = 0;
        unawaited(_tryContinue(p, now: true));
      }
      return;
    }
    if (!LimitChoices.lasting.contains(choice)) throw ArgumentError('Unknown choice: $choice');
    _problem = null;
    if (sessionId == null) {
      _choice = choice;
    } else {
      final p = _paused[sessionId]!;
      p.override = choice == _choice ? null : choice;
    }
    _changed();
    for (final p in _paused.values.toList()) {
      if (sessionId != null && p.id != sessionId) continue;
      p.timer?.cancel();
      unawaited(_apply(p));
    }
  }

  // ------------------------------------------------------------ what happens next

  /// Claude Code continued by itself (`quota_auto_resume_fired`).
  void claudeContinued(String sessionId) {
    final p = _paused[sessionId];
    if (p != null) _resumed(p, 'claude');
  }

  /// Claude Code waits for Enter after a reset during sleep (`quota_auto_resume_stale`), or
  /// gave up waiting (`quota_auto_resume_disabled`): Perch acts as if it never waited.
  void claudeStopped(String sessionId) {
    final p = _paused[sessionId];
    if (p == null) return;
    p.claudeWaiting = false;
    _changed();
    if (_back && _choiceFor(p) == LimitChoices.continueWhenAvailable) {
      p.tries = 0;
      unawaited(_tryContinue(p));
    }
  }

  /// The owner sent the session a message (typed at the terminal, or from the phone).
  void ownerPrompt(String sessionId, [String? text]) {
    if (_sending.contains(sessionId)) return;
    final sent = _sentAt[sessionId];
    if (text != null &&
        text.toLowerCase().contains(continueText) &&
        sent != null &&
        clock().difference(sent) < const Duration(minutes: 2)) {
      return; // Perch's own please continue
    }
    final p = _paused[sessionId];
    if (p != null) _resumed(p, 'owner');
  }

  static bool _isAgentTool(String name) => name == 'Task' || name == 'Agent';

  /// A live conversation event of the session.
  void activity(String sessionId, ConversationEvent e) {
    final p = _paused[sessionId];
    if (p != null && e.parentToolUseId == null && _isWork(e) && e.atMs >= p.hitAt.millisecondsSinceEpoch) {
      _resumed(p, e is UserMessage ? 'owner' : 'claude');
    }
    final c = _comparing[sessionId];
    if (c == null || e.parentToolUseId != null) return;
    switch (e) {
      case ToolCall(:final name, :final input) when _isAgentTool(name):
        c.started.add(AgentRun(
            input['subagent_type'] is String ? input['subagent_type'] as String : 'general-purpose',
            input['description'] is String ? input['description'] as String : ''));
        _decide(c);
      case ToolCall():
        c.mainTools++;
      case SubagentStarted(:final subagentType, :final description):
        c.started.add(AgentRun(subagentType, description));
        _decide(c);
      case TurnEnded():
        _decide(c);
      default:
        break;
    }
  }

  bool _isWork(ConversationEvent e) => switch (e) {
        ToolCall() || SubagentStarted() => true,
        UserMessage(:final text) => !text.toLowerCase().contains(continueText) || !_sentRecently(e),
        AssistantText(:final text) =>
          parseLimitMessage(text, clock()) == null && !text.trimLeft().startsWith('API Error'),
        _ => false,
      };

  bool _sentRecently(ConversationEvent e) {
    for (final t in _sentAt.values) {
      if ((e.atMs - t.millisecondsSinceEpoch).abs() < 120000) return true;
    }
    return false;
  }

  /// A subagent started (the `SubagentStart` hook).
  void agentStarted(String sessionId, AgentRun run) {
    final c = _comparing[sessionId];
    if (c == null) return;
    c.started.add(run);
    _decide(c);
  }

  /// The session's turn ended (the `Stop` hook).
  void turnEnded(String sessionId) {
    final c = _comparing[sessionId];
    if (c != null) _decide(c);
  }

  /// The session is gone (ended, deleted).
  void forget(String sessionId) {
    _comparing.remove(sessionId)?.timer?.cancel();
    if (_drop(sessionId)) {
      if (_paused.isEmpty) {
        _clear();
      } else {
        _changed();
      }
    }
  }

  bool _drop(String id) {
    final p = _paused.remove(id);
    p?.timer?.cancel();
    return p != null;
  }

  void _resumed(_Paused p, String by) {
    if (_paused[p.id] != p) return;
    _drop(p.id);
    // What ran when the limit hit, now that the transcript has caught up.
    final agents = <AgentRun>[...p.agents];
    for (final a in sessions.agentsAt(p.id, p.hitAt)) {
      if (!agents.any((x) => x.sameAs(a) && x.description == a.description)) agents.add(a);
    }
    _say('Usage limit: ${sessions.nameOf(p.id)} resumed (by $by)');
    final c = _Compare(p.id, agents);
    _comparing[p.id] = c;
    if (agents.isEmpty) {
      _decide(c);
    } else {
      c.timer = Timer(compareWindow, () => _decide(c));
    }
    if (_paused.isEmpty) {
      _clear();
    } else {
      _changed();
    }
  }

  void _decide(_Compare c) {
    if (_comparing[c.id] != c || _disposed) return;
    _comparing.remove(c.id);
    c.timer?.cancel();
    String text;
    var changed = false;
    if (c.atLimit.isEmpty) {
      text = resumedSameNote;
    } else if (c.started.isNotEmpty) {
      final same = c.started.any((s) => c.atLimit.any(s.sameAs));
      if (same) {
        text = resumedSameNote;
      } else {
        changed = true;
        text = 'Resumed with a different agent (${c.started.first.type} instead of ${c.atLimit.first.type})';
      }
    } else if (c.mainTools > 0) {
      changed = true;
      text = resumedWithoutSubagentNote;
    } else {
      text = resumedSameNote;
    }
    sessions.note(c.id, text);
    if (!_reports.isClosed) {
      _reports.add(ResumeReport(sessionId: c.id, sessionName: sessions.nameOf(c.id), changed: changed, text: text));
    }
  }

  void _clear() {
    for (final p in _paused.values) {
      p.timer?.cancel();
    }
    _paused.clear();
    _resetTimer?.cancel();
    _unknownTimer?.cancel();
    _resetsAt = null;
    _window = null;
    _back = false;
    _problem = null;
    _changed();
  }

  /// Paused sessions being moved to another account (ended, then resumed): not pruned while
  /// their process is gone.
  final Set<String> _moving = {};

  /// [sessionId] is about to be ended and resumed on another account.
  void beginMove(String sessionId) {
    if (_paused.containsKey(sessionId)) _moving.add(sessionId);
  }

  /// The move of [sessionId] did not happen: it is an ordinary paused session again.
  void moveFailed(String sessionId) => _moving.remove(sessionId);

  /// [oldId] runs again as [newId] on another account, which has usage: Perch continues it
  /// now (`please continue` only at its prompt, and only when the owner sent nothing since
  /// the limit), then compares how it resumed as after any limit.
  void moved(String oldId, String newId) {
    _moving.remove(oldId);
    final p = _paused.remove(oldId);
    if (p == null || _disposed) return;
    p.timer?.cancel();
    final next = _Paused(newId, p.hitAt, claudeWaiting: false, override: LimitChoices.continueWhenAvailable, agents: p.agents);
    _paused[newId] = next;
    _say('Usage limit: ${sessions.nameOf(newId)} moved to another account');
    _changed();
    unawaited(_tryContinue(next));
  }

  /// Sessions that are gone leave the limit (the manager calls this after each listing).
  void prune() {
    var any = false;
    for (final id in _paused.keys.toList()) {
      if (_moving.contains(id)) continue;
      if (sessions.kindOf(id) == LimitSessionKind.none) any = _drop(id) || any;
    }
    if (!any) return;
    if (_paused.isEmpty) {
      _clear();
    } else {
      _changed();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _resetTimer?.cancel();
    _unknownTimer?.cancel();
    for (final p in _paused.values) {
      p.timer?.cancel();
    }
    for (final c in _comparing.values) {
      c.timer?.cancel();
    }
    await _changes.close();
    await _backs.close();
    await _reports.close();
    await _hits.close();
  }
}

/// Where the cursor is and where [o] is in the menu (for menus drawn without numbers).
({int selected, int target}) limitMenuOptionIndex(String screen, DialogOption o) {
  final options = parseDialogOptions(screen);
  var selected = 0, target = 0;
  for (var i = 0; i < options.length; i++) {
    if (options[i].selected) selected = i;
    if (options[i].label == o.label) target = i;
  }
  return (selected: selected, target: target);
}
