// The Perch plugin's setup step (claude_plugin/perch/hooks/perch-setup.sh), run with the real
// sh (Git Bash on Windows) against a local web server playing the GitHub Release: it
// downloads the host build of the plugin's version, checks its SHA-256, unpacks it into the
// state folder, and skips work it need not do. PERCH_SETUP_DRY keeps it from running the
// downloaded host. Windows and macOS (Apple Silicon) only, like the release builds.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:perch_host/src/hooks.dart';
import 'package:test/test.dart';

final sep = Platform.pathSeparator;

String? shell() {
  if (!Platform.isWindows) return '/bin/sh';
  for (final p in [r'C:\Program Files\Git\bin\bash.exe', r'C:\Program Files (x86)\Git\bin\bash.exe']) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

void main() {
  final supported = Platform.isWindows || (Platform.isMacOS && !Platform.version.contains('x64'));
  late Directory tmp;
  late HttpServer web;
  late Directory plugin;
  late Directory state;
  final served = <String, List<int>>{};
  final requests = <String>[];

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_setupsh_');
    plugin = Directory('${tmp.path}${sep}plugin')..createSync();
    Directory('${plugin.path}$sep.claude-plugin').createSync();
    File('${plugin.path}$sep.claude-plugin${sep}plugin.json').writeAsStringSync('{\n  "name": "perch",\n  "version": "9.8.7"\n}\n');
    Directory('${plugin.path}${sep}hooks').createSync();
    File('${plugin.path}${sep}hooks${sep}perch-setup.sh')
        .writeAsStringSync(File('claude_plugin/perch/hooks/perch-setup.sh').readAsStringSync().replaceAll('\r\n', '\n'));
    state = Directory('${tmp.path}${sep}state');
    served.clear();
    requests.clear();
    web = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    web.listen((r) async {
      requests.add(r.uri.path);
      final body = served[r.uri.path];
      if (body == null) {
        r.response.statusCode = 404;
      } else {
        r.response.add(body);
      }
      await r.response.close();
    });
  });

  tearDown(() async {
    await web.close(force: true);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A release archive holding a fake host and a board page, served with its checksum.
  Future<String> publish({bool badSum = false}) async {
    final content = Directory('${tmp.path}${sep}content')..createSync();
    final exe = Platform.isWindows ? 'perch_host.exe' : 'perch_host';
    File('${content.path}$sep$exe').writeAsStringSync('fake host');
    File('${content.path}${sep}board${sep}index.html')
      ..createSync(recursive: true)
      ..writeAsStringSync('<html></html>');
    final asset = Platform.isWindows ? 'perch-host-9.8.7-windows-x64.zip' : 'perch-host-9.8.7-macos-arm64.tar.gz';
    final archive = '${tmp.path}$sep$asset';
    final r = Platform.isWindows
        ? await Process.run('${Platform.environment['SYSTEMROOT'] ?? r'C:\Windows'}\\System32\\tar.exe',
            ['-a', '-cf', archive, '-C', content.path, '.'])
        : await Process.run('tar', ['-czf', archive, '-C', content.path, '.']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final bytes = File(archive).readAsBytesSync();
    final sum = badSum ? '0' * 64 : sha256.convert(bytes).toString();
    served['/v9.8.7/$asset'] = bytes;
    served['/v9.8.7/SHA256SUMS.txt'] = utf8.encode('$sum  $asset\n${'1' * 64}  perch-9.8.7.apk\n');
    return asset;
  }

  Future<String> runSetup({Map<String, String> env = const {}}) async {
    final cmd = perchPluginSetupCommand().replaceAll(r'${CLAUDE_PLUGIN_ROOT}', plugin.path.replaceAll(r'\', '/'));
    final r = await Process.run(shell()!, ['-c', cmd], environment: {
      'PERCH_STATE_DIR': state.path,
      'PERCH_RELEASE_URL': 'http://127.0.0.1:${web.port}',
      'PERCH_RELEASE_REPO': 'nobody/none',
      'PERCH_SETUP_DRY': '1',
      // Never the real gh: a failed download must fail.
      'PATH': Platform.isWindows ? r'C:\Program Files\Git\usr\bin;C:\Windows\System32' : '/usr/bin:/bin',
      ...env,
    });
    expect(r.exitCode, 0, reason: 'the hook never fails the session');
    final log = File('${state.path}${sep}setup.log');
    return log.existsSync() ? log.readAsStringSync() : '';
  }

  test('downloads_checks_and_unpacks_the_release_of_the_plugins_version', () async {
    await publish();
    final log = await runSetup();
    expect(log, contains('Perch 9.8.7'));
    expect(log, contains('Unpacked into'));
    expect(log, contains('Dry run: would run'));
    final out = '${state.path}${sep}releases${sep}9.8.7';
    expect(File('$out$sep${Platform.isWindows ? 'perch_host.exe' : 'perch_host'}').readAsStringSync(), 'fake host');
    expect(File('$out${sep}board${sep}index.html').existsSync(), isTrue);
    expect(Directory('${state.path}${sep}releases$sep.lock').existsSync(), isFalse, reason: 'lock released');
    expect(Directory('${state.path}${sep}releases$sep.download-9.8.7').existsSync(), isFalse);
  }, skip: supported && shell() != null ? false : 'Windows and macOS on Apple Silicon only');

  test('the_release_repository_comes_from_plugin_json_unless_overridden', () async {
    await publish();
    File('${plugin.path}$sep.claude-plugin${sep}plugin.json').writeAsStringSync(
        '{\n  "name": "perch",\n  "version": "9.8.7",\n  "repository": "https://github.com/some-friend/perch-fork.git"\n}\n');
    var log = await runSetup(env: {'PERCH_RELEASE_REPO': ''});
    expect(log, contains('from some-friend/perch-fork'));
    Directory('${state.path}${sep}releases').deleteSync(recursive: true);
    log = await runSetup(env: {'PERCH_RELEASE_REPO': 'other/repo'});
    expect(log, contains('from other/repo'));
  }, skip: supported && shell() != null ? false : 'Windows and macOS on Apple Silicon only');

  test('a_wrong_checksum_installs_nothing', () async {
    await publish(badSum: true);
    final log = await runSetup();
    expect(log, contains('does not match'));
    expect(Directory('${state.path}${sep}releases${sep}9.8.7').existsSync(), isFalse);
  }, skip: supported && shell() != null ? false : 'Windows and macOS on Apple Silicon only');

  test('nothing_is_downloaded_when_installed_on_a_developer_machine_or_turned_off', () async {
    await publish();
    // Installed already.
    File('${state.path}${sep}releases${sep}9.8.7${sep}installed').createSync(recursive: true);
    await runSetup();
    expect(requests, isEmpty);
    Directory('${state.path}${sep}releases').deleteSync(recursive: true);
    // Turned off.
    await runSetup(env: {'PERCH_NO_SETUP': '1'});
    expect(requests, isEmpty);
    // Autostart runs a host built from the repo.
    File('${state.path}${sep}autostart.json').writeAsStringSync('{"setup": {"exe": "x", "repo": "y"}}');
    await runSetup();
    expect(requests, isEmpty);
    // A release-managed autostart is updated.
    File('${state.path}${sep}autostart.json').writeAsStringSync('{"setup": {"exe": "x", "release": "9.8.6"}}');
    await runSetup();
    expect(requests, isNotEmpty);
  }, skip: supported && shell() != null ? false : 'Windows and macOS on Apple Silicon only');
}
