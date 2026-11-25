// The Perch plugin (`/perch` and Perch's hooks; claude_plugin/perch, embedded in
// claude_plugin_files.dart) without a marketplace: `perch_host commands install` writes it into
// `<Claude Code config dir>/skills/perch`, where Claude Code loads a plugin folder by itself in
// every session. The usual way is `/plugin install perch@perch` from the repository's
// marketplace (README); both carry the same files, so only one should be installed. A folder
// already there that is not Perch's is moved aside into `<config dir>/perch-backup/` first and
// put back by `commands uninstall`, which removes exactly what install wrote. The plugin names
// no port: its hooks and menu read the port file `serve` writes into the state folder.
import 'dart:convert';
import 'dart:io';

import 'claude_plugin_files.dart';

/// The folder under `<config dir>/skills` that holds the plugin.
const perchPluginFolder = 'perch';

/// Written beside the plugin's files: marks the folder as Perch's, with the version of the
/// files, and where a folder it replaced was moved.
const perchInstallMarker = '.perch-install.json';

/// A short fingerprint of the embedded plugin: an install from an older host shows as
/// outdated.
String perchPluginVersion() {
  var h = 0x811c9dc5;
  for (final e in claudePluginFiles.entries) {
    for (final c in utf8.encode('${e.key}\n${e.value}\n')) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
  }
  return h.toRadixString(16).padLeft(8, '0');
}

enum CommandState { installed, notInstalled, outdated, foreign }

class CommandStatus {
  final CommandState state;
  final String path;
  const CommandStatus(this.state, this.path);

  bool get installed => state == CommandState.installed || state == CommandState.outdated;

  String describe() => switch (state) {
        CommandState.installed => 'Installed: the Perch plugin (/perch and the hooks) in $path.',
        CommandState.outdated =>
          'Installed from an older Perch ($path). Run perch_host commands install again for the current menu.',
        CommandState.notInstalled => 'Not installed. Run: perch_host commands install',
        CommandState.foreign => '$path is not Perch\'s; perch_host commands install moves it aside first.',
      };
}

class CommandInstaller {
  final String configDir;
  CommandInstaller({required this.configDir});

  /// `CLAUDE_CONFIG_DIR`, else `~/.claude`.
  factory CommandInstaller.fromEnvironment([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    final configured = e['CLAUDE_CONFIG_DIR'];
    if (configured != null && configured.trim().isNotEmpty) return CommandInstaller(configDir: configured.trim());
    final home = (Platform.isWindows ? e['USERPROFILE'] : e['HOME']) ?? e['HOME'] ?? '.';
    return CommandInstaller(configDir: '$home${Platform.pathSeparator}.claude');
  }

  String get _sep => Platform.pathSeparator;
  Directory get pluginDir => Directory('$configDir${_sep}skills$_sep$perchPluginFolder');
  Directory get backupDir => Directory('$configDir${_sep}perch-backup');
  File get _marker => File('${pluginDir.path}$_sep$perchInstallMarker');

  Map<String, dynamic>? _readMarker() {
    try {
      final j = jsonDecode(_marker.readAsStringSync());
      if (j is Map && j['perch'] == true) return j.cast<String, dynamic>();
    } catch (_) {}
    return null;
  }

  String _stamp() => DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '').substring(0, 14);

  /// Writes the plugin, replacing an earlier Perch install. Returns the folder a folder that
  /// was not Perch's was moved to, if any.
  String? install() {
    final skills = Directory('$configDir${_sep}skills');
    var createdSkills = !skills.existsSync();
    String? movedAside;
    String? keptBackup;
    if (pluginDir.existsSync()) {
      final marker = _readMarker();
      if (marker == null) {
        backupDir.createSync(recursive: true);
        movedAside = '${backupDir.path}${_sep}skills-perch-${_stamp()}';
        pluginDir.renameSync(movedAside);
      } else {
        keptBackup = marker['movedAside'] is String ? marker['movedAside'] as String : null;
        createdSkills = marker['createdSkills'] == true;
        pluginDir.deleteSync(recursive: true);
      }
    }
    // Written beside the skills folder, then moved in whole: Claude Code never loads half.
    final staging = Directory('$configDir$_sep.perch-staging-${_stamp()}');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    for (final e in claudePluginFiles.entries) {
      final f = File('${staging.path}$_sep${e.key.replaceAll('/', _sep)}');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(e.value);
    }
    File('${staging.path}$_sep$perchInstallMarker').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({
          'perch': true,
          'version': perchPluginVersion(),
          'movedAside': ?(movedAside ?? keptBackup),
          if (createdSkills) 'createdSkills': true,
        })}\n');
    skills.createSync(recursive: true);
    staging.renameSync(pluginDir.path);
    return movedAside;
  }

  /// Removes the plugin and puts back the folder install moved aside. A folder that is not
  /// Perch's is left alone (returns false).
  bool uninstall() {
    if (!pluginDir.existsSync()) return true;
    final marker = _readMarker();
    if (marker == null) return false;
    final aside = marker['movedAside'] is String ? marker['movedAside'] as String : null;
    pluginDir.deleteSync(recursive: true);
    if (aside != null && Directory(aside).existsSync()) {
      Directory(aside).renameSync(pluginDir.path);
      try {
        if (backupDir.listSync().isEmpty) backupDir.deleteSync();
      } catch (_) {}
    }
    final skills = Directory('$configDir${_sep}skills');
    try {
      if (marker['createdSkills'] == true && skills.existsSync() && skills.listSync().isEmpty) skills.deleteSync();
    } catch (_) {}
    return true;
  }

  CommandStatus status() {
    final path = pluginDir.path;
    if (!pluginDir.existsSync()) return CommandStatus(CommandState.notInstalled, path);
    final marker = _readMarker();
    if (marker == null) return CommandStatus(CommandState.foreign, path);
    if (marker['version'] != perchPluginVersion()) return CommandStatus(CommandState.outdated, path);
    return CommandStatus(CommandState.installed, path);
  }
}
