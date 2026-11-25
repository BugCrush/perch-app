// How long since the owner last used this machine's keyboard or mouse. The push notifier
// stays quiet while the owner is at the machine.
//
// macOS: `HIDIdleTime` (nanoseconds) of the IOHIDSystem entry in `ioreg -c IOHIDSystem`.
// Windows: user32 `GetLastInputInfo` through a one-line PowerShell type (not run on a
// Windows machine yet: unverified there). Elsewhere, or when reading fails: null, and the
// caller falls back to its own rule.
import 'dart:convert';
import 'dart:io';

import 'console_typer.dart';

/// The time since the last keyboard or mouse input, or null when it cannot be read.
typedef InputIdleReader = Future<Duration?> Function();

/// Runs a program; returns its exit code and standard output (replaced in tests).
typedef IdleCommandRunner = Future<({int exitCode, String stdout})> Function(String executable, List<String> args);

Future<({int exitCode, String stdout})> _run(String executable, List<String> args) async {
  final r = await Process.run(executable, args, stdoutEncoding: utf8).timeout(const Duration(seconds: 10));
  return (exitCode: r.exitCode, stdout: '${r.stdout}');
}

/// The `HIDIdleTime` from `ioreg -c IOHIDSystem` output, or null.
Duration? parseHidIdleTime(String ioreg) {
  final m = RegExp(r'"HIDIdleTime"\s*=\s*(\d+)').firstMatch(ioreg);
  if (m == null) return null;
  final ns = int.tryParse(m[1]!);
  return ns == null ? null : Duration(microseconds: ns ~/ 1000);
}

/// The PowerShell command that prints the milliseconds since the last input (ASCII only:
/// Windows PowerShell 5.1 reads it as ANSI). -1 when the call fails.
const windowsIdleScript = r'''
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PerchIdle {
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  public static long IdleMs() {
    LASTINPUTINFO i = new LASTINPUTINFO();
    i.cbSize = (uint)Marshal.SizeOf(i);
    if (!GetLastInputInfo(ref i)) return -1;
    return (long)unchecked((uint)Environment.TickCount - i.dwTime);
  }
}
"@
[PerchIdle]::IdleMs()
''';

/// The milliseconds [windowsIdleScript] printed, or null.
Duration? parseWindowsIdle(String out) {
  final m = RegExp(r'^\s*(-?\d+)\s*$', multiLine: true).firstMatch(out);
  if (m == null) return null;
  final ms = int.tryParse(m[1]!);
  return ms == null || ms < 0 ? null : Duration(milliseconds: ms);
}

/// The reader for this platform; [run] replaces the process runner in tests.
InputIdleReader inputIdleReader({String? os, IdleCommandRunner? run}) {
  final platform = os ?? Platform.operatingSystem;
  final runner = run ?? _run;
  switch (platform) {
    case 'macos':
      return () async {
        try {
          final r = await runner('/usr/sbin/ioreg', ['-c', 'IOHIDSystem', '-d', '4', '-r']);
          return r.exitCode == 0 ? parseHidIdleTime(r.stdout) : null;
        } catch (_) {
          return null;
        }
      };
    case 'windows':
      return () async {
        try {
          final r = await runner('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', windowsIdleScript]);
          return r.exitCode == 0 ? parseWindowsIdle(r.stdout) : null;
        } catch (_) {
          return null;
        }
      };
    default:
      return () async => null;
  }
}

/// When Perch itself last pressed keys in a terminal. On macOS the key events Perch posts
/// count as keyboard input (they reset `HIDIdleTime`, checked live), so input at those
/// moments is not taken for the owner's.
class PerchKeyLog {
  final DateTime Function() _clock;
  PerchKeyLog({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  DateTime? _start;
  DateTime? _end;
  int _running = 0;

  /// Input this long after Perch's last key still counts as Perch's (the system may log
  /// the event a moment late).
  static const slack = Duration(seconds: 3);

  void began() {
    if (_running++ == 0) _start = _clock();
    _end = null;
  }

  void ended() {
    if (_running > 0) _running--;
    if (_running == 0) _end = _clock();
  }

  /// Whether input at [at] was Perch pressing keys.
  bool covers(DateTime at) {
    final start = _start;
    if (start == null || at.isBefore(start.subtract(const Duration(seconds: 1)))) return false;
    if (_running > 0) return true;
    final end = _end;
    return end != null && !at.isAfter(end.add(slack));
  }
}

/// A [TerminalConsole] that tells [log] whenever it presses keys or types.
class KeyLoggingConsole implements TerminalConsole {
  final TerminalConsole inner;
  final PerchKeyLog log;
  KeyLoggingConsole(this.inner, this.log);

  Future<bool> _logged(Future<bool> Function() press) async {
    log.began();
    try {
      return await press();
    } finally {
      log.ended();
    }
  }

  @override
  bool get supported => inner.supported;
  @override
  Future<bool> type(int pid, String text) => _logged(() => inner.type(pid, text));
  @override
  Future<bool> keys(int pid, String keys) => _logged(() => inner.keys(pid, keys));
  @override
  Future<bool> pressEnter(int pid) => _logged(() => inner.pressEnter(pid));
  @override
  Future<String?> screen(int pid) => inner.screen(pid);
  @override
  Future<bool> bringForward(int pid) => inner.bringForward(pid);
  @override
  Future<bool> canOperate(int pid) => inner.canOperate(pid);
}
