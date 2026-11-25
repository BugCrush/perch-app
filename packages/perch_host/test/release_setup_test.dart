// `perch_host setup`, run by the Perch plugin's SessionStart step from a downloaded release
// (<state>/releases/<version>/perch_host): turns autostart on for that build, starts it when
// no host runs, asks a running host to switch when it is idle, keeps the previous release,
// and leaves a machine that runs Perch from its repo alone. Only temporary folders and a
// fake process runner are used.
import 'dart:io';

import 'package:perch_host/src/autostart.dart';
import 'package:perch_host/src/release_setup.dart';
import 'package:test/test.dart';

final native = Platform.isWindows ? AutostartPlatform.windows : AutostartPlatform.macos;
final sep = Platform.pathSeparator;
final ext = Platform.isWindows ? '.exe' : '';

class FakeRunner {
  final calls = <List<String>>[];
  Future<ProcessResult> call(String exe, List<String> args) async {
    calls.add([exe, ...args]);
    return ProcessResult(0, 0, exe == 'id' ? '501\n' : '', '');
  }

  bool ran(String exe, String firstArg) => calls.any((c) => c[0] == exe && c.length > 1 && c[1] == firstArg);
}

void main() {
  late Directory state;
  late FakeRunner runner;
  late Autostart autostart;

  String release(String v) {
    final d = Directory('${state.path}${sep}releases$sep$v')..createSync(recursive: true);
    File('${d.path}${sep}perch_host$ext').writeAsStringSync('exe');
    File('${d.path}${sep}board${sep}index.html')
      ..createSync(recursive: true)
      ..writeAsStringSync('<html></html>');
    return '${d.path}${sep}perch_host$ext';
  }

  setUp(() {
    state = Directory.systemTemp.createTempSync('perch_setup_');
    runner = FakeRunner();
    autostart = Autostart(
        platform: native,
        stateDir: state.path,
        run: runner.call,
        launchAgentsDir: '${state.path}${sep}LaunchAgents',
        userId: r'PC\someone');
  });
  tearDown(() {
    try {
      state.deleteSync(recursive: true);
    } catch (_) {}
  });

  ReleaseSetup setupFor(String exe, String version,
          {bool listening = false, String? Function(String action)? control}) =>
      ReleaseSetup(
        autostart: autostart,
        exe: exe,
        version: version,
        defaultPort: 8787,
        environment: const {},
        listening: (_) async => listening,
        control: (port, action) async => control?.call(action),
      );

  test('a_first_install_turns_autostart_on_for_the_release_and_starts_it', () async {
    final exe = release('0.3.0');
    final r = await setupFor(exe, '0.3.0').run();
    expect(r.outcome, SetupOutcome.started);
    final rec = autostart.load()!;
    expect(rec.setup.exe, exe);
    expect(rec.setup.release, '0.3.0');
    expect(rec.setup.port, 8787);
    expect(rec.setup.board, '${File(exe).parent.path}${sep}board');
    expect(Platform.isWindows ? runner.ran('schtasks', '/Run') : runner.ran('launchctl', 'kickstart'), isTrue);
    expect(File('${state.path}${sep}releases${sep}0.3.0$sep$releaseInstalledMarker').existsSync(), isTrue);
    expect(r.lines.join('\n'), contains('/perch'));
  });

  test('a_new_release_with_a_host_running_asks_it_to_switch_when_idle_and_keeps_the_previous', () async {
    final first = release('0.3.0');
    await setupFor(first, '0.3.0').run();
    release('0.2.9'); // an older one: pruned
    final next = release('0.3.1');
    final asked = <String>[];
    final r = await setupFor(next, '0.3.1', listening: true, control: (a) {
      asked.add(a);
      return 'OK';
    }).run();
    expect(r.outcome, SetupOutcome.switching);
    expect(asked, ['switch-when-idle']);
    expect(autostart.load()!.setup.exe, next);
    expect(Directory('${state.path}${sep}releases${sep}0.3.0').existsSync(), isTrue, reason: 'kept for rollback');
    expect(Directory('${state.path}${sep}releases${sep}0.2.9').existsSync(), isFalse);
  });

  test('a_running_host_that_cannot_switch_changes_at_the_next_login', () async {
    final exe = release('0.3.0');
    final r = await setupFor(exe, '0.3.0', listening: true, control: (_) => null).run();
    expect(r.outcome, SetupOutcome.atNextLogin);
    expect(autostart.load()!.setup.release, '0.3.0');
  });

  test('a_machine_running_perch_from_its_repo_is_left_alone', () async {
    final repoSetup = AutostartSetup(
        platform: native,
        port: 8787,
        repo: '${state.path}${sep}repo',
        dart: 'dart',
        stateDir: state.path,
        exe: '${state.path}${sep}host${sep}perch_host-abc$ext',
        commit: 'abc');
    await autostart.enable(repoSetup);
    runner.calls.clear();
    final exe = release('0.3.0');
    final r = await setupFor(exe, '0.3.0').run();
    expect(r.outcome, SetupOutcome.developer);
    expect(autostart.load()!.setup.exe, repoSetup.exe);
    expect(runner.calls, isEmpty);
    expect(File('${state.path}${sep}releases${sep}0.3.0$sep$releaseInstalledMarker').existsSync(), isTrue,
        reason: 'the plugin does not download it again every session');
  });

  test('the_same_release_again_only_makes_sure_it_runs', () async {
    final exe = release('0.3.0');
    await setupFor(exe, '0.3.0').run();
    final r = await setupFor(exe, '0.3.0', listening: true, control: (_) => fail('no switch')).run();
    expect(r.outcome, SetupOutcome.current);
  });

  test('a_test_host_never_takes_the_main_hosts_task_and_only_release_builds_switch', () async {
    expect(releaseAutostartTitle({}), 'Perch host');
    expect(releaseAutostartTitle({'PERCH_STATE_DIR': state.path}), 'Perch host (test)');
    expect(releaseAutostartTitle({'PERCH_STATE_DIR': state.path, 'PERCH_AUTOSTART_TITLE': 'Perch host (lab)'}),
        'Perch host (lab)');
    final exe = release('0.3.0');
    await ReleaseSetup(
      autostart: autostart,
      exe: exe,
      version: '0.3.0',
      environment: {'PERCH_STATE_DIR': state.path},
      listening: (_) async => false,
      control: (_, _) async => null,
    ).run();
    expect(autostart.load()!.setup.title, 'Perch host (test)');
    expect(isReleaseBuild(exe, state.path), isTrue);
    expect(isReleaseBuild('${state.path}${sep}host${sep}perch_host-abc$ext', state.path), isFalse);
  });

  test('the_setup_records_round_trip_the_release', () {
    final s = AutostartSetup(
        platform: native, port: 8787, repo: 'r', dart: '', stateDir: 's', exe: 'e', release: '0.3.0');
    expect(AutostartSetup.fromJson(s.toJson()).release, '0.3.0');
    expect(s.withBuild(exe: 'x', commit: null).release, '0.3.0');
  });
}
