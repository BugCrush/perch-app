import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/hooks.dart';
import 'package:test/test.dart';

void main() {
  late Directory config;

  setUp(() => config = Directory.systemTemp.createTempSync('perch_hcli_'));
  tearDown(() {
    try {
      config.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<ProcessResult> run(List<String> args) => Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/perch_host.dart', 'hooks', ...args],
        environment: {'CLAUDE_CONFIG_DIR': config.path},
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

  test('install_status_uninstall_on_a_temporary_config_dir', () async {
    final settings = File('${config.path}${Platform.pathSeparator}settings.json')
      ..writeAsStringSync('{"model": "opus"}');
    var r = await run(['status']);
    expect(r.exitCode, 1);
    expect('${r.stdout}', contains('Not installed'));

    r = await run(['install', '--port', '8790']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(HookInstaller(configDir: config.path).status().port, 8790);
    expect((await run(['status', '--port', '8790'])).exitCode, 0);
    final other = await run(['status', '--port', '8787']);
    expect(other.exitCode, 1);
    expect('${other.stdout}', contains('port 8790'));

    r = await run(['uninstall']);
    expect(r.exitCode, 0);
    expect(jsonDecode(settings.readAsStringSync()), {'model': 'opus'});
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('with_the_plugin_install_adds_nothing_and_offers_to_remove_the_old_hooks', () async {
    final sep = Platform.pathSeparator;
    final settings = File('${config.path}${sep}settings.json')..writeAsStringSync('{"model": "opus"}');
    HookInstaller(configDir: config.path).install(port: 8790);
    final plugin = File('${config.path}${sep}skills${sep}perch${sep}hooks${sep}hooks.json')..createSync(recursive: true);
    plugin.writeAsStringSync(jsonEncode({'modules': ['./register.tsx'], ...perchPluginHooks()}));
    var r = await run(['status']);
    expect(r.exitCode, 0);
    expect('${r.stdout}', contains('Perch plugin'));
    expect('${r.stdout}', contains('twice'));
    // No terminal: it only says how.
    r = await run(['install', '--port', '8790']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect('${r.stdout}', contains('nothing to add'));
    expect('${r.stdout}', contains('hooks uninstall'));
    expect(HookInstaller(configDir: config.path).settingsHasPerchHooks, isTrue);
    r = await run(['install', '--yes']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(HookInstaller(configDir: config.path).settingsHasPerchHooks, isFalse);
    expect(jsonDecode(settings.readAsStringSync()), {'model': 'opus'});
    expect('${(await run(['status'])).stdout}', isNot(contains('twice')));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
