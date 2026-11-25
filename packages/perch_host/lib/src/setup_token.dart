// Adding an account with `claude setup-token` (docs/superpowers/specs/2026-11-15-accounts-
// design.md, experiment results). What Claude Code 2.1.325 does, on Windows:
//
// - It needs a console (with piped stdio it prints nothing). It shows a sign-in link
//   (`https://claude.com/cai/oauth/authorize?…`, wrapped over the console's rows) whose
//   redirect is Anthropic's code page, then waits at "Paste code here if prompted >".
// - It runs `$BROWSER <url>` when BROWSER is set (else the system's opener): a program
//   name that does not exist means no browser opens on the machine.
// - A wrong code shows "OAuth error: That code wasn't accepted. … Press Enter to retry."
//   (Enter starts over with a new link).
// - The right code shows "Your OAuth token (valid for 1 year):", the token
//   (`sk-ant-oat01-…`, wrapped), "Store this token securely…", and exits 500 ms later. So
//   the console must outlive it (`cmd /k`) for the token to be read from the screen.
//
// The hidden console runs only while an account is being added, and is closed after.
import 'dart:async';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

import 'claude_session.dart';
import 'console_typer.dart';
import 'host_accounts.dart' show HostAccounts, oauthTokenVariable;
import 'terminal_window.dart' show shellQuote, terminalCommandLine;
import 'token_vault.dart' show validAccountId;

/// A BROWSER value that is no program: Claude Code then opens nothing on the machine.
const noBrowser = 'perch-no-browser';

final _tokenPattern = RegExp(r'^sk-ant-[A-Za-z0-9_-]{20,}$');

List<String> _rows(String screen) => screen.replaceAll('\r', '').split('\n');

/// The newest sign-in link on [screen]: the row where it starts and the rows it wraps
/// onto (full rows with no spaces), up to the next blank or indented row.
String? signInUrlFrom(String screen) {
  final rows = _rows(screen);
  for (var i = rows.length - 1; i >= 0; i--) {
    final at = rows[i].indexOf('https://');
    if (at < 0 || !rows[i].contains('oauth/authorize')) continue;
    final b = StringBuffer(rows[i].substring(at).trimRight());
    for (var j = i + 1; j < rows.length; j++) {
      final r = rows[j].trimRight();
      if (r.isEmpty || r.startsWith(' ') || r.contains(' ')) break;
      b.write(r);
    }
    final url = b.toString();
    return url.contains(' ') ? null : url;
  }
  return null;
}

/// Whether `setup-token` waits for the code now.
bool waitingForCode(String screen) => screen.contains('Paste code here');

/// The token on [screen]: the rows between "Your OAuth token" and "Store this token",
/// joined, when they look like a token.
String? tokenFrom(String screen) {
  final rows = _rows(screen);
  for (var i = rows.length - 1; i >= 0; i--) {
    if (!rows[i].contains('Your OAuth token')) continue;
    final b = StringBuffer();
    for (var j = i + 1; j < rows.length; j++) {
      if (rows[j].contains('Store this token') || rows[j].contains('Use this token')) break;
      b.write(rows[j].trim());
    }
    final t = b.toString();
    return _tokenPattern.hasMatch(t) ? t : null;
  }
  return null;
}

/// How long the token is valid ("valid for 1 year", "30 days"), or null.
Duration? tokenValidityFrom(String screen) {
  final m = RegExp(r'valid for\s+(\d+)\s+(year|month|week|day|hour)s?', caseSensitive: false).allMatches(screen).lastOrNull;
  if (m == null) return null;
  final n = int.parse(m.group(1)!);
  return switch (m.group(2)!.toLowerCase()) {
    'year' => Duration(days: 365 * n),
    'month' => Duration(days: 30 * n),
    'week' => Duration(days: 7 * n),
    'day' => Duration(days: n),
    _ => Duration(hours: n),
  };
}

/// Whether the screen shows Claude Code refusing the sign-in (a wrong or old code).
bool codeRejected(String screen) => signInError(screen) != null;

/// Claude Code's words for a failed sign-in ("That code wasn't accepted. …"), or null.
String? signInError(String screen) {
  final rows = _rows(screen);
  for (var i = rows.length - 1; i >= 0; i--) {
    final at = rows[i].indexOf('OAuth error:');
    if (at < 0) continue;
    final b = StringBuffer(rows[i].substring(at + 'OAuth error:'.length).trim());
    for (var j = i + 1; j < rows.length; j++) {
      final r = rows[j].trim();
      if (r.isEmpty || r.startsWith('Press Enter')) break;
      b.write(' $r');
    }
    return b.toString();
  }
  return null;
}

/// Claude Code's answer to a code that is not all of it (2.1.326; checked before it is
/// sent): the box is emptied and the same link stays. Through BSD `script` on the Mac the
/// log loses the spaces, so the words are matched without them.
const shortCodeMessage = "That doesn't look like the full code. Copy all of it, including the # in the middle.";

/// How many times [screen] shows [shortCodeMessage] (it stays on screen after a retry).
int shortCodeMessages(String screen) =>
    RegExp(r"doesn.tlooklikethefullcode", caseSensitive: false).allMatches(screen.replaceAll(RegExp(r'\s+'), '')).length;

/// Terminal output made plain: escape sequences dropped, carriage returns as line breaks.
/// Cursor moves along a row ("go to column n", "forward n") become spaces: Claude Code
/// 2.1.326 draws gaps between words that way (seen through BSD `script` on the Mac).
String plainTerminalText(String raw) {
  final s = raw
      .replaceAll(RegExp(r'\x1B\][^\x07\x1B]*(\x07|\x1B\\)'), '') // OSC (titles, links)
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  final out = StringBuffer();
  var column = 0; // of the current row, 0-based
  final csi = RegExp(r'\x1B\[([0-?]*)[ -/]*([@-~])');
  var i = 0;
  for (final m in csi.allMatches(s)) {
    final text = s.substring(i, m.start).replaceAll(RegExp(r'\x1B[@-Z\\-_]'), '');
    out.write(text);
    final nl = text.lastIndexOf('\n');
    column = nl < 0 ? column + text.length : text.length - nl - 1;
    final n = int.tryParse(m.group(1)!) ?? 1;
    if (m.group(2) == 'G' && n - 1 > column) {
      out.write(' ' * (n - 1 - column));
      column = n - 1;
    } else if (m.group(2) == 'C' && n > 0 && n < 1000) {
      out.write(' ' * n);
      column += n;
    }
    i = m.end;
  }
  out.write(s.substring(i).replaceAll(RegExp(r'\x1B[@-Z\\-_]'), ''));
  return out.toString();
}

/// One `claude setup-token` in a console Perch can read and type into.
abstract class SetupTokenConsole {
  Future<void> start();

  /// What it shows now (rows), or null when it cannot be read.
  Future<String?> screen();

  /// Types [text] and Enter.
  Future<bool> type(String text);
  Future<bool> enter();

  /// Ends it and closes its window (the token must not stay on a screen).
  Future<void> close();
}

typedef SetupTokenConsoleFactory = SetupTokenConsole Function({required bool visible});

/// The environment for `setup-token`: Claude Code's own, without session markers or a
/// token; hidden ones open no browser on the machine.
Map<String, String> setupTokenEnvironment(ClaudeLauncher launcher, {required bool visible}) {
  final env = launcher.childEnvironment()..remove(oauthTokenVariable);
  if (!visible) env['BROWSER'] = noBrowser;
  return env;
}

/// Windows: a console window of its own (conhost; hidden unless [visible]) running
/// `cmd /k` so it stays after `setup-token` exits; read and typed into with the console
/// helper, like terminal sessions.
class WindowsSetupTokenConsole implements SetupTokenConsole {
  final ClaudeLauncher launcher;
  final bool visible;
  final TerminalConsole console;
  WindowsSetupTokenConsole({required this.launcher, required this.visible, required this.console});

  int? _cmdPid;

  @override
  Future<void> start() async {
    final env = setupTokenEnvironment(launcher, visible: visible)
      ..['PERCH_SETUP_COMMAND'] =
          'mode con: cols=200 lines=60 & ${terminalCommandLine(launcher.executable, [...launcher.leadingArgs, 'setup-token'])}';
    final hidden = visible ? '' : '-WindowStyle Hidden ';
    final r = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "\$p = Start-Process conhost.exe $hidden-PassThru -ArgumentList 'cmd.exe /k %PERCH_SETUP_COMMAND%'; "
              r"Start-Sleep -Milliseconds 700; "
              r"(Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $p.Id) | Where-Object Name -eq 'cmd.exe' | Select-Object -First 1).ProcessId"
        ],
        environment: env,
        includeParentEnvironment: false);
    final pid = int.tryParse('${r.stdout}'.trim());
    if (pid == null) throw StateError('Could not open a console for claude setup-token.');
    _cmdPid = pid;
  }

  @override
  Future<String?> screen() async => _cmdPid == null ? null : console.screen(_cmdPid!);

  @override
  Future<bool> type(String text) async => _cmdPid != null && await console.type(_cmdPid!, text);

  @override
  Future<bool> enter() async => _cmdPid != null && await console.pressEnter(_cmdPid!);

  @override
  Future<void> close() async {
    final pid = _cmdPid;
    _cmdPid = null;
    if (pid != null) await killProcessTree(pid);
  }
}

/// macOS and Linux: `script` gives `setup-token` a terminal and records what it shows in
/// a log file (owner-only, deleted on close). Hidden: the host runs `script` itself and
/// types into its stdin. Visible (macOS): a Terminal.app window runs it; the owner types.
/// NOT YET CHECKED ON A MAC (docs/mac-parity-checklist.md, Accounts).
class ScriptSetupTokenConsole implements SetupTokenConsole {
  final ClaudeLauncher launcher;
  final bool visible;
  final String runDir;
  ScriptSetupTokenConsole({required this.launcher, required this.visible, required this.runDir});

  Process? _process;
  File? _log;

  List<String> get _claude => [launcher.executable, ...launcher.leadingArgs, 'setup-token'];

  @override
  Future<void> start() async {
    Directory(runDir).createSync(recursive: true);
    if (!Platform.isWindows) await Process.run('chmod', ['700', runDir]);
    final log = File('$runDir/setup-${DateTime.now().microsecondsSinceEpoch}.log')..writeAsStringSync('');
    if (!Platform.isWindows) await Process.run('chmod', ['600', log.path]);
    _log = log;
    final env = setupTokenEnvironment(launcher, visible: visible);
    final wide = 'stty cols 500 rows 60 2>/dev/null; exec ${_claude.map(shellQuote).join(' ')}';
    if (visible && Platform.isMacOS) {
      final command = "script -q -F ${shellQuote(log.path)} /bin/sh -c ${shellQuote(wide)}; exit";
      final r = await Process.run('/usr/bin/osascript',
          ['-e', 'on run argv\n  tell application "Terminal" to do script (item 1 of argv)\nend run', command]);
      if (r.exitCode != 0) throw StateError('Terminal could not open a window: ${'${r.stderr}'.trim()}');
      return;
    }
    final args = Platform.isMacOS
        ? ['-q', '-F', log.path, '/bin/sh', '-c', wide]
        : ['-q', '-f', '-c', wide, log.path];
    _process = await Process.start('script', args, environment: env, includeParentEnvironment: false);
    unawaited(_process!.stdout.drain<void>().catchError((Object _) {}));
    unawaited(_process!.stderr.drain<void>().catchError((Object _) {}));
  }

  @override
  Future<String?> screen() async {
    final log = _log;
    if (log == null) return null;
    try {
      final raw = log.readAsStringSync();
      return plainTerminalText(raw.length > 60000 ? raw.substring(raw.length - 60000) : raw);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> type(String text) async {
    final p = _process;
    if (p == null) return false;
    p.stdin.write('$text\r');
    await p.stdin.flush();
    return true;
  }

  @override
  Future<bool> enter() => type('');

  @override
  Future<void> close() async {
    final p = _process;
    _process = null;
    if (p != null) {
      p.kill();
      await p.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    }
    try {
      _log?.deleteSync();
    } catch (_) {}
    _log = null;
  }
}

/// The platform's setup-token console.
SetupTokenConsoleFactory defaultSetupTokenConsoles(ClaudeLauncher launcher, String stateDir) =>
    ({required bool visible}) => Platform.isWindows
        ? WindowsSetupTokenConsole(
            launcher: launcher, visible: visible, console: WindowsTerminalConsole(stateDir: stateDir))
        : ScriptSetupTokenConsole(launcher: launcher, visible: visible, runDir: '$stateDir/run');

class _Flow {
  final String id;
  String label;
  String? email;
  String? plan;
  SetupTokenConsole? console;
  bool visible = false;
  String state = '';
  int generation = 0;
  Timer? expiry;
  _Flow(this.id, this.label, this.email, this.plan);
}

/// Adding accounts: one flow per new account ([AccountSignIn.flowId] is its id).
class AccountSignIns {
  final HostAccounts accounts;
  final SetupTokenConsoleFactory console;
  final Duration poll;

  /// How long the link may take to show, and the token after the code.
  final Duration urlTimeout;
  final Duration tokenTimeout;

  /// How long a flow may stay open at all (the owner signing in).
  final Duration flowTimeout;
  final DateTime Function() clock;
  final void Function(String line)? log;

  AccountSignIns({
    required this.accounts,
    required this.console,
    this.poll = const Duration(milliseconds: 500),
    this.urlTimeout = const Duration(seconds: 40),
    this.tokenTimeout = const Duration(seconds: 40),
    this.flowTimeout = const Duration(minutes: 15),
    DateTime Function()? clock,
    this.log,
  }) : clock = clock ?? DateTime.now;

  final Map<String, _Flow> _flows = {};
  final _updates = StreamController<AccountSignInUpdate>.broadcast(sync: true);
  bool _disposed = false;

  /// Every step of every flow (the server passes each to the device that asked).
  Stream<AccountSignInUpdate> get updates => _updates.stream;

  void _emit(_Flow f, String state, {String? url, String? message, AccountInfo? account, String? token}) {
    f.state = state;
    if (!_disposed) {
      _updates.add(AccountSignInUpdate(flowId: f.id, state: state, url: url, message: message, account: account, token: token));
    }
  }

  static String _label(String? raw) {
    final l = (raw ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (l.isEmpty) throw ArgumentError('Give the account a name.');
    if (l.length > maxAccountLabelLength) throw ArgumentError('At most $maxAccountLabelLength characters.');
    return l;
  }

  Future<void> handle(AccountSignIn m) async {
    switch (m.action) {
      case AccountSignInActions.start:
        await _start(m, visible: false);
      case AccountSignInActions.atMachine:
        await _start(m, visible: true);
      case AccountSignInActions.code:
        await _code(m);
      case AccountSignInActions.cancel:
        final f = _flows.remove(m.flowId);
        if (f == null) return;
        await _close(f);
        _emit(f, AccountSignInStates.cancelled);
    }
  }

  Future<void> _start(AccountSignIn m, {required bool visible}) async {
    if (!validAccountId(m.flowId) || m.flowId == machineLoginAccountId) throw ArgumentError('Not an account id.');
    final old = _flows[m.flowId];
    final label = old != null && (m.label == null || m.label!.trim().isEmpty) ? old.label : _label(m.label);
    if (old != null) await _close(old);
    final f = old ?? _Flow(m.flowId, label, null, null);
    f
      ..label = label
      ..email = _clean(m.email) ?? f.email
      ..plan = _clean(m.plan) ?? f.plan
      ..visible = visible
      ..generation += 1;
    _flows[f.id] = f;
    f.expiry?.cancel();
    f.expiry = Timer(flowTimeout, () => _fail(f, 'The sign-in took too long. Start again from Accounts.'));
    final c = console(visible: visible);
    f.console = c;
    try {
      await c.start();
    } catch (e) {
      await _fail(f, 'Perch could not run claude setup-token on this machine.');
      return;
    }
    if (visible) {
      log?.call('Account sign-in for ${f.label}: waiting at the machine');
      _emit(f, AccountSignInStates.atMachine,
          message: 'Sign in in the terminal window that opened on the machine; Perch picks the account up from there.');
      unawaited(_watchForToken(f, f.generation, flowTimeout));
      return;
    }
    final url = await _waitFor(f, (s) => signInUrlFrom(s), urlTimeout);
    if (url == null) {
      await _fail(f, 'Claude Code did not show a sign-in link. Try again, or Sign in at the machine.');
      return;
    }
    log?.call('Account sign-in for ${f.label}: link sent to the phone');
    _emit(f, AccountSignInStates.url, url: url);
  }

  static String? _clean(String? s) {
    final t = s?.trim();
    return t == null || t.isEmpty ? null : t;
  }

  Future<void> _code(AccountSignIn m) async {
    final f = _flows[m.flowId];
    final c = f?.console;
    if (f == null || c == null || f.visible) throw StateError('This sign-in is no longer open. Start again.');
    final code = (m.code ?? '').replaceAll(RegExp(r'\s+'), '');
    if (code.isEmpty) throw ArgumentError('Paste the code the sign-in page showed.');
    if (f.state != AccountSignInStates.url) throw StateError('Perch is still busy with the last code.');
    _emit(f, AccountSignInStates.checking);
    final shortBefore = shortCodeMessages(await c.screen() ?? '');
    if (!await c.type(code)) {
      await _fail(f, 'Perch could not type the code into claude setup-token.');
      return;
    }
    final gen = f.generation;
    final outcome = await _waitFor(f, (s) {
      final t = tokenFrom(s);
      if (t != null) return (token: t, screen: s, error: null);
      if (shortCodeMessages(s) > shortBefore) return (token: null, screen: s, error: shortCodeMessage);
      final e = signInError(s);
      return e == null ? null : (token: null, screen: s, error: e);
    }, tokenTimeout);
    if (_flows[f.id] != f || f.generation != gen) return;
    if (outcome == null) {
      await _fail(f, 'Claude Code did not finish the sign-in. Try again, or Sign in at the machine.');
      return;
    }
    if (outcome.token != null) {
      await _finish(f, outcome.token!, outcome.screen);
      return;
    }
    // Not all of the code: Claude Code waits for it again on the same link.
    if (outcome.error == shortCodeMessage) {
      log?.call('Account sign-in for ${f.label}: the code was not complete');
      _emit(f, AccountSignInStates.url, url: signInUrlFrom(outcome.screen), message: shortCodeMessage);
      return;
    }
    // Refused: Enter starts over with a new link.
    log?.call('Account sign-in for ${f.label}: code not accepted');
    final before = signInUrlFrom(outcome.screen);
    await c.enter();
    final url = await _waitFor(f, (s) {
      final u = signInUrlFrom(s);
      return u != null && u != before && waitingForCode(s) ? u : null;
    }, urlTimeout);
    if (url == null) {
      await _fail(f, '${outcome.error} Try again, or Sign in at the machine.');
      return;
    }
    _emit(f, AccountSignInStates.url, url: url, message: '${outcome.error} Use this new link.');
  }

  Future<void> _watchForToken(_Flow f, int gen, Duration timeout) async {
    final r = await _waitFor(f, (s) {
      final t = tokenFrom(s);
      return t == null ? null : (token: t, screen: s);
    }, timeout, generation: gen);
    if (r == null || _flows[f.id] != f || f.generation != gen) return;
    await _finish(f, r.token, r.screen);
  }

  /// Reads the console every [poll] until [find] returns something, or [timeout].
  Future<T?> _waitFor<T>(_Flow f, T? Function(String screen) find, Duration timeout, {int? generation}) async {
    final gen = generation ?? f.generation;
    final end = clockNow().add(timeout);
    while (!_disposed && _flows[f.id] == f && f.generation == gen) {
      final s = await f.console?.screen();
      if (s != null) {
        final v = find(s);
        if (v != null) return v;
      }
      if (clockNow().isAfter(end)) return null;
      await Future<void>.delayed(poll);
    }
    return null;
  }

  /// Wall time for timeouts ([clock] may be fixed in tests).
  DateTime clockNow() => DateTime.now();

  Future<void> _finish(_Flow f, String token, String screen) async {
    final now = clock();
    final validity = tokenValidityFrom(screen) ?? const Duration(days: 365);
    final info = AccountInfo(
      id: f.id,
      label: f.label,
      email: f.email,
      plan: f.plan,
      createdAtMs: now.millisecondsSinceEpoch,
      expiresAtMs: now.add(validity).millisecondsSinceEpoch,
    );
    _flows.remove(f.id);
    await _close(f);
    try {
      await accounts.add(info, token);
    } catch (_) {
      _emit(f, AccountSignInStates.failed, message: 'The sign-in worked, but Perch could not store it on this machine.');
      return;
    }
    log?.call('Account added: ${f.label}');
    _emit(f, AccountSignInStates.done, account: info, token: token);
  }

  Future<void> _fail(_Flow f, String message) async {
    if (_flows[f.id] == f) _flows.remove(f.id);
    await _close(f);
    log?.call('Account sign-in for ${f.label} failed: $message');
    _emit(f, AccountSignInStates.failed, message: message);
  }

  Future<void> _close(_Flow f) async {
    f.expiry?.cancel();
    final c = f.console;
    f.console = null;
    if (c != null) {
      try {
        await c.close();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final f in _flows.values.toList()) {
      await _close(f);
    }
    _flows.clear();
    await _updates.close();
  }
}
