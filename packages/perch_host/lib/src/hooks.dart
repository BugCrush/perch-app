// Claude Code hooks that tell the Perch host the moment something happens in a terminal
// session (a question, a permission request, the end of a turn). They live in the
// owner's Claude Code settings file and are installed only by `perch_host hooks install`.
//
// Every hook but one is an async command hook that posts its input to the host with a
// 2-second limit and always exits 0 printing nothing: it never slows Claude Code down and
// never shows an error, whether or not the host is running. (An `http` hook would show a
// notice when the host is down.) Claude Code runs command hooks with Git Bash on Windows
// and sh elsewhere; curl is there in both.
//
// The exception is `PermissionRequest`, which Claude Code runs alongside its dialog (a
// permission request, a question, a plan approval): it waits for the host's reply and
// prints it, so a card in a terminal Perch cannot type into (VS Code, Cursor, iTerm2) can
// be answered from the phone. The host replies at once with nothing for every other
// session; the dialog is on screen meanwhile, so nothing changes at the desk. Host down:
// curl fails at once, prints nothing, exit 0.
//
// On macOS and Linux, `PreToolUse` (every tool) and `PostToolBatch` also ask the host, at
// once and without waiting, whether the phone pressed Stop for a session Perch cannot press
// Esc in: the host answers `{"continue": false, …}` then, nothing otherwise (1-second
// connect limit, 2 seconds in all). Windows keeps the async `PreToolUse` hook (Esc works in
// every Windows console).
import 'dart:convert';
import 'dart:io';

/// Marks Perch's own hook commands so they can be found again.
const perchHookTag = 'perch-hook';

/// The events Perch listens to, with their matcher (null: every tool / every case).
const perchHookEvents = <String, String?>{
  'PreToolUse': 'AskUserQuestion|ExitPlanMode',
  'PermissionRequest': null,
  'PostToolUse': null,
  'Notification': null,
  'Stop': null,
  'UserPromptSubmit': null,
  'SubagentStart': null,
  'SubagentStop': null,
  'SessionStart': null,
  'SessionEnd': null,
  'StopFailure': null,
};

/// Events added after the first hooks were installed: a host whose hooks lack them still
/// counts as installed (an older version: `hooks install` again adds them).
const perchNewerHookEvents = {'StopFailure'};

/// Events whose hook asks the host whether to stop (macOS and Linux), with their matcher.
const perchStopCheckEvents = <String, String?>{'PreToolUse': null, 'PostToolBatch': null};

/// Whether this machine installs the stop checks.
bool get perchStopChecksByDefault => !Platform.isWindows;

/// The stop check: posts the hook's input and prints the host's immediate answer.
String perchStopCheckCommand(int port) =>
    'curl -sf --connect-timeout 1 -m 2 -X POST -H "Content-Type: application/json" --data-binary @- '
    '"http://127.0.0.1:$port/hook?check=1" 2>/dev/null; exit 0 # $perchHookTag';

/// How long the host keeps a `PermissionRequest` hook waiting for the phone at most.
const perchHookHold = Duration(hours: 6);

/// The waiting `PermissionRequest` hook: prints the host's answer (a decision, or nothing).
String perchWaitingHookCommand(int port) =>
    'curl -sf -m ${perchHookHold.inSeconds + 30} -X POST -H "Content-Type: application/json" --data-binary @- '
    '"http://127.0.0.1:$port/hook?wait=1" 2>/dev/null; exit 0 # $perchHookTag';

String perchHookCommand(int port) =>
    'curl -s -m 2 -o /dev/null -X POST -H "Content-Type: application/json" --data-binary @- '
    'http://127.0.0.1:$port/hook >/dev/null 2>&1; exit 0 # $perchHookTag';

// The Perch plugin (claude_plugin/perch, hooks/hooks.json) carries the same hooks for every
// machine, so its commands cannot name a port: they read it at run time from the state
// folder's `port` file, which `serve` writes (state_dir.dart): `PERCH_STATE_DIR`, else
// `%APPDATA%\perch` (Git Bash sees APPDATA on Windows), else `~/.perch`; 8787 when the file
// is missing or holds anything but digits. `read` is a shell builtin: no extra process.
// A test host's sessions inherit its `PERCH_STATE_DIR`, so their hooks reach the test host.
const _pluginPortLookup = r'd="${PERCH_STATE_DIR:-${APPDATA:+$APPDATA/perch}}"; '
    r'read -r p 2>/dev/null <"${d:-$HOME/.perch}/port"; case "$p" in ""|*[!0-9]*) p=8787;; esac; ';

/// The plugin's async hook: posts the hook's input to the host, prints nothing, exit 0.
String perchPluginHookCommand() => '${_pluginPortLookup}curl -s -m 2 -o /dev/null -X POST -H "Content-Type: application/json" '
    '--data-binary @- "http://127.0.0.1:\$p/hook" >/dev/null 2>&1; exit 0 # $perchHookTag';

/// The plugin's async `PreToolUse` report of questions and plans, on Windows only (elsewhere
/// the stop check below sees every tool, these included).
String perchPluginWindowsHookCommand() => '[ "\$OS" = Windows_NT ] || exit 0; ${perchPluginHookCommand()}';

/// The plugin's waiting `PermissionRequest` hook: prints the host's answer (or nothing).
String perchPluginWaitingHookCommand() => '${_pluginPortLookup}curl -sf -m ${perchHookHold.inSeconds + 30} -X POST '
    '-H "Content-Type: application/json" --data-binary @- "http://127.0.0.1:\$p/hook?wait=1" 2>/dev/null; exit 0 # $perchHookTag';

/// The plugin's stop check (macOS and Linux; on Windows it exits at once: Esc works in
/// every Windows console). Synchronous, so Windows pays one Git Bash start (about 45 ms)
/// per tool call for it.
String perchPluginCheckCommand() => '[ "\$OS" = Windows_NT ] && exit 0; ${_pluginPortLookup}curl -sf --connect-timeout 1 -m 2 '
    '-X POST -H "Content-Type: application/json" --data-binary @- "http://127.0.0.1:\$p/hook?check=1" 2>/dev/null; '
    'exit 0 # $perchHookTag';

/// The plugin's setup step (SessionStart, async, up to 10 minutes): hooks/perch-setup.sh
/// keeps the host installed and current (see that script and release_setup.dart). It runs
/// in the background of the session and prints nothing; its log is `<state>/setup.log`.
String perchPluginSetupCommand() =>
    r'sh "${CLAUDE_PLUGIN_ROOT}/hooks/perch-setup.sh" </dev/null >/dev/null 2>&1; exit 0 # perch-setup';

/// The `hooks` part of the plugin's hooks/hooks.json (tool/embed_claude_plugin.dart writes
/// it beside the `/perch` module).
Map<String, dynamic> perchPluginHooks() {
  final hooks = <String, dynamic>{};
  for (final e in perchHookEvents.entries) {
    hooks[e.key] = [
      {
        if (e.value != null) 'matcher': e.value,
        'hooks': [
          if (e.key == 'SessionStart') {'type': 'command', 'command': perchPluginSetupCommand(), 'async': true, 'timeout': 600},
          if (e.key == 'PermissionRequest')
            {'type': 'command', 'command': perchPluginWaitingHookCommand(), 'timeout': perchHookHold.inSeconds + 60}
          else if (e.key == 'PreToolUse')
            {'type': 'command', 'command': perchPluginWindowsHookCommand(), 'async': true, 'timeout': 5}
          else
            {'type': 'command', 'command': perchPluginHookCommand(), 'async': true, 'timeout': 5}
        ],
      }
    ];
  }
  for (final e in perchStopCheckEvents.entries) {
    hooks[e.key] = [
      ...?(hooks[e.key] as List?),
      {
        if (e.value != null) 'matcher': e.value,
        'hooks': [
          {'type': 'command', 'command': perchPluginCheckCommand(), 'timeout': 5}
        ],
      }
    ];
  }
  return {'hooks': hooks};
}

/// The port a Perch hook command posts to, or null when [command] is not one.
int? hookPortOf(String command) {
  if (!command.contains(perchHookTag)) return null;
  final m = RegExp(r'127\.0\.0\.1:(\d+)/hook').firstMatch(command);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// One matcher group per event, as it goes into `hooks.<event>` of the settings file.
/// [stopChecks]: the stop-check hooks (default: not on Windows).
Map<String, Map<String, dynamic>> perchHookEntries(int port, {bool? stopChecks}) {
  final stops = stopChecks ?? perchStopChecksByDefault;
  return {
    for (final e in perchHookEvents.entries)
      if (!(stops && perchStopCheckEvents.containsKey(e.key)))
        e.key: {
          if (e.value != null) 'matcher': e.value,
          'hooks': [
            if (e.key == 'PermissionRequest')
              {'type': 'command', 'command': perchWaitingHookCommand(port), 'timeout': perchHookHold.inSeconds + 60}
            else
              {'type': 'command', 'command': perchHookCommand(port), 'async': true, 'timeout': 5}
          ],
        },
    if (stops)
      for (final e in perchStopCheckEvents.entries)
        e.key: {
          if (e.value != null) 'matcher': e.value,
          'hooks': [
            {'type': 'command', 'command': perchStopCheckCommand(port), 'timeout': 5}
          ],
        },
  };
}

enum HookState { installed, notInstalled, otherPort, unreadable }

/// Where Claude Code gets Perch's hooks: the Perch plugin, or the user settings file
/// (`perch_host hooks install`, the older way).
enum HookSource { plugin, settings }

class HookStatus {
  final HookState state;

  /// The port the installed hooks post to (null for the plugin: it reads the port file).
  final int? port;
  final String settingsPath;

  /// Where the hooks come from (null: not installed).
  final HookSource? source;

  /// The plugin's hooks.json, when the plugin carries them.
  final String? pluginPath;

  /// Perch's hooks are in the plugin and in settings.json (or in two plugins): every event
  /// reaches the host twice.
  final bool duplicate;

  /// Whether the installed `PermissionRequest` hook waits for the phone's answer (an older
  /// install only reports the request).
  final bool waits;

  /// Whether the stop checks this machine uses are installed (always true where none are).
  final bool stops;

  /// Whether the `StopFailure` hook is installed (a usage limit reaches Perch at once).
  final bool limits;
  const HookStatus(this.state, this.port, this.settingsPath,
      {this.waits = false,
      this.stops = true,
      this.limits = true,
      this.source,
      this.pluginPath,
      this.duplicate = false});

  /// Installed, in the version this host expects.
  bool get current => state == HookState.installed && waits && stops && limits;

  String describe() => source == HookSource.plugin
      ? 'Installed by the Perch plugin ($pluginPath): Claude Code tells the Perch host on this machine about each '
          'event (the port is read from the host\'s state folder).'
          '${duplicate ? ' Perch\'s hooks are also in $settingsPath (or a second Perch plugin): every event reaches '
              'Perch twice. Remove the old ones: perch_host hooks uninstall' : ''}'
      : _describeSettings();

  String _describeSettings() => switch (state) {
        HookState.installed when !waits || !stops || !limits =>
          'Installed: Claude Code tells Perch on port $port about each event ($settingsPath). '
              'An older version: run perch_host hooks install again so cards and Stop work from the phone for '
              'terminals Perch cannot type into (VS Code, Cursor, iTerm2) and usage limits reach Perch at once.',
        HookState.installed => 'Installed: Claude Code tells Perch on port $port about each event ($settingsPath).',
        HookState.otherPort => 'Installed for port $port, not for this host. Run: perch_host hooks install --port <port>',
        HookState.notInstalled => 'Not installed. Run: perch_host hooks install',
        HookState.unreadable => 'Cannot read $settingsPath (not valid JSON); nothing was changed.',
      };
}

class HookSettingsError implements Exception {
  final String message;
  HookSettingsError(this.message);
  @override
  String toString() => message;
}

/// Adds Perch's hooks to, and removes them from, `<config dir>/settings.json`, leaving
/// every other key and every other hook as it was.
class HookInstaller {
  final String configDir;

  /// Whether to install (and expect) the stop checks; default: not on Windows.
  final bool stopChecks;
  HookInstaller({required this.configDir, bool? stopChecks}) : stopChecks = stopChecks ?? perchStopChecksByDefault;

  /// `CLAUDE_CONFIG_DIR`, else `~/.claude`.
  factory HookInstaller.fromEnvironment([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    final configured = e['CLAUDE_CONFIG_DIR'];
    if (configured != null && configured.trim().isNotEmpty) return HookInstaller(configDir: configured.trim());
    final home = (Platform.isWindows ? e['USERPROFILE'] : e['HOME']) ?? e['HOME'] ?? '.';
    return HookInstaller(configDir: '$home${Platform.pathSeparator}.claude');
  }

  File get settingsFile => File('$configDir${Platform.pathSeparator}settings.json');
  File get backupFile => File('${settingsFile.path}.perch-backup');

  Map<String, dynamic> _read() {
    final f = settingsFile;
    if (!f.existsSync()) return <String, dynamic>{};
    final text = f.readAsStringSync();
    if (text.trim().isEmpty) return <String, dynamic>{};
    try {
      final v = jsonDecode(text);
      if (v is Map) return v.cast<String, dynamic>();
    } catch (_) {}
    throw HookSettingsError('${f.path} is not a JSON object; nothing was changed.');
  }

  void _write(Map<String, dynamic> settings) {
    final f = settingsFile;
    if (f.existsSync()) f.copySync(backupFile.path);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(settings)}\n');
  }

  static bool _isPerch(Object? hook) => hook is Map && hook['command'] is String && (hook['command'] as String).contains(perchHookTag);

  /// [settings] without Perch's hooks; groups and events left empty by that are dropped.
  static Map<String, dynamic> _withoutPerch(Map<String, dynamic> settings) {
    final hooks = settings['hooks'];
    if (hooks is! Map) return settings;
    final out = <String, dynamic>{};
    for (final entry in hooks.cast<String, dynamic>().entries) {
      final groups = entry.value;
      if (groups is! List) {
        out[entry.key] = groups;
        continue;
      }
      final kept = <dynamic>[];
      for (final g in groups) {
        if (g is! Map || g['hooks'] is! List || !(g['hooks'] as List).any(_isPerch)) {
          kept.add(g);
          continue;
        }
        final rest = [for (final h in g['hooks'] as List) if (!_isPerch(h)) h];
        if (rest.isNotEmpty) kept.add({...g.cast<String, dynamic>(), 'hooks': rest});
      }
      if (kept.isNotEmpty) out[entry.key] = kept;
    }
    final copy = {...settings};
    if (out.isEmpty) {
      copy.remove('hooks');
    } else {
      copy['hooks'] = out;
    }
    return copy;
  }

  /// Adds Perch's hooks for [port] (replacing any earlier Perch hooks).
  void install({required int port}) {
    final settings = _withoutPerch(_read());
    final hooks = settings['hooks'] is Map ? (settings['hooks'] as Map).cast<String, dynamic>() : <String, dynamic>{};
    for (final e in perchHookEntries(port, stopChecks: stopChecks).entries) {
      final groups = hooks[e.key] is List ? [...hooks[e.key] as List] : <dynamic>[];
      groups.add(e.value);
      hooks[e.key] = groups;
    }
    _write({...settings, 'hooks': hooks});
  }

  /// Removes Perch's hooks; nothing else changes.
  void uninstall() {
    final settings = _read();
    final without = _withoutPerch(settings);
    if (jsonEncode(without) == jsonEncode(settings)) return;
    _write(without);
  }

  /// Whether settings.json holds any Perch hook.
  bool get settingsHasPerchHooks {
    try {
      final s = _read();
      return jsonEncode(_withoutPerch(s)) != jsonEncode(s);
    } on HookSettingsError {
      return false;
    }
  }

  /// The hooks.json of every Perch plugin Claude Code loads that carries Perch's hooks: the
  /// folder `commands install` writes (`<config>/skills/perch`), and a `perch@<marketplace>`
  /// installed with `/plugin` (`plugins/installed_plugins.json`) and not turned off in
  /// `enabledPlugins`.
  List<String> pluginHookFiles() {
    final sep = Platform.pathSeparator;
    final out = <String>[];
    void consider(String dir) {
      final f = File('$dir${sep}hooks${sep}hooks.json');
      try {
        final j = jsonDecode(f.readAsStringSync());
        final hooks = j is Map ? j['hooks'] : null;
        if (hooks is! Map) return;
        final events = {
          for (final e in hooks.entries)
            if (e.value is List &&
                (e.value as List).any((g) => g is Map && g['hooks'] is List && (g['hooks'] as List).any(_isPerch)))
              e.key
        };
        if (events.containsAll(perchHookEvents.keys) && !out.contains(f.path)) out.add(f.path);
      } catch (_) {}
    }

    consider('$configDir${sep}skills${sep}perch');
    Map? enabled;
    try {
      final e = _read()['enabledPlugins'];
      if (e is Map) enabled = e;
    } catch (_) {}
    try {
      final j = jsonDecode(File('$configDir${sep}plugins${sep}installed_plugins.json').readAsStringSync());
      final plugins = j is Map ? j['plugins'] : null;
      if (plugins is Map) {
        for (final e in plugins.entries) {
          if (e.key is! String || !(e.key as String).startsWith('perch@')) continue;
          if (enabled != null && enabled[e.key] == false) continue;
          for (final inst in e.value is List ? e.value as List : const []) {
            if (inst is Map && inst['installPath'] is String) consider(inst['installPath'] as String);
          }
        }
      }
    } catch (_) {}
    return out;
  }

  /// Whether every Perch hook is installed (by the plugin or in settings.json), and for
  /// which port. With [port], settings hooks for another port count as
  /// [HookState.otherPort]; the plugin's follow the host's port file.
  HookStatus status({int? port}) {
    final settingsStatus = _settingsStatus(port: port);
    final plugins = pluginHookFiles();
    if (plugins.isEmpty) return settingsStatus;
    return HookStatus(HookState.installed, null, settingsFile.path,
        waits: true,
        source: HookSource.plugin,
        pluginPath: plugins.first,
        duplicate: plugins.length > 1 || settingsHasPerchHooks);
  }

  HookStatus _settingsStatus({int? port}) {
    final Map<String, dynamic> settings;
    try {
      settings = _read();
    } on HookSettingsError {
      return HookStatus(HookState.unreadable, null, settingsFile.path);
    }
    final hooks = settings['hooks'];
    final ports = <int>{};
    final covered = <String>{};
    var waits = false;
    final checks = <String>{};
    if (hooks is Map) {
      for (final event in {...perchHookEvents.keys, ...perchStopCheckEvents.keys}) {
        final groups = hooks[event];
        if (groups is! List) continue;
        for (final g in groups) {
          if (g is! Map || g['hooks'] is! List) continue;
          for (final h in g['hooks'] as List) {
            if (!_isPerch(h)) continue;
            final p = hookPortOf((h as Map)['command'] as String);
            if (p != null) {
              ports.add(p);
              if (perchHookEvents.containsKey(event)) covered.add(event);
              if (h['async'] != true && (h['command'] as String).contains('check=1')) checks.add(event);
              if (event == 'PermissionRequest' && (h['async'] != true) && (h['command'] as String).contains('wait=1')) {
                waits = true;
              }
            }
          }
        }
      }
    }
    final required = perchHookEvents.keys.where((e) => !perchNewerHookEvents.contains(e));
    if (!covered.containsAll(required) || ports.length != 1) {
      return HookStatus(HookState.notInstalled, null, settingsFile.path);
    }
    final p = ports.single;
    return HookStatus(port == null || port == p ? HookState.installed : HookState.otherPort, p, settingsFile.path,
        source: HookSource.settings,
        waits: waits,
        stops: !stopChecks || checks.containsAll(perchStopCheckEvents.keys),
        limits: covered.containsAll(perchNewerHookEvents));
  }
}
