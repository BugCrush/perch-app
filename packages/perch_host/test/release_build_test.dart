// What a release build needs at run time: the macOS key helper shipped prebuilt next to the
// compiled host (no Xcode tools on the user's Mac), the board page in `board/` next to it,
// and one version for the host, the plugin and the app (tool/release_version.dart, which
// the GitHub Actions workflow runs).
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/board_page.dart';
import 'package:perch_host/src/mac_helper.dart';
import 'package:perch_host/src/server.dart' show hostVersion;
import 'package:test/test.dart';

import '../tool/release_version.dart' as rv;

final sep = Platform.pathSeparator;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('perch_release_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a_prebuilt_helper_next_to_the_host_is_used_without_compiling', () async {
    final shipped = Directory('${tmp.path}${sep}release')..createSync();
    final prebuilt = File('${shipped.path}$sep${MacHelper.fileName}')..writeAsStringSync('helper');
    final calls = <String>[];
    final h = MacHelper(
        binDir: '${tmp.path}${sep}bin',
        prebuiltDirs: [shipped.path],
        run: (exe, args) async {
          calls.add(exe);
          return (exitCode: 0, stdout: 'yes\n');
        });
    expect(await h.path(), prebuilt.path);
    expect(await h.trusted(), isTrue);
    expect(calls, [prebuilt.path], reason: 'no swiftc');
  });

  test('without_a_prebuilt_helper_it_compiles_as_before', () async {
    final calls = <String>[];
    final h = MacHelper(
        binDir: '${tmp.path}${sep}bin',
        prebuiltDirs: ['${tmp.path}${sep}nothing'],
        run: (exe, args) async {
          calls.add(exe);
          if (exe == '/usr/bin/swiftc') File(args.last).writeAsStringSync('built');
          return (exitCode: 0, stdout: '');
        });
    expect(await h.path(), endsWith(MacHelper.fileName));
    expect(calls, ['/usr/bin/swiftc']);
  });

  test('the_board_page_next_to_a_compiled_host_is_served', () {
    final exeDir = Directory('${tmp.path}${sep}host')..createSync();
    File('${exeDir.path}${sep}board${sep}index.html')
      ..createSync(recursive: true)
      ..writeAsStringSync('<html></html>');
    final exe = '${exeDir.path}${sep}perch_host${Platform.isWindows ? '.exe' : ''}';
    expect(defaultBoardDir(environment: {}, script: Uri.file(exe), executable: exe), '${exeDir.path}${sep}board');
    // PERCH_BOARD_DIR still wins.
    expect(defaultBoardDir(environment: {'PERCH_BOARD_DIR': 'x'}, script: Uri.file(exe), executable: exe), 'x');
  });

  test('host_plugin_and_app_carry_one_version', () {
    final v = rv.readVersions('../..');
    expect(v.host, hostVersion);
    expect(v.plugin, hostVersion, reason: 'claude_plugin/perch/.claude-plugin/plugin.json');
    expect(v.app, hostVersion, reason: 'apps/perch_app/pubspec.yaml version name');
    expect(v.appShown, hostVersion, reason: 'appVersion in apps/perch_app/lib/src/ui/app_menu.dart');
    expect(rv.problems(v, tag: 'v$hostVersion'), isEmpty);
    expect(rv.problems(v, tag: 'v$hostVersion-rc1'), isEmpty);
    expect(rv.problems(v, tag: 'v0.0.1'), isNotEmpty);
    expect(rv.problems((host: '1.0.0', plugin: '1.0.1', app: '1.0.0', build: 3, appShown: '1.0.0'), tag: null), isNotEmpty);
    expect(jsonDecode(File('../../.claude-plugin/marketplace.json').readAsStringSync())['plugins'][0]['source'],
        './packages/perch_host/claude_plugin/perch');
  });
}
