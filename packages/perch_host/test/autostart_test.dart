import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/autostart.dart';
import 'package:perch_host/src/claude_session.dart' show ClaudeLauncher;
import 'package:test/test.dart';

/// Tests that build, copy and delete real files use the platform they run on: an
/// `Autostart` for Windows joins paths with `\`, which on the Mac makes file names
/// such as `state\host\…` instead of folders.
final native = Platform.isWindows ? AutostartPlatform.windows : AutostartPlatform.macos;
final ext = Platform.isWindows ? '.exe' : '';

AutostartSetup win({String repo = r'D:\My Projects\perch', String title = 'Perch host', Map<String, String> env = const {}}) =>
    AutostartSetup(
      platform: AutostartPlatform.windows,
      title: title,
      port: 8787,
      repo: repo,
      dart: r'C:\src\flutter sdk\bin\dart.bat',
      stateDir: r'C:\Users\Some One\AppData\Roaming\perch',
      env: env,
    );

AutostartSetup mac({String repo = '/Users/me/Desktop/my work/perch', String title = 'Perch host'}) => AutostartSetup(
      platform: AutostartPlatform.macos,
      title: title,
      port: 8787,
      repo: repo,
      dart: "/Users/me/src/flutter's/bin/dart",
      stateDir: '/Users/me/.perch',
      env: const {'PERCH_STATE_DIR': '/Users/me/.perch'},
    );

/// The PowerShell commands a Windows launcher runs, decoded from their -EncodedCommand.
List<String> encodedCommands(String script) => [
      for (final m in RegExp(r'-EncodedCommand ([A-Za-z0-9+/=]+)').allMatches(script))
        String.fromCharCodes(base64.decode(m.group(1)!).buffer.asUint16List())
    ];

class FakeRunner {
  final calls = <List<String>>[];
  final Map<String, int> exitCodes = {};
  final Map<String, String> outputs = {};
  Future<ProcessResult> call(String exe, List<String> args) async {
    final call = [exe, ...args];
    calls.add(call);
    final key = '$exe ${args.isEmpty ? '' : args.first}'.trim();
    return ProcessResult(0, exitCodes[key] ?? 0, outputs[key] ?? '', '');
  }

  bool ran(String exe, String firstArg) => calls.any((c) => c[0] == exe && c.length > 1 && c[1] == firstArg);
}

void main() {
  group('windows launcher', () {
    test('runs the host from the repo with the recorded dart, in a titled window', () {
      final s = windowsLauncherScript(win());
      expect(s, contains('title Perch host'));
      expect(s, contains(r'cd /d "D:\My Projects\perch\packages\perch_host"'));
      expect(s, contains(r'call "C:\src\flutter sdk\bin\dart.bat" run bin\perch_host.dart serve --port 8787'));
      expect(s, contains(r'rem Repo: D:\My Projects\perch'));
      expect(s, contains(r'rem Dart: C:\src\flutter sdk\bin\dart.bat'));
      // Batch files want CRLF and plain ASCII.
      expect(s.replaceAll('\r\n', ''), isNot(contains('\n')));
      expect(s.codeUnits.every((c) => c < 128), isTrue);
    });

    test('clears every Claude Code session marker', () {
      final s = windowsLauncherScript(win());
      for (final m in ClaudeLauncher.inheritedSessionMarkers) {
        expect(s, contains('set "$m="'));
      }
    });

    test('carries the state folder and doubles percent signs', () {
      final s = windowsLauncherScript(win(env: {'PERCH_STATE_DIR': r'D:\x\100%\state'}));
      expect(s, contains(r'set "PERCH_STATE_DIR=D:\x\100%%\state"'));
    });

    test('exits quietly when the port is taken, before starting a host', () {
      final s = windowsLauncherScript(win());
      final ps = encodedCommands(s);
      expect(ps.first, contains('TcpListener'));
      expect(ps.first, contains('8787'));
      expect(ps.first, contains("'busy'"));
      final check = s.indexOf('"%PERCH_NOW%"=="busy" goto running');
      expect(check, greaterThan(0));
      expect(check, lessThan(s.indexOf('call "C:')));
      final running = s.substring(s.indexOf(':running'));
      expect(running.split('\r\n')[1], 'exit /b 0');
    });

    test('stops on a clean exit (Q), restarts on an error with a back-off and a cap', () {
      final s = windowsLauncherScript(win());
      expect(s, contains('if "%PERCH_CODE%"=="0" goto done'));
      expect(s, contains(r'"%SystemRoot%\System32\timeout.exe" /t ' '$autostartBackoffSeconds /nobreak'));
      expect(s, contains('if %PERCH_TRIES% GTR $autostartMaxRestarts goto giveup'));
      // A host that ran a while before failing starts a new count.
      expect(s, contains('if %PERCH_RAN% GEQ $autostartHealthySeconds set PERCH_TRIES=0'));
      expect(s, contains('goto run'));
    });

    test('non-ASCII paths switch the batch file to UTF-8', () {
      final s = windowsLauncherScript(win(repo: r'D:\Projekte\Größe\perch'));
      expect(s.split('\r\n')[1], 'chcp 65001 >nul');
      expect(windowsLauncherScript(win()), isNot(contains('chcp')));
    });
  });

  group('windows task', () {
    test('runs at log on of this user, without admin rights, opening a minimized console', () {
      final x = windowsTaskXml(win(), userId: r'PC\Some One', launcherPath: r'C:\Users\Some One\perch\autostart\perch-host-1.cmd');
      expect(x, contains('<LogonTrigger>'));
      expect(RegExp(r'<UserId>PC\\Some One</UserId>').allMatches(x).length, 2);
      expect(x, contains('<LogonType>InteractiveToken</LogonType>'));
      expect(x, contains('<RunLevel>LeastPrivilege</RunLevel>'));
      expect(x, contains('<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>'));
      expect(x, contains('<Command>%SystemRoot%\\System32\\conhost.exe</Command>'));
      expect(
          x,
          contains('<Arguments>cmd.exe /d /c start &quot;Perch host&quot; /min /normal conhost.exe cmd.exe /d /c '
              '&quot;C:\\Users\\Some One\\perch\\autostart\\perch-host-1.cmd&quot;</Arguments>'));
    });

    test('escapes XML in names', () {
      final x = windowsTaskXml(win(title: 'Perch <A&B>'), userId: 'PC\\me', launcherPath: r'C:\a&b\l.cmd');
      expect(x, contains('Perch &lt;A&amp;B&gt;'));
      expect(x, contains(r'C:\a&amp;b\l.cmd'));
    });
  });

  group('mac files', () {
    test('the launcher runs the host with caffeinate, markers cleared, quoted paths', () {
      final s = macLauncherScript(mac());
      expect(s, startsWith('#!/bin/sh\n'));
      expect(s, contains("cd '/Users/me/Desktop/my work/perch/packages/perch_host'"));
      expect(s, contains("caffeinate -i '/Users/me/src/flutter'\\''s/bin/dart' run bin/perch_host.dart serve --port 8787"));
      expect(s, contains("export PERCH_STATE_DIR='/Users/me/.perch'"));
      for (final m in ClaudeLauncher.inheritedSessionMarkers) {
        expect(s, contains(m));
      }
      expect(s, contains('unset '));
      expect(s, contains(r"printf '\033]0;%s\007' 'Perch host'"));
      expect(s, contains('/usr/sbin/lsof -nP -iTCP:8787 -sTCP:LISTEN'));
      expect(s, contains('[ "\$code" -eq 0 ] && exit 0'));
      expect(s, contains('sleep $autostartBackoffSeconds'));
      expect(s, contains('-gt $autostartMaxRestarts'));
      expect(s, isNot(contains('\r')));
    });

    test('the login script checks the port, then opens a Terminal window', () {
      final s = macLoginScript(mac(), launcherPath: '/Users/me/.perch/autostart/perch host-1.sh');
      final check = s.indexOf('/usr/sbin/lsof -nP -iTCP:8787 -sTCP:LISTEN');
      expect(check, greaterThan(0));
      expect(check, lessThan(s.indexOf('/usr/bin/osascript')));
      expect(s, contains('do script (item 1 of argv)'));
      // The window's shell runs: exec /bin/sh '<launcher>'
      expect(s, contains("'exec /bin/sh '\\''/Users/me/.perch/autostart/perch host-1.sh'\\'''"));
    });

    test('the plist runs the login script at load, with an escaped label and path', () {
      final p = macPlist(mac(), loginScriptPath: '/Users/me/.perch/autostart/login & go.sh');
      expect(p, contains('<key>Label</key>\n  <string>dev.perch.host</string>'));
      expect(p, contains('<key>RunAtLoad</key>\n  <true/>'));
      expect(p, contains('<string>/bin/sh</string>'));
      expect(p, contains('<string>/Users/me/.perch/autostart/login &amp; go.sh</string>'));
      expect(p, isNot(contains('KeepAlive')));
    });

    test('a test title gets its own label', () {
      expect(mac().label, 'dev.perch.host');
      expect(mac(title: 'Perch host (test)').label, 'dev.perch.host.test');
      expect(win(title: 'Perch host (test)').taskName, 'Perch host (test)');
    });
  });

  group('paths', () {
    test('finds the repo from a script inside it', () {
      final tmp = Directory.systemTemp.createTempSync('perch_auto_repo_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final sep = Platform.pathSeparator;
      Directory('${tmp.path}${sep}packages${sep}perch_host${sep}bin').createSync(recursive: true);
      File('${tmp.path}${sep}packages${sep}perch_host${sep}pubspec.yaml').writeAsStringSync('name: perch_host');
      expect(findPerchRepo('${tmp.path}${sep}packages${sep}perch_host${sep}bin${sep}perch_host.dart'), tmp.path);
      expect(findPerchRepo(Directory.systemTemp.path), isNull);
    });

    test('prefers the Flutter dart wrapper over the SDK executable', () {
      bool exists(String p) => true;
      expect(flutterDartWrapper(r'C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe', AutostartPlatform.windows, exists: exists),
          r'C:\src\flutter\bin\dart.bat');
      expect(flutterDartWrapper('/Users/me/src/flutter/bin/cache/dart-sdk/bin/dart', AutostartPlatform.macos, exists: exists),
          '/Users/me/src/flutter/bin/dart');
      expect(flutterDartWrapper(r'C:\dart-sdk\bin\dart.exe', AutostartPlatform.windows, exists: exists), r'C:\dart-sdk\bin\dart.exe');
      expect(
          flutterDartWrapper(r'C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe', AutostartPlatform.windows,
              exists: (_) => false),
          r'C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe');
    });
  });

  group('enable, disable, status', () {
    late Directory tmp;
    late FakeRunner runner;
    String p(String rel) => '${tmp.path}${Platform.pathSeparator}$rel';
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('perch_auto_');
      runner = FakeRunner();
    });
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Autostart manager(AutostartPlatform platform) => Autostart(
          platform: platform,
          stateDir: p('state'),
          run: runner.call,
          launchAgentsDir: p('LaunchAgents'),
          userId: r'PC\me',
        );

    AutostartSetup setup(AutostartPlatform platform, {String title = 'Perch host', String? repo}) => AutostartSetup(
          platform: platform,
          title: title,
          port: 8899,
          repo: repo ?? p('repo with space'),
          dart: p('flutter/bin/dart.bat'),
          stateDir: p('state'),
          env: {'PERCH_STATE_DIR': p('state')},
        );

    List<String> files(String dir) => Directory(dir).existsSync()
        ? [for (final f in Directory(dir).listSync(recursive: true)) f.path.substring(dir.length + 1)]
        : [];

    test('windows: enable writes the launcher and creates the task; disable removes exactly that', () async {
      final a = manager(AutostartPlatform.windows);
      Directory(p('state')).createSync();
      File(p('state/host.json')).writeAsStringSync('{}');
      await a.enable(setup(AutostartPlatform.windows));
      final create = runner.calls.singleWhere((c) => c.contains('/Create'));
      expect(create, containsAllInOrder(['schtasks', '/Create', '/TN', 'Perch host', '/XML']));
      expect(create, contains('/F'));
      final record = a.load()!;
      expect(record.setup.port, 8899);
      expect(File(record.launcherPath).existsSync(), isTrue);
      expect(File(record.launcherPath).readAsStringSync(), contains('serve --port 8899'));
      // The task XML was a temporary file.
      expect(files(p('state')).where((f) => f.endsWith('.xml')), isEmpty);

      runner.calls.clear();
      await a.disable();
      expect(runner.calls.single, ['schtasks', '/Delete', '/TN', 'Perch host', '/F']);
      expect(files(p('state')), ['host.json']);
      expect(a.load(), isNull);
    });

    test('windows: the task XML is UTF-16 with a byte-order mark', () async {
      String? xml;
      final a = Autostart(
          platform: AutostartPlatform.windows,
          stateDir: p('state'),
          userId: r'PC\me',
          run: (exe, args) async {
            if (args.contains('/XML')) {
              final bytes = File(args[args.indexOf('/XML') + 1]).readAsBytesSync();
              expect(bytes.sublist(0, 2), [0xFF, 0xFE]);
              xml = String.fromCharCodes(bytes.buffer.asUint16List(2));
            }
            return ProcessResult(0, 0, '', '');
          });
      await a.enable(setup(AutostartPlatform.windows));
      expect(xml, contains('encoding="UTF-16"'));
      expect(xml, contains('<LogonTrigger>'));
    });

    test('windows: enabling again after the repo moved updates the paths and drops the old launcher', () async {
      final a = manager(AutostartPlatform.windows);
      await a.enable(setup(AutostartPlatform.windows));
      final first = a.load()!.launcherPath;
      await a.enable(setup(AutostartPlatform.windows, repo: p('moved repo')));
      final second = a.load()!;
      expect(second.setup.repo, p('moved repo'));
      expect(second.launcherPath, isNot(first));
      expect(File(first).existsSync(), isFalse);
      expect(File(second.launcherPath).readAsStringSync(), contains('moved repo'));
      expect(runner.calls.where((c) => c.contains('/Create')).length, 2);
      // Same task name: it is replaced (/F), not deleted.
      expect(runner.calls.where((c) => c.contains('/Delete')), isEmpty);
    });

    test('windows: a new title removes the task under the old name', () async {
      final a = manager(AutostartPlatform.windows);
      await a.enable(setup(AutostartPlatform.windows));
      await a.enable(setup(AutostartPlatform.windows, title: 'Perch host (test)'));
      expect(runner.calls.where((c) => c.contains('/Delete')).single, contains('Perch host'));
      expect(a.load()!.setup.taskName, 'Perch host (test)');
    });

    test('windows: enable fails and leaves nothing when the scheduler refuses', () async {
      runner.exitCodes['schtasks /Create'] = 1;
      final a = manager(AutostartPlatform.windows);
      await expectLater(a.enable(setup(AutostartPlatform.windows)), throwsA(isA<AutostartError>()));
      expect(a.load(), isNull);
      expect(files(p('state')), isEmpty);
    });

    test('dry run writes and runs nothing but shows the files', () async {
      final a = manager(AutostartPlatform.windows);
      final lines = await a.enable(setup(AutostartPlatform.windows), dryRun: true);
      expect(runner.calls, isEmpty);
      expect(Directory(p('state')).existsSync(), isFalse);
      final text = lines.join('\n');
      expect(text, contains('<LogonTrigger>'));
      expect(text, contains('serve --port 8899'));
      expect(text, contains('schtasks /Create /TN "Perch host"'));
    });

    test('windows: status reports the paths and whether the task exists', () async {
      final a = manager(AutostartPlatform.windows);
      var st = await a.status();
      expect(st.enabled, isFalse);
      expect(st.lines.join('\n'), contains('off'));
      await a.enable(setup(AutostartPlatform.windows));
      st = await a.status();
      expect(st.enabled, isTrue);
      final text = st.lines.join('\n');
      expect(text, contains(p('repo with space')));
      expect(text, contains(p('flutter/bin/dart.bat')));
      expect(text, contains('8899'));
      expect(text, contains('Perch host'));
      // The repo does not exist in this test: status says to enable again.
      expect(text, contains('autostart enable'));
      runner.exitCodes['schtasks /Query'] = 1;
      st = await a.status();
      expect(st.enabled, isFalse);
      expect(st.lines.join('\n'), contains('task is missing'));
    });

    test('mac: enable writes the plist and scripts; disable unloads and removes exactly them', () async {
      Directory(p('LaunchAgents')).createSync();
      File(p('LaunchAgents/com.other.agent.plist')).writeAsStringSync('<plist/>');
      runner.outputs['id -u'] = '501\n';
      final a = manager(AutostartPlatform.macos);
      await a.enable(setup(AutostartPlatform.macos));
      expect(runner.calls, isEmpty);
      final plist = File(p('LaunchAgents/dev.perch.host.plist'));
      expect(plist.readAsStringSync(), contains('<string>dev.perch.host</string>'));
      final record = a.load()!;
      expect(File(record.launcherPath).readAsStringSync(), contains('serve --port 8899'));
      expect(File(record.loginScriptPath!).readAsStringSync(), contains(record.launcherPath.split(Platform.pathSeparator).last));
      expect((await a.status()).enabled, isTrue);

      await a.disable();
      expect(runner.calls.last, ['launchctl', 'bootout', 'gui/501/dev.perch.host']);
      expect(plist.existsSync(), isFalse);
      expect(files(p('LaunchAgents')), ['com.other.agent.plist']);
      expect(files(p('state')), isEmpty);
    });

    test('disable when off says so and touches nothing', () async {
      final a = manager(AutostartPlatform.windows);
      final lines = await a.disable();
      expect(lines.join('\n'), contains('not on'));
      expect(runner.calls, isEmpty);
    });

    test('banner line only when on, with the port when it differs', () async {
      expect(autostartBannerLine(p('state'), 8899), isNull);
      await manager(AutostartPlatform.windows).enable(setup(AutostartPlatform.windows));
      expect(autostartBannerLine(p('state'), 8899), 'Starts at login: yes');
      expect(autostartBannerLine(p('state'), 8787), 'Starts at login: yes (on port 8899)');
    });
  });
  group('compiled host', () {
    late Directory tmp;
    String p(String rel) => '${tmp.path}${Platform.pathSeparator}$rel';
    setUp(() => tmp = Directory.systemTemp.createTempSync('perch_exe_'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    AutostartSetup built(AutostartSetup s) =>
        s.withBuild(exe: r'C:\Users\Some One\AppData\Roaming\perch\host\perch_host-abc123-20261116-100000.exe', commit: 'abc123');

    test('the windows launcher runs the compiled host from the state folder, not the repo', () {
      final s = windowsLauncherScript(built(win()));
      expect(s, contains(r'cd /d "C:\Users\Some One\AppData\Roaming\perch"'));
      expect(s, contains(r'if not exist "C:\Users\Some One\AppData\Roaming\perch\host\perch_host-abc123-20261116-100000.exe" goto noexe'));
      expect(s, contains(r'"C:\Users\Some One\AppData\Roaming\perch\host\perch_host-abc123-20261116-100000.exe" serve --port 8787'));
      expect(s, isNot(contains(r'run bin\perch_host.dart')));
      expect(s, contains(r'set "PERCH_REPO=D:\My Projects\perch"'));
      expect(s, contains('set "PERCH_HOST_COMMIT=abc123"'));
      expect(s, contains('rem Host: '));
      expect(s, contains('autostart update'));
      // Restart and give-up logic stay.
      expect(s, contains('if %PERCH_TRIES% GTR $autostartMaxRestarts goto giveup'));
      expect(s.codeUnits.every((c) => c < 128), isTrue);
    });

    test('the mac launcher runs the compiled host under caffeinate', () {
      final s = macLauncherScript(mac().withBuild(exe: '/Users/me/.perch/host/perch_host-abc123-1', commit: 'abc123'));
      expect(s, contains("caffeinate -i '/Users/me/.perch/host/perch_host-abc123-1' serve --port 8787"));
      expect(s, contains("cd '/Users/me/.perch' || exit 1"));
      expect(s, contains("[ -x '/Users/me/.perch/host/perch_host-abc123-1' ]"));
      expect(s, contains("export PERCH_REPO='/Users/me/Desktop/my work/perch'"));
      expect(s, isNot(contains('run bin/perch_host.dart')));
    });

    test('the record keeps the compiled host and its commit', () {
      final r = AutostartRecord(setup: built(win()), launcherPath: 'x');
      final back = AutostartRecord.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect(back.setup.exe, endsWith('100000.exe'));
      expect(back.setup.commit, 'abc123');
    });

    test('the SDK dart compiles (no batch file in between)', () {
      expect(sdkDart(r'C:\src\flutter\bin\dart.bat', AutostartPlatform.windows, exists: (_) => true),
          r'C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe');
      expect(sdkDart('/u/flutter/bin/dart', AutostartPlatform.macos, exists: (_) => true), '/u/flutter/bin/cache/dart-sdk/bin/dart');
      expect(sdkDart(r'C:\src\flutter\bin\dart.bat', AutostartPlatform.windows, exists: (_) => false), r'C:\src\flutter\bin\dart.bat');
    });

    Future<ProcessResult> Function(String, List<String>) runner(List<List<String>> calls, {bool compiles = true}) =>
        (exe, args) async {
          calls.add([exe, ...args]);
          if (exe == 'git' && args.contains('--abbrev-ref')) return ProcessResult(0, 0, 'main\n', '');
          if (exe == 'git' && args.contains('HEAD')) return ProcessResult(0, 0, '0123456789abcdef0123\n', '');
          if (exe == 'git' && args.contains('status')) return ProcessResult(0, 0, '', '');
          if (args.isNotEmpty && args.first == 'compile') {
            if (!compiles) return ProcessResult(0, 1, '', 'bin/perch_host.dart:450: Error: not exhaustively matched');
            File(args.last).writeAsStringSync('binary');
            return ProcessResult(0, 0, 'Generated', '');
          }
          return ProcessResult(0, 0, '', '');
        };

    AutostartSetup plain() =>
        AutostartSetup(platform: native, port: 8899, repo: p('repo'), dart: 'dart', stateDir: p('state'));

    test('build compiles under a temporary name, then names it after the commit', () async {
      final calls = <List<String>>[];
      final a = Autostart(platform: native, stateDir: p('state'), launchAgentsDir: p('agents'), run: runner(calls), userId: r'PC\me');
      final b = await a.buildHost(repo: p('repo'), dart: p('flutter/bin/dart.bat'), now: DateTime.utc(2026, 11, 16, 10));
      expect(b.commit, '0123456789ab');
      expect(b.branch, 'main');
      expect(b.exe, p('state${Platform.pathSeparator}host${Platform.pathSeparator}perch_host-0123456789ab-20261116-100000$ext'));
      expect(File(b.exe).existsSync(), isTrue);
      final compile = calls.singleWhere((c) => c.contains('compile'));
      expect(compile, containsAllInOrder(['compile', 'exe', '-o']));
      expect(compile[3], endsWith('perch_host.dart'));
      expect(compile.last, endsWith('perch_host-building$ext'));
      expect(File(compile.last).existsSync(), isFalse);
    });

    test('code that does not compile leaves the host in use untouched', () async {
      final calls = <List<String>>[];
      final a = Autostart(platform: native, stateDir: p('state'), launchAgentsDir: p('agents'), run: runner(calls), userId: r'PC\me');
      final good = await a.buildHost(repo: p('repo'), dart: 'dart');
      await a.enable(plain().withBuild(exe: good.exe, commit: good.commit));
      final launcher = a.load()!.launcherPath;
      final broken = Autostart(
          platform: native, stateDir: p('state'), launchAgentsDir: p('agents'), run: runner(calls, compiles: false), userId: r'PC\me');
      await expectLater(broken.buildHost(repo: p('repo'), dart: 'dart'),
          throwsA(isA<AutostartError>().having((e) => e.message, 'message', contains('not exhaustively matched'))));
      expect(a.load()!.setup.exe, good.exe);
      expect(File(good.exe).existsSync(), isTrue);
      expect(File(launcher).readAsStringSync(), contains(good.exe));
      expect(Directory(a.buildDir).listSync().map((f) => f.path), [good.exe]);
    });

    test('old builds are pruned except the ones kept', () async {
      final a = Autostart(platform: native, stateDir: p('state'), launchAgentsDir: p('agents'), userId: r'PC\me');
      Directory(a.buildDir).createSync(recursive: true);
      String f(String n) => '${a.buildDir}${Platform.pathSeparator}$n';
      for (final n in ['perch_host-a.exe', 'perch_host-b.exe', 'perch_host-c.exe', 'other.txt']) {
        File(f(n)).writeAsStringSync('x');
      }
      a.pruneBuilds({f('perch_host-b.exe'), f('perch_host-c.exe')});
      expect(Directory(a.buildDir).listSync().map((e) => e.path.split(Platform.pathSeparator).last).toSet(),
          {'perch_host-b.exe', 'perch_host-c.exe', 'other.txt'});
    });

    test('status names the compiled host and its commit; a missing one is a problem', () async {
      final a = Autostart(platform: native, stateDir: p('state'), launchAgentsDir: p('agents'), run: runner([]), userId: r'PC\me');
      final b = await a.buildHost(repo: p('repo'), dart: 'dart');
      await a.enable(plain().withBuild(exe: b.exe, commit: b.commit));
      var st = await a.status();
      expect(st.enabled, isTrue);
      expect(st.lines.join('\n'), contains('Built from: 0123456789ab'));
      File(b.exe).deleteSync();
      st = await a.status();
      expect(st.enabled, isFalse);
      expect(st.lines.join('\n'), contains('compiled host is missing'));
      // Disable removes the compiled hosts with everything else.
      final again = await a.buildHost(repo: p('repo'), dart: 'dart', now: DateTime.utc(2027));
      await a.disable();
      expect(File(again.exe).existsSync(), isFalse);
      expect(Directory(a.buildDir).existsSync(), isFalse);
    });

    test('the banner hints at an update when main moved past the running build', () async {
      final a = Autostart(platform: native, stateDir: p('state'), launchAgentsDir: p('agents'), run: runner([]), userId: r'PC\me');
      final exe = p('perch_host-0123456789ab-1.exe');
      await a.enable(plain().withBuild(exe: exe, commit: '0123456789ab'));
      var ancestor = 1;
      Future<ProcessResult> git(String e, List<String> args) async {
        if (args.contains('rev-parse')) return ProcessResult(0, 0, 'fedcba9876543210fedc\n', '');
        return ProcessResult(0, ancestor, '', '');
      }

      final line = await autostartStaleLine(p('state'), runningExe: exe.toUpperCase(), run: git);
      expect(line, contains('built from 0123456789ab'));
      expect(line, contains('fedcba987654'));
      expect(line, contains('autostart update'));
      ancestor = 0; // main is already in the build
      expect(await autostartStaleLine(p('state'), runningExe: exe, run: git), isNull);
      ancestor = 1;
      // Not autostart's build (a host run by hand): no hint.
      expect(await autostartStaleLine(p('state'), runningExe: p('dart.exe'), run: git), isNull);
    });
  });
  group('board page copy', () {
    late Directory tmp;
    String p(String rel) => '${tmp.path}${Platform.pathSeparator}$rel';
    setUp(() => tmp = Directory.systemTemp.createTempSync('perch_boardcopy_'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('the built page is copied next to the host and named in the launcher; old copies go', () {
      final a = Autostart(platform: native, stateDir: p('state'), launchAgentsDir: p('agents'), userId: r'PC\me');
      expect(a.copyBoard(p('repo'), stamp: 'x'), isNull, reason: 'not built');
      final web = Directory(p('repo/apps/perch_app/build/web/assets'))..createSync(recursive: true);
      File('${web.parent.path}${Platform.pathSeparator}index.html').writeAsStringSync('<html>');
      File('${web.path}${Platform.pathSeparator}a.txt').writeAsStringSync('a');
      final copy = a.copyBoard(p('repo'), stamp: 'abc-1')!;
      expect(copy, endsWith('board-abc-1'));
      expect(File('$copy${Platform.pathSeparator}index.html').existsSync(), isTrue);
      expect(File('$copy${Platform.pathSeparator}assets${Platform.pathSeparator}a.txt').readAsStringSync(), 'a');
      final s = windowsLauncherScript(win().withBuild(exe: r'C:\h\perch_host-abc-1.exe', commit: 'abc', board: copy));
      expect(s, contains('set "PERCH_BOARD_DIR=$copy"'));
      final older = a.copyBoard(p('repo'), stamp: 'old')!;
      a.pruneBuilds({copy});
      expect(Directory(copy).existsSync(), isTrue);
      expect(Directory(older).existsSync(), isFalse);
    });
  });
}
