// Starting the Perch host by itself at login (`perch_host autostart enable|disable|status`).
//
// Windows: a per-user scheduled task ("At log on" of this user, no admin rights) opens a
// minimized console window running a launcher batch file kept in the host's state folder.
// macOS: a per-user LaunchAgent (`~/Library/LaunchAgents/dev.perch.host.plist`, RunAtLoad)
// runs a login script that opens a Terminal.app window running a launcher shell script
// (the host must run inside Terminal so the keys it posts carry Terminal's Accessibility
// permission).
//
// Both launchers clear Claude Code's session markers, leave quietly when a host already
// listens on the port, run the host from the repo with the Flutter `dart` that was in use
// when autostart was enabled, stop when the host exits cleanly (Q in its window) and
// start it again after an error, with a back-off and a cap.
//
// What `enable` created is listed in `autostart.json` in the state folder; `disable`
// removes exactly that. A launcher's file name carries a hash of its content: a shell
// reads a running script from disk as it goes, so a launcher that is running is never
// rewritten in place (enabling again writes a new file and deletes the old one).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'claude_session.dart' show ClaudeLauncher;

enum AutostartPlatform { windows, macos }

/// Restarts after an error before the launcher gives up.
const autostartMaxRestarts = 5;

/// Seconds the launcher waits before starting a failed host again.
const autostartBackoffSeconds = 10;

/// A host that ran at least this long before failing starts a new count of restarts.
const autostartHealthySeconds = 600;

const defaultAutostartTitle = 'Perch host';

/// The environment variables `enable` copies into the launcher when they are set (a test
/// host's state folder and stand-ins; the login environment has none of them).
const autostartCarriedVariables = ['PERCH_STATE_DIR', 'PERCH_CLAUDE_BIN', 'CLAUDE_CONFIG_DIR'];

class AutostartError implements Exception {
  final String message;
  AutostartError(this.message);
  @override
  String toString() => message;
}

/// What a launcher runs: everything it needs is recorded here at `enable` time.
class AutostartSetup {
  final AutostartPlatform platform;

  /// The host window's title (and the Windows task's name).
  final String title;
  final int port;

  /// The repository root (holds `packages/perch_host`).
  final String repo;

  /// The `dart` used to run the host (Flutter's `bin\dart.bat` / `bin/dart`).
  final String dart;
  final String stateDir;

  /// Environment variables the launcher sets (see [autostartCarriedVariables]).
  final Map<String, String> env;

  /// The compiled host the launcher runs (in the state folder, built at `enable` or
  /// `update`); null: an older record that ran `dart run` from the repo.
  final String? exe;

  /// The commit [exe] was built from (with `-dirty` when the tree had changes).
  final String? commit;

  /// A copy of the board's web page taken with the build (null: none was built).
  final String? board;

  /// The Perch release this build came from, when the Perch plugin installed it
  /// (`perch_host setup`); null for a host built from a repo.
  final String? release;

  AutostartSetup({
    required this.platform,
    required this.port,
    required this.repo,
    required this.dart,
    required this.stateDir,
    this.title = defaultAutostartTitle,
    this.env = const {},
    this.exe,
    this.commit,
    this.board,
    this.release,
  });

  AutostartSetup withBuild({required String exe, required String? commit, String? board}) => AutostartSetup(
      platform: platform,
      port: port,
      repo: repo,
      dart: dart,
      stateDir: stateDir,
      title: title,
      env: env,
      exe: exe,
      commit: commit,
      board: board,
      release: release);

  String get sep => platform == AutostartPlatform.windows ? r'\' : '/';
  String join(String a, String b) => a.endsWith(sep) ? '$a$b' : '$a$sep$b';

  String get hostDir => join(join(repo, 'packages'), 'perch_host');

  String get taskName => title;

  /// The LaunchAgent's label: `dev.perch.host`, with a suffix for another title
  /// ("Perch host (test)" → `dev.perch.host.test`).
  String get label {
    var rest = title.trim();
    if (rest.toLowerCase().startsWith('perch host')) rest = rest.substring('perch host'.length);
    final slug = rest.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'dev.perch.host' : 'dev.perch.host.$slug';
  }

  Map<String, Object?> toJson() => {
        'platform': platform.name,
        'title': title,
        'port': port,
        'repo': repo,
        'dart': dart,
        'stateDir': stateDir,
        'env': env,
        'exe': ?exe,
        'board': ?board,
        'commit': ?commit,
        'release': ?release,
      };

  factory AutostartSetup.fromJson(Map<String, dynamic> j) => AutostartSetup(
        platform: AutostartPlatform.values.byName(j['platform'] as String),
        title: j['title'] as String? ?? defaultAutostartTitle,
        port: j['port'] as int,
        repo: j['repo'] as String,
        dart: j['dart'] as String,
        stateDir: j['stateDir'] as String,
        env: {...?(j['env'] as Map?)?.cast<String, String>()},
        exe: j['exe'] as String?,
        board: j['board'] as String?,
        commit: j['commit'] as String?,
        release: j['release'] as String?,
      );

  /// What the launcher sets besides [env]: where the repo is (the board's web files) and
  /// which commit the host was built from (the banner compares it with `main`).
  Map<String, String> get launcherEnv => {
        ...env,
        if (exe != null) 'PERCH_REPO': repo,
        if (exe != null && commit != null) 'PERCH_HOST_COMMIT': commit!,
        if (exe != null && board != null) 'PERCH_BOARD_DIR': board!,
      };
}

/// What `enable` installed.
class AutostartRecord {
  final AutostartSetup setup;
  final String launcherPath;
  final String? loginScriptPath;
  final String? plistPath;
  AutostartRecord({required this.setup, required this.launcherPath, this.loginScriptPath, this.plistPath});

  Map<String, Object?> toJson() => {
        'setup': setup.toJson(),
        'launcher': launcherPath,
        if (loginScriptPath != null) 'loginScript': loginScriptPath,
        if (plistPath != null) 'plist': plistPath,
      };

  factory AutostartRecord.fromJson(Map<String, dynamic> j) => AutostartRecord(
        setup: AutostartSetup.fromJson((j['setup'] as Map).cast<String, dynamic>()),
        launcherPath: j['launcher'] as String,
        loginScriptPath: j['loginScript'] as String?,
        plistPath: j['plist'] as String?,
      );
}

// ---------------------------------------------------------------------------------------
// Windows files

/// A value inside a batch file's double quotes: `%` would expand a variable.
String _batchValue(String s) => s.replaceAll('%', '%%');

/// `powershell -EncodedCommand` text for [script]: UTF-16LE in base64, padded with spaces so
/// the base64 has no `=` (a `for /f` command line splits at an unquoted `=`).
String _encodedPowerShell(String script) {
  var s = script;
  while (s.length % 3 != 0) {
    s += ' ';
  }
  final units = Uint16List.fromList(s.codeUnits);
  final bytes = ByteData(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    bytes.setUint16(i * 2, units[i], Endian.little);
  }
  return base64.encode(bytes.buffer.asUint8List());
}

/// A PowerShell command line for [script] (no progress records: the first run of a day
/// may print "Preparing modules for first use").
String _powerShell(String script) => 'powershell.exe -NoProfile -NonInteractive -EncodedCommand '
    "${_encodedPowerShell("\$ProgressPreference = 'SilentlyContinue'; $script")}";

/// The launcher batch file: CRLF line ends; plain ASCII unless a path needs UTF-8.
String windowsLauncherScript(AutostartSetup s) {
  // Prints the time (Unix seconds) when the port is free, `busy` when something listens.
  final check = _powerShell('\$l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, ${s.port}); '
      "try { \$l.Start(); \$l.Stop(); [DateTimeOffset]::Now.ToUnixTimeSeconds() } catch { 'busy' }");
  final now = _powerShell('[DateTimeOffset]::Now.ToUnixTimeSeconds()');
  final exe = s.exe;
  // A compiled host runs from the state folder: whatever the repo's working tree holds
  // (another branch, code that does not compile) cannot stop it.
  final hostDir = _batchValue(exe == null ? s.hostDir : s.stateDir);
  final lines = [
    '@echo off',
    if (!s.isAscii) 'chcp 65001 >nul',
    'rem Perch host autostart launcher, written by perch_host autostart enable.',
    'rem Do not edit: autostart enable writes a new one, autostart disable removes it.',
    'rem Repo: ${s.repo}',
    if (exe == null) 'rem Dart: ${s.dart}' else 'rem Host: ${s.exe} (built from ${s.commit ?? 'an unknown commit'})',
    'rem Port: ${s.port}',
    'setlocal',
    'title ${_batchValue(s.title).replaceAll(RegExp(r'[&|<>^]'), '')}',
    'rem Claude Code session markers: a host that inherits them starts sessions that save no transcript.',
    for (final m in ClaudeLauncher.inheritedSessionMarkers) 'set "$m="',
    for (final e in s.launcherEnv.entries) 'set "${e.key}=${_batchValue(e.value)}"',
    'cd /d "$hostDir" 2>nul',
    'if errorlevel 1 goto nofolder',
    if (exe != null) 'if not exist "${_batchValue(exe)}" goto noexe',
    'set PERCH_TRIES=0',
    ':run',
    'set "PERCH_NOW="',
    "for /f %%s in ('$check') do set \"PERCH_NOW=%%s\"",
    'rem A host already listens on the port: leave it be.',
    'if "%PERCH_NOW%"=="busy" goto running',
    'if not defined PERCH_NOW set PERCH_NOW=0',
    'set PERCH_STARTED=%PERCH_NOW%',
    if (exe == null)
      'call "${_batchValue(s.dart)}" run bin\\perch_host.dart serve --port ${s.port}'
    else
      '"${_batchValue(exe)}" serve --port ${s.port}',
    'set PERCH_CODE=%ERRORLEVEL%',
    'rem Exit code 0: the owner quit with Q (or Ctrl+C).',
    'if "%PERCH_CODE%"=="0" goto done',
    'set "PERCH_NOW="',
    "for /f %%s in ('$now') do set \"PERCH_NOW=%%s\"",
    'if not defined PERCH_NOW set PERCH_NOW=0',
    'set /a PERCH_RAN=PERCH_NOW-PERCH_STARTED',
    'if %PERCH_RAN% GEQ $autostartHealthySeconds set PERCH_TRIES=0',
    'set /a PERCH_TRIES+=1',
    'if %PERCH_TRIES% GTR $autostartMaxRestarts goto giveup',
    'echo.',
    'echo Perch host stopped with exit code %PERCH_CODE%. Starting it again in $autostartBackoffSeconds seconds, '
        'try %PERCH_TRIES% of $autostartMaxRestarts. Close this window to stop it.',
    // The system's timeout (Git Bash's GNU timeout may come first on PATH).
    '"%SystemRoot%\\System32\\timeout.exe" /t $autostartBackoffSeconds /nobreak >nul',
    'goto run',
    ':running',
    'exit /b 0',
    ':giveup',
    'echo.',
    'echo Perch host stopped with an error ${autostartMaxRestarts + 1} times in a row, so it is not started again. '
        'Start it by hand or log in again.',
    'pause',
    'exit /b %PERCH_CODE%',
    ':nofolder',
    'echo Perch host: cannot find the folder "$hostDir". Run perch_host autostart enable again from the repo.',
    'pause',
    'exit /b 1',
    ':noexe',
    'echo Perch host: cannot find the compiled host "${_batchValue(exe ?? '')}". Run perch_host autostart update from the repo.',
    'pause',
    'exit /b 1',
    ':done',
    'exit /b 0',
  ];
  return '${lines.join('\r\n')}\r\n';
}

String _xml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// The task's command line (after `conhost.exe`): `start` opens a minimized console window
/// of its own (conhost, not the default terminal app, so /min applies) titled [title]
/// running the launcher; the first window closes at once.
String windowsTaskArguments(AutostartSetup s, String launcherPath) =>
    'cmd.exe /d /c start "${s.title.replaceAll('"', "'")}" /min /normal conhost.exe cmd.exe /d /c "$launcherPath"';

/// Task Scheduler XML: at log on of [userId], as that user, without elevation.
String windowsTaskXml(AutostartSetup s, {required String userId, required String launcherPath}) => '''
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Starts the Perch host at log on (perch_host autostart enable). Port ${s.port}, repo ${_xml(s.repo)}.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>${_xml(userId)}</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>${_xml(userId)}</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>5</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>%SystemRoot%\\System32\\conhost.exe</Command>
      <Arguments>${_xml(windowsTaskArguments(s, launcherPath))}</Arguments>
    </Exec>
  </Actions>
</Task>
''';

// ---------------------------------------------------------------------------------------
// macOS files

String _q(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// The launcher shell script a Terminal.app window runs.
String macLauncherScript(AutostartSetup s) => '''
#!/bin/sh
# Perch host autostart launcher, written by perch_host autostart enable.
# Do not edit: autostart enable writes a new one, autostart disable removes it.
# Repo: ${s.repo}
# ${s.exe == null ? 'Dart: ${s.dart}' : 'Host: ${s.exe} (built from ${s.commit ?? 'an unknown commit'})'}
# Port: ${s.port}
printf '\\033]0;%s\\007' ${_q(s.title)}
# Claude Code session markers: a host that inherits them starts sessions that save no transcript.
unset ${ClaudeLauncher.inheritedSessionMarkers.join(' ')}
${[for (final e in s.launcherEnv.entries) 'export ${e.key}=${_q(e.value)}\n'].join()}${s.exe == null ? "cd ${_q(s.hostDir)} || { echo 'Perch host: cannot find the folder '${_q(s.hostDir)}'. Run perch_host autostart enable again from the repo.'; exit 1; }" : "cd ${_q(s.stateDir)} || exit 1\n[ -x ${_q(s.exe!)} ] || { echo 'Perch host: cannot find the compiled host '${_q(s.exe!)}'. Run perch_host autostart update from the repo.'; exit 1; }"}
tries=0
while :; do
  # A host already listens on the port: leave it be.
  if /usr/sbin/lsof -nP -iTCP:${s.port} -sTCP:LISTEN >/dev/null 2>&1; then
    echo 'A Perch host already listens on port ${s.port}.'
    exit 0
  fi
  started=\$(date +%s)
  caffeinate -i ${s.exe == null ? '${_q(s.dart)} run bin/perch_host.dart' : _q(s.exe!)} serve --port ${s.port}
  code=\$?
  # Exit code 0: the owner quit with Q (or Ctrl+C).
  [ "\$code" -eq 0 ] && exit 0
  [ \$((\$(date +%s) - started)) -ge $autostartHealthySeconds ] && tries=0
  tries=\$((tries + 1))
  if [ "\$tries" -gt $autostartMaxRestarts ]; then
    echo 'Perch host stopped with an error ${autostartMaxRestarts + 1} times in a row, so it is not started again. Start it by hand or log in again.'
    exit "\$code"
  fi
  echo
  echo "Perch host stopped with exit code \$code. Starting it again in $autostartBackoffSeconds seconds, try \$tries of $autostartMaxRestarts. Close this window to stop it."
  sleep $autostartBackoffSeconds
done
''';

/// The script launchd runs at login: unless a host already listens on the port, a new
/// Terminal.app window runs the launcher (Terminal is not brought to the front).
String macLoginScript(AutostartSetup s, {required String launcherPath}) => '''
#!/bin/sh
# Perch host autostart, run at login by launchd (${s.label}), written by perch_host autostart enable.
/usr/sbin/lsof -nP -iTCP:${s.port} -sTCP:LISTEN >/dev/null 2>&1 && exit 0
exec /usr/bin/osascript -e 'on run argv' -e 'tell application "Terminal" to do script (item 1 of argv)' -e 'end run' ${_q('exec /bin/sh ${_q(launcherPath)}')}
''';

String _plistString(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String macPlist(AutostartSetup s, {required String loginScriptPath}) => '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${_plistString(s.label)}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>${_plistString(loginScriptPath)}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
</dict>
</plist>
''';

// ---------------------------------------------------------------------------------------
// Paths

/// The repository root above [from] (a file or folder inside it): the folder holding
/// `packages/perch_host/pubspec.yaml`.
String? findPerchRepo(String from) {
  var dir = FileSystemEntity.isDirectorySync(from) ? Directory(from) : File(from).parent;
  dir = dir.absolute;
  while (true) {
    final sep = Platform.pathSeparator;
    if (File('${dir.path}${sep}packages${sep}perch_host${sep}pubspec.yaml').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

/// Flutter's `dart` wrapper for the SDK's [executable]
/// (`<flutter>/bin/cache/dart-sdk/bin/dart.exe` → `<flutter>/bin/dart.bat`); [executable]
/// itself when it is not inside Flutter.
String flutterDartWrapper(String executable, AutostartPlatform platform, {bool Function(String)? exists}) {
  final m = RegExp(r'^(.*)[\\/]bin[\\/]cache[\\/]dart-sdk[\\/]bin[\\/]dart(\.exe)?$', caseSensitive: false)
      .firstMatch(executable);
  if (m == null) return executable;
  final windows = platform == AutostartPlatform.windows;
  final wrapper = windows ? '${m.group(1)}\\bin\\dart.bat' : '${m.group(1)}/bin/dart';
  return (exists ?? (p) => File(p).existsSync())(wrapper) ? wrapper : executable;
}

/// The SDK's own `dart` behind Flutter's wrapper ([dart] = `<flutter>/bin/dart.bat` or
/// `<flutter>/bin/dart`), so `dart compile` runs without a batch file in between; [dart]
/// itself otherwise.
String sdkDart(String dart, AutostartPlatform platform, {bool Function(String)? exists}) {
  final m = RegExp(r'^(.*)[\\/]bin[\\/]dart(\.bat)?$', caseSensitive: false).firstMatch(dart);
  if (m == null) return dart;
  final windows = platform == AutostartPlatform.windows;
  final sdk = windows ? '${m.group(1)}\\bin\\cache\\dart-sdk\\bin\\dart.exe' : '${m.group(1)}/bin/cache/dart-sdk/bin/dart';
  return (exists ?? (p) => File(p).existsSync())(sdk) ? sdk : dart;
}

/// A line for the `serve` banner when this host is autostart's compiled host and the
/// repo's `main` has moved past the commit it was built from; null otherwise.
Future<String?> autostartStaleLine(String stateDir,
    {required String runningExe, AutostartRunner? run}) async {
  final r = loadAutostartRecord(stateDir);
  final s = r?.setup;
  if (s == null || s.exe == null || s.commit == null || s.release != null) return null;
  if (s.exe!.toLowerCase() != runningExe.toLowerCase()) return null;
  final go = run ?? _runProcess;
  try {
    final built = s.commit!.replaceFirst('-dirty', '');
    final m = await go('git', ['-C', s.repo, 'rev-parse', 'main']);
    final main = '${m.stdout}'.trim();
    if (m.exitCode != 0 || main.isEmpty || main.startsWith(built)) return null;
    final has = await go('git', ['-C', s.repo, 'merge-base', '--is-ancestor', main, built]);
    if (has.exitCode == 0) return null;
    return 'This host was built from ${s.commit}; main is now at ${main.substring(0, 12)}. '
        'Update it: perch_host autostart update (in the repo), then restart it.';
  } catch (_) {
    return null;
  }
}

/// The record's file in [stateDir].
String autostartRecordPath(String stateDir) => '$stateDir${Platform.pathSeparator}autostart.json';

AutostartRecord? loadAutostartRecord(String stateDir) {
  try {
    final f = File(autostartRecordPath(stateDir));
    if (!f.existsSync()) return null;
    return AutostartRecord.fromJson((jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>());
  } catch (_) {
    return null;
  }
}

/// The `serve` banner's line: null unless autostart is on for this state folder.
String? autostartBannerLine(String stateDir, int port) {
  final r = loadAutostartRecord(stateDir);
  if (r == null) return null;
  return r.setup.port == port ? 'Starts at login: yes' : 'Starts at login: yes (on port ${r.setup.port})';
}

String _fnv(String s) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(s)) {
    h = ((h ^ b) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

typedef AutostartRunner = Future<ProcessResult> Function(String executable, List<String> args);

Future<ProcessResult> _runProcess(String executable, List<String> args) => Process.run(executable, args);

class AutostartStatus {
  final bool enabled;
  final List<String> lines;
  AutostartStatus(this.enabled, this.lines);
}

/// Installs, removes and reports autostart for one state folder.
class Autostart {
  final AutostartPlatform platform;
  final String stateDir;
  final AutostartRunner run;

  /// macOS: `~/Library/LaunchAgents`.
  final String launchAgentsDir;

  /// Windows: `DOMAIN\user`, the user whose log on starts the task.
  final String userId;

  Autostart({
    required this.platform,
    required this.stateDir,
    AutostartRunner? run,
    String? launchAgentsDir,
    String? userId,
  })  : run = run ?? _runProcess,
        launchAgentsDir = launchAgentsDir ?? '${Platform.environment['HOME'] ?? '.'}/Library/LaunchAgents',
        userId = userId ?? '${Platform.environment['USERDOMAIN'] ?? ''}\\${Platform.environment['USERNAME'] ?? ''}';

  String get _sep => platform == AutostartPlatform.windows ? r'\' : '/';
  String get _dir => '$stateDir${_sep}autostart';

  AutostartRecord? load() => loadAutostartRecord(stateDir);

  void _deleteFile(String? path) {
    if (path == null) return;
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  void _deleteDirIfEmpty() {
    try {
      final d = Directory(_dir);
      if (d.existsSync() && d.listSync().isEmpty) d.deleteSync();
    } catch (_) {}
  }

  /// Where compiled hosts are kept (not `bin`: the Mac helper lives there).
  String get buildDir => '$stateDir${_sep}host';

  /// Compiles the host from [repo] with `dart compile exe` into [buildDir]: first under a
  /// temporary name, then renamed, so a failed build leaves the host in use untouched.
  /// Throws [AutostartError] when the code does not compile.
  Future<({String exe, String? commit, String? branch})> buildHost(
      {required String repo, required String dart, DateTime? now}) async {
    final setupSep = _sep;
    final hostDir = '$repo${setupSep}packages${setupSep}perch_host';
    String? out(ProcessResult r) => r.exitCode == 0 && '${r.stdout}'.trim().isNotEmpty ? '${r.stdout}'.trim() : null;
    final head = out(await run('git', ['-C', repo, 'rev-parse', 'HEAD']));
    // Only the Dart packages count: Flutter rewrites the app's plugin registrants on every pub get.
    final dirty = (out(await run('git', ['-C', repo, 'status', '--porcelain', '--untracked-files=no', '--', 'packages'])) ?? '').isNotEmpty;
    final branch = out(await run('git', ['-C', repo, 'rev-parse', '--abbrev-ref', 'HEAD']));
    final commit = head == null ? null : '${head.substring(0, head.length < 12 ? head.length : 12)}${dirty ? '-dirty' : ''}';
    final t = (now ?? DateTime.now()).toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
    final ext = platform == AutostartPlatform.windows ? '.exe' : '';
    Directory(buildDir).createSync(recursive: true);
    final tmp = '$buildDir${_sep}perch_host-building$ext';
    _deleteFile(tmp);
    final r = await run(sdkDart(dart, platform), [
      'compile',
      'exe',
      '$hostDir${setupSep}bin${setupSep}perch_host.dart',
      '-o',
      tmp,
    ]);
    if (r.exitCode != 0 || !File(tmp).existsSync()) {
      _deleteFile(tmp);
      final why = '${r.stdout}\n${r.stderr}'.trim().split('\n').where((l) => l.trim().isNotEmpty).take(12).join('\n');
      throw AutostartError('The host did not compile, so the host in use stays as it is:\n$why');
    }
    final exe = '$buildDir${_sep}perch_host-${commit ?? 'unknown'}-$stamp$ext';
    File(tmp).renameSync(exe);
    return (exe: exe, commit: commit, branch: branch);
  }

  /// Deletes compiled hosts other than [keep] (the new one and the one before it). One
  /// that is running cannot be deleted on Windows; it goes next time.
  void pruneBuilds(Set<String> keep) {
    final d = Directory(buildDir);
    if (!d.existsSync()) return;
    final kept = {for (final k in keep) k.toLowerCase()};
    for (final f in d.listSync()) {
      final name = f.path.split(RegExp(r'[\\/]')).last;
      final ours = (f is File && name.startsWith('perch_host-')) || (f is Directory && name.startsWith('board-'));
      if (!ours || kept.contains(f.path.toLowerCase())) continue;
      try {
        f.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// Copies the board's built web page from [repo] (`apps/perch_app/build/web`) next to
  /// the compiled host, so the page does not change with the working tree either. Null
  /// when it has not been built.
  String? copyBoard(String repo, {required String stamp}) {
    final sep = _sep;
    final from = Directory('$repo${sep}apps${sep}perch_app${sep}build${sep}web');
    if (!File('${from.path}${sep}index.html').existsSync()) return null;
    final to = '$buildDir${sep}board-$stamp';
    void copy(Directory a, String b) {
      Directory(b).createSync(recursive: true);
      for (final e in a.listSync()) {
        final name = e.path.split(RegExp(r'[\\/]')).last;
        if (e is Directory) {
          copy(e, '$b$sep$name');
        } else if (e is File) {
          e.copySync('$b$sep$name');
        }
      }
    }

    copy(from, to);
    return to;
  }

  /// Installs (or reinstalls with new paths) autostart for [s]; returns the lines to print.
  Future<List<String>> enable(AutostartSetup s, {bool dryRun = false}) async {
    final windows = platform == AutostartPlatform.windows;
    final launcherText = windows ? windowsLauncherScript(s) : macLauncherScript(s);
    final launcherPath = '$_dir${_sep}perch-host-${_fnv(launcherText)}.${windows ? 'cmd' : 'sh'}';
    final old = load();
    if (windows) {
      final xmlPath = '$_dir${_sep}task.xml';
      final xml = windowsTaskXml(s, userId: userId, launcherPath: launcherPath);
      final create = ['/Create', '/TN', s.taskName, '/XML', xmlPath, '/F'];
      if (dryRun) {
        return [
          'Would write $launcherPath:',
          launcherText.replaceAll('\r\n', '\n'),
          'Would register the scheduled task "${s.taskName}" for $userId from this XML:',
          xml,
          'Would run: schtasks /Create /TN "${s.taskName}" /XML "$xmlPath" /F',
          'Would record it in ${autostartRecordPath(stateDir)}.',
        ];
      }
      if (old != null && old.setup.taskName != s.taskName) {
        await run('schtasks', ['/Delete', '/TN', old.setup.taskName, '/F']);
      }
      Directory(_dir).createSync(recursive: true);
      File(launcherPath).writeAsStringSync(launcherText, encoding: s.isAscii ? ascii : utf8);
      final units = '﻿$xml'.codeUnits;
      final bytes = ByteData(units.length * 2);
      for (var i = 0; i < units.length; i++) {
        bytes.setUint16(i * 2, units[i], Endian.little);
      }
      File(xmlPath).writeAsBytesSync(bytes.buffer.asUint8List());
      final r = await run('schtasks', create);
      _deleteFile(xmlPath);
      if (r.exitCode != 0) {
        if (old?.launcherPath != launcherPath) _deleteFile(launcherPath);
        _deleteDirIfEmpty();
        throw AutostartError('Task Scheduler refused the task: ${'${r.stderr}'.trim()}${'${r.stdout}'.trim()}');
      }
      if (old != null && old.launcherPath != launcherPath) _deleteFile(old.launcherPath);
      _save(AutostartRecord(setup: s, launcherPath: launcherPath));
      return [
        'Autostart is on: at each log on the Perch host starts in a minimized window titled "${s.title}" '
            '(scheduled task "${s.taskName}"), port ${s.port}.',
        'Repo: ${s.repo}',
        s.exe == null ? 'Dart: ${s.dart}' : 'Host: ${s.exe} (built from ${s.commit ?? 'an unknown commit'}; changes in the repo do not affect it until autostart update)',
        'It starts again after an error (up to $autostartMaxRestarts times in a row); Q in its window stops it until the next log on.',
        'If a host already listens on port ${s.port} at log on, it leaves that one be.',
        'Turn it off: perch_host autostart disable',
      ];
    }
    // macOS
    final loginPath = '$_dir${_sep}login.sh';
    final loginText = macLoginScript(s, launcherPath: launcherPath);
    final plistPath = '$launchAgentsDir/${s.label}.plist';
    final plistText = macPlist(s, loginScriptPath: loginPath);
    if (dryRun) {
      return [
        'Would write $launcherPath:',
        launcherText,
        'Would write $loginPath:',
        loginText,
        'Would write $plistPath:',
        plistText,
        'Would record it in ${autostartRecordPath(stateDir)}.',
      ];
    }
    if (old != null && old.plistPath != null && old.plistPath != plistPath) {
      await _bootout(old.setup.label);
      _deleteFile(old.plistPath);
    }
    Directory(_dir).createSync(recursive: true);
    File(launcherPath).writeAsStringSync(launcherText);
    File(loginPath).writeAsStringSync(loginText);
    Directory(launchAgentsDir).createSync(recursive: true);
    File(plistPath).writeAsStringSync(plistText);
    if (old != null && old.launcherPath != launcherPath) _deleteFile(old.launcherPath);
    _save(AutostartRecord(setup: s, launcherPath: launcherPath, loginScriptPath: loginPath, plistPath: plistPath));
    return [
      'Autostart is on: from the next login the Perch host starts in a Terminal window titled "${s.title}" '
          '(LaunchAgent ${s.label}), port ${s.port}.',
      'Repo: ${s.repo}',
      s.exe == null ? 'Dart: ${s.dart}' : 'Host: ${s.exe} (built from ${s.commit ?? 'an unknown commit'}; changes in the repo do not affect it until autostart update)',
      'It starts again after an error (up to $autostartMaxRestarts times in a row); Q in its window stops it until the next login.',
      'If a host already listens on port ${s.port} at login, it leaves that one be.',
      'Turn it off: perch_host autostart disable',
    ];
  }

  void _save(AutostartRecord r) {
    Directory(stateDir).createSync(recursive: true);
    File(autostartRecordPath(stateDir)).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(r.toJson()));
  }

  /// Starts the host through autostart now (as a log on would): Windows runs the task,
  /// macOS loads the LaunchAgent (once) and starts it. The launcher leaves quietly when a
  /// host already listens on the port. False when nothing is recorded or it failed.
  Future<bool> startNow() async {
    final r = load();
    if (r == null) return false;
    try {
      if (r.setup.platform == AutostartPlatform.windows) {
        return (await run('schtasks', ['/Run', '/TN', r.setup.taskName])).exitCode == 0;
      }
      final uid = '${(await run('id', ['-u'])).stdout}'.trim();
      if (uid.isEmpty) return false;
      if (r.plistPath != null) await run('launchctl', ['bootstrap', 'gui/$uid', r.plistPath!]);
      return (await run('launchctl', ['kickstart', 'gui/$uid/${r.setup.label}'])).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _bootout(String label) async {
    try {
      final id = await run('id', ['-u']);
      final uid = '${id.stdout}'.trim();
      if (uid.isNotEmpty) await run('launchctl', ['bootout', 'gui/$uid/$label']);
    } catch (_) {}
  }

  /// Removes exactly what [enable] created. A host running now keeps running.
  Future<List<String>> disable({bool dryRun = false}) async {
    final r = load();
    if (r == null) return ['Autostart is not on (nothing recorded in ${autostartRecordPath(stateDir)}).'];
    final windows = r.setup.platform == AutostartPlatform.windows;
    final files = [r.launcherPath, ?r.loginScriptPath, ?r.plistPath, autostartRecordPath(stateDir)];
    if (dryRun) {
      return [
        if (windows) 'Would run: schtasks /Delete /TN "${r.setup.taskName}" /F',
        if (!windows) 'Would run: launchctl bootout gui/<uid>/${r.setup.label}',
        for (final f in files) 'Would delete $f',
        if (r.setup.exe != null) 'Would delete the compiled hosts in $buildDir',
      ];
    }
    var note = '';
    if (windows) {
      final d = await run('schtasks', ['/Delete', '/TN', r.setup.taskName, '/F']);
      if (d.exitCode != 0) note = ' (the scheduled task was already gone)';
    } else {
      await _bootout(r.setup.label);
    }
    for (final f in files) {
      _deleteFile(f);
    }
    _deleteDirIfEmpty();
    // The compiled hosts too (one still running stays until it exits).
    pruneBuilds(const {});
    try {
      final d = Directory(buildDir);
      if (d.existsSync() && d.listSync().isEmpty) d.deleteSync();
    } catch (_) {}
    return [
      windows
          ? 'Autostart is off: removed the scheduled task "${r.setup.taskName}"$note and the launcher.'
          : 'Autostart is off: removed the LaunchAgent ${r.setup.label} and the launcher.',
      'A host running now keeps running.',
    ];
  }

  Future<AutostartStatus> status() async {
    final r = load();
    if (r == null) return AutostartStatus(false, ['Autostart: off (turn it on: perch_host autostart enable)']);
    final s = r.setup;
    final windows = s.platform == AutostartPlatform.windows;
    bool exists(String p) => File(p).existsSync() || Directory(p).existsSync();
    final problems = <String>[];
    if (windows) {
      final q = await run('schtasks', ['/Query', '/TN', s.taskName]);
      if (q.exitCode != 0) problems.add('the task is missing');
    } else if (r.plistPath == null || !File(r.plistPath!).existsSync()) {
      problems.add('the LaunchAgent file is missing');
    }
    if (!File(r.launcherPath).existsSync()) problems.add('the launcher is missing');
    if (s.exe != null && !File(s.exe!).existsSync()) problems.add('the compiled host is missing');
    final enabled = problems.isEmpty;
    final moved = s.release != null
        ? [
            'Release: Perch ${s.release} (installed by the Perch plugin; it updates with the plugin)',
            'Host: ${s.exe}',
          ]
        : [
      if (!exists(s.hostDir)) 'Repo: ${s.repo} (not found: run perch_host autostart enable again from the repo)'
      else 'Repo: ${s.repo}',
      if (s.exe != null) ...[
        'Host: ${s.exe}',
        'Built from: ${s.commit ?? 'an unknown commit'} (update it after pulling: perch_host autostart update)',
      ] else if (!exists(s.dart))
        'Dart: ${s.dart} (not found: run perch_host autostart enable again with the dart now in use)'
      else
        'Dart: ${s.dart} (runs the repo\'s working tree: run perch_host autostart update to use a compiled host)',
    ];
    return AutostartStatus(enabled, [
      enabled
          ? 'Autostart: on, port ${s.port}, window "${s.title}" '
              '(${windows ? 'scheduled task "${s.taskName}"' : 'LaunchAgent ${s.label}'})'
          : 'Autostart: off: ${problems.join(', ')} (run perch_host autostart enable again)',
      ...moved,
      'Launcher: ${r.launcherPath}',
      if (r.plistPath != null) 'LaunchAgent: ${r.plistPath}',
      'State folder: ${s.stateDir}',
      for (final e in s.env.entries) 'Sets ${e.key}=${e.value}',
    ]);
  }
}

extension on AutostartSetup {
  bool get isAscii =>
      [repo, dart, title, stateDir, ?exe, ...env.values].every((v) => v.codeUnits.every((c) => c < 128));
}
