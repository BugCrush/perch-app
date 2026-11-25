// macOS and Linux: operates terminal Claude Code sessions that run inside tmux. The owner's
// `claude` shell function (`perch_host shell install`) starts each interactive session in
// its own invisible tmux server, in whatever terminal they use (Warp, Terminal.app, …);
// Perch finds the pane holding a session's `claude` process, types with `send-keys` and
// reads the screen with `capture-pane`. A session outside tmux cannot be typed into: the
// calls return false or null and the app offers the take-over instead.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'console_typer.dart';

/// Result of one tmux (or ps) call.
typedef TmuxResult = ({int exitCode, String stdout});

/// Runs [executable] with [args] and returns its exit code and stdout.
typedef TmuxRunner = Future<TmuxResult> Function(String executable, List<String> args);

class TmuxTerminalConsole implements TerminalConsole {
  /// The tmux program (a full path, or found on PATH).
  final String tmux;

  /// Folders holding tmux server sockets (`$TMUX_TMPDIR/tmux-<uid>`, `/tmp/tmux-<uid>`).
  final List<String> socketDirs;

  final TmuxRunner _run;
  final bool _available;

  TmuxTerminalConsole(
      {required this.tmux,
      required this.socketDirs,
      TmuxRunner? run,
      bool? available,
      this.keyGap = const Duration(milliseconds: 60)})
      : _run = run ?? _runProcess,
        _available = available ?? !Platform.isWindows;

  /// tmux on PATH or in Homebrew's folders; null when it is not installed.
  static String? findTmux({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final dirs = [...(env['PATH'] ?? '').split(':'), '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin'];
    for (final d in dirs) {
      if (d.isEmpty) continue;
      final f = File('$d/tmux');
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  /// Where this user's tmux servers keep their sockets.
  static List<String> defaultSocketDirs({Map<String, String>? environment, int? uid}) {
    final env = environment ?? Platform.environment;
    final id = uid ?? _uid();
    final dirs = <String>{
      if ((env['TMUX_TMPDIR'] ?? '').isNotEmpty) '${env['TMUX_TMPDIR']}/tmux-$id',
      '/tmp/tmux-$id',
      '/private/tmp/tmux-$id',
    };
    return dirs.toList();
  }

  static int _uid() {
    try {
      final r = Process.runSync('id', ['-u']);
      return int.tryParse('${r.stdout}'.trim()) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  @override
  bool get supported => _available;

  /// tmux key names for the special keys in [ConsoleKeys].
  static final Map<String, String> keyNames = {
    ConsoleKeys.up: 'Up',
    ConsoleKeys.down: 'Down',
    ConsoleKeys.left: 'Left',
    ConsoleKeys.right: 'Right',
    ConsoleKeys.escape: 'Escape',
    ConsoleKeys.tab: 'Tab',
    ConsoleKeys.enter: 'Enter',
  };

  /// The tmux calls that press [keys]: one per special key in [ConsoleKeys], one per run of
  /// other characters (`send-keys -l`, so tmux never reads them as key names). They are
  /// sent apart, as a person types: Claude Code takes a burst of input for a paste, in
  /// which Enter is a new line rather than a submit.
  static List<List<String>> sendKeysCalls(String socket, String pane, String keys) {
    final calls = <List<String>>[];
    final literal = StringBuffer();
    void flush() {
      if (literal.isEmpty) return;
      calls.add(['-S', socket, 'send-keys', '-t', pane, '-l', '--', literal.toString()]);
      literal.clear();
    }

    for (final rune in keys.runes) {
      final ch = String.fromCharCode(rune);
      final name = keyNames[ch];
      if (name != null) {
        flush();
        calls.add(['-S', socket, 'send-keys', '-t', pane, name]);
      } else {
        literal.write(ch);
      }
    }
    flush();
    return calls;
  }

  /// The tmux call that pastes [text] into [pane] as a bracketed paste (line breaks stay
  /// line breaks in Claude Code's prompt, as when the owner pastes), from a buffer that is
  /// deleted afterwards.
  static List<String> pasteArgs(String socket, String pane, String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return ['-S', socket, 'set-buffer', '-b', bufferName, '--', normalized, ';', 'paste-buffer', '-p', '-d', '-b', bufferName, '-t', pane];
  }

  static const bufferName = 'perch-message';

  /// The visible rows of a pane, trailing spaces trimmed and empty rows left out (the same
  /// shape as the Windows console reader).
  static String screenText(String captured) {
    final rows = const LineSplitter().convert(captured).map((l) => l.trimRight()).where((l) => l.isNotEmpty);
    return rows.isEmpty ? '' : '${rows.join('\n')}\n';
  }

  /// The tmux pane ([socket], pane id) whose process is [pid] or one of its ancestors.
  Future<({String socket, String pane})?> paneOf(int pid) async {
    if (!supported) return null;
    final panes = <int, ({String socket, String pane})>{};
    for (final socket in _sockets()) {
      final r = await _call(['-S', socket, 'list-panes', '-a', '-F', '#{pane_pid} #{pane_id}']);
      if (r == null || r.exitCode != 0) continue;
      for (final line in const LineSplitter().convert(r.stdout)) {
        final parts = line.trim().split(' ');
        final p = parts.length == 2 ? int.tryParse(parts[0]) : null;
        if (p != null) panes[p] = (socket: socket, pane: parts[1]);
      }
    }
    if (panes.isEmpty) return null;
    if (panes[pid] case final hit?) return hit;
    // A `claude` started from the shell inside a pane: walk up its parents.
    final parents = await _parents();
    var cur = pid;
    for (var i = 0; i < 16; i++) {
      final up = parents[cur];
      if (up == null || up <= 1) return null;
      if (panes[up] case final hit?) return hit;
      cur = up;
    }
    return null;
  }

  Iterable<String> _sockets() sync* {
    final seen = <String>{};
    for (final d in socketDirs) {
      final dir = Directory(d);
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync()) {
        final real = e.resolveSymbolicLinksSync();
        if (FileSystemEntity.typeSync(real) == FileSystemEntityType.unixDomainSock && seen.add(real)) yield e.path;
      }
    }
  }

  Future<Map<int, int>> _parents() async {
    final r = await _safeRun('ps', ['-Ao', 'pid=,ppid=']);
    final m = <int, int>{};
    if (r == null || r.exitCode != 0) return m;
    for (final line in const LineSplitter().convert(r.stdout)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length != 2) continue;
      final a = int.tryParse(parts[0]), b = int.tryParse(parts[1]);
      if (a != null && b != null) m[a] = b;
    }
    return m;
  }

  Future<TmuxResult?> _call(List<String> args) => _safeRun(tmux, args);

  Future<TmuxResult?> _safeRun(String exe, List<String> args) async {
    try {
      return await _run(exe, args);
    } catch (_) {
      return null;
    }
  }

  /// Pause between separate key presses and before the Enter that submits a message.
  final Duration keyGap;

  Future<bool> _tmuxOk(List<String> args) async {
    final r = await _call(args);
    return r != null && r.exitCode == 0;
  }

  Future<bool> _send(int pid, String keys) async {
    if (keys.isEmpty) return true;
    final p = await paneOf(pid);
    if (p == null) return false;
    final calls = sendKeysCalls(p.socket, p.pane, keys);
    for (var i = 0; i < calls.length; i++) {
      if (i > 0) await Future<void>.delayed(keyGap);
      if (!await _tmuxOk(calls[i])) return false;
    }
    return true;
  }

  @override
  Future<bool> type(int pid, String text) async {
    final p = await paneOf(pid);
    if (p == null) return false;
    if (text.isNotEmpty) {
      if (!await _tmuxOk(pasteArgs(p.socket, p.pane, text))) return false;
      await Future<void>.delayed(keyGap * 5);
    }
    return _tmuxOk(sendKeysCalls(p.socket, p.pane, ConsoleKeys.enter).single);
  }

  @override
  Future<bool> keys(int pid, String keys) => _send(pid, keys);

  @override
  Future<bool> pressEnter(int pid) => _send(pid, ConsoleKeys.enter);

  @override
  Future<bool> bringForward(int pid) async => await paneOf(pid) != null;

  @override
  Future<bool> canOperate(int pid) async => await paneOf(pid) != null;

  @override
  Future<String?> screen(int pid) async {
    final p = await paneOf(pid);
    if (p == null) return null;
    final r = await _call(['-S', p.socket, 'capture-pane', '-p', '-t', p.pane]);
    if (r == null || r.exitCode != 0) return null;
    return screenText(r.stdout);
  }

  static Future<TmuxResult> _runProcess(String executable, List<String> args) async {
    final r = await Process.run(executable, args, stdoutEncoding: const Utf8Codec(allowMalformed: true))
        .timeout(const Duration(seconds: 15));
    return (exitCode: r.exitCode, stdout: '${r.stdout}');
  }
}
