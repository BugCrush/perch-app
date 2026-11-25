// Perch host service.
//   perch_host serve [--port 8787] [--bind 0.0.0.0] [--name <machine name>] [--log-hooks]
//   perch_host pair [--port <port>] [--name <machine name>]
//   perch_host forget-devices [--port <port>]
//   perch_host devices [--port <port>] | devices allow <id> [--watch] | deny <id> | full <id> | watch <id> | rename <id> <name> | remove <id>
//   perch_host relay set <url> | relay clear | relay show | relay usage | relay invite <code> | relay invite --clear [--port <port>]
//   perch_host name set <name> | name clear | name show [--port <port>]
//   perch_host stop-remote [--port 8787]
//   perch_host hooks install [--yes] | uninstall | status [--port 8787]
//   perch_host commands install|uninstall|status
//   perch_host selftest on|off|run|status [--port 8787]
//   perch_host setup [--port 8787]   (run by the Perch plugin from a downloaded release)
//   perch_host autostart enable [--port 8787] [--title "Perch host"] [--dart <path>] [--dry-run] | update | disable [--dry-run] | status
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:perch_host/src/autostart.dart';
import 'package:perch_host/src/board_page.dart';
import 'package:perch_host/src/claude_session.dart';
import 'package:perch_host/src/console_typer.dart';
import 'package:perch_host/src/approval_dialog.dart';
import 'package:perch_host/src/devices_cli.dart';
import 'package:perch_host/src/commands_install.dart';
import 'package:perch_host/src/compatibility.dart';
import 'package:perch_host/src/external_sessions.dart';
import 'package:perch_host/src/host_board.dart';
import 'package:perch_host/src/host_board_relay.dart';
import 'package:perch_host/src/hooks.dart';
import 'package:perch_host/src/host_accounts.dart';
import 'package:perch_host/src/host_notice.dart';
import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/inbox.dart';
import 'package:perch_host/src/input_idle.dart';
import 'package:perch_host/src/push_notifier.dart';
import 'package:perch_host/src/relay_client.dart';
import 'package:perch_host/src/release_setup.dart';
import 'package:perch_host/src/mac_helper.dart';
import 'package:perch_host/src/release_notes.dart';
import 'package:perch_host/src/self_test.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/setup_token.dart';
import 'package:perch_host/src/state_dir.dart';
import 'package:perch_host/src/task_board.dart';
import 'package:perch_host/src/token_vault.dart';
import 'package:perch_host/src/transcript.dart' show claudeConfigDir;
import 'package:perch_host/src/version_store.dart';
import 'package:perch_protocol/perch_protocol.dart'
    show Compatibility, CompatibilityStatus, WorkingKinds, modelTableOf, seenWorkingLine, untestedLine;

const minimumClaudeVersion = '2.1.322';

String _now() => DateTime.now().toIso8601String().substring(11, 23);

HostNotice? notice;

/// Calls the running host's loopback control endpoint; null when it is not reachable.
Future<String?> control(int port, String action, {Duration? timeout}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  if (timeout != null) client.idleTimeout = timeout;
  try {
    final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/control?action=$action'))
      ..headers.set(PerchServer.controlHeader, '1');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return res.statusCode == 200 ? body : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Like [control], with the status: a refusal's text reaches the owner.
Future<({int status, String body})?> controlCall(int port, String query) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/control?$query'))
      ..headers.set(PerchServer.controlHeader, '1');
    final res = await req.close();
    return (status: res.statusCode, body: await res.transform(utf8.decoder).join());
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// When the Perch plugin carries the hooks and settings.json still holds Perch's older ones,
/// every event would reach the host twice: offers to remove the old ones (asks on a
/// terminal unless [yes]; without a terminal it only says how).
Future<void> offerSettingsHookRemoval(HookInstaller installer, int port, {required bool yes}) async {
  if (installer.pluginHookFiles().isEmpty || !installer.settingsHasPerchHooks) return;
  stdout.writeln("Perch's older hooks are also in ${installer.settingsFile.path}: with the plugin, every event "
      'would reach Perch twice.');
  var remove = yes;
  if (!yes && stdin.hasTerminal) {
    stdout.write('Remove them from settings.json now? [Y/n] ');
    final answer = (stdin.readLineSync() ?? '').trim().toLowerCase();
    remove = answer.isEmpty || answer.startsWith('y');
  }
  if (!remove) {
    stdout.writeln('Left as they are. Remove them later: perch_host hooks uninstall (or hooks install --yes).');
    return;
  }
  installer.uninstall();
  stdout.writeln('Removed them (the previous file is saved as ${installer.backupFile.path}).');
  if (await control(port, 'reload') != null) stdout.writeln('The running host on port $port was told.');
}

/// Whether something listens on the loopback [port].
Future<bool> portListening(int port) async {
  try {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 1));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<String?> claudeVersion(ClaudeLauncher launcher) async {
  try {
    final r = await launcher.run(['--version']).timeout(const Duration(seconds: 20));
    final m = RegExp(r'(\d+\.\d+\.\d+)').firstMatch('${r.stdout}');
    return m?.group(1);
  } catch (_) {
    return null;
  }
}

/// Compiles the host for autostart (a few tens of seconds) and returns [setup] running it.
Future<AutostartSetup> _buildFor(Autostart autostart, AutostartSetup setup) async {
  stdout.writeln('Compiling the host from ${setup.repo} (dart compile exe)…');
  final b = await autostart.buildHost(repo: setup.repo, dart: setup.dart);
  if (b.branch != null && b.branch != 'main') {
    stdout.writeln('Note: built from branch ${b.branch}, not main.');
  }
  if (b.commit?.endsWith('-dirty') ?? false) stdout.writeln('Note: the working tree had uncommitted changes.');
  final name = b.exe.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.exe$'), '').replaceFirst('perch_host-', '');
  final board = autostart.copyBoard(setup.repo, stamp: name);
  stdout.writeln(board == null
      ? 'The board page is not built: in apps/perch_app run flutter build web --no-web-resources-cdn, then autostart update.'
      : 'Board page: copied from apps/perch_app/build/web.');
  return setup.withBuild(exe: b.exe, commit: b.commit, board: board);
}

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addCommand(
        'serve',
        ArgParser()
          ..addOption('port', defaultsTo: '8787')
          ..addOption('bind', defaultsTo: '0.0.0.0')
          ..addOption('name', help: 'Machine name for this run (default: perch_host name set, else the computer name)')
          ..addFlag('log-hooks', negatable: false, help: 'Print each hook and card with the time it arrived'))
    ..addCommand('stop-remote', ArgParser()..addOption('port', defaultsTo: '8787'))
    ..addCommand(
        'pair',
        ArgParser()
          ..addOption('port', help: 'Port of the host (default: the last serve)')
          ..addOption('name', help: 'Machine name (default: the last serve)'))
    ..addCommand('forget-devices', ArgParser()..addOption('port', help: 'Port of a running host to tell'))
    ..addCommand(
        'devices',
        ArgParser()
          ..addOption('port', help: 'Port of the running host (default: the last serve)')
          ..addFlag('watch', negatable: false, help: 'With allow: watch only'))
    ..addCommand(
        'relay',
        ArgParser()
          ..addOption('port', help: 'Port of a running host to tell')
          ..addCommand('set')
          ..addCommand('clear')
          ..addCommand('show')
          ..addCommand('usage')
          ..addCommand('invite', ArgParser()..addFlag('clear', negatable: false, help: 'Forget the invite code')))
    ..addCommand(
        'name',
        ArgParser()
          ..addOption('port', help: 'Port of a running host to tell')
          ..addCommand('set', ArgParser()..addOption('port'))
          ..addCommand('clear', ArgParser()..addOption('port'))
          ..addCommand('show', ArgParser()..addOption('port')))
    ..addCommand(
        'hooks',
        ArgParser()
          ..addOption('port', defaultsTo: '8787')
          ..addCommand(
              'install',
              ArgParser()
                ..addFlag('yes',
                    abbr: 'y', negatable: false, help: 'Remove older Perch hooks from settings.json without asking'))
          ..addCommand('uninstall')
          ..addCommand('status'))
    ..addCommand(
        'commands',
        ArgParser()
          ..addOption('port', defaultsTo: '8787')
          ..addCommand('install')
          ..addCommand('uninstall')
          ..addCommand('status'))
    ..addCommand('setup', ArgParser()..addOption('port', help: 'The port for a first install (default: 8787)'))
    ..addCommand(
        'selftest',
        ArgParser()
          ..addOption('port', help: 'Port of a running host (default: the last serve)')
          ..addCommand('on')
          ..addCommand('off')
          ..addCommand('run')
          ..addCommand('status'))
    ..addCommand(
        'autostart',
        ArgParser()
          ..addCommand(
              'enable',
              ArgParser()
                ..addOption('port', defaultsTo: '8787')
                ..addOption('title',
                    defaultsTo: defaultAutostartTitle, help: 'Window title (and the Windows task name; another one for a test host)')
                ..addOption('dart', help: 'The dart that runs the host (default: the Flutter dart running this command)')
                ..addFlag('dry-run', negatable: false, help: 'Print what would be installed; change nothing'))
          ..addCommand('update', ArgParser()..addOption('dart', help: 'The dart that compiles the host (default: the one recorded)'))
          ..addCommand('disable', ArgParser()..addFlag('dry-run', negatable: false))
          ..addCommand('status'))
    ..addFlag('help', abbr: 'h', negatable: false);
  const usage = 'Usage: perch_host serve [--port 8787] [--bind 0.0.0.0] [--name <machine name>] [--log-hooks]\n'
      '       perch_host pair [--port <port>] [--name <machine name>]\n'
      '       perch_host forget-devices [--port <port>]\n'
      '       $devicesUsage\n'
      '       perch_host relay set <url> | relay clear | relay show | relay usage | relay invite <code> | relay invite --clear [--port <port>]\n'
      '       perch_host name set <name> | name clear | name show [--port <port>]\n'
      '       perch_host stop-remote [--port 8787]\n'
      '       perch_host hooks install [--yes] | uninstall | status [--port 8787]\n'
      '       perch_host commands install|uninstall|status\n'
      '       perch_host selftest on|off|run|status [--port <port>]\n'
      '       perch_host setup [--port 8787]   (the Perch plugin runs it from a downloaded release)\n'
      '       perch_host autostart enable [--port 8787] [--dry-run] | autostart update | autostart disable | autostart status';
  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(usage);
    exit(64);
  }
  final cmd = args.command;
  if (cmd == null || args['help'] == true) {
    stdout.writeln(usage);
    exit(cmd == null ? 64 : 0);
  }

  if (cmd.name == 'hooks') {
    final port = int.tryParse(cmd['port'] as String) ?? 8787;
    final installer = HookInstaller.fromEnvironment();
    try {
      switch (cmd.command?.name) {
        case 'install':
          final plugins = installer.pluginHookFiles();
          if (plugins.isNotEmpty) {
            stdout.writeln("The Perch plugin carries Perch's hooks (${plugins.first}): nothing to add to "
                '${installer.settingsFile.path}.');
            await offerSettingsHookRemoval(installer, port, yes: cmd.command!['yes'] == true);
            break;
          }
          installer.install(port: port);
          stdout.writeln('Installed Perch hooks for port $port in ${installer.settingsFile.path}.');
          stdout.writeln('The previous file is saved as ${installer.backupFile.path}.');
          stdout.writeln("(The Perch plugin carries the same hooks and follows the host's port: README, "
              '"The Perch plugin". After installing it, run perch_host hooks uninstall.)');
          if (await control(port, 'reload') != null) stdout.writeln('The running host on port $port now has instant updates on.');
        case 'uninstall':
          installer.uninstall();
          stdout.writeln('Removed Perch hooks from ${installer.settingsFile.path}.');
          final plugins = installer.pluginHookFiles();
          if (plugins.isNotEmpty) {
            stdout.writeln('The Perch plugin still carries them (${plugins.first}); remove it with /plugin in Claude Code '
                '(or perch_host commands uninstall for the copy that command installed).');
          }
          if (await control(port, 'reload') != null) stdout.writeln('The running host on port $port was told.');
        case 'status':
          final st = installer.status(port: port);
          stdout.writeln(st.describe());
          exit(st.state == HookState.installed ? 0 : 1);
        default:
          stderr.writeln(usage);
          exit(64);
      }
    } on HookSettingsError catch (e) {
      stderr.writeln(e.message);
      exit(1);
    }
    exit(0);
  }

  if (cmd.name == 'commands') {
    final installer = CommandInstaller.fromEnvironment();
    switch (cmd.command?.name) {
      case 'install':
        final hooks = HookInstaller.fromEnvironment();
        final others = [
          for (final f in hooks.pluginHookFiles())
            if (!f.startsWith(installer.pluginDir.path)) f
        ];
        if (others.isNotEmpty) {
          stderr.writeln('The Perch plugin is already installed from a marketplace (${others.first}): '
              'installing it here too would give /perch and every hook twice. Nothing was changed.');
          exit(1);
        }
        final aside = installer.install();
        stdout.writeln('Installed the Perch plugin (/perch and the hooks) in ${installer.pluginDir.path}.');
        if (aside != null) stdout.writeln('The folder that was there is saved as $aside (put back by commands uninstall).');
        stdout.writeln('New Claude Code sessions have it; in a running session type /reload-plugins.');
        await offerSettingsHookRemoval(hooks, readPortFile(stateDirectory()) ?? 8787, yes: false);
      case 'uninstall':
        if (!installer.uninstall()) {
          stderr.writeln("${installer.pluginDir.path} is not Perch's; nothing was changed.");
          exit(1);
        }
        stdout.writeln('Removed the Perch plugin from ${installer.pluginDir.path}.');
      case 'status':
        final st = installer.status();
        stdout.writeln(st.describe());
        exit(st.state == CommandState.installed ? 0 : 1);
      default:
        stderr.writeln(usage);
        exit(64);
    }
    exit(0);
  }

  if (cmd.name == 'selftest') {
    final sub = cmd.command?.name;
    if (sub == null) {
      stderr.writeln(usage);
      exit(64);
    }
    final dir = stateDirectory();
    final port = int.tryParse((cmd['port'] as String?) ?? '') ?? HostState.load(dir).lastPort ?? 8787;
    // A running host does it (it holds the state and has the version).
    final told = await control(port, 'selftest-$sub', timeout: sub == 'run' ? const Duration(minutes: 10) : null);
    if (told != null) {
      stdout.write(told);
      exit(0);
    }
    final launcher = ClaudeLauncher.fromEnvironment();
    final tracker = CompatibilityTracker(store: VersionStore.load(dir));
    switch (sub) {
      case 'on' || 'off':
        tracker.setSelfTestEnabled(sub == 'on');
      case 'run':
        tracker.setVersion(await claudeVersion(launcher));
        stdout.writeln('No Perch host is running on port $port; running the self-test here.');
        final tester = SelfTester(
          tracker: tracker,
          launcher: launcher,
          external: ExternalSessions(launcher),
          console: defaultTerminalConsole(),
          stateDir: dir,
          log: (l) => stdout.writeln('${_now()}  $l'),
        );
        final r = await tester.run();
        stdout.writeln(selfTestResultText(r));
        exit(r.passed ? 0 : 1);
    }
    stdout.writeln(selfTestLine(tracker.current));
    exit(0);
  }

  if (cmd.name == 'setup') {
    final platform = Platform.isWindows
        ? AutostartPlatform.windows
        : Platform.isMacOS
            ? AutostartPlatform.macos
            : null;
    if (platform == null) {
      stderr.writeln('Perch release builds are for Windows and macOS.');
      exit(1);
    }
    final exe = Platform.resolvedExecutable;
    final name = exe.split(RegExp(r'[\\/]')).last.toLowerCase();
    if (!name.startsWith('perch_host')) {
      stderr.writeln('perch_host setup runs from a downloaded release (the Perch plugin does this). '
          'From the repo use perch_host autostart enable.');
      exit(64);
    }
    final dir = stateDirectory();
    final port = int.tryParse((cmd['port'] as String?) ?? '') ?? readPortFile(dir) ?? 8787;
    final r = await ReleaseSetup(
      autostart: Autostart(platform: platform, stateDir: dir),
      exe: exe,
      version: hostVersion,
      defaultPort: port,
      listening: portListening,
      control: (p, a) async {
        final r = await control(p, a);
        return r != null && r.startsWith('OK') ? r : null;
      },
    ).run();
    for (final l in r.lines) {
      stdout.writeln(l);
    }
    exit(r.outcome == SetupOutcome.failed ? 1 : 0);
  }

  if (cmd.name == 'autostart') {
    final platform = Platform.isWindows
        ? AutostartPlatform.windows
        : Platform.isMacOS
            ? AutostartPlatform.macos
            : null;
    if (platform == null) {
      stderr.writeln('Autostart is available on Windows and macOS only.');
      exit(1);
    }
    final dir = stateDirectory();
    final autostart = Autostart(platform: platform, stateDir: dir);
    final sub = cmd.command;
    try {
      switch (sub?.name) {
        case 'enable':
          final port = int.tryParse(sub!['port'] as String);
          if (port == null || port < 1 || port > 65535) {
            stderr.writeln('Not a port: ${sub['port']}');
            exit(64);
          }
          final script = Platform.script.scheme == 'file' ? Platform.script.toFilePath() : Directory.current.path;
          final repo = findPerchRepo(script) ?? findPerchRepo(Directory.current.path);
          if (repo == null) {
            stderr.writeln('Run this from the Perch repo (packages/perch_host): the launcher runs the host from there.');
            exit(1);
          }
          var setup = AutostartSetup(
            platform: platform,
            title: sub['title'] as String,
            port: port,
            repo: repo,
            dart: (sub['dart'] as String?) ?? flutterDartWrapper(Platform.resolvedExecutable, platform),
            stateDir: dir,
            env: {
              for (final k in autostartCarriedVariables)
                if ((Platform.environment[k] ?? '').isNotEmpty) k: Platform.environment[k]!,
            },
          );
          final dry = sub['dry-run'] == true;
          final old = autostart.load()?.setup;
          if (dry) {
            setup = setup.withBuild(exe: '${autostart.buildDir}${Platform.pathSeparator}perch_host-<commit>-<time>', commit: null);
          } else {
            setup = await _buildFor(autostart, setup);
          }
          for (final l in await autostart.enable(setup, dryRun: dry)) {
            stdout.writeln(l);
          }
          if (!dry) autostart.pruneBuilds({setup.exe!, ?setup.board, ?old?.exe, ?old?.board});
        case 'update':
          final r = autostart.load();
          if (r == null) {
            stderr.writeln('Autostart is not on: perch_host autostart enable');
            exit(1);
          }
          final script = Platform.script.scheme == 'file' ? Platform.script.toFilePath() : Directory.current.path;
          final repo = findPerchRepo(script) ?? findPerchRepo(Directory.current.path) ?? r.setup.repo;
          final base = AutostartSetup(
              platform: r.setup.platform,
              title: r.setup.title,
              port: r.setup.port,
              repo: repo,
              dart: (sub!['dart'] as String?) ?? r.setup.dart,
              stateDir: r.setup.stateDir,
              env: r.setup.env);
          final setup = await _buildFor(autostart, base);
          for (final l in await autostart.enable(setup)) {
            stdout.writeln(l);
          }
          autostart.pruneBuilds({setup.exe!, ?setup.board, ?r.setup.exe, ?r.setup.board});
          final restart = r.setup.platform == AutostartPlatform.macos
              ? 'launchctl kickstart gui/\$(id -u)/${setup.label}'
              : 'start the scheduled task';
          stdout.writeln('A host running now keeps its old code until it restarts: '
              'quit it (Q in its window), then $restart, or log in again.');
        case 'disable':
          for (final l in await autostart.disable(dryRun: sub!['dry-run'] == true)) {
            stdout.writeln(l);
          }
        case 'status':
          final st = await autostart.status();
          for (final l in st.lines) {
            stdout.writeln(l);
          }
          exit(st.enabled ? 0 : 1);
        default:
          stderr.writeln(usage);
          exit(64);
      }
    } on AutostartError catch (e) {
      stderr.writeln(e.message);
      exit(1);
    }
    exit(0);
  }

  if (cmd.name == 'stop-remote') {
    final port = int.tryParse(cmd['port'] as String) ?? 8787;
    final r = await control(port, 'stop-remote');
    if (r == null) {
      stderr.writeln('Could not reach the Perch host on port $port.');
      exit(1);
    }
    stdout.write(r);
    exit(0);
  }

  if (cmd.name == 'relay') {
    final state = HostState.load(stateDirectory());
    final sub = cmd.command;
    switch (sub?.name) {
      case 'set':
        final url = sub!.rest.isEmpty ? '' : sub.rest.first;
        try {
          state.setRelay(url);
        } on ArgumentError {
          stderr.writeln('Not a relay URL: "$url". Example: perch_host relay set https://perch-relay.<account>.workers.dev');
          exit(64);
        }
        stdout.writeln('Relay set to ${state.relayUrl}.');
        stdout.writeln('Devices paired earlier learn it the next time they connect on this network.');
      case 'clear':
        state.setRelay(null);
        stdout.writeln('Relay cleared: this host is reachable on its network only.');
      case 'show':
        stdout.writeln(relayLine(state.relayUrl));
        exit(0);
      case 'usage':
        // Reads host.json (relay, machine id, board key) and asks the relay; never prints a key.
        (await relayUsageLines(state)).forEach(stdout.writeln);
        exit(0);
      case 'invite':
        // The code is never printed back.
        if (sub!['clear'] == true) {
          state.setRelayInvite(null);
          stdout.writeln('Invite code forgotten.');
        } else if (sub.rest.isEmpty || sub.rest.join('').trim().isEmpty) {
          stderr.writeln('Give the code you were sent: perch_host relay invite perch-xxxx-xxxx-xxxx');
          exit(64);
        } else {
          state.setRelayInvite(sub.rest.join(''));
          stdout.writeln('Invite code saved. The relay checks it the first time this machine connects.');
        }
      default:
        stderr.writeln(usage);
        exit(64);
    }
    final port = int.tryParse((cmd['port'] as String?) ?? '') ?? state.lastPort ?? 8787;
    if (await control(port, 'reload') != null) stdout.writeln('The running host on port $port uses it now.');
    exit(0);
  }

  if (cmd.name == 'name') {
    final state = HostState.load(stateDirectory());
    final sub = cmd.command;
    switch (sub?.name) {
      case 'set':
        final name = sub!.rest.join(' ');
        try {
          state.setMachineName(name);
        } on ArgumentError catch (e) {
          stderr.writeln('${e.message} Example: perch_host name set "Studio desk"');
          exit(64);
        }
        stdout.writeln('This machine is now called "${state.machineName}".');
      case 'clear':
        state.setMachineName(null);
        stdout.writeln('This machine is called by its computer name again ("${Platform.localHostname}").');
      case 'show':
        stdout.writeln(state.machineName == null
            ? 'Machine name: ${Platform.localHostname} (the computer name; change it with perch_host name set "<name>")'
            : 'Machine name: ${state.machineName}');
        exit(0);
      default:
        stderr.writeln(usage);
        exit(64);
    }
    // `perch_host pair` shows the new name too.
    state
      ..lastName = serveName(state)
      ..save();
    final port =
        int.tryParse((sub!['port'] as String?) ?? (cmd['port'] as String?) ?? '') ?? state.lastPort ?? 8787;
    final told = await control(port, 'reload');
    if (told != null) {
      stdout.writeln(told.contains('Machine name: ${serveName(state)}\n')
          ? 'The running host on port $port uses it now and told its devices.'
          : 'The running host on port $port was started with --name and keeps that name until it restarts.');
    }
    exit(0);
  }

  if (cmd.name == 'pair') {
    final state = HostState.load(stateDirectory());
    final port = int.tryParse((cmd['port'] as String?) ?? '') ?? state.lastPort ?? 8787;
    final name = (cmd['name'] as String?) ?? state.lastName ?? serveName(state);
    final lan = [for (final a in await localAddresses()) '$a:$port'];
    for (final l in pairingLines(state, name: name, lan: lan)) {
      stdout.writeln(l);
    }
    stdout.writeln(relayLine(state.relayUrl));
    exit(0);
  }

  if (cmd.name == 'devices') {
    final dir = stateDirectory();
    final port = int.tryParse((cmd['port'] as String?) ?? '') ?? HostState.load(dir).lastPort ?? 8787;
    exit(await runDevicesCommand(cmd.rest,
        watchFlag: cmd['watch'] == true,
        stateDir: dir,
        control: (q) => controlCall(port, q),
        out: stdout.writeln,
        err: stderr.writeln));
  }

  if (cmd.name == 'forget-devices') {
    final state = HostState.load(stateDirectory())..forgetDevices();
    stdout.writeln('Every paired device is forgotten: this machine has a new key, and each device must pair again '
        '(perch_host pair shows the new code).');
    final port = int.tryParse((cmd['port'] as String?) ?? '') ?? state.lastPort ?? 8787;
    if (await control(port, 'reload') != null) stdout.writeln('The running host on port $port dropped its devices.');
    exit(0);
  }

  // serve
  final port = int.tryParse(cmd['port'] as String) ?? 8787;
  final bind = cmd['bind'] as String;
  final nameFlag = cmd['name'] as String?;
  final name = serveName(HostState.load(stateDirectory()), flag: nameFlag);
  final launcher = ClaudeLauncher.fromEnvironment();

  final version = await claudeVersion(launcher);
  if (version == null) {
    stderr.writeln('Warning: could not run "${launcher.executable} --version". Is Claude Code installed and on PATH? '
        '(Set PERCH_CLAUDE_BIN to its path.)');
  } else if (compareVersions(version, minimumClaudeVersion) < 0) {
    stderr.writeln('Warning: Claude Code $version is older than $minimumClaudeVersion, the version Perch was tested with.');
  }

  final hooks = HookInstaller.fromEnvironment().status(port: port);
  final hooksOn = hooks.state == HookState.installed;
  final state = HostState.load(stateDirectory())..rememberServe(name: name, port: port);
  final addresses = bind == '0.0.0.0' ? await localAddresses() : [bind];
  final versions = VersionStore.load(stateDirectory());
  final compatibility = CompatibilityTracker(store: versions, releaseNotes: ReleaseNotesScanner(store: versions));
  // One line per change worth saying (not every status message).
  var said = <String>{};
  void say(Compatibility c) {
    final lines = switch (c.status) {
      CompatibilityStatus.drifted => [
          'Claude Code changed: ${c.reason} Perch cannot answer its prompts any more; answer in the terminal and update Perch.\n'
              '${c.evidence}'
        ],
      CompatibilityStatus.untested => [
          untestedLine(c),
          if (c.seenWorking.any(WorkingKinds.required.contains)) seenWorkingLine(c),
          for (final l in c.releaseNotes?.relevantLines ?? const <String>[]) '  Release notes: $l',
        ],
      CompatibilityStatus.ok => [if (said.any((l) => l.startsWith('Claude Code'))) 'Claude Code ${c.claudeVersion} is checked now.'],
    };
    for (final l in lines) {
      if (!said.contains(l)) stdout.writeln('${_now()}  $l');
    }
    said = lines.toSet();
  }

  compatibility.changes.listen(say);
  compatibility.setVersion(version);
  // Again every 30 minutes: an update changes the status.
  compatibility.watchVersion(() => claudeVersion(launcher));
  // Perch's own key presses count as keyboard input on macOS: the notifier must know them.
  final perchKeys = PerchKeyLog();
  final console = KeyLoggingConsole(defaultTerminalConsole(), perchKeys);
  // Accounts: names in host.json, tokens in protected storage (DPAPI / Keychain).
  final accounts = HostAccounts(vault: defaultTokenVault(stateDirectory()), store: state, launcher: launcher);
  final signIns = AccountSignIns(
      accounts: accounts,
      console: defaultSetupTokenConsoles(launcher, stateDirectory()),
      log: (l) => stdout.writeln('${_now()}  $l'));
  final manager = SessionManager(
      launcher: launcher,
      typer: console,
      inbox: ClaudeInbox(configDir: claudeConfigDir()),
      accounts: accounts,
      compatibility: compatibility,
      limitStore: state,
      searchIndexDir: '${stateDirectory()}${Platform.pathSeparator}search-index')
    ..stopHooks = hooksOn && hooks.stops;
  // The search index is built in the background, so the first search from the phone is quick.
  unawaited(manager.warmSearchIndex());
  manager.limits.log = (line) => stdout.writeln('${_now()}  $line');
  final selfTester = SelfTester(
    tracker: compatibility,
    launcher: launcher,
    external: manager.external,
    console: console,
    stateDir: stateDirectory(),
    log: (l) => stdout.writeln('${_now()}  $l'),
  );
  final notifier = PushNotifier(
      source: manager,
      state: state,
      machineName: name,
      inputIdle: inputIdleReader(),
      perchKeys: perchKeys,
      log: (line) => stdout.writeln('${_now()}  $line'));
  // The relay owner's machines hear when the shared pool passes 80% (friends' hosts ask too,
  // but the relay says they are not exempt and nothing is sent).
  RelayPoolWatch(
      state: state,
      warn: (pct) {
        stdout.writeln('${_now()}  Shared relay pool $pct% used today.');
        notifier.relayPool(pct);
      })
        .start();
  // The board every device keeps (board.json; tasks.json and host.json's projects and model
  // table move into it once), and the task board running this machine's tasks from it.
  final hostBoard = HostBoard(
      stateDir: stateDirectory(),
      machineId: state.machineId,
      legacyProjects: state.projects,
      legacyModels: state.modelTable,
      log: (line) => stdout.writeln('${_now()}  $line'));
  final board = TaskBoard(
      board: hostBoard,
      sessions: ManagerTaskSessions(manager),
      modelTable: () => modelTableOf(hostBoard.board) ?? state.models,
      onSend: notifier.perchTyping,
      log: (line) => stdout.writeln('${_now()}  $line'))
    ..start();
  final boardDir = defaultBoardDir();
  final boardLine = 'Board: http://localhost:$port/ (in a browser on this machine)'
      '${boardDir != null && File('$boardDir${Platform.pathSeparator}index.html').existsSync() ? '' : ' (not built yet: see the page)'}';
  // One line when autostart is on for this state folder.
  final autostartLine = autostartBannerLine(stateDirectory(), port);
  // Autostart's compiled host built from an older main: say how to update it.
  final staleLine = await autostartStaleLine(stateDirectory(), runningExe: Platform.resolvedExecutable);
  final noticeLines = <String>[
    boardLine,
    ?autostartLine,
    ?staleLine,
    if (!hooksOn) hooksOffLine,
    if (hooksOn && !hooks.current)
      'Cards and Stop for sessions in terminals Perch cannot type into (VS Code, Cursor, iTerm2), and usage limits '
          'reaching Perch at once, need the newer hooks: run perch_host hooks install',
    if (hooks.duplicate) duplicateHooksLine,
    ?switch (CommandInstaller.fromEnvironment().status().state) {
      CommandState.installed || CommandState.notInstalled || CommandState.foreign => null,
      CommandState.outdated => 'The Perch plugin in Claude Code\'s skills folder is from an older Perch: run perch_host commands install',
    },
  ];
  late final PerchServer server;
  server = PerchServer(
      notifier: notifier,
      manager: manager,
      state: state,
      machineName: name,
      nameFixed: nameFlag != null,
      onRenamed: (n) => stdout.writeln('${_now()}  This machine is now called "$n"; connected devices were told.'),
      bindAddress: bind,
      port: port,
      lanAddresses: [for (final a in addresses) '$a:$port'],
      onReload: () {
        noticeLines
          ..clear()
          ..addAll([boardLine, ?autostartBannerLine(stateDirectory(), port), if (!server.hooksInstalled) hooksOffLine]);
        notice?.reprint();
      },
      claudeVersion: version,
      hooksInstalled: hooksOn,
      checkHooks: () {
        final st = HookInstaller.fromEnvironment().status(port: port);
        manager.stopHooks = st.state == HookState.installed && st.stops;
        return st.state == HookState.installed;
      },
      selfTester: selfTester,
      accessibility: Platform.isMacOS ? () => MacHelper(binDir: '${stateDirectory()}/bin').trusted() : null,
      // Only a release build the plugin installed restarts into a newer one by itself.
      onSwitch: !isReleaseBuild(Platform.resolvedExecutable, stateDirectory()) ? null : () async {
        // `perch_host setup` turned autostart to a newer build: start it and leave.
        final platform = Platform.isWindows ? AutostartPlatform.windows : AutostartPlatform.macos;
        if (!Platform.isWindows && !Platform.isMacOS) return;
        final autostart = Autostart(platform: platform, stateDir: stateDirectory());
        final next = autostart.load()?.setup;
        if (next?.exe == null || next!.exe!.toLowerCase() == Platform.resolvedExecutable.toLowerCase()) return;
        stdout.writeln('${_now()}  Restarting into Perch ${next.release ?? 'the new build'} (nothing is in flight).');
        await server.close();
        await board.dispose();
        await manager.dispose();
        await autostart.startNow();
        exit(0);
      },
      signIns: signIns,
      board: board,
      boardDir: boardDir,
      approvals: approvalDialogEnabled(Platform.environment)
          ? OsApprovalDialog(seconds: approvalDialogSeconds(Platform.environment))
          : null,
      onSelfTestHook: (_) => stdout.writeln('${_now()}  Ignoring hook events from a Perch self-test session.'),
      onHook: cmd['log-hooks'] == true
          ? (j) => stdout.writeln('${_now()}  hook ${j['hook_event_name']} ${j['tool_name'] ?? ''} '
              '${j['notification_type'] ?? ''} ${j['session_id']}')
          : null);
  final relay = RelayClient(state: state, onDevice: server.attach);
  server.relay = relay;
  relay.statusChanges.listen((s) {
    if (s == 'connected' || s.startsWith('retrying') || s.startsWith('daily limit')) {
      stdout.writeln('${_now()}  Relay ${state.relayUrl}: $s');
    }
  });
  // The board's encrypted copy in the relay: at start, after changes, every 3 minutes.
  final boardRelay = HostBoardRelay(board: hostBoard, state: state, log: (line) => stdout.writeln('${_now()}  $line'));
  server.boardKeyChanges.listen((_) => boardRelay.keyChanged());
  if (cmd['log-hooks'] == true) {
    manager.promptsOpened.listen((p) => stdout.writeln('${_now()}  card opened ${p.prompt.kind.name} ${p.prompt.promptId}'));
    manager.promptsClosed.listen((p) => stdout.writeln('${_now()}  card closed ${p.promptId}'));
  }
  final int bound;
  try {
    bound = await server.start();
  } on SocketException catch (e) {
    stderr.writeln('Could not listen on $bind:$port: ${e.message}');
    exit(1);
  }
  // The Perch plugin's hooks and /perch menu find this host through the port file.
  writePortFile(stateDirectory(), bound);
  // Off unless the owner turned it on (perch_host selftest on, or the app).
  selfTester.start();
  boardRelay.start();

  Future<void> shutdown() async {
    stdout.writeln('Stopping Perch host. Sessions it started are stopped; their conversations stay resumable with claude --resume.');
    await boardRelay.dispose();
    await server.close();
    await board.dispose();
    await manager.dispose();
    exit(0);
  }

  notice = HostNotice(server,
      state: state,
      addresses: addresses,
      onQuit: shutdown,
      relayStatus: () => relay.status,
      extraLines: noticeLines);
  notice!.start(boundPort: bound);
  ProcessSignal.sigint.watch().listen((_) => shutdown());
}
