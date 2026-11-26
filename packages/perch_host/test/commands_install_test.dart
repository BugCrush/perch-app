// `perch_host commands install|uninstall|status`: the /perch plugin goes into
// `<Claude Code config dir>/skills/perch` (Claude Code loads a plugin folder there by
// itself), with Perch's hooks; the plugin names no port (it reads the host's port file); anything already in that folder is moved aside and put back
// on uninstall, which removes exactly what install wrote. The embedded copy is the plugin
// in claude_plugin/perch. Only temporary config folders are touched.
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/claude_plugin_files.dart';
import 'package:perch_host/src/commands_install.dart';
import 'package:perch_host/src/slash_commands.dart';
import 'package:test/test.dart';

import '../tool/embed_claude_plugin.dart' as embed;

final sep = Platform.pathSeparator;

List<String> tree(Directory d) => [
      for (final e in d.listSync(recursive: true))
        if (e is File) e.path.substring(d.path.length + 1).replaceAll('\\', '/')
    ]..sort();

void main() {
  late Directory config;
  late CommandInstaller installer;

  setUp(() {
    config = Directory.systemTemp.createTempSync('perch_cmds_');
    installer = CommandInstaller(configDir: config.path);
  });
  tearDown(() {
    try {
      config.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the_embedded_plugin_is_the_one_in_claude_plugin', () {
    final generated = embed.embedded('claude_plugin/perch').replaceAll('\r\n', '\n');
    final kept = File('lib/src/claude_plugin_files.dart').readAsStringSync().replaceAll('\r\n', '\n');
    expect(kept, generated, reason: 'run: dart run tool/embed_claude_plugin.dart');
    expect(File('claude_plugin/perch/hooks/hooks.json').readAsStringSync().replaceAll('\r\n', '\n'), embed.hooksJson(),
        reason: 'the hooks in lib/src/hooks.dart changed: run dart run tool/embed_claude_plugin.dart');
    expect(claudePluginFiles.keys, containsAll(['.claude-plugin/plugin.json', 'hooks/hooks.json', 'hooks/register.tsx']));
    expect(jsonDecode(claudePluginFiles['.claude-plugin/plugin.json']!)['name'], 'perch');
    final module = claudePluginFiles['hooks/register.tsx']!;
    // The menu registers /perch, talks to the host on loopback with its header, and sends a
    // task as the owner's own message.
    expect(module, contains("name: 'perch'"));
    expect(module, contains('http://127.0.0.1:\${port}/local/perch/'));
    expect(module, contains("\${dir}/port"));
    final hooks = jsonDecode(claudePluginFiles['hooks/hooks.json']!) as Map;
    expect(hooks['modules'], ['./register.tsx']);
    expect((hooks['hooks'] as Map).keys, containsAll(['PermissionRequest', 'Stop', 'StopFailure']));
    expect(module, contains("'x-perch-menu': '1'"));
    expect(module, contains('asUser: true'));
    // Mac, 2026-11-26: Enter in the invite code field only stored the text; Save had to be
    // reached with Tab. Enter saves a code now, the same way Save does.
    final field = RegExp(r'onSubmit=\{v => \{([^}]*)\}\}').allMatches(module).map((m) => m.group(1)!).toList();
    expect(field.where((b) => b.contains('inviteCode = v') && b.contains('saveInviteCode()')), hasLength(1));
    expect(module, contains('onPress={saveInviteCode}'));
  });

  test('install_writes_the_plugin_and_uninstall_removes_exactly_it', () {
    final settings = File('${config.path}${sep}settings.json')..writeAsStringSync('{"model":"opus"}');
    expect(installer.status().state, CommandState.notInstalled);
    expect(installer.install(), isNull);
    final dir = installer.pluginDir;
    expect(dir.path, '${config.path}${sep}skills${sep}perch');
    expect(tree(dir), ['.claude-plugin/plugin.json', '.perch-install.json', 'hooks/hooks.json', 'hooks/perch-setup.sh', 'hooks/register.tsx']);
    expect(File('${dir.path}${sep}hooks${sep}register.tsx').readAsStringSync(), claudePluginFiles['hooks/register.tsx']);
    expect(File('${dir.path}${sep}hooks${sep}hooks.json').readAsStringSync(), claudePluginFiles['hooks/hooks.json']);
    expect(installer.status().state, CommandState.installed);
    expect(installer.status().describe(), contains('Perch plugin'));
    // Installing again replaces it in place.
    installer.install();
    expect(installer.status().state, CommandState.installed);
    expect(config.listSync().where((e) => e.path.contains('.perch-staging')), isEmpty);
    // Claude Code writes its type files into a watched plugin folder: they go too.
    Directory('${dir.path}$sep.claude-plugin${sep}types').createSync(recursive: true);
    File('${dir.path}${sep}tsconfig.json').writeAsStringSync('{}');
    expect(installer.uninstall(), isTrue);
    expect(dir.existsSync(), isFalse);
    expect(Directory('${config.path}${sep}skills').existsSync(), isFalse, reason: 'install made it');
    expect(settings.readAsStringSync(), '{"model":"opus"}', reason: 'settings are never touched');
    expect(installer.uninstall(), isTrue, reason: 'nothing to remove');
  });

  test('a_folder_that_is_not_perchs_is_moved_aside_and_put_back', () {
    final mine = Directory('${config.path}${sep}skills${sep}perch')..createSync(recursive: true);
    File('${mine.path}${sep}SKILL.md').writeAsStringSync('---\nname: perch\n---\nThe owner\'s own skill\n');
    final otherSkill = Directory('${config.path}${sep}skills${sep}notes')..createSync();
    File('${otherSkill.path}${sep}SKILL.md').writeAsStringSync('notes');
    expect(installer.status().state, CommandState.foreign);
    expect(installer.uninstall(), isFalse, reason: 'not Perch\'s: left alone');
    final aside = installer.install();
    expect(aside, isNotNull);
    expect(File('$aside${sep}SKILL.md').readAsStringSync(), contains("owner's own skill"));
    expect(installer.status().state, CommandState.installed);
    installer.install(); // a reinstall keeps the way back
    expect(installer.uninstall(), isTrue);
    expect(File('${mine.path}${sep}SKILL.md').readAsStringSync(), contains("owner's own skill"));
    expect(Directory(aside!).existsSync(), isFalse);
    expect(installer.backupDir.existsSync(), isFalse);
    expect(File('${otherSkill.path}${sep}SKILL.md').existsSync(), isTrue);
  });

  test('an_install_from_an_older_host_is_outdated', () {
    installer.install();
    final marker = File('${installer.pluginDir.path}$sep$perchInstallMarker');
    final j = jsonDecode(marker.readAsStringSync()) as Map;
    marker.writeAsStringSync(jsonEncode({...j, 'version': 'old'}));
    expect(installer.status().state, CommandState.outdated);
    expect(installer.status().describe(), contains('older Perch'));
  });

  test('the_phone_lists_perch_among_the_commands', () {
    final c = SlashCommandCatalog(configDir: () => config.path).commandsFor(config.path);
    final perch = c.firstWhere((x) => x.name == '/perch');
    expect(perch.source, 'perch');
    expect(perch.description, contains('board'));
  });

  test('the_cli_installs_reports_and_uninstalls_on_a_temporary_config_dir', () async {
    Future<ProcessResult> run(List<String> args) => Process.run(
          Platform.resolvedExecutable,
          ['run', 'bin/perch_host.dart', 'commands', ...args],
          environment: {'CLAUDE_CONFIG_DIR': config.path},
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
    var r = await run(['status']);
    expect(r.exitCode, 1);
    expect('${r.stdout}', contains('Not installed'));
    r = await run(['install']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect('${r.stdout}', contains('Installed the Perch plugin'));
    expect((await run(['status'])).exitCode, 0);
    r = await run(['uninstall']);
    expect(r.exitCode, 0);
    expect(installer.pluginDir.existsSync(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
