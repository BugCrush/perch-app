// `perch_host setup`: the host's half of the Perch plugin's setup step. The plugin's
// SessionStart hook (claude_plugin/perch/hooks/perch-setup.sh) downloads the release build
// for this machine into `<state>/releases/<version>/`, checks its SHA-256 and runs this from
// there. It:
//   - leaves a machine alone whose autostart runs a host built from the repo (a developer);
//   - turns autostart on (or moves it) to this build: the Windows scheduled task / macOS
//     LaunchAgent run it at every log on;
//   - starts it now when no host listens on the port, or asks the running host to restart
//     into it once it is idle (no card open, nothing being typed; `switch-when-idle`), or,
//     for a host too old to be asked, leaves the switch to the next log on;
//   - keeps this release and the one before it (rollback), deletes older ones;
//   - marks the release installed, so the plugin does not download it again.
import 'dart:io';

import 'autostart.dart';

/// The autostart title (and Windows task name) for a first release install: `Perch host`,
/// or `PERCH_AUTOSTART_TITLE`; a host with its own state folder (`PERCH_STATE_DIR`, a test
/// or second host) gets `Perch host (test)`, so it never takes over the main host's task.
String releaseAutostartTitle(Map<String, String> env) {
  final own = env['PERCH_AUTOSTART_TITLE'];
  if (own != null && own.trim().isNotEmpty) return own.trim();
  return (env['PERCH_STATE_DIR'] ?? '').isNotEmpty ? '$defaultAutostartTitle (test)' : defaultAutostartTitle;
}

/// Whether [exe] is a release build the plugin installed (`<state>/releases/<version>/…`):
/// only such a host restarts into a newer one by itself.
bool isReleaseBuild(String exe, String stateDir) {
  String norm(String x) => x.replaceAll(r'\', '/').toLowerCase();
  return norm(exe).startsWith('${norm(stateDir)}/releases/');
}

/// Written into `<state>/releases/<version>/` once that release is set up.
const releaseInstalledMarker = 'installed';

enum SetupOutcome { started, switching, atNextLogin, current, developer, failed }

class SetupResult {
  final SetupOutcome outcome;
  final List<String> lines;
  SetupResult(this.outcome, this.lines);
}

class ReleaseSetup {
  final Autostart autostart;

  /// The downloaded host (`<state>/releases/<version>/perch_host[.exe]`).
  final String exe;
  final String version;
  final int defaultPort;
  final Map<String, String> environment;

  /// Whether a host listens on the port.
  final Future<bool> Function(int port) listening;

  /// Asks the host on the port (`/control?action=…`); null when it did not answer OK.
  final Future<String?> Function(int port, String action) control;

  ReleaseSetup({
    required this.autostart,
    required this.exe,
    required this.version,
    required this.listening,
    required this.control,
    this.defaultPort = 8787,
    Map<String, String>? environment,
  }) : environment = environment ?? Platform.environment;

  String get _sep => Platform.pathSeparator;
  String get releasesDir => '${autostart.stateDir}${_sep}releases';
  String get releaseDir => File(exe).parent.path;

  void _markInstalled(String how) {
    try {
      File('$releaseDir$_sep$releaseInstalledMarker').writeAsStringSync('$how\n');
    } catch (_) {}
  }

  /// Deletes releases other than [keep] (one that is running cannot go on Windows; it goes
  /// next time).
  void _prune(Set<String> keep) {
    final d = Directory(releasesDir);
    if (!d.existsSync()) return;
    for (final e in d.listSync()) {
      final name = e.path.split(RegExp(r'[\\/]')).last;
      if (e is! Directory || keep.contains(name) || name.startsWith('.')) continue;
      try {
        e.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  Future<SetupResult> run() async {
    final old = autostart.load();
    if (old != null && old.setup.release == null) {
      _markInstalled('developer');
      return SetupResult(SetupOutcome.developer, [
        'This machine runs Perch from its repo (autostart built from ${old.setup.repo}); '
            'the plugin leaves that host alone. Update it with perch_host autostart update.',
      ]);
    }
    final port = old?.setup.port ?? defaultPort;
    final board = '$releaseDir${_sep}board';
    final setup = AutostartSetup(
      platform: autostart.platform,
      port: port,
      repo: releaseDir,
      dart: '',
      stateDir: autostart.stateDir,
      title: old?.setup.title ?? releaseAutostartTitle(environment),
      env: {
        for (final k in autostartCarriedVariables)
          if ((environment[k] ?? '').isNotEmpty) k: environment[k]!,
      },
      exe: exe,
      commit: 'v$version',
      board: File('$board${_sep}index.html').existsSync() ? board : null,
      release: version,
    );
    final same = old != null && old.setup.release == version && old.setup.exe == exe;
    if (!same) {
      try {
        await autostart.enable(setup);
      } on AutostartError catch (e) {
        return SetupResult(SetupOutcome.failed, ['Could not turn on autostart for Perch $version: ${e.message}']);
      }
    }
    _prune({version, ?old?.setup.release});
    _markInstalled('release');
    final running = await listening(port);
    if (!running) {
      final ok = await autostart.startNow();
      return SetupResult(ok ? SetupOutcome.started : SetupOutcome.atNextLogin, [
        ok
            ? 'Perch host $version installed and started (it also starts at every log on).'
            : 'Perch host $version installed; it starts at the next log on (starting it now failed).',
        'Open /perch in Claude Code to pair your phone.',
      ]);
    }
    if (same) return SetupResult(SetupOutcome.current, ['Perch host $version is installed and running.']);
    final told = await control(port, 'switch-when-idle');
    if (told != null) {
      return SetupResult(SetupOutcome.switching, [
        'Perch host $version installed. The host running now restarts into it as soon as it is idle '
            '(no card open, nothing being typed).',
      ]);
    }
    return SetupResult(SetupOutcome.atNextLogin, [
      'Perch host $version installed. The host running on port $port changes to it at the next log on '
          '(or quit it with Q and it starts again from the new build).',
    ]);
  }
}
