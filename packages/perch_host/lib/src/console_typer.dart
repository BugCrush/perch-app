// Operates the console of a terminal Claude Code session from outside: types messages,
// presses keys, and reads the visible screen. The session stays in its terminal; nothing
// is killed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'state_dir.dart';
import 'mac_console.dart';
import 'mac_helper.dart';
import 'tmux_console.dart';

abstract class TerminalConsole {
  /// Whether this machine can operate another process's console at all.
  bool get supported;

  /// Types [text] into the console of process [pid] and submits it (Enter). True on success.
  Future<bool> type(int pid, String text);

  /// Presses the characters of [keys] one by one, without Enter. Special keys are the
  /// private-use characters in [ConsoleKeys].
  Future<bool> keys(int pid, String keys);

  /// Presses Enter.
  Future<bool> pressEnter(int pid);

  /// The visible text of the console (one line per row, empty rows left out), or null.
  Future<String?> screen(int pid);

  /// Makes the session the one that receives keys and whose screen can be read, before a
  /// card is answered (macOS Warp: switches to its tab). False when that is not possible.
  Future<bool> bringForward(int pid);

  /// Whether this console can operate the session with process id [pid] at all (macOS:
  /// it runs in Terminal.app, Warp or tmux). False for terminals with no adapter (VS Code,
  /// Cursor, iTerm2, …): their messages go to the session's inbox instead.
  Future<bool> canOperate(int pid);
}

/// Older name, kept for existing call sites.
typedef ConsoleTyper = TerminalConsole;

/// Special keys for [TerminalConsole.keys]: U+E000 plus the Windows virtual-key code.
abstract final class ConsoleKeys {
  static final up = String.fromCharCode(0xE000 + 0x26);
  static final down = String.fromCharCode(0xE000 + 0x28);
  static final left = String.fromCharCode(0xE000 + 0x25);
  static final right = String.fromCharCode(0xE000 + 0x27);
  static final escape = String.fromCharCode(0xE000 + 0x1B);
  static final tab = String.fromCharCode(0xE000 + 0x09);
  static final enter = String.fromCharCode(0xE000 + 0x0D);
}

/// Runs [executable] with [args] and returns what it printed on stdout.
typedef ScriptRunner = Future<String> Function(String executable, List<String> args);

/// Windows: a helper PowerShell process attaches to the target's console
/// (`AttachConsole`), writes key events to `CONIN$` (`WriteConsoleInput`) or reads
/// `CONOUT$` (`ReadConsoleOutputCharacter`). The attach happens in the helper, never in the
/// host, so the host keeps its own console.
class WindowsTerminalConsole implements TerminalConsole {
  final String stateDir;
  final ScriptRunner _run;
  String? _scriptPath;

  WindowsTerminalConsole({required this.stateDir, ScriptRunner? run}) : _run = run ?? _runHelper;

  static const scriptName = 'perch_console.ps1';

  @override
  bool get supported => Platform.isWindows;

  /// UTF-16LE bytes in base64, so quotes, line breaks and non-ASCII survive the command line.
  /// Windows line breaks become a single `\n`.
  static String encodeText(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final bytes = <int>[];
    for (final unit in normalized.codeUnits) {
      bytes
        ..add(unit & 0xff)
        ..add(unit >> 8);
    }
    return base64Encode(bytes);
  }

  static List<String> argumentsFor(String scriptPath, String action, int pid, [String text = '']) => [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        // No -WindowStyle Hidden: the helper shares the host's console, and that flag
        // would hide the host's own window.
        '-File',
        scriptPath,
        '-Action',
        action,
        '-TargetPid',
        '$pid',
        '-TextB64',
        text.isEmpty ? '' : encodeText(text),
      ];

  /// The helper prints `ok screen` on the first line, then the screen; anything else is a failure.
  static String? parseScreenOutput(String out) {
    final nl = out.indexOf('\n');
    final first = (nl < 0 ? out : out.substring(0, nl)).trim();
    if (first != 'ok screen') return null;
    return nl < 0 ? '' : out.substring(nl + 1);
  }

  String _ensureScript() {
    final existing = _scriptPath;
    if (existing != null && File(existing).existsSync()) return existing;
    final dir = Directory(stateDir)..createSync(recursive: true);
    final f = File('${dir.path}${Platform.pathSeparator}$scriptName');
    if (!f.existsSync() || f.readAsStringSync() != consoleScript) f.writeAsStringSync(consoleScript);
    return _scriptPath = f.path;
  }

  Future<String?> _call(String action, int pid, [String text = '']) async {
    if (!supported) return null;
    try {
      return await _run('powershell.exe', argumentsFor(_ensureScript(), action, pid, text));
    } catch (_) {
      return null;
    }
  }

  static bool _ok(String? out) => out != null && out.trimLeft().startsWith('ok');

  @override
  Future<bool> type(int pid, String text) async => _ok(await _call('type', pid, text));

  @override
  Future<bool> keys(int pid, String keys) async => _ok(await _call('keys', pid, keys));

  @override
  Future<bool> pressEnter(int pid) async => _ok(await _call('enter', pid));

  @override
  Future<bool> bringForward(int pid) async => supported;

  @override
  Future<bool> canOperate(int pid) async => supported;

  @override
  Future<String?> screen(int pid) async {
    final out = await _call('screen', pid);
    return out == null ? null : parseScreenOutput(out);
  }

  /// Runs the helper and collects its stdout (UTF-8). It starts on the host's console (a
  /// detached PowerShell prints nothing) and leaves it at once for the target's console.
  static Future<String> _runHelper(String executable, List<String> args) async {
    final p = await Process.start(executable, args);
    unawaited(p.stdin.close().catchError((Object _) {}));
    unawaited(p.stderr.drain<void>().catchError((Object _) {}));
    try {
      return await p.stdout.transform(const Utf8Decoder(allowMalformed: true)).join().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      p.kill();
      return 'error timeout';
    }
  }
}

/// Older name, kept for existing call sites.
typedef WindowsConsoleTyper = WindowsTerminalConsole;

/// Platforms without a console mechanism yet (macOS, Linux).
class UnsupportedTerminalConsole implements TerminalConsole {
  @override
  bool get supported => false;

  @override
  Future<bool> type(int pid, String text) async => false;

  @override
  Future<bool> keys(int pid, String keys) async => false;

  @override
  Future<bool> pressEnter(int pid) async => false;

  @override
  Future<String?> screen(int pid) async => null;

  @override
  Future<bool> bringForward(int pid) async => false;

  @override
  Future<bool> canOperate(int pid) async => false;
}

/// Older name, kept for existing call sites.
typedef UnsupportedConsoleTyper = UnsupportedTerminalConsole;

/// Windows: the console helper. macOS: Terminal.app and Warp (plus tmux when installed).
/// Linux: tmux when installed, else none.
TerminalConsole defaultTerminalConsole() {
  if (Platform.isWindows) return WindowsTerminalConsole(stateDir: stateDirectory());
  final tmuxBin = TmuxTerminalConsole.findTmux();
  final tmux = tmuxBin == null ? null : TmuxTerminalConsole(tmux: tmuxBin, socketDirs: TmuxTerminalConsole.defaultSocketDirs());
  if (Platform.isMacOS) {
    return MacTerminalConsole(
        helper: MacHelper(binDir: '${stateDirectory()}/bin'),
        tmux: tmux,
        log: (line) => stdout.writeln('${DateTime.now().toIso8601String().substring(11, 23)}  $line'));
  }
  return tmux ?? UnsupportedTerminalConsole();
}

/// Older name, kept for existing call sites.
TerminalConsole defaultConsoleTyper() => defaultTerminalConsole();

/// The helper script (based on experiments/phase1/inject.ps1 and screen.ps1).
/// `-Action type`: the text, then Enter. A line break inside the text is typed as a
/// backslash followed by Enter, which Claude Code's prompt takes as a new line; only the
/// final Enter submits. `-Action keys`: the characters only; U+E000 + a virtual-key code is
/// pressed as that key. `-Action enter`: Enter. Each key is a key-down and key-up record.
/// Prints `ok ...` or `error ...`. `-Action screen` prints `ok screen`, then the visible
/// rows of the console, as UTF-8 bytes.
const consoleScript = r'''
param([string]$Action = 'type', [int]$TargetPid, [string]$TextB64 = '')
try {
  $text = ''
  if ($TextB64) { $text = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($TextB64)) }
  Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PerchConsole {
  [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
  public struct INPUT_RECORD {
    [FieldOffset(0)] public ushort EventType;
    [FieldOffset(4)] public int bKeyDown;
    [FieldOffset(8)] public ushort wRepeatCount;
    [FieldOffset(10)] public ushort wVirtualKeyCode;
    [FieldOffset(12)] public ushort wVirtualScanCode;
    [FieldOffset(14)] public char UnicodeChar;
    [FieldOffset(16)] public uint dwControlKeyState;
  }
  [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X; public short Y; }
  [StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct INFO { public COORD Size; public COORD Cursor; public ushort Attr; public SMALL_RECT Window; public COORD Max; }
  [DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint pid);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool WriteConsoleInput(IntPtr h, INPUT_RECORD[] buf, uint len, out uint written);
  [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleScreenBufferInfo(IntPtr h, out INFO info);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool ReadConsoleOutputCharacter(IntPtr h, StringBuilder sb, uint len, COORD at, out uint read);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);

  static INPUT_RECORD Key(char c, ushort vk, bool down) {
    var r = new INPUT_RECORD();
    r.EventType = 1; r.bKeyDown = down ? 1 : 0; r.wRepeatCount = 1; r.wVirtualKeyCode = vk; r.UnicodeChar = c;
    return r;
  }

  static bool Press(IntPtr h, char c, ushort vk, ref uint total) {
    uint n;
    var recs = new INPUT_RECORD[] { Key(c, vk, true), Key(c, vk, false) };
    if (!WriteConsoleInput(h, recs, 2, out n)) return false;
    total += n;
    return true;
  }

  // U+E000 + virtual-key code: that key (Enter, Esc, Tab and Backspace also carry their character).
  static bool PressChar(IntPtr h, char c, ref uint total) {
    if (c >= 0xE000 && c < 0xE100) {
      ushort vk = (ushort)(c - 0xE000);
      char uc = (vk == 0x0D || vk == 0x1B || vk == 0x09 || vk == 0x08) ? (char)vk : '\0';
      return Press(h, uc, vk, ref total);
    }
    return Press(h, c, 0, ref total);
  }

  static IntPtr Open(uint pid, string name, out string error) {
    error = null;
    FreeConsole();
    if (!AttachConsole(pid)) { error = "error AttachConsole " + Marshal.GetLastWin32Error(); return IntPtr.Zero; }
    IntPtr h = CreateFile(name, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    if (h == new IntPtr(-1)) { error = "error " + name + " " + Marshal.GetLastWin32Error(); FreeConsole(); return IntPtr.Zero; }
    return h;
  }

  public static string Send(uint pid, string action, string text) {
    string error;
    IntPtr h = Open(pid, "CONIN$", out error);
    if (error != null) return error;
    uint total = 0;
    try {
      if (action == "enter") {
        if (!Press(h, '\r', 0x0D, ref total)) return "error WriteConsoleInput " + Marshal.GetLastWin32Error();
        return "ok records=" + total;
      }
      if (action == "keys") {
        foreach (char c in text) {
          if (!PressChar(h, c, ref total)) return "error WriteConsoleInput " + Marshal.GetLastWin32Error();
          System.Threading.Thread.Sleep(30);
        }
        return "ok records=" + total;
      }
      string[] lines = text.Split('\n');
      for (int i = 0; i < lines.Length; i++) {
        foreach (char c in lines[i]) {
          if (!Press(h, c, 0, ref total)) return "error WriteConsoleInput " + Marshal.GetLastWin32Error();
        }
        if (i < lines.Length - 1) {
          System.Threading.Thread.Sleep(100);
          if (!Press(h, '\\', 0, ref total)) return "error WriteConsoleInput " + Marshal.GetLastWin32Error();
          System.Threading.Thread.Sleep(100);
          if (!Press(h, '\r', 0x0D, ref total)) return "error WriteConsoleInput " + Marshal.GetLastWin32Error();
          System.Threading.Thread.Sleep(100);
        }
      }
      System.Threading.Thread.Sleep(300);
      if (!Press(h, '\r', 0x0D, ref total)) return "error WriteConsoleInput " + Marshal.GetLastWin32Error();
      return "ok records=" + total;
    } finally {
      CloseHandle(h);
      FreeConsole();
    }
  }

  public static string Screen(uint pid) {
    string error;
    IntPtr h = Open(pid, "CONOUT$", out error);
    if (error != null) return error;
    try {
      INFO i;
      if (!GetConsoleScreenBufferInfo(h, out i)) return "error info " + Marshal.GetLastWin32Error();
      var all = new StringBuilder("ok screen\n");
      for (short y = i.Window.Top; y <= i.Window.Bottom; y++) {
        var sb = new StringBuilder(i.Size.X + 1); uint n;
        ReadConsoleOutputCharacter(h, sb, (uint)i.Size.X, new COORD { X = 0, Y = y }, out n);
        var line = sb.ToString(0, (int)Math.Min(n, (uint)sb.Length)).TrimEnd();
        if (line.Length > 0) { all.Append(line); all.Append('\n'); }
      }
      return all.ToString();
    } finally {
      CloseHandle(h);
      FreeConsole();
    }
  }
}
"@
  if ($Action -eq 'screen') {
    $result = [PerchConsole]::Screen([uint32]$TargetPid)
  } else {
    $result = [PerchConsole]::Send([uint32]$TargetPid, $Action, $text)
  }
  # Raw UTF-8 bytes: changing the console's output code page would change the host's too.
  $bytes = [Text.Encoding]::UTF8.GetBytes($result + "`n")
  $out = [Console]::OpenStandardOutput()
  $out.Write($bytes, 0, $bytes.Length)
  $out.Flush()
} catch {
  Write-Output ("error " + $_.Exception.Message)
}
''';
