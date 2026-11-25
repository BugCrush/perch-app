// Decides when the owner's phone is told something, seals what it is told, and hands it
// to the relay (POST /m/<machine id>/push). The relay, FCM and Google see only the sealed
// payload and an opaque per-session collapse key.
//
// Notified: a card opens (question, permission, plan); a session is blocked; a usage
// limit is hit; a turn finishes (any session).
// Not notified: while the owner is at the machine, that is, used its keyboard or mouse in
// the last 60 seconds (a locked machine counts as idle). Where that cannot be read, a
// session the owner typed into at the terminal in the last 2 minutes (a
// `UserPromptSubmit` hook whose prompt Perch did not type) instead. Never to a device that
// shows that session in the foreground right now. Muting a session is per phone: the app
// drops those notifications itself.
// Withdrawn: when the card is answered anywhere, or the session moves on.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

import 'host_state.dart';
import 'inbox.dart' show isPerchInboxPrompt;
import 'input_idle.dart' show InputIdleReader, PerchKeyLog;
import 'session_manager.dart' show trustReason;
import 'terminal_prompts.dart' show trustFolderTool;

/// What the notifier watches (the session manager).
abstract interface class PushSource {
  Stream<({String sessionId, PromptRequest prompt})> get promptsOpened;
  Stream<({String sessionId, String promptId})> get promptsClosed;
  Stream<SessionSummary> get sessionUpdates;
  Stream<String> get usageLimits;
  SessionSummary? summaryOf(String sessionId);

  /// What the subagents still running in [sessionId] do (their short descriptions; empty
  /// strings when they have none). Empty when none run.
  List<String> runningSubagents(String sessionId);
}

/// The first few words of a subagent's description, for a notification.
String shortTask(String description, {int words = 4}) {
  final w = description.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
  if (w.length <= words) return w.join(' ');
  return '${w.take(words).join(' ')}…';
}

/// "finished", or what the turn handed to subagents still running when it ended.
String finishedWhat(List<String> subagents) {
  if (subagents.isEmpty) return pushWhat(PushKinds.finished);
  final what = subagents.map(shortTask).firstWhere((d) => d.isNotEmpty, orElse: () => '');
  final who = subagents.length == 1 ? 'a subagent' : '${subagents.length} subagents';
  return what.isEmpty ? 'handed work to $who' : 'handed work to $who · $what';
}

/// Posts [body] to [uri]; returns the HTTP status and the answer (replaced in tests).
typedef PushPoster = Future<({int status, String body})> Function(Uri uri, Map<String, String> headers, String body);

Future<({int status, String body})> defaultPushPoster(Uri uri, Map<String, String> headers, String body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.postUrl(uri).timeout(const Duration(seconds: 15));
    headers.forEach(req.headers.set);
    req.add(utf8.encode(body));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final answer = await utf8.decoder.bind(res).join();
    return (status: res.statusCode, body: answer);
  } finally {
    client.close(force: true);
  }
}

/// The words after `<session name>: `.
String pushWhat(String kind, {PromptRequest? prompt}) {
  switch (kind) {
    case PushKinds.question:
      final qs = prompt?.input['questions'];
      final n = qs is List ? qs.length : 1;
      return n <= 1 ? 'asked a question' : 'asked $n questions';
    case PushKinds.permission:
      return 'wants permission to use ${prompt?.toolName ?? 'a tool'}';
    case PushKinds.plan:
      return 'has a plan to approve';
    case PushKinds.usageLimit:
      return 'hit a usage limit';
    case PushKinds.finished:
      return 'finished';
    case PushKinds.resumedChanged:
      return 'resumed without the subagent';
    default:
      return 'is blocked';
  }
}

class _Shown {
  final String kind;
  final String body;
  String? promptId;
  _Shown(this.kind, this.body, this.promptId);
}

class PushNotifier {
  final PushSource source;
  final HostState state;

  /// The notification title (the app shows its own alias for the machine instead, if any).
  String machineName;
  final PushPoster poster;

  /// How long a reason to notify must hold before the notification goes (a card answered
  /// at once is not worth a buzz), and how long a withdraw waits for a follow-up card.
  final Duration settle;

  /// Typing at the terminal silences that session for this long (only where [inputIdle]
  /// cannot be read).
  final Duration terminalQuiet;

  /// The time since the machine's last keyboard or mouse input (null reader, or a null
  /// answer: unknown, the [terminalQuiet] rule applies).
  final InputIdleReader? inputIdle;

  /// Keyboard or mouse input this recent means the owner is at the machine: nothing is sent.
  final Duration deskActive;

  /// When Perch itself pressed keys in a terminal (that input is not the owner's).
  final PerchKeyLog? perchKeys;
  final DateTime Function() _clock;

  /// One line per notification sent or withdrawn (the console), without its text.
  final void Function(String line)? log;

  /// False while remote access is stopped: nothing is sent.
  bool enabled = true;

  /// Devices that show [sessionId] in the foreground now (the server knows).
  Iterable<String> Function(String sessionId) focusedDevices = (_) => const [];

  PushNotifier({
    required this.source,
    required this.state,
    required this.machineName,
    PushPoster? poster,
    this.settle = const Duration(milliseconds: 1500),
    this.terminalQuiet = const Duration(minutes: 2),
    this.inputIdle,
    this.deskActive = const Duration(seconds: 60),
    this.perchKeys,
    DateTime Function()? clock,
    this.log,
  })  : poster = poster ?? defaultPushPoster,
        _clock = clock ?? DateTime.now;

  final List<StreamSubscription<dynamic>> _subs = [];
  final Map<String, Map<String, PromptRequest>> _open = {};
  final Map<String, SessionState> _states = {};
  final Map<String, _Shown> _shown = {};
  final Map<String, Timer> _pendingNotify = {};
  final Map<String, Timer> _pendingWithdraw = {};

  /// A withdraw was called off by a new reason: the same text need not buzz again.
  final Set<String> _kept = {};
  final List<({String text, DateTime at})> _perchTexts = [];
  final Map<String, DateTime> _typedAt = {};
  final Map<String, DateTime> _limitAt = {};
  Future<void> _sending = Future.value();

  void start() {
    _subs
      ..add(source.promptsOpened.listen((p) => _promptOpened(p.sessionId, p.prompt)))
      ..add(source.promptsClosed.listen((p) => _promptClosed(p.sessionId, p.promptId)))
      ..add(source.sessionUpdates.listen(_sessionUpdated))
      ..add(source.usageLimits.listen(_usageLimit));
  }

  // ------------------------------------------------------------ what Perch and the owner do

  static String _norm(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Perch is about to type or send [text] (a message, or a new session's first
  /// instruction): its `UserPromptSubmit` hook is not the owner at the terminal.
  void perchTyping(String text) {
    final now = _clock();
    _perchTexts
      ..removeWhere((t) => now.difference(t.at) > terminalQuiet)
      ..add((text: _norm(text), at: now));
  }

  /// A Claude Code hook's input (the server passes every one).
  void onHook(Map<String, dynamic> j) {
    if (j['hook_event_name'] != 'UserPromptSubmit') return;
    final sid = j['session_id'];
    if (sid is! String || sid.isEmpty) return;
    final now = _clock();
    // A phone message delivered through the inbox (terminals Perch cannot type into):
    // the owner is away, not at the terminal.
    if (j['prompt'] is String && isPerchInboxPrompt(j['prompt'] as String)) return;
    final prompt = j['prompt'] is String ? _norm(j['prompt'] as String) : null;
    _perchTexts.removeWhere((t) => now.difference(t.at) > terminalQuiet);
    final i = prompt == null ? -1 : _perchTexts.indexWhere((t) => t.text == prompt);
    if (i >= 0) {
      _perchTexts.removeAt(i);
    } else {
      _typedAt[sid] = now;
    }
  }

  bool _ownerAtTerminal(String sid) {
    final t = _typedAt[sid];
    return t != null && _clock().difference(t) < terminalQuiet;
  }

  /// Whether the owner is at the machine: recent keyboard or mouse input; where that
  /// cannot be read, recent typing at this session's terminal.
  Future<bool> _ownerAtMachine(String sid) async {
    Duration? idle;
    try {
      idle = await inputIdle?.call();
    } catch (_) {}
    if (idle != null) {
      if (idle >= deskActive) return false;
      // The last input was Perch typing a phone message or answering a card.
      if (perchKeys?.covers(_clock().subtract(idle)) ?? false) return false;
      return true;
    }
    return _ownerAtTerminal(sid);
  }

  // ------------------------------------------------------------ reasons

  void _promptOpened(String sid, PromptRequest p) {
    (_open[sid] ??= {})[p.promptId] = p;
    final kind = p.toolName == trustFolderTool
        ? PushKinds.blocked
        : switch (p.kind) {
            PromptKind.question => PushKinds.question,
            PromptKind.permission => PushKinds.permission,
            PromptKind.plan => PushKinds.plan,
          };
    _schedule(sid, kind, prompt: p, holds: () => _open[sid]?.containsKey(p.promptId) ?? false);
  }

  void _promptClosed(String sid, String promptId) {
    _open[sid]?.remove(promptId);
    if (_shown[sid]?.promptId == promptId) _scheduleWithdraw(sid);
  }

  static bool _busy(SessionState? s) =>
      s == SessionState.working ||
      s == SessionState.waitingQuestion ||
      s == SessionState.waitingPermission ||
      s == SessionState.waitingPlan;

  void _sessionUpdated(SessionSummary s) {
    final sid = s.id;
    final prev = _states[sid];
    final now = s.state;
    _states[sid] = now;
    final shown = _shown[sid];
    if (now == SessionState.blocked && prev != SessionState.blocked) {
      final limit = _limitAt[sid];
      final byLimit = limit != null && _clock().difference(limit) < const Duration(seconds: 30);
      // The folder-trust card says it; a usage limit has its own words.
      if (s.reason != trustReason && !byLimit) {
        _schedule(sid, PushKinds.blocked, holds: () => _states[sid] == SessionState.blocked);
      }
    }
    if (now != SessionState.blocked &&
        shown != null &&
        (shown.kind == PushKinds.blocked || shown.kind == PushKinds.usageLimit) &&
        shown.promptId == null) {
      _scheduleWithdraw(sid);
    }
    if (_busy(prev) && (now == SessionState.idle || now == SessionState.finished)) {
      _schedule(sid, PushKinds.finished,
          holds: () => _states[sid] == SessionState.idle || _states[sid] == SessionState.finished);
    }
    if (shown?.kind == PushKinds.finished && now == SessionState.working) _scheduleWithdraw(sid);
    if (now == SessionState.stopped && shown != null) _scheduleWithdraw(sid);
  }

  void _usageLimit(String sid) {
    _limitAt[sid] = _clock();
    _schedule(sid, PushKinds.usageLimit, holds: () => true);
  }

  // ------------------------------------------------------------ usage limits

  /// The machine's usage limit reset with [sessionIds] still paused: one notification for
  /// the machine ("Usage is back · 2 sessions paused"), with Continue and Open in the app.
  /// A session the owner typed into at its terminal in the last 2 minutes is left out
  /// (the owner is there); muting is the phone's.
  void usageBack(List<String> sessionIds) {
    final away = [for (final s in sessionIds) if (!_ownerAtTerminal(s)) s];
    if (away.isEmpty || _disposed) return;
    final body = 'Usage is back · ${away.length} ${away.length == 1 ? 'session' : 'sessions'} paused';
    _shown[usageLimitPushId] = _Shown(PushKinds.usageBack, body, null);
    _post(
      PushNote(
        title: machineName,
        body: body,
        machineId: state.machineId,
        sessionId: usageLimitPushId,
        kind: PushKinds.usageBack,
        sessionIds: away,
      ),
      usageLimitPushId,
    );
  }

  /// The machine's limit is over (every session resumed): its notification goes.
  void usageCleared() {
    if (_shown.remove(usageLimitPushId) == null) return;
    _post(PushNote(machineId: state.machineId, sessionId: usageLimitPushId, kind: PushKinds.withdraw), usageLimitPushId,
        withdraw: true);
  }

  /// [sessionId] resumed after the limit but not the same way: [text] is the note
  /// ("Resumed without the subagent"). Not to a device showing that session (its toast says
  /// it); the app drops it for a muted session, and while it is in front (the toast).
  void resumedChanged(String sessionId, String text) {
    if (_disposed) return;
    final name = source.summaryOf(sessionId)?.name.trim();
    final what = text.isEmpty ? pushWhat(PushKinds.resumedChanged) : '${text[0].toLowerCase()}${text.substring(1)}';
    final body = '${name == null || name.isEmpty ? 'A session' : name} $what';
    _shown[sessionId] = _Shown(PushKinds.resumedChanged, body, null);
    _post(
      PushNote(
          title: machineName, body: body, machineId: state.machineId, sessionId: sessionId, kind: PushKinds.resumedChanged),
      sessionId,
      except: focusedDevices(sessionId).toList(),
    );
  }

  /// The relay's shared pool is [percent]% used today: one notification to this
  /// (the relay owner's) machine's devices.
  void relayPool(int percent) {
    if (_disposed) return;
    final body = 'Shared relay pool $percent% used today. Friends\' machines pause at 100% until 00:00 UTC; yours keep working.';
    _post(
      PushNote(title: machineName, body: body, machineId: state.machineId, sessionId: relayPoolPushId, kind: PushKinds.relayPool),
      relayPoolPushId,
    );
  }

  // ------------------------------------------------------------ sending

  void _schedule(String sid, String kind, {PromptRequest? prompt, required bool Function() holds}) {
    final withdrawing = _pendingWithdraw.remove(sid);
    if (withdrawing != null) {
      withdrawing.cancel();
      _kept.add(sid);
    }
    _pendingNotify.remove(sid)?.cancel();
    late final Timer timer;
    timer = Timer(settle, () async {
      if (_pendingNotify[sid] == timer) _pendingNotify.remove(sid);
      if (!holds()) return;
      if (await _ownerAtMachine(sid) || _disposed) return;
      // A newer reason arrived while the idle time was read: that one decides.
      if (_pendingNotify.containsKey(sid) || !holds()) return;
      _notify(sid, kind, prompt);
    });
    _pendingNotify[sid] = timer;
  }

  void _scheduleWithdraw(String sid) {
    if (!_shown.containsKey(sid)) return;
    _pendingWithdraw.remove(sid)?.cancel();
    _pendingWithdraw[sid] = Timer(settle, () {
      _pendingWithdraw.remove(sid);
      final shown = _shown.remove(sid);
      _kept.remove(sid);
      if (shown == null) return;
      _post(PushNote(machineId: state.machineId, sessionId: sid, kind: PushKinds.withdraw), sid, withdraw: true);
    });
  }

  void _notify(String sid, String kind, PromptRequest? prompt) {
    final name = source.summaryOf(sid)?.name.trim();
    final what = kind == PushKinds.finished ? finishedWhat(source.runningSubagents(sid)) : pushWhat(kind, prompt: prompt);
    final body = '${name == null || name.isEmpty ? 'A session' : name}: $what';
    final shown = _shown[sid];
    // A card replaced by the same card (answered, asked again): no second buzz.
    if (shown != null && _kept.remove(sid) && shown.body == body) {
      shown.promptId = prompt?.promptId;
      return;
    }
    _shown[sid] = _Shown(kind, body, prompt?.promptId);
    _post(
      PushNote(
        title: machineName,
        body: body,
        machineId: state.machineId,
        sessionId: sid,
        kind: kind,
        promptId: prompt?.promptId,
      ),
      sid,
      except: focusedDevices(sid).toList(),
    );
  }

  /// Sends [note] to every allowed device: one post per device, sealed with its own key (its
  /// collapse tag from it too). Nothing is sealed with the pairing secret (keyless access was
  /// removed on 2026-11-19). With no target there is no post at all (an empty `devices` list).
  void _post(PushNote note, String sid, {bool withdraw = false, List<String> except = const []}) {
    final url = state.relayUrl;
    if (!enabled || url == null) return;
    final skip = except.toSet();
    final bodies = [
      for (final d in state.devices)
        if (!skip.contains(d.id) && d.keyBytes != null)
          _body(d.keyBytes!, note, sid, withdraw, [d.id], except),
    ];
    if (bodies.isEmpty) return;
    final uri = relayHttpUri(url, state.machineId, 'push');
    final headers = {
      'Authorization': 'Bearer ${state.hostToken}',
      'X-Perch-Device-Token-Hash': tokenHash(state.deviceToken),
      if (state.relayInvite != null) 'X-Perch-Invite': state.relayInvite!,
      'Content-Type': 'application/json',
    };
    // One at a time, in order: a withdraw never overtakes its notification.
    _sending = _sending.then((_) async {
      for (final body in bodies) {
        try {
          final r = await poster(uri, headers, body);
          // The relay says how many devices it handed the message to: {"sent":n,"failed":m}.
          final answer = r.body.length > 100 ? r.body.substring(0, 100) : r.body;
          log?.call('Push ${withdraw ? 'withdrawn' : 'sent (${note.kind})'}: relay answered ${r.status} $answer');
        } catch (e) {
          log?.call('Push ${withdraw ? 'withdraw' : note.kind} failed: $e');
        }
      }
    });
  }

  String _body(List<int> key, PushNote note, String sid, bool withdraw, List<String> devices, List<String> except) =>
      jsonEncode({
        'payload': sealPush(key, state.machineId, note),
        'collapseKey': pushTag(key, sid),
        'priority': withdraw ? 'normal' : 'high',
        if (withdraw) 'withdraw': true,
        'devices': devices,
        if (except.isNotEmpty) 'except': except,
      });

  /// Waits for the notifications already handed to the relay (tests).
  Future<void> get idle => _sending;

  bool _disposed = false;

  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    for (final t in [..._pendingNotify.values, ..._pendingWithdraw.values]) {
      t.cancel();
    }
    _pendingNotify.clear();
    _pendingWithdraw.clear();
    await _sending;
  }
}
