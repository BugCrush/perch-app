// Registry of sessions: Perch-run ones (child processes) and outside ones (terminal or
// background sessions listed by `claude agents --json`, watched through their transcript).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:perch_protocol/perch_protocol.dart';

import 'claude_session.dart';
import 'compatibility.dart';
import 'console_typer.dart';
import 'dialog_screen.dart';
import 'external_sessions.dart';
import 'host_accounts.dart';
import 'hooks.dart' show perchHookEvents, perchHookHold;
import 'inbox.dart';
import 'limit_tracker.dart';
import 'push_notifier.dart' show PushSource;
import 'self_test.dart' show isSelfTestEntry, isSelfTestHook;
import 'session_search.dart';
import 'stream_parser.dart';
import 'terminal_prompts.dart';
import 'terminal_window.dart';
import 'transcript.dart';
import 'transcript_tailer.dart';
import 'usage_limits.dart';

const int maxEventsPerSession = 5000;

/// Events sent on a first subscribe, and per `loadEarlier`.
const int historyPageSize = 300;

const takeOverNotice = 'Continued on phone. To take it back, run claude --resume in the terminal.';
const handBackNotice = 'Continued in the terminal.';

/// How long after a hand-back a `SessionEnd` hook is taken for the host's own copy's.
const handBackEndGrace = Duration(seconds: 15);
const trustReason = 'Trust this folder on the machine to continue';

class NoSuchSession implements Exception {
  final String id;
  NoSuchSession([this.id = '']);
  @override
  String toString() => 'No such session: $id';
}

class ReadOnlySession implements Exception {
  @override
  String toString() => 'This session cannot be controlled from Perch';
}

/// The terminal session is working; taking it over needs `force`.
class SessionBusy implements Exception {
  @override
  String toString() => 'Claude is still working in the terminal';
}

/// A message could not be typed into a terminal session (no live process, typing not
/// supported on this machine, or the typing helper failed). The app may offer a take-over.
class CannotType implements Exception {
  final String message;
  CannotType(this.message);
  @override
  String toString() => message;
}

/// A phone message was not typed: the terminal shows one of Claude Code's dialogs.
class TerminalShowsDialog implements Exception {
  final String message;
  TerminalShowsDialog(this.message);
  @override
  String toString() => message;
}

class TakeoverFailed implements Exception {
  final String message;
  TakeoverFailed(this.message);
  @override
  String toString() => message;
}

/// A `PermissionRequest` hook of a terminal Perch cannot type into, waiting for the
/// phone's answer to the card for [tool] with [input].
class _HookWaiter {
  final String tool;
  final Map<String, dynamic> input;
  final Object? suggestions;
  final done = Completer<Map<String, dynamic>?>();
  _HookWaiter(this.tool, this.input, this.suggestions);

  void finish(Map<String, dynamic>? decision) {
    if (!done.isCompleted) done.complete(decision);
  }
}

/// Events, prompts and state of one session with a conversation buffer.
class _Session {
  final String id;
  String name;
  String cwd;
  String? model;
  final int startedAtMs;
  SessionOrigin origin;

  /// Running child process (origin perch).
  ClaudeSession? claude;
  final List<StreamSubscription<dynamic>> claudeSubs = [];

  /// Outside session data (origin external), and the Claude session id for both kinds.
  ExternalEntry? entry;
  String? claudeId;
  TranscriptTailer? tailer;
  StreamSubscription<TranscriptLine>? tailerSub;
  String? title;

  /// The name the owner gave the session in Claude Code (`-n`, `/rename`, Perch's Rename):
  /// wins over every other name.
  String? customTitle;

  /// When the owner last sent the session a message (its transcript, or Perch sending to
  /// a session it runs).
  int? lastPromptAtMs;
  bool takenOver = false;

  /// The account Perch started (or resumed) it on; null: not started by Perch.
  String? accountId;

  /// The name given when Perch started it (`-n`); wins over Claude's titles.
  String? fixedName;

  /// Started from the phone and stopped at the "trust this folder" dialog; the first
  /// instruction is typed once the folder is trusted.
  bool trustPending = false;
  String? pendingInstruction;

  /// The card for what a terminal session is waiting on, if any.
  PromptRequest? terminalPrompt;
  final Set<String> answeredTerminalPrompts = {};

  /// The tool use the open card stands for (its result closes the card), when known.
  String? promptToolUseId;

  /// When a hook opened the card: it then stays until a hook or the transcript closes it
  /// (or the session stops waiting for longer than the grace period).
  DateTime? hookPromptAt;

  /// The state a hook reported, and when; it wins over the listing for a short while.
  SessionState? hookState;
  String? hookReason;
  DateTime? hookStateAt;
  bool hookEnded = false;

  /// When the owner resumed this taken-over session in a terminal: the host's own copy,
  /// stopped then, still sends a `SessionEnd` with the same session id.
  DateTime? handedBackAt;

  /// The host's own copy as Claude Code lists it when it runs under a `.cmd` shim: the
  /// claude.exe ([child]) under the process the host started ([parent]).
  ({int parent, int child})? copyChild;

  /// Bumped whenever a hook closes the card (a slower hook in flight must not reopen it).
  int closeSeq = 0;

  /// Waiting `PermissionRequest` hooks (terminals Perch cannot type into).
  final List<_HookWaiter> hookWaiters = [];

  /// When the phone pressed Stop for a terminal Perch cannot press Esc in: the next stop
  /// check (before or after a tool) ends the turn.
  DateTime? stopRequestedAt;

  /// Subagents a `SubagentStart` hook reported and no `SubagentStop` ended yet (agent id ->
  /// agent type).
  final Map<String, String> hookAgents = {};

  /// The state Claude Code listed last (a turn that ended is checked for a usage limit on
  /// screen when no hook said so).
  SessionState? lastListedState;

  /// Transcript lines of known types Perch could not read.
  int malformedLines = 0;
  bool answering = false;
  Future<void>? refreshing;

  final List<ConversationEvent> buffer = [];
  int seq = 0;

  /// True while the transcript already on disk is being read in: those events are history,
  /// served by `history()`, not live updates to push to every client.
  bool readingBacklog = false;
  final Set<String> knownPrompts = {};

  _Session({
    required this.id,
    required this.name,
    required this.cwd,
    this.model,
    required this.startedAtMs,
    required this.origin,
  });
}

class SessionManager implements PushSource {
  final ClaudeLauncher launcher;
  final ExternalSessions external;
  /// Types into terminal sessions. Defaults to none; the host entry point passes the real one.
  final TerminalConsole typer;

  /// Delivers messages to terminal sessions no [typer] adapter can operate, through
  /// Claude Code's session inbox. Null: none (such sends raise [CannotType]).
  final ClaudeInbox? inbox;
  final String? _configDir;

  /// Opens a visible terminal window for a new session (Windows).
  final TerminalWindowOpener _openWindow;

  /// How long a new terminal session may take to appear in `claude agents --json`, and how
  /// often to look.
  final Duration terminalStartTimeout;
  final Duration terminalPoll;

  /// How often, and how long, to re-read a terminal's screen while answering a card.
  final Duration answerPoll;
  final Duration answerTimeout;

  /// How long what a hook said wins over `claude agents --json`, which may lag behind.
  final Duration hookGrace;

  /// How long an answer waits for the `PermissionRequest` hook of a terminal Perch cannot
  /// type into, when the card opened before it arrived.
  final Duration hookArrival;

  /// Raised to `drifted` when Claude Code shows or sends something Perch cannot read.
  final CompatibilityTracker compatibility;

  /// The accounts sessions can start on (null: every session uses the machine's login).
  final HostAccounts? accounts;

  SessionManager({
    required this.launcher,
    ExternalSessions? external,
    TerminalConsole? typer,
    this.inbox,
    this.accounts,
    String? claudeConfigDir,
    TerminalWindowOpener? openWindow,
    this.terminalStartTimeout = const Duration(seconds: 45),
    this.terminalPoll = const Duration(seconds: 1),
    this.answerPoll = const Duration(milliseconds: 300),
    this.answerTimeout = const Duration(seconds: 6),
    this.hookGrace = const Duration(seconds: 10),
    this.hookArrival = const Duration(seconds: 2),
    CompatibilityTracker? compatibility,
    LimitStore? limitStore,
    UsageLimitTracker Function(LimitSessions sessions)? limitTracker,
    this.searchIndexDir,
  })  : compatibility = compatibility ?? CompatibilityTracker(),
        external = external ?? ExternalSessions(launcher),
        typer = typer ?? UnsupportedTerminalConsole(),
        _configDir = claudeConfigDir,
        _openWindow = openWindow ?? openTerminalWindow {
    final adapter = _LimitAdapter(this);
    limits = limitTracker?.call(adapter) ?? UsageLimitTracker(sessions: adapter, store: limitStore);
    limits.hits.listen((sid) {
      if (!_disposed) _usageLimits.add(sid);
    });
    limits.changes.listen(_limitChanged);
    _pausedIds = {for (final x in limits.current?.sessions ?? const <LimitedSession>[]) x.id};
    limits.start();
  }

  /// The machine's usage limit (one per machine: every session shares the account).
  late final UsageLimitTracker limits;

  /// What this machine is called (the usage-limit messages name it).
  String machineName = Platform.localHostname;

  Set<String> _pausedIds = {};

  /// The limit changed: sessions it paused or let go show their new state.
  void _limitChanged(UsageLimit? l) {
    if (_disposed) return;
    final now = {for (final x in l?.sessions ?? const <LimitedSession>[]) x.id};
    for (final id in {..._pausedIds, ...now}) {
      final s = _sessions[id];
      if (s != null) {
        _sessionUpdates.add(_summary(s));
      } else if (_externals[id] case final e?) {
        _sessionUpdates.add(_titled(e));
      }
    }
    _pausedIds = now;
  }

  /// A session paused by the usage limit (and not busy with anything else) is blocked,
  /// with the limit's words.
  SessionSummary _limited(SessionSummary s) {
    final reason = limits.pausedReason(s.id);
    if (reason == null || !s.live) return s;
    if (s.state != SessionState.idle && s.state != SessionState.blocked) return s;
    return s.copyWith(state: SessionState.blocked, reason: reason);
  }

  final _sessionUpdates = StreamController<SessionSummary>.broadcast();
  final _events = StreamController<({String sessionId, ConversationEvent event})>.broadcast();
  final _promptsOpened = StreamController<({String sessionId, PromptRequest prompt})>.broadcast();
  final _promptsClosed = StreamController<({String sessionId, String promptId})>.broadcast();
  final _usageUpdates = StreamController<UsageSnapshot>.broadcast();
  final _usageLimits = StreamController<String>.broadcast();

  /// Sessions with a buffer: Perch-run, taken over, and watched outside sessions.
  final Map<String, _Session> _sessions = {};

  /// Outside sessions from the last listing that are not in [_sessions].
  Map<String, ExternalEntry> _externals = {};
  final Map<String, Future<SessionSummary>> _takeovers = {};
  UsageSnapshot? _usage;
  bool _disposed = false;

  @override
  Stream<SessionSummary> get sessionUpdates => _sessionUpdates.stream;
  Stream<({String sessionId, ConversationEvent event})> get events => _events.stream;
  @override
  Stream<({String sessionId, PromptRequest prompt})> get promptsOpened => _promptsOpened.stream;
  @override
  Stream<({String sessionId, String promptId})> get promptsClosed => _promptsClosed.stream;
  Stream<UsageSnapshot> get usageUpdates => _usageUpdates.stream;

  /// Session ids, as a session hits a usage limit (Claude Code's quota notification, or a
  /// Perch-run session's usage window turning `rejected`).
  @override
  Stream<String> get usageLimits => _usageLimits.stream;
  UsageSnapshot? get usage => _usage;

  /// The session's summary now, or null when it is not known.
  @override
  SessionSummary? summaryOf(String sessionId) {
    final s = _sessions[sessionId];
    if (s != null) return _summary(s);
    final e = _externals[sessionId];
    return e == null ? null : _titled(e);
  }

  /// Whether Perch has keys for a terminal (an adapter), by process id; else it reaches it
  /// through the inbox. Learnt when a limit hits (macOS asks the console).
  final Map<int, bool> _operable = {};

  /// Whether a Claude Code session id belongs to a session Perch runs as a child process
  /// (its hooks say nothing about a terminal).
  bool isPerchRun(String claudeId) => _perchRun(claudeId);

  /// The window a usage snapshot says is used up, if any.
  static ({int resetsAt, String? type})? _rejectedWindow(UsageSnapshot u) {
    if (u.fiveHour?.status == 'rejected') return (resetsAt: u.fiveHour!.resetsAt, type: 'five_hour');
    if (u.sevenDay?.status == 'rejected') return (resetsAt: u.sevenDay!.resetsAt, type: 'seven_day');
    return null;
  }

  static String? _windowOfType(String? t) => switch (t) {
        'five_hour' => LimitWindows.fiveHour,
        'seven_day' => LimitWindows.sevenDay,
        'seven_day_opus' => LimitWindows.opus,
        'seven_day_sonnet' => LimitWindows.sonnet,
        _ => null,
      };

  /// Claude Code's own session id for a session, once known.
  String? claudeSessionIdOf(String sessionId) {
    final s = _sessions[sessionId];
    return s?.claude?.claudeSessionId ?? s?.claudeId;
  }

  /// The session whose Claude Code session id is [claudeId] (`/perch` in a terminal names
  /// its own session that way), listing the machine's sessions again when it is not known
  /// yet; null when Perch does not see it. A session listed only by process id is matched
  /// through Claude Code's own registry (`sessions/<pid>.json`).
  Future<SessionSummary?> sessionForClaudeId(String claudeId) async {
    SessionSummary? find() {
      for (final s in _sessions.values) {
        final pid = s.entry?.pid ?? s.claude?.pid;
        final cid = s.claude?.claudeSessionId ??
            s.claudeId ??
            s.entry?.claudeSessionId ??
            (pid == null ? null : registeredSessionId(pid));
        if (cid == claudeId) return _summary(s);
      }
      for (final e in _externals.values) {
        final cid = e.claudeSessionId ?? (e.pid == null ? null : registeredSessionId(e.pid!));
        if (cid == claudeId) return _titled(e);
      }
      return null;
    }

    if (claudeId.isEmpty) return null;
    final known = find();
    if (known != null) return known;
    try {
      await list();
    } catch (_) {}
    return find();
  }

  /// The Claude Code version reported by any running session, if known.
  String? get claudeVersion {
    for (final s in _sessions.values) {
      final v = s.claude?.claudeVersion;
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  SessionSummary _summary(_Session s) {
    if (s.origin == SessionOrigin.external) {
      // The session's own id: a session first listed as pid:<pid> keeps it.
      final base = s.entry?.summary.copyWith(id: s.id) ??
          SessionSummary(
              id: s.id, name: s.name, cwd: s.cwd, origin: SessionOrigin.external, state: SessionState.idle, startedAtMs: s.startedAtMs);
      var summary = base.copyWith(
          name: s.customTitle ?? s.fixedName ?? s.title ?? base.name,
          openPrompts: s.terminalPrompt == null ? 0 : 1,
          lastPromptAtMs: s.lastPromptAtMs ?? _transcriptFacts(s.claudeId)?.promptAt,
          accountId: _accountOf(s.accountId, s.claudeId));
      if (_hookStateFresh(s)) {
        summary = summary.copyWith(state: s.hookState, reason: s.hookReason, clearReason: s.hookReason == null);
      }
      if (s.hookEnded) summary = summary.copyWith(state: SessionState.stopped, live: false);
      if (s.trustPending) {
        summary = summary.copyWith(state: SessionState.blocked, reason: trustReason);
      }
      return _limited(summary);
    }
    final c = s.claude;
    return _limited(SessionSummary(
      id: s.id,
      name: s.customTitle ?? s.title ?? s.name,
      cwd: s.cwd,
      origin: SessionOrigin.perch,
      state: c?.state ?? SessionState.stopped,
      model: s.model,
      startedAtMs: s.startedAtMs,
      reason: c?.reason,
      openPrompts: c?.openPrompts.length ?? 0,
      live: c != null && c.isAlive,
      lastPromptAtMs: s.lastPromptAtMs,
      accountId: _accountOf(s.accountId, c?.claudeSessionId ?? s.claudeId),
    ));
  }

  // ------------------------------------------------------------ accounts

  /// The account a session runs on: the one Perch started it on, else the machine's own
  /// login (a session the owner started by typing `claude`). Null without accounts.
  String? _accountOf(String? started, String? claudeId) {
    final a = accounts;
    if (a == null) return null;
    return started ?? a.accountOf(claudeId) ?? machineLoginAccountId;
  }

  /// The account to start on: [chosen], else the machine's active one; null without accounts.
  String? _startAccount(String? chosen) {
    final a = accounts;
    if (a == null) return null;
    final id = (chosen == null || chosen.isEmpty) ? a.activeId : chosen;
    if (id != machineLoginAccountId && a.byId(id) == null) {
      throw StateError('This machine does not have that account. Open Accounts in the app to add it again.');
    }
    return id;
  }

  /// The child environment for a session on [account] (its token added; none for the
  /// machine's login). Throws [StateError] when the account cannot be used.
  Future<Map<String, String>> _environmentFor(String? account) async {
    final base = launcher.childEnvironment();
    final a = accounts;
    if (a == null || account == null) return base;
    return a.environmentFor(account, base);
  }

  /// Remembers which account a session Perch started runs on, once Claude Code's id is known.
  void _noteAccount(_Session s) {
    final cid = s.claude?.claudeSessionId ?? s.claudeId;
    final acc = s.accountId;
    if (cid != null && acc != null && _uuid.hasMatch(cid)) accounts?.recordSession(cid, acc);
  }

  /// Perch sessions plus outside ones. Also detects hand-back to a terminal.
  Future<List<SessionSummary>> list() async {
    final entries = await external.listEntries();

    // Hand-back: the owner resumed a taken-over session in a terminal.
    for (final s in _sessions.values.toList()) {
      if (s.origin != SessionOrigin.perch || !s.takenOver || s.claudeId == null) continue;
      final ourPid = s.claude?.pid;
      final candidates = entries.where((e) =>
          e.interactive && e.claudeSessionId == s.claudeId && e.pid != null && e.pid != ourPid);
      for (final e in candidates) {
        // A `.cmd` claude (npm's shim) runs through cmd.exe: Claude Code lists the host's own
        // copy under its claude.exe's pid, a child of [ourPid]. That is no hand-back (and it
        // can be listed before the terminal's own resume).
        if (ourPid != null && s.copyChild?.parent == ourPid && s.copyChild?.child == e.pid) continue;
        if (ourPid != null && await external.descendsFrom(e.pid!, ourPid)) {
          s.copyChild = (parent: ourPid, child: e.pid!);
          continue;
        }
        await _handBack(s, e);
        break;
      }
    }

    final ourClaudeIds = <String>{};
    final ourPids = <int>{};
    for (final s in _sessions.values) {
      if (s.origin != SessionOrigin.perch) continue;
      final cid = s.claude?.claudeSessionId ?? s.claudeId;
      if (cid != null) ourClaudeIds.add(cid);
      final pid = s.claude?.pid;
      if (pid != null) ourPids.add(pid);
      final child = s.copyChild;
      if (child != null && child.parent == pid) ourPids.add(child.child);
    }

    final ext = <String, ExternalEntry>{};
    final seenWatched = <String>{};
    final refresh = <_Session>[];
    for (final e in entries) {
      // The self-test of a new Claude Code version is not one of the owner's sessions.
      if (isSelfTestEntry(e)) {
        if (e.claudeSessionId != null) _selfTestIds.add(e.claudeSessionId!);
        continue;
      }
      if (e.claudeSessionId != null && ourClaudeIds.contains(e.claudeSessionId)) continue;
      if (_deleted.contains(e.summary.id) && !e.summary.live) continue;
      if (e.pid != null && ourPids.contains(e.pid)) continue;
      var known = _sessions[e.summary.id];
      // A session first seen before Claude Code listed it (folder not trusted yet) keeps
      // its `pid:` id once it is listed under its real one.
      if (known == null && e.pid != null) {
        final early = _sessions['pid:${e.pid}'];
        if (early != null && early.origin == SessionOrigin.external) known = early;
      }
      if (known != null) {
        if (known.origin == SessionOrigin.external) {
          known.entry = e;
          known.claudeId ??= e.claudeSessionId;
          _noteAccount(known);
          seenWatched.add(known.id);
          // A new session has no transcript until its first message.
          if (known.tailer == null) _startTailer(known, fromEnd: false, live: true);
          refresh.add(known);
        }
        continue;
      }
      ext[e.summary.id] = e;
    }
    // Claude session ids running now: an ended session that runs again is no longer ended.
    final runningIds = {
      for (final e in entries)
        if (e.claudeSessionId != null && e.summary.live) e.claudeSessionId!,
      ...ourClaudeIds,
    };
    _ended.removeWhere((_, e) => runningIds.contains(e.claudeId));
    // Watched outside sessions that are gone from the listing.
    for (final s in _sessions.values.where((s) => s.origin == SessionOrigin.external).toList()) {
      if (!seenWatched.contains(s.id)) {
        _remember(_summary(s), s.claudeId, runningIds);
        await _forget(s);
      }
    }
    for (final e in _externals.values) {
      if (!ext.containsKey(e.summary.id) && !_sessions.containsKey(e.summary.id)) {
        _remember(_titled(e), e.claudeSessionId, runningIds);
      }
    }
    for (final s in refresh) {
      await _refreshTerminalPrompt(s);
      final listed = s.entry?.summary.state;
      // A turn that ended without a hook saying why: a usage limit shows on screen.
      if (s.lastListedState == SessionState.working &&
          listed != null &&
          listed != SessionState.working &&
          !limits.isPaused(s.id)) {
        unawaited(_limitFromScreen(s));
      }
      s.lastListedState = listed;
    }
    _externals = ext;
    limits.prune();
    final listed = [
      for (final s in _sessions.values) _summary(s),
      for (final e in ext.values) _titled(e),
    ];
    final ids = {for (final s in listed) s.id};
    return _lastListed = [
      ...listed,
      for (final e in _ended.values)
        if (!ids.contains(e.summary.id)) e.summary,
    ];
  }

  /// Sessions that ended while this host ran (oldest first), kept so they can be resumed,
  /// renamed or deleted from the phone: Claude Code stops listing a session when it ends.
  final Map<String, ({SessionSummary summary, String claudeId})> _ended = {};

  /// How many ended sessions are kept.
  static const maxEnded = 50;

  void _remember(SessionSummary s, String? claudeId, Set<String> running) {
    if (claudeId == null || running.contains(claudeId) || _selfTestIds.contains(claudeId)) return;
    _ended.remove(s.id);
    _ended[s.id] = (
      summary: s.copyWith(state: SessionState.stopped, live: false, reason: 'Not running', openPrompts: 0),
      claudeId: claudeId,
    );
    while (_ended.length > maxEnded) {
      _ended.remove(_ended.keys.first);
    }
  }

  List<SessionSummary>? _lastListed;

  /// Claude session ids of self-test sessions seen in the listing (their hooks are ignored).
  final Set<String> _selfTestIds = {};

  /// What was read from the end of transcripts (the owner's name for the session, else
  /// Claude's title; the time of the owner's last message), by Claude session id, with the
  /// file size and time they were read at: re-read only when the file changed.
  final Map<String, ({File file, int size, DateTime modified, String? title, int? promptAt})> _titles = {};

  /// The cached tail facts of [cid]'s transcript (the most recently written one), or null.
  ({String? title, int? promptAt})? _transcriptFacts(String? cid) {
    if (cid == null) return null;
    try {
      var cached = _titles[cid];
      final file = cached?.file ?? findTranscript(cid, configDir: _configDir);
      if (file == null) return null;
      final stat = file.statSync();
      if (cached == null || cached.size != stat.size || cached.modified != stat.modified) {
        final t = latestTitles(file);
        cached = (
          file: file,
          size: stat.size,
          modified: stat.modified,
          title: t.custom ?? t.ai,
          promptAt: latestOwnerPromptMs(file),
        );
        _titles[cid] = cached;
      }
      return (title: cached.title, promptAt: cached.promptAt);
    } catch (_) {
      _titles.remove(cid); // a moved or deleted file: look again next time
      return null;
    }
  }

  /// A listed terminal session named by the latest `ai-title` in its transcript (Claude
  /// Code's placeholder names such as `harness-0f` are hard to recognise), else as listed,
  /// with the time of the owner's last message.
  SessionSummary _titled(ExternalEntry e) {
    final f = _transcriptFacts(e.claudeSessionId);
    final summary = e.summary.copyWith(accountId: _accountOf(null, e.claudeSessionId));
    if (f == null) return _limited(summary);
    return _limited(summary.copyWith(name: f.title, lastPromptAtMs: f.promptAt));
  }

  /// Working folders of current and recent sessions, most recently started first.
  /// Uses the last listing when there is one.
  Future<List<String>> recentFolders() async {
    final all = [...(_lastListed ?? await list())]..sort((a, b) => b.startedAtMs.compareTo(a.startedAtMs));
    return [for (final s in all) if (s.cwd.isNotEmpty) s.cwd];
  }

  /// Starts a session on [accountId] (null: the machine's active account): its token goes
  /// into the new `claude`'s environment; the machine's own login adds none.
  Future<SessionSummary> start(
      {required String cwd, required String prompt, String? name, String? model, String? accountId}) async {
    if (cwd.trim().isEmpty || !Directory(cwd).existsSync()) {
      throw ArgumentError.value(cwd, 'cwd', 'Folder does not exist');
    }
    final account = _startAccount(accountId);
    final environment = await _environmentFor(account);
    final chosenModel = (model == null || model.trim().isEmpty) ? null : model.trim();
    if (typer.supported) {
      final given = (name == null || name.trim().isEmpty) ? null : name.trim();
      return _startInTerminal(
          cwd: cwd, prompt: prompt, name: given, model: chosenModel, account: account, environment: environment);
    }
    final s = _Session(
      id: newUuid(),
      name: (name == null || name.trim().isEmpty) ? _defaultName(prompt) : name.trim(),
      cwd: cwd,
      model: chosenModel,
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
      origin: SessionOrigin.perch,
    )..accountId = account;
    _sessions[s.id] = s;
    final token = environment[oauthTokenVariable];
    final claude = ClaudeSession(
        launcher: token == null ? launcher : launcher.withEnvironment({oauthTokenVariable: token}),
        cwd: cwd,
        name: s.name,
        model: chosenModel);
    _attach(s, claude);
    _record(s, UserMessage(prompt));
    s.lastPromptAtMs = DateTime.now().millisecondsSinceEpoch;
    await claude.start(prompt);
    _publish(s);
    return _summary(s);
  }

  static bool _samePath(String a, String b) {
    String norm(String p) {
      var n = p.replaceAll('/', Platform.pathSeparator);
      while (n.length > 3 && n.endsWith(Platform.pathSeparator)) {
        n = n.substring(0, n.length - 1);
      }
      // NTFS and APFS (macOS) ignore case: ~/Desktop/Work and ~/Desktop/work are one folder.
      return Platform.isWindows || Platform.isMacOS ? n.toLowerCase() : n;
    }

    return norm(a) == norm(b);
  }

  /// Windows: opens a visible terminal window running interactive `claude` in [cwd], waits
  /// for it to appear in `claude agents --json`, and types the first instruction into it.
  /// The result is an ordinary terminal session.
  Future<SessionSummary> _startInTerminal(
      {required String cwd,
      required String prompt,
      String? name,
      String? model,
      String? account,
      required Map<String, String> environment}) async {
    final before = {
      for (final e in await external.listEntries())
        if (e.pid != null) e.pid!
    };
    await _openWindow(TerminalLaunch(
      cwd: cwd,
      executable: launcher.executable,
      args: [
        ...launcher.leadingArgs,
        if (name != null) ...['-n', name],
        if (model != null) ...['--model', model],
      ],
      environment: environment,
    ));
    final deadline = DateTime.now().add(terminalStartTimeout);
    ExternalEntry? found;
    while (true) {
      found = (await external.listEntries())
          .where((e) => e.interactive && e.pid != null && !before.contains(e.pid) && _samePath(e.summary.cwd, cwd))
          .firstOrNull;
      if (found != null || DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(terminalPoll);
    }
    if (found == null) {
      return SessionSummary(
        id: newUuid(),
        name: name ?? _defaultName(prompt),
        cwd: cwd,
        origin: SessionOrigin.perch,
        state: SessionState.blocked,
        startedAtMs: DateTime.now().millisecondsSinceEpoch,
        reason: 'Claude Code did not start in a terminal window within ${terminalStartTimeout.inSeconds} seconds.',
        live: false,
      );
    }
    _externals[found.summary.id] = found;
    final s = _watch(found)
      ..fixedName = name
      ..accountId = account;
    _noteAccount(s);
    final pid = found.pid!;

    // Wait until Claude Code shows its input box or the folder-trust dialog.
    final readyBy = DateTime.now().add(terminalStartTimeout);
    var trust = false;
    while (true) {
      final screen = await typer.screen(pid);
      if (screen != null && detectDialog(screen) == DialogKind.trust) {
        trust = true;
        break;
      }
      if ((screen != null && isPromptReady(screen)) || DateTime.now().isAfter(readyBy)) break;
      await Future<void>.delayed(terminalPoll);
    }
    if (trust) {
      s
        ..trustPending = true
        ..pendingInstruction = prompt;
      _publish(s);
      return _summary(s);
    }
    if (!await typer.type(pid, prompt)) {
      _publish(s);
      return _summary(s).copyWith(
          state: SessionState.blocked, reason: 'The terminal opened, but Perch could not type the instruction into it.');
    }
    _publish(s);
    return _summary(s);
  }

  static String _defaultName(String prompt) {
    final p = prompt.trim().replaceAll(RegExp(r'\s+'), ' ');
    return p.length <= 40 ? p : p.substring(0, 40);
  }

  void _attach(_Session s, ClaudeSession claude) {
    s.claude = claude;
    s.claudeSubs.add(claude.lines.listen((line) {
      switch (line) {
        case ParsedEvents(:final events):
          for (final e in events) {
            _record(s, e);
            _limitEvent(s, e);
          }
        case ParsedInit(:final claudeSessionId):
          if (claudeSessionId.isNotEmpty) s.claudeId = claudeSessionId;
          _noteAccount(s);
        case ParsedUsage(:final status, :final resetsAt, :final limitType):
          // Usage is the account's (decision 5): labelled with the account it ran on.
          final usage = line.usage.withAccount(_accountOf(s.accountId, s.claudeId));
          _usage = usage;
          if (!_disposed) {
            _usageUpdates.add(usage);
            limits.usageChanged(usage);
            final rejected = status == 'rejected' ? (resetsAt: resetsAt, type: limitType) : _rejectedWindow(usage);
            if (rejected != null) {
              limits.hit(s.id,
                  resetsAt: rejected.resetsAt > 0 ? DateTime.fromMillisecondsSinceEpoch(rejected.resetsAt * 1000) : null,
                  window: _windowOfType(rejected.type),
                  claudeWaiting: false);
            }
          }
        case ParsedMalformed(:final reason):
          compatibility.drift(
              reason: 'Claude Code sent a permission request Perch cannot read.',
              session: '${s.title ?? s.name} (${s.id})',
              expected: 'a permission request with request_id and tool_name; got $reason');
        default:
          break;
      }
    }));
    s.claudeSubs.add(claude.changed.listen((_) => _publish(s)));
  }

  Future<void> _detachClaude(_Session s) async {
    for (final sub in s.claudeSubs) {
      await sub.cancel();
    }
    s.claudeSubs.clear();
    final c = s.claude;
    s.claude = null;
    await c?.stop();
  }

  /// Stamps and buffers an event, then broadcasts it.
  void _record(_Session s, ConversationEvent e) {
    e.seq = ++s.seq;
    // Transcript events carry their own time; the rest happen now.
    if (e.atMs == 0) e.atMs = DateTime.now().millisecondsSinceEpoch;
    s.buffer.add(e);
    if (s.buffer.length > maxEventsPerSession) {
      s.buffer.removeRange(0, s.buffer.length - maxEventsPerSession);
    }
    if (!_disposed && !s.readingBacklog) _events.add((sessionId: s.id, event: e));
  }

  /// Broadcasts prompt changes and the session summary.
  void _publish(_Session s) {
    if (_disposed) return;
    _releaseHookWaiters(s);
    final open = _openPrompts(s);
    final openIds = {for (final p in open) p.promptId};
    for (final p in open) {
      if (s.knownPrompts.add(p.promptId)) _promptsOpened.add((sessionId: s.id, prompt: p));
    }
    for (final id in s.knownPrompts.where((id) => !openIds.contains(id)).toList()) {
      s.knownPrompts.remove(id);
      _promptsClosed.add((sessionId: s.id, promptId: id));
    }
    _sessionUpdates.add(_summary(s));
  }

  List<PromptRequest> _openPrompts(_Session s) {
    final c = s.claude;
    if (c != null) return c.openPrompts;
    final t = s.terminalPrompt;
    return t == null ? const [] : [t];
  }

  // ------------------------------------------------------------ outside sessions

  /// Starts watching an outside session's transcript (once).
  _Session _watch(ExternalEntry e) {
    final existing = _sessions[e.summary.id];
    if (existing != null) return existing;
    final s = _Session(
      id: e.summary.id,
      name: e.summary.name,
      cwd: e.summary.cwd,
      startedAtMs: e.summary.startedAtMs,
      origin: SessionOrigin.external,
    )
      ..entry = e
      ..claudeId = e.claudeSessionId;
    _sessions[s.id] = s;
    _externals.remove(s.id);
    _startTailer(s, fromEnd: false);
    return s;
  }

  /// [live]: the session was watched before its transcript existed (a new session), so
  /// devices already have its (empty) history and what is read now is news to them.
  void _startTailer(_Session s, {required bool fromEnd, bool live = false}) {
    final cid = s.claudeId;
    if (cid == null || s.tailer != null) return;
    final file = findTranscript(cid, configDir: _configDir);
    if (file == null) return;
    final t = TranscriptTailer(file, fromEnd: fromEnd);
    s.tailer = t;
    s.tailerSub = t.lines.listen((line) {
      switch (line) {
        case TranscriptEvents(:final events, :final ownerPromptAtMs):
          if (ownerPromptAtMs != null && ownerPromptAtMs > (s.lastPromptAtMs ?? 0)) {
            s.lastPromptAtMs = ownerPromptAtMs;
            if (!s.readingBacklog) _publish(s);
          }
          for (final e in events) {
            _record(s, e);
            _limitEvent(s, e);
            // The tool ran (or was refused): the card is answered.
            if (e is ToolResult &&
                s.terminalPrompt != null &&
                (s.terminalPrompt!.promptId == e.toolUseId || s.promptToolUseId == e.toolUseId)) {
              _dropCard(s);
              _publish(s);
            }
          }
        case TranscriptTitle(:final title, :final custom):
          if (custom ? s.customTitle != title : s.title != title) {
            if (custom) {
              s.customTitle = title;
            } else {
              s.title = title;
            }
            _publish(s);
          }
        case TranscriptMalformed(:final reason):
          if (++s.malformedLines >= 3) {
            compatibility.drift(
                reason: "Claude Code's transcript has lines Perch cannot read.",
                session: '${_summary(s).name} (${s.id})',
                expected: 'user and assistant lines with a message and its content; ${s.malformedLines} were not, '
                    'the last: $reason');
          }
        default:
          break;
      }
    });
    // Read what is already there now, so history() includes it on return. It is history,
    // not news: it is not broadcast as live events (that doubled the traffic on first open).
    s.readingBacklog = !fromEnd && !live;
    try {
      t.pollNow();
    } finally {
      s.readingBacklog = false;
    }
    // A transcript read without a line Perch could not read is evidence too.
    if (!fromEnd && s.buffer.isNotEmpty && s.malformedLines == 0) compatibility.recordWorking(WorkingKinds.transcript);
  }

  Future<void> _stopTailer(_Session s) async {
    final t = s.tailer;
    if (t == null) return;
    t.pollNow(); // catch up before stopping
    await s.tailerSub?.cancel();
    s.tailerSub = null;
    await t.close();
    s.tailer = null;
  }

  Future<void> _forget(_Session s) async {
    await _stopTailer(s);
    _sessions.remove(s.id);
  }

  /// Takes a terminal session over: closes the terminal's Claude process and resumes
  /// the same conversation under Perch.
  Future<SessionSummary> takeOver(String sessionId, {bool force = false}) {
    final pending = _takeovers[sessionId];
    if (pending != null) return pending;
    // Block body: returning the removed future from whenComplete would make it wait on itself.
    final f = _takeOver(sessionId, force).whenComplete(() {
      _takeovers.remove(sessionId);
    });
    _takeovers[sessionId] = f;
    return f;
  }

  Future<SessionSummary> _takeOver(String sessionId, bool force) async {
    final known = _sessions[sessionId];
    if (known != null && known.origin == SessionOrigin.perch) {
      final c = known.claude;
      if (c != null && c.isAlive) return _summary(known);
      if (known.claudeId == null) throw ReadOnlySession();
    }
    final entry = known?.entry ?? _externals[sessionId];
    if (entry == null && known == null) throw NoSuchSession(sessionId);
    final claudeId = entry?.claudeSessionId ?? known?.claudeId;
    if (claudeId == null) throw ReadOnlySession();
    if (entry != null && entry.summary.state == SessionState.working && !force) throw SessionBusy();

    final pid = entry?.pid;
    if (pid != null) {
      await external.killPid(pid);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (await external.pidAlive(pid)) {
        if (DateTime.now().isAfter(deadline)) {
          throw TakeoverFailed('The terminal session did not close (pid $pid).');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    final s = known ?? _watch(entry!);
    final mode = s.tailer?.lastPermissionMode;
    await _stopTailer(s);
    _externals.remove(s.id);
    final claude = ClaudeSession(
      launcher: launcher,
      cwd: entry?.summary.cwd ?? s.cwd,
      resumeId: claudeId,
      permissionMode: mode,
    );
    s
      ..origin = SessionOrigin.perch
      ..takenOver = true
      ..claudeId = claudeId
      ..title = s.title ?? entry?.summary.name;
    _attach(s, claude);
    await claude.start(null);
    _record(s, Notice(takeOverNotice));
    _publish(s);
    if (claude.state == SessionState.blocked) {
      throw TakeoverFailed(claude.reason ?? 'Could not resume the session.');
    }
    return _summary(s);
  }

  /// The terminal resumed this session: stop our process and watch it again.
  Future<void> _handBack(_Session s, ExternalEntry e) async {
    await _detachClaude(s);
    s
      ..origin = SessionOrigin.external
      ..takenOver = false
      ..handedBackAt = DateTime.now()
      // Alive again in the terminal: the end its earlier process reported at the take-over
      // is over (and its SessionStart came while the session was still the host's).
      ..hookEnded = false
      ..entry = e;
    s.knownPrompts.clear();
    _record(s, Notice(handBackNotice));
    _startTailer(s, fromEnd: true);
    _publish(s);
  }

  // ------------------------------------------------------------ commands

  _Session _controlled(String id) {
    final s = _sessions[id];
    if (s != null && s.origin == SessionOrigin.perch) return s;
    if (s != null || _externals.containsKey(id)) throw ReadOnlySession();
    throw NoSuchSession(id);
  }

  /// Where the search index is kept (`<state>/search-index`); null: every search reads the
  /// transcripts themselves (tests).
  final String? searchIndexDir;

  /// Builds the search index in the background (the host calls it once at start, so the
  /// first search is quick). Errors are ignored.
  Future<void> warmSearchIndex() async {
    final idx = searchIndexDir;
    if (idx == null) return;
    final dir = _configDir ?? claudeConfigDir();
    try {
      await Isolate.run(() => updateSearchIndex(configDir: dir, indexDir: idx));
    } catch (_) {}
  }

  /// Full-text search across every conversation on the machine (see session_search.dart),
  /// run in its own isolate. A hit in a session the machine lists carries that session's
  /// id (and name); any other hit carries Claude Code's session id, which [history] opens.
  Future<SearchResults> search(String query) async {
    final dir = _configDir ?? claudeConfigDir();
    final q = query;
    final idx = searchIndexDir;
    final found = await Isolate.run(() => searchTranscripts(configDir: dir, query: q, indexDir: idx));
    final listed = _listedByClaudeId();
    return SearchResults(
      query: query,
      truncated: found.truncated,
      hits: [
        for (final h in found.hits)
          SearchHit(
            sessionId: listed[h.claudeId]?.id ?? h.claudeId,
            name: (listed[h.claudeId]?.name.isNotEmpty ?? false) ? listed[h.claudeId]!.name : h.name,
            cwd: listed[h.claudeId]?.cwd ?? h.cwd,
            atMs: h.atMs,
            fromUser: h.fromUser,
            snippet: h.snippet,
            running: listed[h.claudeId]?.live ?? false,
          ),
      ],
    );
  }

  /// The sessions Perch lists now, by Claude Code's session id.
  Map<String, SessionSummary> _listedByClaudeId() {
    final out = <String, SessionSummary>{};
    for (final e in _ended.values) {
      out[e.claudeId] = e.summary;
    }
    for (final e in _externals.values) {
      final cid = e.claudeSessionId;
      if (cid != null) out[cid] = _titled(e);
    }
    for (final s in _sessions.values) {
      final cid = s.claude?.claudeSessionId ?? s.claudeId ?? s.entry?.claudeSessionId;
      if (cid != null) out[cid] = _summary(s);
    }
    return out;
  }

  /// An old conversation opened from a search: listed as not running from now on, like a
  /// session that ended while the host ran. Only a Claude Code session id (a UUID) with a
  /// transcript is opened.
  bool _openOldConversation(String claudeId) {
    if (!isClaudeSessionId(claudeId)) return false;
    final file = findTranscript(claudeId, configDir: _configDir);
    if (file == null) return false;
    var cwd = '';
    int? startedAt;
    String? first;
    try {
      for (final line in const LineSplitter().convert(file.readAsStringSync())) {
        final j = decodeJsonObject(line);
        if (j == null) continue;
        if (cwd.isEmpty && j['cwd'] is String) cwd = j['cwd'] as String;
        startedAt ??= transcriptTimeMs(j['timestamp']);
        if (first == null) {
          final t = parseTranscriptLine(line);
          if (t is TranscriptEvents) {
            for (final e in t.events) {
              if (e is UserMessage && e.text.trim().isNotEmpty) first ??= e.text.trim();
            }
          }
        }
        if (cwd.isNotEmpty && startedAt != null && first != null) break;
      }
    } catch (_) {}
    final titles = latestTitles(file);
    var name = titles.custom ?? titles.ai ?? (first ?? '').replaceAll(RegExp(r'\s+'), ' ');
    if (name.length > 60) name = '${name.substring(0, 59).trimRight()}…';
    final summary = SessionSummary(
      id: claudeId,
      name: name,
      cwd: cwd,
      origin: SessionOrigin.external,
      state: SessionState.stopped,
      startedAtMs: startedAt ?? 0,
    );
    _remember(summary, claudeId, const {});
    final kept = _ended[claudeId];
    if (kept == null) return false;
    if (!_disposed) _sessionUpdates.add(kept.summary);
    return true;
  }

  /// The events after [afterSeq] and the open prompts. A first look (afterSeq 0) gets only
  /// the latest [pageSize] events when [paged]; [hasEarlier] then says more are buffered.
  ({List<ConversationEvent> events, List<PromptRequest> openPrompts, bool hasEarlier}) history(String sessionId,
      {int afterSeq = 0, bool paged = false, int pageSize = historyPageSize}) {
    if (!_sessions.containsKey(sessionId) &&
        !_externals.containsKey(sessionId) &&
        !_ended.containsKey(sessionId)) {
      _openOldConversation(sessionId);
    }
    var s = _sessions[sessionId];
    if (s == null) {
      final e = _externals[sessionId];
      final ended = _ended[sessionId];
      if (e == null && ended != null) {
        final events = [for (final x in _endedEvents(ended.claudeId)) if (x.seq > afterSeq) x];
        final cut = paged && afterSeq == 0 && events.length > pageSize;
        return (events: cut ? events.sublist(events.length - pageSize) : events, openPrompts: const [], hasEarlier: cut);
      }
      if (e == null) throw NoSuchSession(sessionId);
      if (e.claudeSessionId == null) return (events: const [], openPrompts: const [], hasEarlier: false);
      s = _watch(e);
    } else if (s.origin == SessionOrigin.external && s.tailer == null) {
      _startTailer(s, fromEnd: false); // transcript may not have existed before
    }
    if (s.origin == SessionOrigin.external) unawaited(_refreshTerminalPrompt(s));
    final events = [for (final e in s.buffer) if (e.seq > afterSeq) e];
    final cut = paged && afterSeq == 0 && events.length > pageSize;
    return (
      events: cut ? events.sublist(events.length - pageSize) : events,
      openPrompts: _openPrompts(s),
      hasEarlier: cut,
    );
  }

  /// Up to [pageSize] buffered events just before [beforeSeq], oldest first, and whether
  /// still older ones are buffered.
  ({List<ConversationEvent> events, bool hasEarlier}) earlier(String sessionId, int beforeSeq,
      {int pageSize = historyPageSize}) {
    final s = _sessions[sessionId];
    final ended = _ended[sessionId];
    if (s == null && ended == null) {
      if (_externals.containsKey(sessionId)) return (events: const [], hasEarlier: false);
      throw NoSuchSession(sessionId);
    }
    final buffer = s?.buffer ?? _endedEvents(ended!.claudeId);
    final before = [for (final e in buffer) if (e.seq < beforeSeq) e];
    final from = before.length > pageSize ? before.length - pageSize : 0;
    return (events: before.sublist(from), hasEarlier: from > 0);
  }

  /// The conversation of an ended session, read from its transcript (the last
  /// [maxEventsPerSession] events, numbered from 1).
  List<ConversationEvent> _endedEvents(String claudeId) {
    final file = findTranscript(claudeId, configDir: _configDir);
    if (file == null) return const [];
    final out = <ConversationEvent>[];
    try {
      for (final line in const LineSplitter().convert(file.readAsStringSync())) {
        final t = parseTranscriptLine(line);
        if (t is TranscriptEvents) out.addAll(t.events);
      }
    } catch (_) {}
    final kept = out.length > maxEventsPerSession ? out.sublist(out.length - maxEventsPerSession) : out;
    for (var i = 0; i < kept.length; i++) {
      kept[i].seq = i + 1;
    }
    return kept;
  }

  /// Sends a user message. A terminal session gets it typed into its console (it stays in
  /// the terminal; the reply arrives through its transcript); a terminal no adapter can
  /// operate (VS Code, Cursor, iTerm2, …) gets it through the session's inbox. Throws
  /// [CannotType] when neither is possible; taking the session over is a separate,
  /// explicit [takeOver].
  Future<void> send(String sessionId, String text) async {
    _sending++;
    try {
      await _send(sessionId, text);
    } finally {
      _sending--;
    }
  }

  /// Messages being typed or sent right now.
  int _sending = 0;

  /// Nothing in flight: no message being typed, no card open or being answered, no
  /// `PermissionRequest` hook held for the phone, no first instruction waiting for a folder
  /// to be trusted. A host waits for this before it restarts into a new build.
  bool get quiet =>
      _sending == 0 &&
      _takeovers.isEmpty &&
      _sessions.values.every((s) =>
          !s.answering && s.terminalPrompt == null && s.hookWaiters.isEmpty && s.pendingInstruction == null);

  Future<void> _send(String sessionId, String text) async {
    // A take-over requested just before this message: wait for it, then send to the result.
    final pending = _takeovers[sessionId];
    if (pending != null) await pending;
    final s = _sessions[sessionId];
    if (s == null && !_externals.containsKey(sessionId)) throw NoSuchSession(sessionId);
    limits.ownerPrompt(sessionId, text);
    if (s != null && s.origin == SessionOrigin.perch) {
      final c = s.claude;
      if (c != null && c.isAlive) {
        c.sendUser(text);
        _record(s, UserMessage(text));
        s.lastPromptAtMs = DateTime.now().millisecondsSinceEpoch;
        _publish(s);
        return;
      }
      if (!s.takenOver) throw StateError('This session has ended');
      // A taken-over session whose process ended: resume it again under Perch.
      await takeOver(sessionId);
      final again = _sessions[sessionId]?.claude;
      if (again == null) throw StateError('This session has ended');
      again.sendUser(text);
      _record(s, UserMessage(text));
      s.lastPromptAtMs = DateTime.now().millisecondsSinceEpoch;
      _publish(s);
      return;
    }
    final entry = s?.entry ?? _externals[sessionId];
    final pid = entry?.pid;
    if (pid == null) throw CannotType('This session is not running in a terminal Perch can type into.');
    final adapter = typer.supported && await typer.canOperate(pid);
    final viaInbox = !adapter && (inbox?.supported ?? false);
    if (!adapter && !viaInbox) {
      throw CannotType(typer.supported
          ? 'Perch cannot type into the terminal this session runs in.'
          : 'Typing into a terminal session is not supported on this machine.');
    }
    // Watch the transcript so the message and the reply reach every device.
    final watched = s ?? _watch(entry!);
    if (watched.tailer == null) _startTailer(watched, fromEnd: false);
    if (adapter) {
      // A dialog on the screen (one of Claude Code's own, with no card on the phone) would
      // take the paste and its Enter would pick an option: type nothing then. A screen that
      // cannot be read does not stop the message. Warp reads only the tab in front.
      await typer.bringForward(pid);
      final screen = await typer.screen(pid);
      if (screen != null && showsDialog(screen)) {
        throw TerminalShowsDialog('Claude Code is asking something in the terminal on this machine: '
            'answer it there, then send your message again.');
      }
      if (!await typer.type(pid, text)) throw CannotType('Could not type into the terminal session.');
    } else if (!await inbox!.send(pid, text, folder: entry?.summary.cwd)) {
      throw CannotType("Could not reach the session's inbox (Claude Code 2.1.224 or later is needed).");
    }
    // A new session writes its transcript only now: start reading it as soon as it is
    // there, rather than at the next listing.
    if (watched.tailer == null) unawaited(_tailWhenWritten(watched));
  }

  Future<void> _tailWhenWritten(_Session s) async {
    for (var i = 0; i < 40 && s.tailer == null && !_disposed && _sessions[s.id] == s; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      _startTailer(s, fromEnd: false, live: true);
    }
  }

  void answer(String sessionId, String promptId, PromptAnswer answer) {
    final s = _controlled(sessionId);
    final c = s.claude;
    if (c == null) throw PromptAlreadyAnswered();
    c.answer(promptId, answer);
  }

  /// Answers an open card. A Perch-run session gets it on its control channel; a terminal
  /// session gets the keys the owner would press ([CannotAnswerInTerminal] when the screen
  /// is not what Perch expects; nothing is guessed).
  Future<void> answerPrompt(String sessionId, String promptId, PromptAnswer answer) async {
    final s = _sessions[sessionId];
    if (s == null || s.origin == SessionOrigin.perch) return this.answer(sessionId, promptId, answer);
    final p = s.terminalPrompt;
    if (p == null || p.promptId != promptId || s.answering) throw PromptAlreadyAnswered();
    final pid = s.entry?.pid;
    if (pid == null || !typer.supported) {
      throw CannotAnswerInTerminal('This terminal cannot be operated from Perch on this machine.');
    }
    if (!await typer.canOperate(pid)) {
      // No keys for this terminal: the card is answered through the waiting hook (it may
      // arrive a moment after the card opened).
      var w = _waiterFor(s, p);
      final end = DateTime.now().add(hookArrival);
      while (w == null && DateTime.now().isBefore(end) && !_disposed) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        w = _waiterFor(s, p);
      }
      if (s.terminalPrompt?.promptId != promptId) throw PromptAlreadyAnswered();
      if (w == null) {
        throw CannotAnswerInTerminal('Answer this at the machine: Perch cannot operate the terminal this session runs '
            'in, and Claude Code did not hand the request to Perch (run perch_host hooks install).');
      }
      w.finish(_hookDecision(p, answer, w));
      s.answeredTerminalPrompts.add(promptId);
      final tuid = s.promptToolUseId;
      if (tuid != null) s.answeredTerminalPrompts.add(tuid);
      s.hookWaiters.remove(w);
      _dropCard(s);
      compatibility.recordWorking(switch (p.kind) {
        PromptKind.question => WorkingKinds.question,
        PromptKind.permission => WorkingKinds.permission,
        PromptKind.plan => WorkingKinds.plan,
      });
      _publish(s);
      return;
    }
    s.answering = true;
    try {
      await TerminalAnswerer(typer, pid, poll: answerPoll, timeout: answerTimeout).answer(p, answer);
    } on CannotAnswerInTerminal {
      // Was it Claude Code drawing something Perch cannot read? (A dialog that is simply
      // gone is not.)
      final screen = await typer.screen(pid);
      if (screen != null) unawaited(_confirmScreenDrift(s, screen, _waitingFor(p.kind)));
      rethrow;
    } finally {
      s.answering = false;
    }
    s.answeredTerminalPrompts.add(promptId);
    final tuid = s.promptToolUseId;
    if (tuid != null) s.answeredTerminalPrompts.add(tuid);
    _dropCard(s);
    // Evidence that this Claude Code version still works with Perch.
    if (p.toolName != trustFolderTool) {
      compatibility.recordWorking(switch (p.kind) {
        PromptKind.question => WorkingKinds.question,
        PromptKind.permission => WorkingKinds.permission,
        PromptKind.plan => WorkingKinds.plan,
      });
    }
    if (p.toolName == trustFolderTool) {
      final allowed = answer is PermissionAnswer && answer.allow;
      s.trustPending = false;
      final first = s.pendingInstruction;
      s.pendingInstruction = null;
      _publish(s);
      if (allowed && first != null) await _typeWhenReady(s, pid, first);
      return;
    }
    _publish(s);
  }

  /// Types [text] once Claude Code shows its input box.
  Future<void> _typeWhenReady(_Session s, int pid, String text) async {
    final end = DateTime.now().add(answerTimeout);
    while (true) {
      final screen = await typer.screen(pid);
      if (screen != null && isPromptReady(screen)) break;
      if (DateTime.now().isAfter(end)) throw CannotType('Could not type the first instruction into the terminal.');
      await Future<void>.delayed(answerPoll);
    }
    if (s.tailer == null) _startTailer(s, fromEnd: false);
    if (!await typer.type(pid, text)) throw CannotType('Could not type the first instruction into the terminal.');
  }

  /// Works out the card for a terminal session: the tool use it waits on (from its
  /// transcript), or the folder-trust dialog (from its screen). One at a time per session.
  Future<void> _refreshTerminalPrompt(_Session s) {
    final running = s.refreshing;
    if (running != null) return running;
    final f = _computeTerminalPrompt(s).whenComplete(() => s.refreshing = null);
    s.refreshing = f;
    return f;
  }

  Future<void> _computeTerminalPrompt(_Session s) async {
    if (s.origin != SessionOrigin.external || s.answering || _disposed) return;
    final wasPending = s.trustPending;
    s.tailer?.pollNow(); // the transcript as it is now
    final pid = s.entry?.pid;
    final state = _stateOf(s);
    final waiting = state == SessionState.waitingQuestion ||
        state == SessionState.waitingPermission ||
        state == SessionState.waitingPlan;
    // A card a hook opened stays while the session waits (and for a short grace period,
    // as the listing may lag); hooks and the transcript close it.
    final hookCard = s.terminalPrompt;
    final hookAt = s.hookPromptAt;
    if (hookCard != null &&
        hookAt != null &&
        (waiting || DateTime.now().difference(hookAt) < hookGrace || _waiterFor(s, hookCard) != null)) {
      if (s.promptToolUseId == null) {
        final call = _pendingCall(s, hookCard.toolName, hookCard.input);
        if (call != null) s.promptToolUseId = call.toolUseId;
      }
      return;
    }
    PromptRequest? next;
    String? nextToolUseId;
    if (waiting || s.trustPending) {
      final call = waiting ? pendingToolUse(s.buffer) : null;
      nextToolUseId = call?.toolUseId;
      // A question set whose first steps were answered from the screen before the
      // transcript had it: the terminal shows a later step (or the review), so the card
      // stays the screen's step rather than the whole set again.
      String? laterStep;
      if (call != null &&
          call.name == 'AskUserQuestion' &&
          typer.supported &&
          pid != null &&
          !s.answeredTerminalPrompts.contains(call.toolUseId) &&
          s.terminalPrompt?.promptId != call.toolUseId) {
        final screen = await typer.screen(pid);
        if (screen != null && _laterQuestionStep(screen, call)) laterStep = screen;
      }
      if (laterStep != null) {
        final p = screenPrompt(laterStep, s.id);
        next = p == null || s.answeredTerminalPrompts.contains(p.promptId)
            ? null
            : (s.terminalPrompt?.promptId == p.promptId ? s.terminalPrompt : p);
      } else if (call != null) {
        if (s.answeredTerminalPrompts.contains(call.toolUseId)) {
          next = null;
        } else if (s.terminalPrompt?.promptId == call.toolUseId) {
          next = s.terminalPrompt;
        } else {
          String? always;
          if (PromptRequest.kindForTool(call.name) == PromptKind.permission && typer.supported && pid != null) {
            final screen = await typer.screen(pid);
            if (screen != null) always = alwaysOptionOn(screen);
          }
          next = promptForToolUse(call, alwaysLabel: always);
        }
      } else if (typer.supported && pid != null) {
        final screen = await typer.screen(pid);
        if (screen != null && detectDialog(screen) == DialogKind.trust) {
          final t = trustPrompt(s.id, s.cwd);
          next = s.answeredTerminalPrompts.contains(t.promptId) ? null : (s.terminalPrompt ?? t);
        } else if (screen != null && waiting) {
          // Not in the transcript yet: the card comes from the dialog on screen.
          final p = screenPrompt(screen, s.id);
          if (p == null) unawaited(_confirmScreenDrift(s, screen, state));
          next = p == null || s.answeredTerminalPrompts.contains(p.promptId)
              ? null
              : (s.terminalPrompt?.promptId == p.promptId ? s.terminalPrompt : p);
        } else if (screen != null && s.trustPending && isPromptReady(screen)) {
          // Trusted at the machine: send the first instruction now.
          s.trustPending = false;
          final first = s.pendingInstruction;
          s.pendingInstruction = null;
          if (first != null) {
            if (s.tailer == null) _startTailer(s, fromEnd: false);
            await typer.type(pid, first);
          }
        }
      }
    }
    if (s.answering || _disposed) return;
    // A hook may have opened a card while this ran: it wins.
    if (s.hookPromptAt != null && s.hookPromptAt != hookAt) return;
    final changed = s.terminalPrompt?.promptId != next?.promptId || wasPending != s.trustPending;
    s
      ..terminalPrompt = next
      ..promptToolUseId = next == null ? null : nextToolUseId
      ..hookPromptAt = null;
    if (changed) _publish(s);
  }

  // ------------------------------------------------------------ usage limits

  /// A live event of [s]: Claude Code's limit message pauses it; everything is news for the
  /// limit (new work after a reset, the shape of the resumed turn).
  void _limitEvent(_Session s, ConversationEvent e) {
    if (s.readingBacklog || _disposed) return;
    limits.activity(s.id, e);
    if (limits.isPaused(s.id) || e.parentToolUseId != null) return;
    final text = switch (e) {
      AssistantText(:final text) => text,
      TurnEnded(:final isError, :final text) when isError => text,
      _ => null,
    };
    if (text == null) return;
    final now = DateTime.now();
    // An old line read late is not a limit now.
    if (e.atMs > 0 && now.millisecondsSinceEpoch - e.atMs > const Duration(minutes: 10).inMilliseconds) return;
    if (parseLimitMessage(text, now) != null) unawaited(_limitHit(s, text: text));
  }

  /// [s] hit the usage limit ([text]: what Claude Code said, if anything). A terminal Perch
  /// can read gets its screen read too (the reset, whether Claude Code waits by itself, its
  /// options menu); words about the limit Perch cannot read raise drift, never a guess.
  Future<void> _limitHit(_Session s, {String? text}) async {
    if (_disposed) return;
    final m = text == null ? null : parseLimitMessage(text, DateTime.now());
    // At once (the notification and the card), with what the message says.
    limits.hit(s.id, resetsAt: m?.resetsAt, window: m?.window, claudeWaiting: (m?.claudeWaiting ?? false) ? true : null);
    final pid = s.origin == SessionOrigin.external ? s.entry?.pid : null;
    if (pid == null || !typer.supported) return;
    if (!(_operable[pid] ??= await typer.canOperate(pid))) return;
    // The waiting lines can take a moment to show.
    LimitScreen? seen;
    String? last;
    for (var i = 0; i < 6 && !_disposed; i++) {
      last = await typer.screen(pid);
      if (last != null) {
        final r = readLimitScreen(last, DateTime.now());
        if (r.kind != LimitScreenKind.none || r.resetsAt != null) {
          seen = r;
          if (r.kind != LimitScreenKind.unreadable && r.kind != LimitScreenKind.none) break;
        }
      }
      await Future<void>.delayed(answerPoll);
    }
    if (_disposed) return;
    if (seen?.kind == LimitScreenKind.unreadable && last != null) unawaited(_limitDrift(s, last));
    final known = seen?.kind == LimitScreenKind.unreadable ? null : seen;
    if (known == null) return;
    limits.hit(s.id,
        resetsAt: known.resetsAt, window: known.window, claudeWaiting: known.claudeWaiting, menu: known.kind == LimitScreenKind.menu, refine: true);
  }

  /// A turn of [s] ended with no hook saying why: is a usage limit on its screen?
  Future<void> _limitFromScreen(_Session s) async {
    final pid = s.entry?.pid;
    if (pid == null || !typer.supported || _disposed) return;
    if (!(_operable[pid] ??= await typer.canOperate(pid))) return;
    final screen = await typer.screen(pid);
    if (screen == null || _disposed) return;
    final r = readLimitScreen(screen, DateTime.now());
    switch (r.kind) {
      case LimitScreenKind.unreadable:
        unawaited(_limitDrift(s, screen));
        limits.hit(s.id);
      case LimitScreenKind.waiting || LimitScreenKind.menu || LimitScreenKind.continuingShortly:
        limits.hit(s.id,
            resetsAt: r.resetsAt, window: r.window, claudeWaiting: r.claudeWaiting, menu: r.kind == LimitScreenKind.menu);
      case LimitScreenKind.none when r.resetsAt != null:
        limits.hit(s.id, resetsAt: r.resetsAt, window: r.window);
      default:
        break;
    }
  }

  /// Claude Code shows words about a usage limit Perch cannot read: drift, when a second
  /// look a moment later still shows them.
  Future<void> _limitDrift(_Session s, String screen) async {
    if (compatibility.current.status == CompatibilityStatus.drifted) return;
    final pid = s.entry?.pid;
    if (pid == null) return;
    await Future<void>.delayed(answerPoll);
    final again = await typer.screen(pid);
    if (again == null || _disposed || readLimitScreen(again, DateTime.now()).kind != LimitScreenKind.unreadable) return;
    compatibility.drift(
        reason: 'Claude Code shows a usage limit in words Perch cannot read.',
        session: '${_summary(s).name} (${s.id})',
        expected: "Claude Code's usage-limit lines (Usage limit reached · limit resets <time>; Continuing automatically "
            'at <time> · Esc to cancel)',
        screen: again);
  }

  /// What the subagents still running in [sessionId] do (for the "finished" notification:
  /// a turn that handed work to a background subagent is not finished).
  @override
  List<String> runningSubagents(String sessionId) {
    final s = _sessions[sessionId];
    if (s == null) return const [];
    return [for (final a in _agentsAt(s, DateTime.now())) a.description];
  }

  /// The subagents that were running in [s]'s turn that stopped at [hitAt]: subagent calls
  /// in that turn with no result or a failed one, and those a hook reported running.
  List<AgentRun> _agentsAt(_Session s, DateTime hitAt) {
    final until = hitAt.millisecondsSinceEpoch + 5000;
    final buf = s.buffer;
    var from = 0;
    for (var i = buf.length - 1; i >= 0; i--) {
      final e = buf[i];
      if (e is UserMessage && e.parentToolUseId == null && e.atMs <= until) {
        from = i;
        break;
      }
    }
    final results = {for (final e in buf) if (e is ToolResult) e.toolUseId: e};
    final finished = {for (final e in buf) if (e is SubagentFinished) e.taskId: e.status};
    final out = <AgentRun>[];
    void add(AgentRun a) {
      if (!out.any((x) => x.sameAs(a) && x.description == a.description)) out.add(a);
    }

    for (var i = from; i < buf.length; i++) {
      final e = buf[i];
      if (e.parentToolUseId != null || e.atMs > until) continue;
      if (e is ToolCall && (e.name == 'Task' || e.name == 'Agent')) {
        final r = results[e.toolUseId];
        if (r == null || r.isError) {
          add(AgentRun(e.input['subagent_type'] is String ? e.input['subagent_type'] as String : 'general-purpose',
              e.input['description'] is String ? e.input['description'] as String : ''));
        }
      } else if (e is SubagentStarted) {
        final st = finished[e.taskId];
        if (st == null || st != 'completed') add(AgentRun(e.subagentType, e.description));
      }
    }
    for (final type in s.hookAgents.values) {
      if (!out.any((x) => x.type.toLowerCase() == type.toLowerCase())) out.add(AgentRun(type));
    }
    return out;
  }

  /// Whether [s] waits for a message now: at its input prompt with no dialog (a terminal
  /// Perch reads), not working (one Perch reaches through its inbox), idle (one Perch runs).
  Future<bool> _atPrompt(_Session s) async {
    if (s.origin == SessionOrigin.perch) {
      final c = s.claude;
      return c != null && c.isAlive && c.openPrompts.isEmpty && c.state != SessionState.working;
    }
    if (s.answering || s.terminalPrompt != null) return false;
    final pid = s.entry?.pid;
    if (pid == null) return false;
    final state = _stateOf(s);
    if (typer.supported && (_operable[pid] ??= await typer.canOperate(pid))) {
      if (state == SessionState.working) return false;
      await typer.bringForward(pid);
      final screen = await typer.screen(pid);
      return screen != null && isIdlePrompt(screen) && !isUsageLimitMenu(screen);
    }
    return state != SessionState.working &&
        state != SessionState.waitingQuestion &&
        state != SessionState.waitingPermission &&
        state != SessionState.waitingPlan;
  }

  LimitSessionKind _limitKind(String id) {
    final s = _sessions[id];
    if (s != null && s.origin == SessionOrigin.perch) {
      return (s.claude?.isAlive ?? false) ? LimitSessionKind.perchRun : LimitSessionKind.none;
    }
    final e = s?.entry ?? _externals[id];
    final pid = e?.pid;
    if (e == null || pid == null || !e.summary.live || (s?.hookEnded ?? false)) return LimitSessionKind.none;
    if (typer.supported && (_operable[pid] ?? true)) return LimitSessionKind.terminal;
    return (inbox?.supported ?? false) ? LimitSessionKind.inbox : LimitSessionKind.watchOnly;
  }


  // ------------------------------------------------------------ hooks

  bool _hookStateFresh(_Session s) {
    final at = s.hookStateAt;
    return s.hookState != null && at != null && DateTime.now().difference(at) < hookGrace;
  }

  /// The session's state: what a hook said a moment ago, else what Claude Code lists.
  SessionState? _stateOf(_Session s) => _hookStateFresh(s) ? s.hookState : s.entry?.summary.state;

  void _setHookState(_Session s, SessionState state, {String? reason}) {
    s
      ..hookState = state
      ..hookReason = reason
      ..hookStateAt = DateTime.now();
  }

  void _dropCard(_Session s) {
    s
      ..terminalPrompt = null
      ..promptToolUseId = null
      ..hookPromptAt = null;
  }

  /// Closes the open card (answered at the machine, or the turn moved on): it is not
  /// offered again.
  void _closeCard(_Session s) {
    final p = s.terminalPrompt;
    if (p == null) return;
    s.answeredTerminalPrompts.add(p.promptId);
    final tuid = s.promptToolUseId;
    if (tuid != null) s.answeredTerminalPrompts.add(tuid);
    s.closeSeq++;
    _dropCard(s);
  }

  static bool _sameJson(Object? a, Object? b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !_sameJson(a[k], b[k])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_sameJson(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  /// The waiting hook for card [p], if any.
  _HookWaiter? _waiterFor(_Session s, PromptRequest p) {
    for (final w in s.hookWaiters) {
      if (w.tool == p.toolName && _sameJson(w.input, p.input)) return w;
    }
    return null;
  }

  /// Lets go (with no answer) every waiting hook whose card is no longer open: answered at
  /// the machine, the tool ran, the turn ended.
  void _releaseHookWaiters(_Session s) {
    if (s.hookWaiters.isEmpty) return;
    final p = s.terminalPrompt;
    for (final w in s.hookWaiters.toList()) {
      if (p == null || w.tool != p.toolName || !_sameJson(w.input, p.input)) {
        s.hookWaiters.remove(w);
        w.finish(null);
      }
    }
  }

  /// Whether a `PermissionRequest` hook of the session is waiting for the phone.
  bool isHoldingHook(String sessionId) => _sessions[sessionId]?.hookWaiters.isNotEmpty ?? false;

  /// The `decision` Claude Code takes from a `PermissionRequest` hook for [answer] (the
  /// same shape Perch answers its own sessions with).
  static Map<String, dynamic> _hookDecision(PromptRequest p, PromptAnswer answer, _HookWaiter w) {
    switch (answer) {
      case QuestionAnswer(:final answers):
        return {
          'behavior': 'allow',
          'updatedInput': {...w.input, 'answers': answers},
        };
      case PermissionAnswer(:final allow, :final always, :final message):
        final s = w.suggestions;
        return allow
            ? {
                'behavior': 'allow',
                'updatedInput': w.input,
                if (always && s is List && s.isNotEmpty) 'updatedPermissions': s,
              }
            : {'behavior': 'deny', 'message': (message == null || message.isEmpty) ? 'Denied by user' : message};
      case PlanAnswer(:final approve, :final feedback):
        if (approve) {
          // As the terminal's first "Yes, and use auto mode": the plan as received (Claude
          // Code injected its text and file) and the session switched to auto mode.
          return {
            'behavior': 'allow',
            'updatedInput': w.input,
            'updatedPermissions': [
              {'type': 'setMode', 'mode': 'auto', 'destination': 'session'}
            ],
          };
        }
        return {'behavior': 'deny', 'message': (feedback == null || feedback.isEmpty) ? 'Keep planning' : feedback};
    }
  }

  /// A waiting `PermissionRequest` hook (see hooks.dart): opens the card as [handleHook]
  /// does, then, for a terminal session Perch cannot type into, waits until the phone
  /// answers it (returns the hook's output with the decision) or the card closes some
  /// other way, or [limit] passes (returns null: Claude Code's dialog decides). Every other
  /// session gets null at once.
  Future<Map<String, dynamic>?> holdPermissionHook(Map<String, dynamic> j, {Duration? limit}) async {
    await handleHook(j);
    if (_disposed || j['hook_event_name'] != 'PermissionRequest') return null;
    final claudeId = j['session_id'];
    final tool = j['tool_name'];
    final input = j['tool_input'];
    if (claudeId is! String || tool is! String || input is! Map || _perchRun(claudeId)) return null;
    final s = await _hookSession(claudeId);
    final pid = s?.entry?.pid;
    // Only a session with a terminal dialog: a background one denies at once without a
    // decision, and must not wait for the phone.
    if (s == null || pid == null || s.entry?.interactive != true || _disposed) return null;
    if (!typer.supported || await typer.canOperate(pid)) return null;
    final p = s.terminalPrompt;
    final toolInput = input.cast<String, dynamic>();
    if (p == null || p.toolName != tool || !_sameJson(p.input, toolInput)) return null;
    final w = _HookWaiter(tool, toolInput, j['permission_suggestions']);
    s.hookWaiters.add(w);
    final timer = Timer(limit ?? perchHookHold, () {
      s.hookWaiters.remove(w);
      w.finish(null);
    });
    final decision = await w.done.future;
    timer.cancel();
    s.hookWaiters.remove(w);
    if (decision == null) return null;
    return {
      'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': decision},
    };
  }

  /// The tool use in the transcript that waits for a result and matches [tool] and [input].
  ToolCall? _pendingCall(_Session s, String tool, Map<String, dynamic> input) {
    final done = {for (final e in s.buffer) if (e is ToolResult) e.toolUseId};
    for (final e in s.buffer.reversed) {
      if (e is ToolCall && e.name == tool && !done.contains(e.toolUseId) && _sameJson(e.input, input)) return e;
    }
    return null;
  }

  Future<List<SessionSummary>>? _listing;
  final Map<String, DateTime> _unknownLookedUp = {};

  /// One `claude agents --json` at a time for hooks about sessions not seen yet.
  Future<void> _refreshListing() => _listing ??= list().whenComplete(() => _listing = null);

  bool _perchRun(String claudeId) => _sessions.values
      .any((s) => s.origin == SessionOrigin.perch && (s.claude?.claudeSessionId ?? s.claudeId) == claudeId);

  /// The watched terminal session a hook is about, learning it from the listing if needed.
  Future<_Session?> _hookSession(String claudeId) async {
    _Session? known() {
      final s = _sessions[claudeId];
      if (s != null) return s.origin == SessionOrigin.external ? s : null;
      // A session first listed as pid:<pid> (before its folder was trusted).
      final early = _sessions.values
          .where((x) => x.origin == SessionOrigin.external && x.id.startsWith('pid:') && x.claudeId == claudeId)
          .firstOrNull;
      if (early != null) return early;
      final e = _externals[claudeId];
      return e == null ? null : _watch(e);
    }

    final s = known();
    if (s != null || _sessions.containsKey(claudeId)) return s;
    final last = _unknownLookedUp[claudeId];
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 2)) return null;
    _unknownLookedUp[claudeId] = DateTime.now();
    await _refreshListing();
    return known();
  }

  /// Opens [p] as the session's card unless it is already open or was answered.
  void _openHookCard(_Session s, PromptRequest p, {String? toolUseId}) {
    if (s.answering) return;
    final answered = s.answeredTerminalPrompts;
    if (answered.contains(p.promptId) || (toolUseId != null && answered.contains(toolUseId))) return;
    final cur = s.terminalPrompt;
    if (cur != null && (cur.promptId == p.promptId || (toolUseId != null && s.promptToolUseId == toolUseId))) {
      s.hookPromptAt ??= DateTime.now();
      return;
    }
    s
      ..terminalPrompt = p
      ..promptToolUseId = toolUseId
      ..hookPromptAt = DateTime.now();
  }

  static SessionState _waitingFor(PromptKind k) => switch (k) {
        PromptKind.question => SessionState.waitingQuestion,
        PromptKind.plan => SessionState.waitingPlan,
        PromptKind.permission => SessionState.waitingPermission,
      };

  /// A Claude Code hook's input (see hooks.dart). Opens and closes cards and updates the
  /// session's state at once; the 5-second listing stays the safety net.
  Future<void> handleHook(Map<String, dynamic> j) async {
    if (_disposed || isSelfTestHook(j)) return;
    final event = j['hook_event_name'];
    final claudeId = j['session_id'];
    if (claudeId is String && _selfTestIds.contains(claudeId)) return;
    if (event is! String || event.isEmpty || claudeId is! String || claudeId.isEmpty) {
      _hookDrift(j, 'session_id and hook_event_name');
      return;
    }
    if (!perchHookEvents.containsKey(event) || _perchRun(claudeId)) return;
    final tool = j['tool_name'];
    final input = j['tool_input'];
    final needsTool = event == 'PreToolUse' || event == 'PermissionRequest' || event == 'PostToolUse';
    if (needsTool && (tool is! String || tool.isEmpty || input is! Map)) {
      _hookDrift(j, 'tool_name and tool_input');
      return;
    }
    if (event == 'PreToolUse' && (j['tool_use_id'] is! String || (j['tool_use_id'] as String).isEmpty)) {
      _hookDrift(j, 'tool_use_id');
      return;
    }
    if (event == 'Notification' && j['notification_type'] is! String) {
      _hookDrift(j, 'notification_type');
      return;
    }
    final s = await _hookSession(claudeId);
    if (s == null || _disposed) return;
    final toolInput = input is Map ? input.cast<String, dynamic>() : <String, dynamic>{};
    switch (event) {
      case 'PreToolUse':
        final id = j['tool_use_id'] as String;
        final kind = PromptRequest.kindForTool(tool as String);
        if (kind == PromptKind.permission) return;
        s.tailer?.pollNow();
        _openHookCard(s, promptForToolUse(ToolCall(id, tool, toolInput)), toolUseId: id);
        if (s.terminalPrompt?.promptId == id) _setHookState(s, _waitingFor(kind));
      case 'PermissionRequest':
        if (!await _permissionFromHook(s, tool as String, toolInput, j['permission_suggestions'])) return;
      case 'PostToolUse':
        final p = s.terminalPrompt;
        final id = j['tool_use_id'];
        if (p != null &&
            ((id is String && (p.promptId == id || s.promptToolUseId == id)) ||
                (p.toolName == tool && _sameJson(p.input, toolInput)))) {
          _closeCard(s);
        }
        if (s.terminalPrompt == null) _setHookState(s, SessionState.working);
      case 'Stop':
        _closeCard(s);
        s.stopRequestedAt = null;
        _setHookState(s, SessionState.idle);
        limits.turnEnded(s.id);
      case 'StopFailure':
        // The turn ended on an API error; a usage limit pauses the session.
        _closeCard(s);
        s.stopRequestedAt = null;
        _setHookState(s, SessionState.idle);
        if (j['error'] == 'rate_limit') {
          final text = j['last_assistant_message'] is String ? j['last_assistant_message'] as String : null;
          unawaited(_limitHit(s, text: text));
        }
      case 'UserPromptSubmit':
        _closeCard(s);
        _setHookState(s, SessionState.working);
        final prompt = j['prompt'] is String ? j['prompt'] as String : null;
        limits.ownerPrompt(s.id, prompt);
      case 'SessionEnd':
        // Right after a hand-back the end is the host's own copy's (the listing still drops
        // the terminal's session if that is what ended).
        final back = s.handedBackAt;
        if (back != null && DateTime.now().difference(back) < handBackEndGrace) return;
        _closeCard(s);
        s.stopRequestedAt = null;
        s.hookEnded = true;
      case 'SessionStart':
        s.hookEnded = false;
        _setHookState(s, SessionState.idle);
      case 'SubagentStart':
        if (s.terminalPrompt == null) _setHookState(s, SessionState.working);
        final type = j['agent_type'] is String ? j['agent_type'] as String : '';
        if (j['agent_id'] is String) s.hookAgents[j['agent_id'] as String] = type;
        limits.agentStarted(s.id, AgentRun(type));
      case 'SubagentStop':
        // Says nothing about the main session (seen live arriving after its Stop).
        if (j['agent_id'] is String) s.hookAgents.remove(j['agent_id'] as String);
      case 'Notification':
        final type = j['notification_type'] as String;
        final message = j['message'] is String ? j['message'] as String : '';
        if (type == 'idle_prompt') {
          if (s.terminalPrompt == null) _setHookState(s, SessionState.idle);
        } else if (type == 'permission_prompt') {
          if (s.terminalPrompt == null) _setHookState(s, SessionState.waitingPermission);
        } else if (type == 'quota_auto_resume_fired') {
          // Claude Code continued by itself after the reset.
          _record(s, Notice(message.isEmpty ? 'Usage limit reset · Claude Code continued' : message));
          _setHookState(s, SessionState.working);
          limits.claudeContinued(s.id);
        } else if (type == 'quota_auto_resume_stale' || type == 'quota_auto_resume_disabled') {
          // It waits for Enter, or gave up waiting: Perch acts as if it never waited.
          if (message.isNotEmpty) _record(s, Notice(message));
          limits.claudeStopped(s.id);
        } else if (type.startsWith('quota_')) {
          if (message.isNotEmpty) _record(s, Notice(message));
          if (!type.contains('warn')) {
            _setHookState(s, SessionState.blocked, reason: message.isEmpty ? null : message);
            unawaited(_limitHit(s, text: message));
          }
        } else {
          return;
        }
    }
    _publish(s);
  }

  /// A permission request (or a question / plan approval asked through one): its card,
  /// named after the waiting tool use in the transcript when it is there already.
  /// Returns false when nothing changed.
  Future<bool> _permissionFromHook(_Session s, String tool, Map<String, dynamic> input, Object? suggestions) async {
    final cur = s.terminalPrompt;
    if (cur != null && cur.toolName == tool && _sameJson(cur.input, input)) {
      s.hookPromptAt ??= DateTime.now();
      return false;
    }
    s.tailer?.pollNow();
    final call = _pendingCall(s, tool, input);
    final id = call?.toolUseId ?? 'hook:${s.id}:${(tool + jsonEncode(input)).hashCode.toRadixString(16)}';
    if (s.answeredTerminalPrompts.contains(id)) return false;
    final kind = PromptRequest.kindForTool(tool);
    String? always;
    if (kind == PromptKind.permission) {
      // Read the screen once to learn whether the terminal offers "Yes, and …". When the
      // dialog is not drawn yet, Claude Code's own suggestions say the same.
      final seq = s.closeSeq;
      final pid = s.entry?.pid;
      final screen = pid != null && typer.supported ? await typer.screen(pid) : null;
      if (s.closeSeq != seq || _disposed) return false;
      if (screen != null && detectDialog(screen) == DialogKind.permission) {
        always = alwaysOptionOn(screen);
      } else {
        if (suggestions is List && suggestions.isNotEmpty) always = "Yes, and don't ask again";
        if (screen != null && screenDrift(screen) != null) {
          unawaited(_confirmScreenDrift(s, screen, SessionState.waitingPermission));
        }
      }
    }
    _openHookCard(s, promptForToolUse(ToolCall(id, tool, input), alwaysLabel: always), toolUseId: call?.toolUseId);
    if (s.terminalPrompt?.promptId == id) _setHookState(s, _waitingFor(kind));
    return true;
  }

  /// A hook without the fields Perch needs: Claude Code changed what it sends.
  void _hookDrift(Map<String, dynamic> j, String missing) {
    final event = j['hook_event_name'] is String ? j['hook_event_name'] as String : 'unknown';
    final claudeId = j['session_id'] is String ? j['session_id'] as String : 'unknown';
    compatibility.drift(
      reason: 'A Claude Code hook ($event) arrived without the fields Perch needs.',
      session: _sessions[claudeId] == null ? claudeId : '${_summary(_sessions[claudeId]!).name} ($claudeId)',
      expected: '$missing; it had: ${(j.keys.toList()..sort()).join(', ')}',
    );
  }

  static String _expectedFor(SessionState? state) => switch (state) {
        SessionState.waitingQuestion => 'a question',
        SessionState.waitingPlan => 'a plan approval',
        SessionState.waitingPermission => 'a permission request',
        _ => 'a dialog',
      };

  /// Raises drift when [screen] shows a dialog Perch cannot read and a second look a
  /// moment later still does (a dialog that was mid-change or went away is not drift).
  Future<void> _confirmScreenDrift(_Session s, String screen, SessionState? waitingFor) async {
    if (screenDrift(screen) == null && !_unreadableQuestion(screen, s.id)) return;
    if (compatibility.current.status == CompatibilityStatus.drifted) return;
    final pid = s.entry?.pid;
    if (pid == null || !typer.supported) return;
    await Future<void>.delayed(answerPoll);
    final again = await typer.screen(pid);
    if (again == null || _disposed) return;
    final why = screenDrift(again) ??
        (_unreadableQuestion(again, s.id) ? 'Claude Code shows a question Perch cannot read.' : null);
    if (why == null) return;
    compatibility.drift(
        reason: why, session: '${_summary(s).name} (${s.id})', expected: _expectedFor(waitingFor), screen: again);
  }

  /// Whether [screen] shows a step of [call]'s question set after its first question: a
  /// later question, or the review (which lists every question, the first one too).
  static bool _laterQuestionStep(String screen, ToolCall call) => laterQuestionStep(screen, call.input['questions']);

  /// A dialog recognised as a question whose text or options cannot be read.
  static bool _unreadableQuestion(String screen, String sessionId) =>
      detectDialog(screen) == DialogKind.question && screenPrompt(screen, sessionId) == null;

  /// Whether the stop-check hooks are installed (see hooks.dart); without them Stop
  /// cannot reach a terminal Perch cannot press Esc in.
  bool stopHooks = true;

  /// How long a Stop waits for the session's next tool step.
  static const stopRequestLife = Duration(minutes: 2);

  /// Interrupts the session's current work. A terminal session gets Esc in its terminal,
  /// as the owner would press it. A terminal with no adapter (VS Code, Cursor, iTerm2, …)
  /// stops at its next tool step through the stop-check hooks, or at once when it is
  /// waiting on a permission request held for the phone. [CannotType] when neither works.
  Future<void> interrupt(String sessionId) async {
    final s = _sessions[sessionId];
    if (s != null && s.origin == SessionOrigin.perch) return s.claude?.interrupt();
    final e = s?.entry ?? _externals[sessionId];
    if (e == null) throw NoSuchSession(sessionId);
    final pid = e.pid;
    if (pid == null || !typer.supported) throw CannotType('This terminal cannot be operated from Perch on this machine.');
    if (await typer.canOperate(pid)) {
      if (!await typer.keys(pid, ConsoleKeys.escape)) throw CannotType('Could not press Esc in the terminal session.');
      return;
    }
    final watched = s ?? _watch(e);
    final p = watched.terminalPrompt;
    final w = p == null ? null : _waiterFor(watched, p);
    if (p != null && w != null) {
      // Waiting on a request held for the phone: refuse it and interrupt, as Esc would.
      w.finish({'behavior': 'deny', 'message': 'Stopped from Perch', 'interrupt': true});
      watched.hookWaiters.remove(w);
      watched.answeredTerminalPrompts.add(p.promptId);
      final tuid = watched.promptToolUseId;
      if (tuid != null) watched.answeredTerminalPrompts.add(tuid);
      _dropCard(watched);
      _publish(watched);
      return;
    }
    if (!stopHooks) {
      throw CannotType('Stop needs the newer Perch hooks on this machine: run perch_host hooks install.');
    }
    // Nothing running: nothing to stop (a request left over would stop the next turn).
    if (_stateOf(watched) == SessionState.idle) return;
    watched.stopRequestedAt = DateTime.now();
  }

  /// A stop check (`PreToolUse` or `PostToolBatch`, see hooks.dart): answers at once.
  /// When Stop was pressed for the session, the hook output that ends the turn (and, before
  /// a tool, refuses that tool); otherwise null.
  Map<String, dynamic>? stopCheck(Map<String, dynamic> j) {
    final claudeId = j['session_id'];
    final event = j['hook_event_name'];
    if (claudeId is! String || event is! String) return null;
    final s = _sessions[claudeId] ??
        _sessions.values.where((x) => x.origin == SessionOrigin.external && x.claudeId == claudeId).firstOrNull;
    final at = s?.stopRequestedAt;
    if (s == null || at == null) return null;
    s.stopRequestedAt = null;
    if (DateTime.now().difference(at) > stopRequestLife) return null;
    // Claude Code runs no Stop hook for a turn a hook ended: say idle now.
    _closeCard(s);
    _setHookState(s, SessionState.idle);
    _publish(s);
    return {
      'continue': false,
      'stopReason': 'Stopped from Perch',
      if (event == 'PreToolUse')
        'hookSpecificOutput': {
          'hookEventName': 'PreToolUse',
          'permissionDecision': 'deny',
          'permissionDecisionReason': 'Stopped from Perch',
        },
    };
  }

  Future<void> stop(String sessionId) async {
    final s = _sessions[sessionId];
    if (s != null && s.origin == SessionOrigin.perch) {
      await s.claude?.stop();
      _publish(s);
      return;
    }
    final e = s?.entry ?? _externals[sessionId];
    if (e == null) throw NoSuchSession(sessionId);
    if (e.pid == null) throw ReadOnlySession();
    await external.killPid(e.pid!);
    limits.forget(sessionId);
  }

  // ------------------------------------------------------------ rename, delete, resume

  /// The longest session name Perch sets.
  static const maxNameLength = 100;

  static final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  /// What Perch knows of a session for rename, delete and resume.
  ({_Session? s, ExternalEntry? entry, SessionSummary? ended, String? claudeId, String cwd, int? pid, bool running})
      _target(String id) {
    final s = _sessions[id];
    final entry = s?.entry ?? _externals[id];
    final ended = _ended[id];
    if (s == null && entry == null && ended == null) throw NoSuchSession(id);
    final child = s?.origin == SessionOrigin.perch ? s?.claude : null;
    final pid = s?.origin == SessionOrigin.perch ? child?.pid : entry?.pid;
    final running = (child != null && child.isAlive) || (s?.origin != SessionOrigin.perch && entry?.pid != null);
    return (
      s: s,
      entry: entry,
      ended: ended?.summary,
      claudeId: s?.claude?.claudeSessionId ??
          s?.claudeId ??
          entry?.claudeSessionId ??
          ended?.claudeId ??
          (pid == null ? null : registeredSessionId(pid)),
      cwd: s?.cwd ?? entry?.summary.cwd ?? ended?.summary.cwd ?? '',
      pid: pid,
      running: running,
    );
  }

  /// The Claude Code session id of the live session with process id [pid], from Claude
  /// Code's own registry (`<config dir>/sessions/<pid>.json`), or null.
  String? registeredSessionId(int pid) {
    try {
      final sep = Platform.pathSeparator;
      final f = File('${_configDir ?? claudeConfigDir()}${sep}sessions$sep$pid.json');
      final j = jsonDecode(f.readAsStringSync());
      if (j is Map && j['pid'] == pid && j['sessionId'] is String) return j['sessionId'] as String;
    } catch (_) {}
    return null;
  }

  /// Whether Claude Code lists [claudeId] as running right now (also a session Perch has
  /// not seen yet, such as one the owner just resumed).
  Future<bool> _listedRunning(String claudeId) async =>
      (await external.listEntries()).any((e) => e.claudeSessionId == claudeId && e.pid != null);

  static String _checkedName(String raw) {
    final name = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (name.isEmpty) throw ArgumentError('Enter a name');
    if (name.length > maxNameLength) throw ArgumentError('At most $maxNameLength characters');
    return name;
  }

  /// Renames a session for Claude Code too. A running session gets `/rename <name>` typed
  /// into its terminal (Claude Code's own command; only where Perch can type, and only
  /// while Claude waits for input). A session that is not running gets what Claude Code's
  /// own rename writes: a `custom-title` and an `agent-name` line at the end of its
  /// conversation (the resume list reads the first, a resumed session the second) and the
  /// `<id>/custom-title.json` beside it. Returns the name set.
  Future<String> rename(String sessionId, String rawName) async {
    final name = _checkedName(rawName);
    final t = _target(sessionId);
    final cid = t.claudeId;
    if (t.running) {
      final pid = t.pid;
      if (t.s?.origin == SessionOrigin.perch || pid == null) {
        throw StateError('Perch cannot rename a session it runs itself. Rename it after it ends.');
      }
      if (!typer.supported || !await typer.canOperate(pid)) {
        throw CannotType('Perch cannot type /rename into the terminal this session runs in. '
            'Type /rename $name there, or rename it from Perch after it ends.');
      }
      final screen = await typer.screen(pid);
      if (screen == null || !isPromptReady(screen) || detectDialog(screen) != DialogKind.none) {
        throw StateError('Claude is busy or waiting for an answer: rename the session when it is idle.');
      }
      if (!await typer.type(pid, '/rename $name')) throw CannotType('Could not type /rename into the terminal.');
      final watched = t.s;
      if (watched != null) {
        watched.customTitle = name;
        _publish(watched);
      }
      return name;
    }
    if (cid == null || !_uuid.hasMatch(cid)) throw StateError('Claude Code has no conversation saved for this session.');
    if (await _listedRunning(cid)) {
      throw StateError('This session is running again: rename it in its terminal or try again.');
    }
    final file = findTranscript(cid, configDir: _configDir);
    if (file == null) throw StateError('Claude Code has no conversation saved for this session.');
    final lines = '${jsonEncode({'type': 'custom-title', 'customTitle': name, 'sessionId': cid})}\n'
        '${jsonEncode({'type': 'agent-name', 'agentName': name, 'sessionId': cid})}\n';
    final raf = file.openSync(mode: FileMode.append);
    try {
      final len = raf.lengthSync();
      var lead = '';
      if (len > 0) {
        raf.setPositionSync(len - 1);
        if (raf.readByteSync() != 10) lead = '\n';
      }
      raf.writeStringSync('$lead$lines');
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    try {
      final side = Directory('${file.parent.path}${Platform.pathSeparator}$cid');
      side.createSync(recursive: true);
      File('${side.path}${Platform.pathSeparator}custom-title.json').writeAsStringSync(jsonEncode({'customTitle': name}));
    } catch (_) {
      // The resume list falls back to the transcript.
    }
    _titles.remove(cid);
    final s = t.s;
    if (s != null) {
      s.customTitle = name;
      _publish(s);
    }
    final ended = _ended[sessionId];
    if (ended != null) {
      _ended[sessionId] = (summary: ended.summary.copyWith(name: name), claudeId: ended.claudeId);
      if (!_disposed) _sessionUpdates.add(_ended[sessionId]!.summary);
    }
    return name;
  }

  /// Switches a running session's model ([model] null, empty or `default`: the default).
  /// A session the host runs gets it directly; a terminal session gets `/model <name>`
  /// typed (only where Perch can type, and only while Claude waits for input). Returns a
  /// line for the phone.
  Future<String> setModel(String sessionId, String? model) async {
    final m = model?.trim() ?? '';
    final name = (m.isEmpty || m.toLowerCase() == 'default') ? null : m;
    if (name != null && !validModelName(name)) throw ArgumentError('Not a model name: $name');
    final said = name == null ? 'Model: your default' : 'Model: $name';
    final t = _target(sessionId);
    if (!t.running) throw StateError('This session is not running: choose its model when it starts again.');
    final s = t.s;
    if (s != null && s.origin == SessionOrigin.perch) {
      s.claude!.setModel(name);
      s.model = name;
      _publish(s);
      return said;
    }
    final pid = t.pid;
    final command = '/model ${name ?? 'default'}';
    if (pid == null || !typer.supported || !await typer.canOperate(pid)) {
      throw CannotType('Perch cannot type into the terminal this session runs in. Type $command there.');
    }
    // Warp reads only the tab in front: bring the session's tab forward first (typing
    // would switch to it anyway).
    await typer.bringForward(pid);
    final screen = await typer.screen(pid);
    if (screen == null) throw CannotType('Perch cannot read this terminal right now. Type $command there.');
    if (!isIdlePrompt(screen) || detectDialog(screen) != DialogKind.none) {
      throw StateError('Claude is busy or waiting for an answer: switch the model when it is idle.');
    }
    final settings = File('${_configDir ?? claudeConfigDir()}${Platform.pathSeparator}settings.json');
    final defaultBefore = _defaultModelIn(settings);
    if (!await typer.type(pid, command)) throw CannotType('Could not type $command into the terminal.');
    // Claude Code may ask to confirm ("Switch model?": the next reply re-reads the whole
    // conversation on the new model). The owner asked for the switch: choose Yes. Then its
    // answer: "Set model to … and saved as your default for new sessions" (2.1.326).
    final end = DateTime.now().add(modelConfirmWait);
    var confirmed = false;
    var savedAsDefault = false;
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final now = await typer.screen(pid);
      if (now == null) continue;
      if (!confirmed && isModelSwitchConfirm(now)) {
        if (!await typer.keys(pid, '1')) throw CannotType('Could not confirm $command in the terminal.');
        confirmed = true;
        continue;
      }
      // Its answer below the command typed just now.
      final at = now.lastIndexOf('/model ');
      final answer = at < 0 ? now : now.substring(at);
      if (RegExp(r'Set model to|Kept model as').hasMatch(answer)) {
        savedAsDefault = answer.contains('saved as your default');
        break;
      }
    }
    // Model… switches this session only: put the owner's default for new sessions back.
    if (savedAsDefault || _defaultModelIn(settings) != defaultBefore) {
      await _restoreDefaultModel(settings, defaultBefore);
    }
    return said;
  }

  /// The `model` in Claude Code's user settings: absent (null), or its value as JSON text.
  static String? _defaultModelIn(File settings) {
    try {
      final j = jsonDecode(settings.readAsStringSync());
      if (j is Map && j.containsKey('model')) return jsonEncode(j['model']);
    } catch (_) {}
    return null;
  }

  /// Waits (up to [modelSaveWait]) for Claude Code to save the new default, then writes
  /// [before] back (removing the key when there was none). Only `model` changes; the file
  /// keeps Claude Code's own layout (2-space JSON).
  Future<void> _restoreDefaultModel(File settings, String? before) async {
    final end = DateTime.now().add(modelSaveWait);
    while (_defaultModelIn(settings) == before) {
      if (DateTime.now().isAfter(end)) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    try {
      final j = jsonDecode(settings.readAsStringSync()) as Map<String, dynamic>;
      if (before == null) {
        j.remove('model');
      } else {
        j['model'] = jsonDecode(before);
      }
      settings.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(j)}\n');
    } catch (_) {}
  }

  /// How long Perch waits for Claude Code to save a switched model as the default.
  Duration modelSaveWait = const Duration(seconds: 2);

  /// How long after typing `/model` Perch watches for Claude Code's confirmation.
  Duration modelConfirmWait = const Duration(seconds: 3);

  /// How long a session being deleted may take to end.
  Duration endTimeout = const Duration(seconds: 10);

  /// Deletes a session for Claude Code too: ends it if it runs (and waits until its
  /// process is gone), then removes exactly what belongs to that Claude Code session id:
  /// its conversation (`projects/<folder>/<id>.jsonl`, in every project folder that has
  /// one), the folder beside it (`<id>/`: subagent conversations, tool results, the name
  /// file), and `file-history/<id>`, `session-env/<id>`, `tasks/<id>` in Claude Code's
  /// folder. Returns how many files and folders were removed.
  Future<int> delete(String sessionId) async {
    final t = _target(sessionId);
    final cid = t.claudeId;
    if (cid != null && !_uuid.hasMatch(cid)) throw StateError('Not a Claude Code session id: $cid');
    if (cid == null && t.running) {
      throw StateError("Claude Code has not said this session's id yet, so nothing was ended or deleted. Try again "
          'in a moment.');
    }
    if (t.running) {
      final s = t.s;
      if (s != null && s.origin == SessionOrigin.perch) {
        await s.claude?.stop();
      } else if (t.pid != null) {
        await external.killPid(t.pid!);
        final end = DateTime.now().add(endTimeout);
        while (await external.pidAlive(t.pid!)) {
          if (DateTime.now().isAfter(end)) throw StateError('The session did not end, so nothing was deleted.');
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    }
    if (cid != null && await _listedRunning(cid)) {
      throw StateError('This session is running again, so nothing was deleted.');
    }
    var removed = 0;
    if (cid != null) {
      final sep = Platform.pathSeparator;
      final root = _configDir ?? claudeConfigDir();
      final projects = Directory('$root${sep}projects');
      final targets = <FileSystemEntity>[];
      if (projects.existsSync()) {
        for (final d in projects.listSync(followLinks: false).whereType<Directory>()) {
          targets
            ..add(File('${d.path}$sep$cid.jsonl'))
            ..add(Directory('${d.path}$sep$cid'));
        }
      }
      for (final dir in const ['file-history', 'session-env', 'tasks']) {
        targets.add(Directory('$root$sep$dir$sep$cid'));
      }
      for (final e in targets) {
        try {
          if (e.existsSync()) {
            e.deleteSync(recursive: true);
            removed++;
          }
        } catch (_) {}
      }
      _titles.remove(cid);
    }
    final s = _sessions[sessionId];
    if (s != null) {
      for (final w in s.hookWaiters) {
        w.finish(null);
      }
      s.hookWaiters.clear();
      await _stopTailer(s);
      await _detachClaude(s);
      _sessions.remove(sessionId);
    }
    _externals.remove(sessionId);
    _ended.remove(sessionId);
    _deleted.add(sessionId);
    limits.forget(sessionId);
    if (cid != null) _deleted.add(cid);
    return removed;
  }

  /// Deleted session ids: never listed again (Claude Code may list an ended background
  /// session for a while).
  final Set<String> _deleted = {};

  /// Resumes a session that is not running in a new terminal window on this machine
  /// (`claude --resume <id>` in its folder: Terminal.app on the Mac, a console window on
  /// Windows), as a session started from the phone. Returns its summary once Claude Code
  /// lists it. It runs on [accountId]; null: the account it ran on before (when Perch
  /// started it and that account is still here), else the machine's active account.
  Future<SessionSummary> resume(String sessionId, {String? accountId}) async {
    final t = _target(sessionId);
    if (t.running) throw StateError('This session is already running.');
    final cid = t.claudeId;
    if (cid == null || !_uuid.hasMatch(cid)) throw StateError('Claude Code has no conversation saved for this session.');
    if (!typer.supported) throw StateError('Perch cannot open a terminal window on this machine.');
    if (t.cwd.isEmpty || !Directory(t.cwd).existsSync()) {
      throw StateError("This session's folder no longer exists: ${t.cwd}");
    }
    if (findTranscript(cid, configDir: _configDir) == null) {
      throw StateError('Claude Code has no conversation saved for this session.');
    }
    final previous = accounts?.accountOf(cid);
    final account = _startAccount(accountId ??
        (previous != null && (previous == machineLoginAccountId || accounts?.byId(previous) != null) ? previous : null));
    final environment = await _environmentFor(account);
    final before = {
      for (final e in await external.listEntries())
        if (e.pid != null) e.pid!
    };
    await _openWindow(TerminalLaunch(
      cwd: t.cwd,
      executable: launcher.executable,
      args: [...launcher.leadingArgs, '--resume', cid],
      environment: environment,
    ));
    final deadline = DateTime.now().add(terminalStartTimeout);
    ExternalEntry? found;
    while (true) {
      found = (await external.listEntries())
          .where((e) =>
              e.interactive &&
              e.pid != null &&
              !before.contains(e.pid) &&
              (e.claudeSessionId == cid || (e.claudeSessionId == null && _samePath(e.summary.cwd, t.cwd))))
          .firstOrNull;
      if (found != null || DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(terminalPoll);
    }
    if (found == null) {
      throw StateError('Claude Code did not start in a terminal window within ${terminalStartTimeout.inSeconds} seconds.');
    }
    _ended.remove(sessionId);
    final old = _sessions[sessionId];
    if (old != null && old.origin == SessionOrigin.perch && !(old.claude?.isAlive ?? false)) {
      await _detachClaude(old);
      _sessions.remove(sessionId);
    }
    _externals[found.summary.id] = found;
    final s = _watch(found)
      ..accountId = account
      ..claudeId ??= cid;
    if (account != null) accounts?.recordSession(cid, account);
    _publish(s);
    return _summary(s);
  }

  /// Moves a session to another account (decision 3: only when the owner switches that
  /// session). A running one is ended first (its conversation is kept), then its
  /// conversation is resumed in a new terminal window under [accountId]'s token. Claude
  /// Code cannot change the account of a running session to a stored token (`/login` signs
  /// in afresh in a browser and replaces the machine's own login).
  Future<SessionSummary> switchAccount(String sessionId, String accountId) async {
    final a = accounts;
    if (a == null) throw StateError('This Perch host does not support accounts.');
    _startAccount(accountId);
    await a.tokenFor(accountId); // an expired or unreadable account fails before anything ends
    final t = _target(sessionId);
    final cid = t.claudeId;
    if (cid == null || !_uuid.hasMatch(cid)) {
      throw StateError("Claude Code has not saved this session's conversation yet, so it cannot move to another account.");
    }
    if (!typer.supported) throw StateError('Perch cannot open a terminal window on this machine.');
    if (findTranscript(cid, configDir: _configDir) == null) {
      throw StateError('Claude Code has no conversation saved for this session.');
    }
    if (t.running) {
      final s = t.s;
      if (s != null && s.origin == SessionOrigin.perch) {
        await s.claude?.stop();
      } else if (t.pid != null) {
        await external.killPid(t.pid!);
        final end = DateTime.now().add(endTimeout);
        while (await external.pidAlive(t.pid!) || await _listedRunning(cid)) {
          if (DateTime.now().isAfter(end)) throw StateError('The session did not end, so it was not moved.');
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      await list(); // it is listed as not running now
    }
    return resume(sessionId, accountId: accountId);
  }

  /// The usage-limit card's Switch account: every session the limit paused moves to
  /// [accountId] (ended and resumed under its token), then Perch continues each one as
  /// after a reset. [makeDefault]: new sessions on this machine start on it too.
  Future<void> switchLimitedTo(String accountId, {bool makeDefault = false}) async {
    final a = accounts;
    if (a == null) throw StateError('This Perch host does not support accounts.');
    final l = limits.current;
    if (l == null || l.sessions.isEmpty) throw StateError('No session is paused by a usage limit.');
    _startAccount(accountId);
    await a.tokenFor(accountId);
    if (makeDefault) a.setActive(accountId);
    final failed = <String>[];
    for (final x in l.sessions) {
      limits.beginMove(x.id);
      try {
        final moved = await switchAccount(x.id, accountId);
        limits.moved(x.id, moved.id);
      } catch (e) {
        limits.moveFailed(x.id);
        failed.add('${x.name.isEmpty ? 'A session' : x.name} (${e is StateError ? e.message : e})');
      }
    }
    if (failed.isNotEmpty) {
      throw StateError("Couldn't move to ${a.labelOf(accountId)}: ${failed.join('; ')}");
    }
  }

  /// Stops Perch sessions and kills outside ones; returns how many.
  Future<int> killAll() async {
    var n = 0;
    for (final s in _sessions.values.toList()) {
      if (s.origin != SessionOrigin.perch) continue;
      final c = s.claude;
      if (c == null) continue;
      if (c.state == SessionState.finished || c.state == SessionState.stopped) continue;
      await c.stop();
      _publish(s);
      n++;
    }
    await list();
    final outside = [
      for (final e in _externals.values) e,
      for (final s in _sessions.values)
        if (s.origin == SessionOrigin.external && s.entry != null) s.entry!,
    ];
    for (final e in outside) {
      if (e.pid == null) continue;
      await external.killPid(e.pid!);
      n++;
    }
    return n;
  }

  Future<void> dispose() async {
    _disposed = true;
    await limits.dispose();
    for (final s in _sessions.values) {
      for (final w in s.hookWaiters) {
        w.finish(null);
      }
      s.hookWaiters.clear();
    }
    for (final s in _sessions.values) {
      await _stopTailer(s);
      await _detachClaude(s);
    }
    await _sessionUpdates.close();
    await _events.close();
    await _promptsOpened.close();
    await _promptsClosed.close();
    await _usageUpdates.close();
    await _usageLimits.close();
  }
}

/// The session manager as the usage-limit tracker sees it.
class _LimitAdapter implements LimitSessions {
  final SessionManager m;
  _LimitAdapter(this.m);

  _Session? _s(String id) {
    final s = m._sessions[id];
    if (s != null) return s;
    final e = m._externals[id];
    return e == null ? null : m._watch(e);
  }

  int? _pid(String id) {
    final s = m._sessions[id];
    return s?.origin == SessionOrigin.external ? (s?.entry?.pid) : (s == null ? m._externals[id]?.pid : null);
  }

  @override
  LimitSessionKind kindOf(String id) => m._limitKind(id);

  @override
  String nameOf(String id) {
    final n = m.summaryOf(id)?.name.trim();
    return n == null || n.isEmpty ? 'A session' : n;
  }

  @override
  String get machineName => m.machineName;

  @override
  Future<String?> screenOf(String id) async {
    final pid = _pid(id);
    if (pid == null || !m.typer.supported) return null;
    return m.typer.screen(pid);
  }

  @override
  Future<bool> keys(String id, String keys) async {
    final pid = _pid(id);
    if (pid == null || !m.typer.supported) return false;
    await m.typer.bringForward(pid);
    return m.typer.keys(pid, keys);
  }

  @override
  Future<bool> typeLine(String id, String text) async {
    final pid = _pid(id);
    if (pid == null || !m.typer.supported) return false;
    await m.typer.bringForward(pid);
    return m.typer.type(pid, text);
  }

  @override
  Future<bool> atPrompt(String id) async {
    final s = _s(id);
    return s != null && await m._atPrompt(s);
  }

  @override
  int? ownerPromptAt(String id) {
    final s = m._sessions[id];
    return s?.lastPromptAtMs ?? m._transcriptFacts(s?.claudeId ?? m._externals[id]?.claudeSessionId)?.promptAt;
  }

  @override
  Future<void> send(String id, String text) => m.send(id, text);

  @override
  void note(String id, String text) {
    final s = _s(id);
    if (s != null) m._record(s, Notice(text));
  }

  @override
  List<AgentRun> agentsAt(String id, DateTime hitAt) {
    final s = m._sessions[id];
    return s == null ? const [] : m._agentsAt(s, hitAt);
  }

  @override
  UsageSnapshot? get usage => m._usage;
}
