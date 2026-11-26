import 'dart:async';
import 'dart:io';

import 'package:perch_host/src/claude_session.dart';
import 'package:perch_host/src/console_typer.dart';
import 'package:perch_host/src/external_sessions.dart';
import 'package:perch_host/src/stream_parser.dart';
import 'package:perch_protocol/perch_protocol.dart';

/// A launcher that runs the scripted stand-in for `claude`.
ClaudeLauncher fakeLauncher({Map<String, String>? env}) => ClaudeLauncher(
      Platform.resolvedExecutable,
      [
        'run',
        '${Directory.current.path}${Platform.pathSeparator}test${Platform.pathSeparator}fixtures'
            '${Platform.pathSeparator}fake_claude.dart'
      ],
      env,
    );

List<ConversationEvent> collectEvents(ClaudeSession s) {
  final out = <ConversationEvent>[];
  s.lines.listen((l) {
    if (l is ParsedEvents) out.addAll(l.events);
  });
  return out;
}

Future<void> waitUntil(FutureOr<bool> Function() cond, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (!await cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> waitForState(ClaudeSession s, SessionState want, {Duration timeout = const Duration(seconds: 30)}) async {
  try {
    await waitUntil(() => s.state == want, timeout: timeout);
  } on TimeoutException {
    throw TimeoutException('state is ${s.state} (reason ${s.reason}), wanted $want');
  }
}

/// A TerminalConsole that records what it was asked to do and shows scripted screens.
class FakeConsoleTyper implements TerminalConsole {
  @override
  bool supported;
  bool result;

  /// `type` calls (text submitted with Enter).
  final List<({int pid, String text})> calls = [];

  /// Every action in order: `type:<text>`, `keys:<keys>`, `enter`, `screen`.
  final List<String> actions = [];

  /// What [screen] returns; null means the screen cannot be read.
  String? currentScreen;

  /// Called after each key press / typing so a test can change the screen in response.
  void Function(String action)? onAction;

  FakeConsoleTyper({this.supported = true, this.result = true, this.currentScreen});

  void _did(String a) {
    actions.add(a);
    onAction?.call(a);
  }

  @override
  Future<bool> type(int pid, String text) async {
    calls.add((pid: pid, text: text));
    _did('type:$text');
    return result;
  }

  @override
  Future<bool> keys(int pid, String keys) async {
    _did('keys:$keys');
    return result;
  }

  @override
  Future<bool> pressEnter(int pid) async {
    _did('enter');
    return result;
  }

  @override
  Future<String?> screen(int pid) async {
    actions.add('screen');
    return currentScreen;
  }

  /// Called when a session's tab is brought forward (a Warp tab can be read only in front).
  void Function()? onBringForward;

  @override
  Future<bool> bringForward(int pid) async {
    onBringForward?.call();
    return supported;
  }

  /// Whether [canOperate] says yes; null: whenever [supported].
  bool? operable;

  @override
  Future<bool> canOperate(int pid) async => operable ?? supported;

  /// Actions other than reading the screen.
  List<String> get presses => [for (final a in actions) if (a != 'screen') a];
}

typedef FakeTerminalConsole = FakeConsoleTyper;

/// An ExternalSessions whose entries and kills are controlled by the test.
class FakeExternalSessions extends ExternalSessions {
  FakeExternalSessions() : super(const ClaudeLauncher('unused-claude'));

  List<ExternalEntry> entries = [];
  final List<int> kills = [];

  /// When true, killing a pid removes its entry (the process is gone).
  bool killRemoves = true;

  ExternalEntry entry({
    int? pid,
    String? sessionId,
    required String cwd,
    String kind = 'interactive',
    String? status = 'idle',
    String? state,
    String? waitingFor,
    String? name,
  }) =>
      ExternalSessions.entryFromJson({
        'pid': ?pid,
        'sessionId': ?sessionId,
        'cwd': cwd,
        'kind': kind,
        'startedAt': 1794410986545,
        if (kind == 'interactive') 'status': ?status,
        'state': ?state,
        'waitingFor': ?waitingFor,
        'name': ?name,
      })!;

  /// How many times the listing was asked for.
  int listCalls = 0;

  @override
  Future<List<ExternalEntry>> listEntries() async {
    listCalls++;
    return List.of(entries);
  }

  @override
  Future<void> killPid(int pid) async {
    kills.add(pid);
    if (killRemoves) entries.removeWhere((e) => e.pid == pid);
  }

  @override
  Future<bool> pidAlive(int pid) async => entries.any((e) => e.pid == pid);

  /// Pids that run under a process the host started (a `.cmd` shim's claude.exe).
  final Set<int> ownChildren = {};

  @override
  Future<bool> descendsFrom(int pid, int ancestor) async => ownChildren.contains(pid);
}
