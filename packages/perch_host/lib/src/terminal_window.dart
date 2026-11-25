// Opens a visible terminal window on the machine running interactive `claude`.
import 'dart:io';

import 'state_dir.dart';

/// What to run in a new terminal window.
class TerminalLaunch {
  final String cwd;
  final String executable;
  final List<String> args;

  /// The complete environment for the window (inherited session markers already removed).
  final Map<String, String> environment;

  /// The window's title.
  final String title;

  /// Keep the window open after Claude Code exits (`cmd /k`); false closes it (`cmd /c`).
  final bool keepOpen;

  const TerminalLaunch(
      {required this.cwd,
      required this.executable,
      required this.args,
      required this.environment,
      this.title = 'Perch session',
      this.keepOpen = true});
}

typedef TerminalWindowOpener = Future<void> Function(TerminalLaunch launch);

/// A cmd.exe command line for [executable] with [args]. Arguments with spaces are quoted;
/// double quotes become single quotes and `%` is dropped, so nothing in a session name can
/// end the quoting or expand a variable.
String terminalCommandLine(String executable, List<String> args) {
  String quote(String a) {
    final clean = a.replaceAll('"', "'").replaceAll('%', '').replaceAll(RegExp(r'[\r\n]+'), ' ');
    return clean.isEmpty || clean.contains(RegExp(r'[\s&|<>^()]')) ? '"$clean"' : clean;
  }

  return [quote(executable), ...args.map(quote)].join(' ');
}

/// Windows: `cmd /c start "<title>" cmd /k <claude …>`, which opens a window in
/// whichever terminal Windows uses by default. The command line travels in an environment
/// variable so Dart's argument quoting cannot mangle it. `/k` keeps the window open after
/// Claude Code exits; `/c` (when [TerminalLaunch.keepOpen] is false) closes it.
Future<void> openWindowsTerminalWindow(TerminalLaunch l) async {
  await Process.start(
    'cmd.exe',
    ['/c', 'start', l.title, 'cmd', l.keepOpen ? '/k' : '/c', '%PERCH_CLAUDE_COMMAND%'],
    workingDirectory: l.cwd,
    environment: {...l.environment, 'PERCH_CLAUDE_COMMAND': terminalCommandLine(l.executable, l.args)},
    includeParentEnvironment: false,
    mode: ProcessStartMode.detached,
  );
}

/// Opens a visible terminal window running interactive `claude`: a console window on
/// Windows, a Terminal.app window on macOS. Elsewhere there is none (the caller runs the
/// session hidden).
Future<void> openTerminalWindow(TerminalLaunch l) =>
    Platform.isWindows ? openWindowsTerminalWindow(l) : openTerminalAppWindow(l);

/// A POSIX shell word for [s].
String shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// The shell command a new Terminal.app window runs: into the folder, then `claude` with its
/// arguments. Environment variables the host sets for Claude Code (not the inherited
/// session markers, which a Terminal window never has) are passed with `env`.
String terminalAppCommand(TerminalLaunch l, {Map<String, String> extraEnv = const {}, String? sourceFile}) {
  final env = [for (final e in extraEnv.entries) '${e.key}=${shellQuote(e.value)}'];
  final run = [if (env.isNotEmpty) ...['env', ...env], shellQuote(l.executable), ...l.args.map(shellQuote)].join(' ');
  // An account's token comes from a file the shell reads and deletes: typed on the command
  // line it would show in the window and the shell's history.
  final source = sourceFile == null ? '' : '. ${shellQuote(sourceFile)} && ';
  // keepOpen false: the shell ends with Claude Code, so the window closes (as `cmd /c`).
  return 'cd ${shellQuote(l.cwd)} && $source$run${l.keepOpen ? '' : '; exit'}';
}

/// The variable an account's token travels in.
const _tokenVariable = 'CLAUDE_CODE_OAUTH_TOKEN';

/// Writes a shell file (owner-only) in [runDir] that exports [token] and deletes itself.
Future<String> writeTokenSourceFile(String token, String runDir) async {
  Directory(runDir).createSync(recursive: true);
  await Process.run('chmod', ['700', runDir]);
  final f = File('$runDir/account-${DateTime.now().microsecondsSinceEpoch}.sh')..writeAsStringSync('');
  await Process.run('chmod', ['600', f.path]);
  f.writeAsStringSync('export $_tokenVariable=${shellQuote(token)}\nrm -f -- ${shellQuote(f.path)}\n', flush: true);
  return f.path;
}

/// AppleScript that opens a Terminal.app window running `item 1` (without activating
/// Terminal: the owner may be using another app).
const terminalAppOpenScript = r'''
on run argv
  tell application "Terminal" to do script (item 1 of argv)
end run
''';

/// macOS: a new Terminal.app window in [TerminalLaunch.cwd] running `claude`. The window
/// stays open after Claude Code exits (the shell remains), as `cmd /k` on Windows.
Future<void> openTerminalAppWindow(TerminalLaunch l) async {
  if (!Platform.isMacOS) throw UnsupportedError('No terminal window on this platform.');
  // Only what the host itself adds for Claude Code; the window's shell has the owner's own
  // environment.
  final extra = {
    for (final k in const ['PERCH_CLAUDE_BIN', 'CLAUDE_CONFIG_DIR'])
      if (l.environment[k] != null && l.environment[k] != Platform.environment[k]) k: l.environment[k]!,
  };
  final token = l.environment[_tokenVariable];
  final source = token != null && token != Platform.environment[_tokenVariable]
      ? await writeTokenSourceFile(token, '${stateDirectory()}/run')
      : null;
  final r = await Process.run(
      '/usr/bin/osascript', ['-e', terminalAppOpenScript, terminalAppCommand(l, extraEnv: extra, sourceFile: source)]);
  if (r.exitCode != 0) throw StateError('Terminal could not open a window: ${'${r.stderr}'.trim()}');
}

/// macOS: closes the Terminal.app windows on [tty] whose shell has ended ("Process
/// completed"; Terminal keeps them open by default). Elsewhere nothing.
Future<void> closeFinishedTerminalWindow(String tty) async {
  if (!Platform.isMacOS) return;
  const script = r'''
on run argv
  tell application "Terminal"
    repeat with w in (every window whose tty of selected tab is (item 1 of argv))
      if busy of selected tab of w is false then close w
    end repeat
  end tell
end run
''';
  try {
    await Process.run('/usr/bin/osascript', ['-e', script, tty]);
  } catch (_) {}
}

/// The terminal device of process [pid] (`/dev/ttys004`), or null (Windows, or none).
Future<String?> ttyOf(int pid) async {
  if (Platform.isWindows) return null;
  try {
    final r = await Process.run('ps', ['-o', 'tty=', '-p', '$pid']);
    final t = '${r.stdout}'.trim();
    return t.startsWith('tty') ? '/dev/$t' : null;
  } catch (_) {
    return null;
  }
}
