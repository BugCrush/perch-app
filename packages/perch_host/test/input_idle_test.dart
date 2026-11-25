import 'package:perch_host/src/input_idle.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  test('HIDIdleTime is read from ioreg (nanoseconds)', () {
    const out = '''
+-o IOHIDSystem  <class IOHIDSystem, id 0x100000abc, registered, matched, active, busy 0 (0 ms), retain 30>
    {
      "HIDIdleTime" = 213730377583
      "HIDParameters" = {"HIDClickTime"=500000000}
    }
''';
    expect(parseHidIdleTime(out), const Duration(microseconds: 213730377));
    expect(parseHidIdleTime('nothing here'), isNull);
  });

  test('the Windows script prints milliseconds; -1 or junk is unreadable', () {
    expect(parseWindowsIdle('4200\r\n'), const Duration(milliseconds: 4200));
    expect(parseWindowsIdle('-1\r\n'), isNull);
    expect(parseWindowsIdle('Add-Type : error'), isNull);
  });

  test('the Windows script stays plain ASCII (PowerShell 5.1 reads it as ANSI)', () {
    expect(windowsIdleScript.codeUnits.every((c) => c < 128), isTrue);
  });

  test('each platform runs its own command; failures read as unknown', () async {
    final calls = <String>[];
    Future<({int exitCode, String stdout})> fake(String exe, List<String> args) async {
      calls.add(exe);
      return exe.endsWith('ioreg') ? (exitCode: 0, stdout: '"HIDIdleTime" = 5000000000') : (exitCode: 0, stdout: '61000');
    }

    expect(await inputIdleReader(os: 'macos', run: fake)(), const Duration(seconds: 5));
    expect(await inputIdleReader(os: 'windows', run: fake)(), const Duration(seconds: 61));
    expect(await inputIdleReader(os: 'linux', run: fake)(), isNull);
    expect(calls, ['/usr/sbin/ioreg', 'powershell.exe']);

    Future<({int exitCode, String stdout})> failing(String exe, List<String> args) async => throw Exception('no');
    expect(await inputIdleReader(os: 'macos', run: failing)(), isNull);
    Future<({int exitCode, String stdout})> exit1(String exe, List<String> args) async => (exitCode: 1, stdout: '');
    expect(await inputIdleReader(os: 'windows', run: exit1)(), isNull);
  });

  test('the real reader on this machine returns a duration on macOS', () async {
    final idle = await inputIdleReader()();
    expect(idle == null || idle >= Duration.zero, isTrue);
  });

  test('Perch\'s own key presses are logged, with a little slack after', () async {
    var now = DateTime(2026, 11, 15, 1);
    final log = PerchKeyLog(clock: () => now);
    expect(log.covers(now), isFalse);
    final console = KeyLoggingConsole(FakeConsoleTyper(), log);
    final typing = console.type(1, 'hi');
    expect(log.covers(now), isTrue, reason: 'while typing');
    await typing;
    now = now.add(const Duration(seconds: 2));
    expect(log.covers(now), isTrue);
    expect(log.covers(now.add(const Duration(seconds: 5))), isFalse);
    expect(log.covers(now.subtract(const Duration(minutes: 1))), isFalse, reason: 'input before Perch typed');
  });
}
