// One `claude` child process in structured input/output mode.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:perch_protocol/perch_protocol.dart';

import 'stream_parser.dart';

/// How to start `claude`. Tests point it at the scripted fake.
class ClaudeLauncher {
  final String executable;
  final List<String> leadingArgs;

  /// Extra environment variables for the child (used by tests).
  final Map<String, String>? environment;

  const ClaudeLauncher(this.executable, [this.leadingArgs = const [], this.environment]);

  /// `PERCH_CLAUDE_BIN` if set, else `claude` on PATH.
  ClaudeLauncher.fromEnvironment()
      : executable = _envBin() ?? 'claude',
        leadingArgs = const [],
        environment = null;

  static String? _envBin() {
    final v = Platform.environment['PERCH_CLAUDE_BIN'];
    return v == null || v.trim().isEmpty ? null : v.trim();
  }

  /// A `.cmd` / `.bat` shim on Windows must go through the shell.
  bool get needsShell {
    if (!Platform.isWindows) return false;
    final lower = executable.toLowerCase();
    return lower.endsWith('.cmd') || lower.endsWith('.bat');
  }

  /// Variables a running Claude Code session sets for its own children. A `claude` started
  /// with them inherited believes it is a child session and, among other things, turns
  /// transcript saving off (so it could not be resumed or watched). Perch's sessions are
  /// independent, so these are removed when the host itself runs inside a Claude session.
  static const inheritedSessionMarkers = [
    'CLAUDECODE',
    'CLAUDE_CODE_CHILD_SESSION',
    'CLAUDE_CODE_ENTRYPOINT',
    'CLAUDE_CODE_SESSION_ID',
    'CLAUDE_CODE_SESSION_ATTENDED',
    'CLAUDE_CODE_MESSAGING_SOCKET',
    'CLAUDE_CODE_MESSAGING_TOKEN',
    'CLAUDE_PID',
  ];

  Map<String, String> childEnvironment() {
    final env = Map<String, String>.of(Platform.environment);
    final markers = inheritedSessionMarkers.map((m) => m.toUpperCase()).toSet();
    env.removeWhere((k, _) => markers.contains(k.toUpperCase()));
    env.addAll(environment ?? const {});
    return env;
  }

  /// The same `claude` with [extra] added to its environment (an account's token).
  ClaudeLauncher withEnvironment(Map<String, String> extra) =>
      ClaudeLauncher(executable, leadingArgs, {...?environment, ...extra});

  Future<Process> start(List<String> args, {String? workingDirectory}) => Process.start(
        executable,
        [...leadingArgs, ...args],
        workingDirectory: workingDirectory,
        environment: childEnvironment(),
        includeParentEnvironment: false,
        runInShell: needsShell,
      );

  /// Runs `claude` [args] to the end; [environment] replaces the child environment.
  Future<ProcessResult> run(List<String> args, {Map<String, String>? environment}) => Process.run(
        executable,
        [...leadingArgs, ...args],
        environment: environment ?? childEnvironment(),
        includeParentEnvironment: false,
        runInShell: needsShell,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
}

class PromptAlreadyAnswered implements Exception {
  @override
  String toString() => 'PromptAlreadyAnswered';
}

final _rand = Random.secure();

String newUuid() {
  final b = List<int>.generate(16, (_) => _rand.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Kills a process and, on Windows, its whole tree.
Future<void> killProcessTree(int pid) async {
  try {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
    } else {
      Process.killPid(pid, ProcessSignal.sigterm);
    }
  } catch (_) {}
}

class ClaudeSession {
  final ClaudeLauncher launcher;
  final String cwd;
  final String? name;
  final String? model;
  final String? resumeId;
  final String? permissionMode;

  ClaudeSession({
    required this.launcher,
    required this.cwd,
    this.name,
    this.model,
    this.resumeId,
    this.permissionMode,
  });

  final _lines = StreamController<ParsedLine>.broadcast(sync: true);
  final _changed = StreamController<void>.broadcast(sync: true);
  final List<PromptRequest> _open = [];
  final Map<String, String> _taskToolUse = {}; // subagent task id -> tool_use_id
  final Set<String> _answered = {};

  Process? _process;
  SessionState _state = SessionState.idle;
  String? _reason;
  String _stderrTail = '';
  String? _claudeSessionId;
  String? _claudeVersion;
  String? _actualModel;

  Stream<ParsedLine> get lines => _lines.stream;
  Stream<void> get changed => _changed.stream;
  SessionState get state => _state;
  String? get reason => _reason;
  List<PromptRequest> get openPrompts => List.unmodifiable(_open);

  /// Claude's own session id, known after the first `init` line (or the resume id).
  String? get claudeSessionId => _claudeSessionId ?? resumeId;
  String? get claudeVersion => _claudeVersion;
  String? get actualModel => _actualModel;
  /// The child process id while it runs.
  int? get pid => _process?.pid;
  bool get isAlive => _process != null && (_state != SessionState.finished && _state != SessionState.stopped);

  List<String> buildArgs() => [
        '-p',
        '--input-format',
        'stream-json',
        '--output-format',
        'stream-json',
        '--verbose',
        '--permission-prompt-tool',
        'stdio',
        '--forward-subagent-text',
        if (model != null && model!.isNotEmpty) ...['--model', model!],
        if (name != null && name!.isNotEmpty) ...['-n', name!],
        if (resumeId != null) ...['--resume', resumeId!],
        if (permissionMode != null && permissionMode!.isNotEmpty) ...['--permission-mode', permissionMode!],
      ];

  void _set(SessionState s, {String? reason}) {
    _state = s;
    if (reason != null) _reason = reason;
    if (!_changed.isClosed) _changed.add(null);
  }

  /// Starts the process. With a [firstPrompt] the session starts working on it; with
  /// null (a resumed session) nothing is sent until [sendUser].
  Future<void> start(String? firstPrompt) async {
    final Process p;
    try {
      p = await launcher.start(buildArgs(), workingDirectory: cwd);
    } catch (e) {
      _set(SessionState.blocked, reason: e is ProcessException ? 'Could not start ${launcher.executable}: ${e.message}'.trim() : '$e');
      return;
    }
    _process = p;
    p.stdin.encoding = utf8;
    p.stdin.done.catchError((_) {});
    p.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(_onLine);
    p.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
      _stderrTail += chunk;
      if (_stderrTail.length > 4000) _stderrTail = _stderrTail.substring(_stderrTail.length - 4000);
    });
    unawaited(p.exitCode.then(_onExit));
    if (firstPrompt != null) {
      sendUser(firstPrompt);
    } else {
      _set(SessionState.idle);
    }
  }

  void _onExit(int code) {
    // Give stderr a moment to drain so the reason is complete.
    Future<void>.delayed(const Duration(milliseconds: 50), () {
      if (_state == SessionState.stopped) return;
      final hadOpen = _open.isNotEmpty;
      _open.clear();
      if (code == 0) {
        _set(SessionState.finished);
      } else {
        final err = _stderrTail.trim();
        final tail = err.length > 300 ? err.substring(err.length - 300) : err;
        _set(SessionState.finished, reason: tail.isEmpty ? 'Claude Code exited with code $code' : tail);
      }
      if (hadOpen && !_changed.isClosed) _changed.add(null);
    });
  }

  void _onLine(String raw) {
    var parsed = parseClaudeLine(raw);
    switch (parsed) {
      case ParsedInit():
        _claudeSessionId = parsed.claudeSessionId.isEmpty ? _claudeSessionId : parsed.claudeSessionId;
        _claudeVersion = parsed.claudeVersion;
        _actualModel = parsed.model;
      case ParsedEvents(:final events):
        for (final e in events) {
          if (e is SubagentStarted) _taskToolUse[e.taskId] = e.toolUseId;
          _resolveParent(e);
        }
      case ParsedPrompt(:final prompt):
        final parent = _resolve(prompt.parentToolUseId);
        if (parent != prompt.parentToolUseId) {
          parsed = ParsedPrompt(PromptRequest(
            promptId: prompt.promptId,
            kind: prompt.kind,
            toolName: prompt.toolName,
            input: prompt.input,
            suggestions: prompt.suggestions,
            parentToolUseId: parent,
          ));
        }
      default:
        break;
    }
    if (!_lines.isClosed) _lines.add(parsed);

    switch (parsed) {
      case ParsedPrompt(:final prompt):
        _open.add(prompt);
        _set(_stateForPrompts());
      case ParsedEvents(:final events):
        if (events.any((e) => e is TurnEnded)) {
          _open.clear();
          if (_state != SessionState.stopped && _state != SessionState.finished) _set(SessionState.idle);
        }
      default:
        break;
    }
  }

  String? _resolve(String? parent) {
    if (parent == null || !parent.startsWith(agentParentPrefix)) return parent;
    return _taskToolUse[parent.substring(agentParentPrefix.length)] ?? parent;
  }

  void _resolveParent(ConversationEvent e) => e.parentToolUseId = _resolve(e.parentToolUseId);

  SessionState _stateForPrompts() {
    if (_open.isEmpty) return SessionState.working;
    return switch (_open.last.kind) {
      PromptKind.question => SessionState.waitingQuestion,
      PromptKind.permission => SessionState.waitingPermission,
      PromptKind.plan => SessionState.waitingPlan,
    };
  }

  bool get _ended =>
      _state == SessionState.finished || _state == SessionState.stopped || _state == SessionState.blocked;

  void _write(Map<String, dynamic> m) {
    final p = _process;
    if (p == null) throw StateError('Claude Code is not running');
    p.stdin.writeln(jsonEncode(m));
  }

  /// Sends a user message. Throws [StateError] if the session has ended.
  void sendUser(String text) {
    if (_ended || _process == null) throw StateError('This session has ended');
    _write({
      'type': 'user',
      'message': {'role': 'user', 'content': text},
    });
    _set(_open.isEmpty ? SessionState.working : _stateForPrompts());
  }

  /// Answers an open prompt. Throws [PromptAlreadyAnswered] if it is unknown or closed.
  void answer(String promptId, PromptAnswer answer) {
    final i = _open.indexWhere((p) => p.promptId == promptId);
    if (i < 0 || _answered.contains(promptId) || _process == null) throw PromptAlreadyAnswered();
    final prompt = _open.removeAt(i);
    _answered.add(promptId);
    final Map<String, dynamic> response;
    switch (answer) {
      case QuestionAnswer(:final answers):
        response = {
          'behavior': 'allow',
          'updatedInput': {'questions': prompt.input['questions'] ?? const [], 'answers': answers},
        };
      case PermissionAnswer(:final allow, :final always, :final message):
        response = allow
            ? {
                'behavior': 'allow',
                'updatedInput': prompt.input,
                if (always && prompt.suggestions.isNotEmpty) 'updatedPermissions': prompt.suggestions,
              }
            : {'behavior': 'deny', 'message': (message == null || message.isEmpty) ? 'Denied by user' : message};
      case PlanAnswer(:final approve, :final feedback):
        response = approve
            ? {'behavior': 'allow', 'updatedInput': prompt.input}
            : {'behavior': 'deny', 'message': (feedback == null || feedback.isEmpty) ? 'Keep planning' : feedback};
    }
    _write({
      'type': 'control_response',
      'response': {'subtype': 'success', 'request_id': promptId, 'response': response},
    });
    _set(_stateForPrompts());
  }

  /// Switches the model for the next turns ([model] null: the default).
  void setModel(String? model) {
    if (_ended || _process == null) throw StateError('This session has ended');
    _write({
      'type': 'control_request',
      'request_id': newUuid(),
      'request': {'subtype': 'set_model', 'model': ?model},
    });
  }

  /// Asks Claude to stop the current turn.
  void interrupt() {
    if (_ended || _process == null) return;
    _write({
      'type': 'control_request',
      'request_id': newUuid(),
      'request': {'subtype': 'interrupt'},
    });
  }

  /// Kills the process; state becomes stopped.
  Future<void> stop() async {
    _open.clear();
    if (_state != SessionState.finished && _state != SessionState.stopped) _set(SessionState.stopped);
    final p = _process;
    if (p != null) {
      try {
        await p.stdin.close();
      } catch (_) {}
      await killProcessTree(p.pid);
      p.kill(ProcessSignal.sigkill);
      await p.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    }
  }

  Future<void> dispose() async {
    await stop();
    await _lines.close();
    await _changed.close();
  }
}
