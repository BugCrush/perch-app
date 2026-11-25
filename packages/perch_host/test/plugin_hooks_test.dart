// Perch's hooks carried by the Perch Claude Code plugin (hooks/hooks.json beside /perch):
// one file for every machine, so the commands find the host's port at run time in the
// state folder's `port` file. `hooks status` reports either source and a duplicate
// (plugin and settings.json both). Only temporary folders are touched; the shell checks
// run the real sh (Git Bash on Windows) with a fake curl.
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/claude_plugin_files.dart';
import 'package:perch_host/src/hooks.dart';
import 'package:perch_host/src/state_dir.dart';
import 'package:test/test.dart';

final sep = Platform.pathSeparator;

/// sh on this machine: Git Bash on Windows (what Claude Code runs hooks with), else /bin/sh.
String? shell() {
  if (!Platform.isWindows) return '/bin/sh';
  for (final p in [r'C:\Program Files\Git\bin\bash.exe', r'C:\Program Files (x86)\Git\bin\bash.exe']) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('perch_phooks_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the_plugin_hooks_cover_every_event_and_name_no_port', () {
    final j = perchPluginHooks();
    final hooks = (j['hooks'] as Map).cast<String, dynamic>();
    expect(hooks.keys.toSet(), {...perchHookEvents.keys, ...perchStopCheckEvents.keys});
    for (final groups in hooks.values) {
      for (final g in groups as List) {
        for (final h in (g as Map)['hooks'] as List) {
          final c = (h as Map)['command'] as String;
          expect(h['type'], 'command', reason: 'never http hooks');
          if (c == perchPluginSetupCommand()) {
            expect(h['async'], isTrue, reason: 'the setup step never holds up a session');
            continue;
          }
          expect(c, contains(perchHookTag));
          expect(c, contains(r'http://127.0.0.1:$p/hook'));
          expect(c, endsWith('exit 0 # $perchHookTag'));
          expect(hookPortOf(c), isNull, reason: 'the port is read at run time');
        }
      }
    }
    final perm = ((hooks['PermissionRequest'] as List).single as Map)['hooks'][0] as Map;
    expect(perm['async'], isNot(true));
    expect(perm['command'], contains('hook?wait=1'));
    // PreToolUse: the async report of questions and plans (Windows), and the stop check (elsewhere).
    final pre = hooks['PreToolUse'] as List;
    expect(pre, hasLength(2));
    final ask = pre.firstWhere((g) => g['matcher'] == 'AskUserQuestion|ExitPlanMode') as Map;
    expect(ask['hooks'][0]['async'], isTrue);
    expect(ask['hooks'][0]['command'], startsWith(r'[ "$OS" = Windows_NT ] || exit 0;'));
    final check = pre.firstWhere((g) => !(g as Map).containsKey('matcher')) as Map;
    expect(check['hooks'][0]['command'], startsWith(r'[ "$OS" = Windows_NT ] && exit 0;'));
    expect(check['hooks'][0]['command'], contains('hook?check=1'));
    expect(check['hooks'][0]['async'], isNot(true));
  });

  test('the_plugin_hooks_json_is_the_generated_one_with_the_menu_module', () {
    final j = jsonDecode(claudePluginFiles['hooks/hooks.json']!) as Map;
    expect(j['modules'], ['./register.tsx']);
    expect(jsonEncode(j['hooks']), jsonEncode(perchPluginHooks()['hooks']),
        reason: 'run: dart run tool/embed_claude_plugin.dart');
  });

  test('the_hook_command_reads_the_port_from_the_state_folder_and_falls_back_to_8787', () async {
    final sh = shell();
    if (sh == null) {
      markTestSkipped('no sh');
      return;
    }
    final state = Directory('${tmp.path}${sep}state')..createSync();
    final cmd = perchPluginCheckCommand().replaceFirst(r'[ "$OS" = Windows_NT ] && exit 0; ', '');
    Future<String> run(Map<String, String> env) async {
      // A fake curl (a shell function) that prints the URL it was given.
      final r = await Process.run(sh, ['-c', 'curl() { for a; do last="\$a"; done; echo "URL \$last"; }; $cmd'],
          environment: {'OS': 'test', ...env}, stdoutEncoding: utf8);
      expect(r.exitCode, 0);
      return '${r.stdout}'.trim();
    }

    expect(await run({'PERCH_STATE_DIR': state.path}), 'URL http://127.0.0.1:8787/hook?check=1');
    writePortFile(state.path, 8899);
    expect(await run({'PERCH_STATE_DIR': state.path}), 'URL http://127.0.0.1:8899/hook?check=1');
    File('${state.path}$sep$perchPortFile').writeAsStringSync('rubbish\n');
    expect(await run({'PERCH_STATE_DIR': state.path}), 'URL http://127.0.0.1:8787/hook?check=1');
    // Without PERCH_STATE_DIR: %APPDATA%\perch (Windows), else ~/.perch.
    final appData = Directory('${tmp.path}${sep}appdata$sep${'perch'}')..createSync(recursive: true);
    writePortFile(appData.path, 8790);
    expect(await run({'PERCH_STATE_DIR': '', 'APPDATA': appData.parent.path}), 'URL http://127.0.0.1:8790/hook?check=1');
    final home = Directory('${tmp.path}${sep}home$sep.perch')..createSync(recursive: true);
    writePortFile(home.path, 8791);
    expect(await run({'PERCH_STATE_DIR': '', 'APPDATA': '', 'HOME': home.parent.path}), 'URL http://127.0.0.1:8791/hook?check=1');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('the_windows_and_stop_check_guards_exit_without_posting', () async {
    final sh = shell();
    if (sh == null) {
      markTestSkipped('no sh');
      return;
    }
    Future<ProcessResult> run(String cmd, String os) =>
        Process.run(sh, ['-c', cmd.replaceFirst('curl ', 'echo POSTED; true ')], environment: {'OS': os});
    final check = perchPluginCheckCommand();
    expect('${(await run(check, 'Windows_NT')).stdout}', isEmpty);
    expect('${(await run(check, 'Darwin')).stdout}', contains('POSTED'));
    final ask = perchPluginWindowsHookCommand();
    expect('${(await run(ask, 'Darwin')).stdout}', isEmpty);
    expect((await run(ask, 'Windows_NT')).exitCode, 0);
  });

  group('status', () {
    late Directory config;
    File settings() => File('${config.path}${sep}settings.json');
    void writePlugin(String dir) {
      final f = File('$dir${sep}hooks${sep}hooks.json');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(claudePluginFiles['hooks/hooks.json']!);
    }

    setUp(() => config = Directory('${tmp.path}${sep}config')..createSync());

    test('a_plugin_in_the_skills_folder_counts_as_installed_for_any_port', () {
      writePlugin('${config.path}${sep}skills${sep}perch');
      final st = HookInstaller(configDir: config.path).status(port: 8899);
      expect(st.state, HookState.installed);
      expect(st.source, HookSource.plugin);
      expect(st.current, isTrue);
      expect(st.duplicate, isFalse);
      expect(st.describe(), contains('Perch plugin'));
    });

    test('a_skills_folder_from_an_older_install_without_hooks_does_not_count', () {
      final f = File('${config.path}${sep}skills${sep}perch${sep}hooks${sep}hooks.json')..createSync(recursive: true);
      f.writeAsStringSync('{ "modules": ["./register.tsx"] }');
      expect(HookInstaller(configDir: config.path).status().state, HookState.notInstalled);
    });

    test('a_plugin_installed_from_a_marketplace_counts_unless_disabled', () {
      final cache = '${config.path}${sep}plugins${sep}cache${sep}perch${sep}perch${sep}0.3.0';
      writePlugin(cache);
      File('${config.path}${sep}plugins${sep}installed_plugins.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({
          'version': 2,
          'plugins': {
            'perch@perch': [
              {'scope': 'user', 'installPath': cache, 'version': '0.3.0'}
            ]
          }
        }));
      final installer = HookInstaller(configDir: config.path);
      expect(installer.status().source, HookSource.plugin);
      expect(installer.status().pluginPath, contains('0.3.0'));
      settings().writeAsStringSync(jsonEncode({
        'enabledPlugins': {'perch@perch': false}
      }));
      expect(installer.status().state, HookState.notInstalled);
    });

    test('hooks_in_both_places_are_reported_as_a_duplicate', () {
      final installer = HookInstaller(configDir: config.path)..install(port: 8787);
      expect(installer.status().source, HookSource.settings);
      expect(installer.status().duplicate, isFalse);
      writePlugin('${config.path}${sep}skills${sep}perch');
      final st = installer.status(port: 8787);
      expect(st.state, HookState.installed);
      expect(st.source, HookSource.plugin);
      expect(st.duplicate, isTrue);
      expect(st.describe(), contains('twice'));
      expect(installer.settingsHasPerchHooks, isTrue);
      installer.uninstall();
      expect(installer.status().duplicate, isFalse);
      expect(installer.settingsHasPerchHooks, isFalse);
    });
  });

  test('serve_writes_the_port_file_the_hooks_read', () {
    writePortFile(tmp.path, 8899);
    expect(File('${tmp.path}$sep$perchPortFile').readAsStringSync(), '8899\n');
    expect(readPortFile(tmp.path), 8899);
    expect(readPortFile('${tmp.path}${sep}missing'), isNull);
  });
}
