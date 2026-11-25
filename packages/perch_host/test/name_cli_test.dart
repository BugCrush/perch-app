import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_state.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('perch_ncli_'));
  tearDown(() {
    try {
      home.deleteSync(recursive: true);
    } catch (_) {}
  });

  String stateDir() =>
      Platform.isWindows ? '${home.path}${Platform.pathSeparator}perch' : '${home.path}/.perch';

  // A port nothing listens on: no running host is told.
  Future<ProcessResult> run(List<String> args) => Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/perch_host.dart', 'name', ...args, '--port', '1'],
        environment: {'APPDATA': home.path, 'HOME': home.path},
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

  test('name_set_show_clear_on_a_temporary_state_dir', () async {
    var r = await run(['set', '  Studio desk  ']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect('${r.stdout}', contains('"Studio desk"'));
    expect(HostState.load(stateDir()).machineName, 'Studio desk');

    r = await run(['show']);
    expect(r.exitCode, 0);
    expect('${r.stdout}', contains('Studio desk'));

    r = await run(['set', '   ']);
    expect(r.exitCode, 64);
    expect(HostState.load(stateDir()).machineName, 'Studio desk');

    r = await run(['clear']);
    expect(r.exitCode, 0);
    expect(HostState.load(stateDir()).machineName, isNull);
    r = await run(['show']);
    expect('${r.stdout}', contains(Platform.localHostname));
  }, timeout: const Timeout(Duration(minutes: 4)));
}
