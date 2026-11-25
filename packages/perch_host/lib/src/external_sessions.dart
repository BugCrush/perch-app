// Sessions Perch did not start, from `claude agents --json`.
import 'dart:convert';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

import 'claude_session.dart';
import 'transcript.dart' show claudeConfigDir;

/// One entry of `claude agents --json`, with the fields Perch needs beyond the summary.
class ExternalEntry {
  final SessionSummary summary;
  final int? pid;
  final String? claudeSessionId;

  /// `interactive` (a terminal) or `background`.
  final String kind;

  const ExternalEntry({required this.summary, this.pid, this.claudeSessionId, required this.kind});

  bool get interactive => kind == 'interactive';
}

class ExternalSessions {
  final ClaudeLauncher launcher;
  ExternalSessions(this.launcher);

  final Map<String, ExternalEntry> _last = {};

  /// Runs `<claude> agents --json`; [] on any failure.
  Future<List<SessionSummary>> list() async => [for (final e in await listEntries()) e.summary];

  /// Like [list] with the extra fields. Remembers the result for [kill].
  Future<List<ExternalEntry>> listEntries() async {
    try {
      final r = await launcher.run(['agents', '--json']).timeout(const Duration(seconds: 20));
      if (r.exitCode != 0) return [];
      final entries = withRegistryStatus(parseEntries('${r.stdout}'), configDir: claudeConfigDir());
      entries.addAll(await unlistedEntries({for (final e in entries) if (e.pid != null) e.pid!}));
      _last
        ..clear()
        ..addEntries(entries.map((e) => MapEntry(e.summary.id, e)));
      return entries;
    } catch (_) {
      return [];
    }
  }

  /// Interactive `claude` processes in a terminal that Claude Code does not list (since
  /// 2.1.325 a session in a folder it does not trust yet is listed only once trusted). Each
  /// is listed as `pid:<pid>`, waiting, so its screen (the trust question) is read. macOS
  /// and Linux: `ps` and `lsof`. Windows: `tasklist`, then (only for `claude.exe` processes
  /// not listed and not looked at before) a PowerShell helper that reads each one's
  /// command line, console and working folder.
  Future<List<ExternalEntry>> unlistedEntries(Set<int> listed) async {
    if (Platform.isWindows) return _unlistedWindows(listed);
    try {
      final r = await Process.run('ps', ['-Ao', 'pid=,tty=,args=']);
      if (r.exitCode != 0) return const [];
      final out = <ExternalEntry>[];
      for (final c in unlistedClaudes('${r.stdout}', listed)) {
        final cwd = await _cwdOf(c.pid);
        if (cwd == null) continue;
        out.add(unlistedEntry(c.pid, cwd, name: c.name));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Claude Code subcommands: not an interactive session.
  static const _subcommands = {
    'agents', 'attach', 'auth', 'auto-mode', 'doctor', 'gateway', 'import', 'install', 'logs', 'mcp', 'plugin', //
    'plugins', 'purge', 'respawn', 'rm', 'setup-token', 'stop', 'kill', 'ultrareview', 'update', 'upgrade',
  };

  /// From `ps -Ao pid=,tty=,args=`: interactive `claude` processes in a terminal that are
  /// not in [listed], with the `-n` name when given.
  static List<({int pid, String? name})> unlistedClaudes(String ps, Set<int> listed) {
    final out = <({int pid, String? name})>[];
    for (final line in const LineSplitter().convert(ps)) {
      final m = RegExp(r'^\s*(\d+)\s+(\S+)\s+(.*)$').firstMatch(line);
      if (m == null) continue;
      final pid = int.parse(m[1]!);
      if (listed.contains(pid) || !m[2]!.startsWith('tty')) continue;
      // `ps` joins arguments with spaces, so a name with spaces is cut; the title comes later.
      final session = _interactiveSession(m[3]!.trim().split(RegExp(r'\s+')));
      if (session == null) continue;
      out.add((pid: pid, name: session.name));
    }
    return out;
  }

  /// When [args] (program first) start an interactive `claude` session: its `-n` name.
  /// Null for anything else (another program, a subcommand, `-p`, `--version`, …).
  static ({String? name})? _interactiveSession(List<String> args) {
    if (args.isEmpty) return null;
    var program = _lastSegment(args.first).toLowerCase();
    if (program.endsWith('.exe')) program = program.substring(0, program.length - 4);
    if (program != 'claude') return null;
    final rest = args.skip(1).toList();
    if (rest.isNotEmpty && _subcommands.contains(rest.first)) return null;
    const notInteractive = {'-p', '--print', '-v', '--version', '-h', '--help'};
    // `--type=…`: a process of the Claude desktop app (Electron), also named claude.exe.
    if (rest.any((a) => notInteractive.contains(a) || a.startsWith('--type='))) return null;
    final n = rest.indexOf('-n');
    return (name: n >= 0 && n + 1 < rest.length ? rest[n + 1] : null);
  }

  // ---------------------------------------------------------------- Windows

  /// `claude.exe` processes looked at and found not to be sessions (no console, a
  /// subcommand, …): not looked at again while they run.
  final Set<int> _rejected = {};

  Future<List<ExternalEntry>> _unlistedWindows(Set<int> listed) async {
    try {
      final t = await Process.run('tasklist', ['/FI', 'IMAGENAME eq claude.exe', '/NH', '/FO', 'CSV'])
          .timeout(const Duration(seconds: 10));
      final running = pidsFromTasklist('${t.stdout}');
      _rejected.removeWhere((p) => !running.contains(p));
      final ask = running.difference(listed).difference(_rejected).toList()
        ..remove(pid); // never the host itself
      if (ask.isEmpty) return const [];
      final r = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-EncodedCommand',
          powerShellEncodedCommand('\$pids = @(${ask.join(',')})\n$windowsProcessScript'),
        ],
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
      ).timeout(const Duration(seconds: 30));
      final found = parseWindowsProcesses('${r.stdout}');
      _rejected.addAll(found.rejected);
      return [for (final c in found.unlisted) if (!listed.contains(c.pid)) unlistedEntry(c.pid, c.cwd, name: c.name)];
    } catch (_) {
      return const [];
    }
  }

  /// The process ids in `tasklist /FO CSV /NH` output.
  static Set<int> pidsFromTasklist(String csv) => {
        for (final m in RegExp(r'^"[^"]*","(\d+)"', multiLine: true).allMatches(csv)) int.parse(m[1]!),
      };

  /// From [windowsProcessScript]'s output: interactive `claude` sessions with a console
  /// (with their `-n` name and working folder), and the processes that are not sessions or
  /// whose folder cannot be read.
  static ({List<({int pid, String? name, String cwd})> unlisted, Set<int> rejected}) parseWindowsProcesses(
      String json) {
    final unlisted = <({int pid, String? name, String cwd})>[];
    final rejected = <int>{};
    Object? v;
    try {
      v = jsonDecode(json.trim());
    } catch (_) {
      return (unlisted: unlisted, rejected: rejected);
    }
    if (v is Map) v = [v];
    if (v is! List) return (unlisted: unlisted, rejected: rejected);
    for (final p in v) {
      if (p is! Map || p['pid'] is! num) continue;
      final pid = (p['pid'] as num).toInt();
      final cmd = p['cmd'] is String ? p['cmd'] as String : '';
      final session = _interactiveSession(windowsCommandLineArgs(cmd));
      if (session == null || p['console'] != true) {
        if (cmd.isNotEmpty) rejected.add(pid);
        continue;
      }
      var cwd = p['cwd'] is String ? (p['cwd'] as String).trim() : '';
      if (cwd.isEmpty) {
        // Not readable (another user's process): asking again every few seconds would not help.
        rejected.add(pid);
        continue;
      }
      if (cwd.endsWith(r'\') && !RegExp(r'^[A-Za-z]:\\$').hasMatch(cwd)) cwd = cwd.substring(0, cwd.length - 1);
      unlisted.add((pid: pid, name: session.name, cwd: cwd));
    }
    return (unlisted: unlisted, rejected: rejected);
  }

  /// Splits a Windows command line as the C runtime does: spaces separate arguments,
  /// double quotes group, `\"` is a quote, backslashes are literal unless before a quote,
  /// `""` inside quotes is a quote.
  static List<String> windowsCommandLineArgs(String line) {
    final out = <String>[];
    final cur = StringBuffer();
    var inArg = false;
    var quoted = false;
    var i = 0;
    while (i < line.length) {
      final c = line[i];
      if (c == r'\') {
        var n = 0;
        while (i < line.length && line[i] == r'\') {
          n++;
          i++;
        }
        inArg = true;
        if (i < line.length && line[i] == '"') {
          cur.write(r'\' * (n ~/ 2));
          if (n.isOdd) {
            cur.write('"');
            i++;
          }
        } else {
          cur.write(r'\' * n);
        }
        continue;
      }
      if (c == '"') {
        inArg = true;
        if (quoted && i + 1 < line.length && line[i + 1] == '"') {
          cur.write('"');
          i += 2;
          continue;
        }
        quoted = !quoted;
        i++;
        continue;
      }
      if ((c == ' ' || c == '\t') && !quoted) {
        if (inArg) out.add(cur.toString());
        cur.clear();
        inArg = false;
        i++;
        continue;
      }
      cur.write(c);
      inArg = true;
      i++;
    }
    if (inArg) out.add(cur.toString());
    return out;
  }

  static ExternalEntry unlistedEntry(int pid, String cwd, {String? name}) => ExternalEntry(
        summary: SessionSummary(
          id: 'pid:$pid',
          name: name ?? _lastSegment(cwd),
          cwd: cwd,
          origin: SessionOrigin.external,
          state: SessionState.waitingQuestion,
          startedAtMs: DateTime.now().millisecondsSinceEpoch,
          live: true,
        ),
        pid: pid,
        kind: 'interactive',
      );

  static Future<String?> _cwdOf(int pid) async {
    try {
      final r = await Process.run('lsof', ['-a', '-p', '$pid', '-d', 'cwd', '-Fn']);
      for (final l in const LineSplitter().convert('${r.stdout}')) {
        if (l.startsWith('n/')) return l.substring(1);
      }
    } catch (_) {}
    return null;
  }

  static List<SessionSummary> parse(String json) => [for (final e in parseEntries(json)) e.summary];

  static List<ExternalEntry> parseEntries(String json) {
    try {
      final v = jsonDecode(json);
      if (v is! List) return [];
      return [
        for (final item in v)
          if (item is Map) ?entryFromJson(item.cast<String, dynamic>())
      ];
    } catch (_) {
      return [];
    }
  }

  static ExternalEntry? entryFromJson(Map<String, dynamic> j) {
    try {
      final pid = j['pid'] is num ? (j['pid'] as num).toInt() : null;
      final sessionId = j['sessionId'] is String && (j['sessionId'] as String).isNotEmpty ? j['sessionId'] as String : null;
      final shortId = j['id'] is String ? j['id'] as String : null;
      final id = sessionId ?? shortId ?? (pid != null ? 'pid:$pid' : null);
      if (id == null) return null;
      final cwd = j['cwd'] is String ? j['cwd'] as String : '';
      final name = j['name'] is String && (j['name'] as String).isNotEmpty ? j['name'] as String : _lastSegment(cwd);
      final startedAt = j['startedAt'] is num ? (j['startedAt'] as num).toInt() : 0;
      final kind = j['kind'] is String ? j['kind'] as String : (pid != null ? 'interactive' : 'background');
      var state = _state(j);
      // Claude Code keeps listing old background sessions whose process is long gone (often
      // as "blocked"). Only a live process can need the owner.
      final live = pid != null || (kind == 'background' && state == SessionState.working);
      String? reason;
      if (!live && state == SessionState.blocked) {
        state = SessionState.idle;
        reason = 'Not running';
      }
      return ExternalEntry(
        summary: SessionSummary(
          id: id,
          name: name,
          cwd: cwd,
          origin: SessionOrigin.external,
          state: state,
          startedAtMs: startedAt,
          reason: reason,
          live: live,
        ),
        pid: pid,
        claudeSessionId: sessionId,
        kind: kind,
      );
    } catch (_) {
      return null;
    }
  }

  /// Claude Code lists a session as `busy` while background shells it started still run,
  /// although its turn ended; its own registry entry (`<configDir>/sessions/<pid>.json`)
  /// then says `shell`. Such a session is idle (Claude is not working).
  static List<ExternalEntry> withRegistryStatus(List<ExternalEntry> entries, {required String configDir}) => [
        for (final e in entries)
          if (e.pid != null && e.summary.state == SessionState.working && _registryStatus(configDir, e.pid!) == 'shell')
            ExternalEntry(
                summary: e.summary.copyWith(state: SessionState.idle, reason: 'Background shells running'),
                pid: e.pid,
                claudeSessionId: e.claudeSessionId,
                kind: e.kind)
          else
            e
      ];

  static String? _registryStatus(String configDir, int pid) {
    try {
      final f = File('$configDir${Platform.pathSeparator}sessions${Platform.pathSeparator}$pid.json');
      final j = jsonDecode(f.readAsStringSync());
      return j is Map && j['status'] is String ? j['status'] as String : null;
    } catch (_) {
      return null;
    }
  }

  static SessionState _state(Map<String, dynamic> j) {
    final status = j['status'];
    final state = j['state'];
    final waitingFor = j['waitingFor'];
    if (waitingFor == 'permission prompt') return SessionState.waitingPermission;
    if (waitingFor == 'input needed') return SessionState.waitingQuestion;
    if (status == 'busy' || state == 'working') return SessionState.working;
    switch (state) {
      case 'blocked':
        return SessionState.blocked;
      case 'done':
        return SessionState.idle;
      case 'failed':
        return SessionState.finished;
      case 'stopped':
        return SessionState.stopped;
    }
    if (status == 'idle') return SessionState.idle;
    if (status == 'waiting') return SessionState.waitingQuestion;
    return SessionState.idle;
  }

  static String _lastSegment(String path) {
    final parts = path.split(RegExp(r'[\\/]+')).where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  /// Kills the session's process by pid; no-op when the entry has none.
  Future<void> kill(SessionSummary s) async {
    final pid = pidOf(s);
    if (pid != null) await killPid(pid);
  }

  int? pidOf(SessionSummary s) {
    final known = _last[s.id]?.pid;
    if (known != null) return known;
    if (s.id.startsWith('pid:')) return int.tryParse(s.id.substring(4));
    return null;
  }

  /// `taskkill /PID <pid> /T /F` on Windows, `kill <pid>` elsewhere.
  Future<void> killPid(int pid) async {
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
      } else {
        await Process.run('kill', ['$pid']);
      }
    } catch (_) {}
  }

  /// Whether a process with this pid still runs.
  Future<bool> pidAlive(int pid) async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV']);
        return '${r.stdout}'.contains('"$pid"');
      }
      final r = await Process.run('kill', ['-0', '$pid']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}

/// [script] as the argument of `powershell.exe -EncodedCommand` (UTF-16LE, base64), so no
/// quote in it is changed on the way through the command line.
String powerShellEncodedCommand(String script) {
  final bytes = <int>[];
  for (final unit in script.codeUnits) {
    bytes
      ..add(unit & 0xff)
      ..add(unit >> 8);
  }
  return base64Encode(bytes);
}

/// Windows: for each process id in `$pids` (set in a line before it), its command line
/// (CIM), whether it has a console (`AttachConsole` succeeds; the Claude desktop app, also a
/// `claude.exe`, has none) and its working folder (read from its process parameters, as
/// Process Explorer does; the same user's processes only). Prints one JSON array as UTF-8.
/// ASCII only: Windows PowerShell 5.1 reads scripts as ANSI.
const windowsProcessScript = r'''
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PerchProc {
  [StructLayout(LayoutKind.Sequential)]
  struct PBI { public IntPtr R1; public IntPtr Peb; public IntPtr R2a; public IntPtr R2b; public IntPtr Id; public IntPtr R3; }
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PBI pbi, int len, out int ret);
  [DllImport("kernel32.dll")] static extern bool FreeConsole();
  [DllImport("kernel32.dll")] static extern bool AttachConsole(uint pid);
  static byte[] Read(IntPtr h, long addr, int n) {
    var b = new byte[n]; IntPtr got;
    if (!ReadProcessMemory(h, new IntPtr(addr), b, new IntPtr(n), out got) || got.ToInt64() != n) return null;
    return b;
  }
  public static string Cwd(int pid) {
    if (IntPtr.Size != 8) return null;
    IntPtr h = OpenProcess(0x0410, false, pid);
    if (h == IntPtr.Zero) return null;
    try {
      var pbi = new PBI(); int ret;
      if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out ret) != 0) return null;
      var pp = Read(h, pbi.Peb.ToInt64() + 0x20, 8);
      if (pp == null) return null;
      var us = Read(h, BitConverter.ToInt64(pp, 0) + 0x38, 16);
      if (us == null) return null;
      int len = BitConverter.ToUInt16(us, 0);
      if (len == 0) return null;
      var s = Read(h, BitConverter.ToInt64(us, 8), len);
      return s == null ? null : Encoding.Unicode.GetString(s);
    } finally { CloseHandle(h); }
  }
  public static bool HasConsole(uint pid) {
    FreeConsole();
    bool ok = AttachConsole(pid);
    FreeConsole();
    return ok;
  }
}
'@
$out = @()
foreach ($p in $pids) {
  $cmd = $null; $cwd = $null; $con = $false
  try { $cmd = (Get-CimInstance Win32_Process -Filter ('ProcessId=' + $p)).CommandLine } catch {}
  try { $cwd = [PerchProc]::Cwd([int]$p) } catch {}
  try { $con = [PerchProc]::HasConsole([uint32]$p) } catch {}
  $out += New-Object PSObject -Property @{ pid = [int]$p; cmd = $cmd; cwd = $cwd; console = $con }
}
$json = ConvertTo-Json -InputObject @($out) -Compress
$bytes = [Text.Encoding]::UTF8.GetBytes($json + "`n")
$stream = [Console]::OpenStandardOutput()
$stream.Write($bytes, 0, $bytes.Length)
$stream.Flush()
''';
