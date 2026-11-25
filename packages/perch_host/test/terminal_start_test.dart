import 'dart:io';

import 'package:perch_host/src/console_typer.dart';
import 'package:perch_host/src/external_sessions.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/terminal_window.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final sep = Platform.pathSeparator;

String screen(String name) => File('test${sep}fixtures${sep}screens$sep$name').readAsStringSync();

void main() {
  late Directory tmp;
  late Directory work;
  late FakeExternalSessions external;
  late FakeConsoleTyper console;
  late List<TerminalLaunch> launches;
  late SessionManager manager;

  /// What the fake window does when opened: adds a new terminal entry (or nothing).
  late void Function(TerminalLaunch) onLaunch;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_ts_');
    work = Directory('${tmp.path}${sep}work')..createSync();
    external = FakeExternalSessions();
    console = FakeConsoleTyper(currentScreen: screen('idle_after_deny.txt'));
    launches = [];
    onLaunch = (l) => external.entries.add(external.entry(
        pid: 7777, sessionId: 'aaaaaaaa-0000-4000-8000-000000000001', cwd: work.path, name: l.args.contains('-n') ? l.args[l.args.indexOf('-n') + 1] : 'work-1a'));
    manager = SessionManager(
      launcher: fakeLauncher(),
      external: external,
      typer: console,
      claudeConfigDir: '${tmp.path}${sep}config',
      openWindow: (l) async {
        launches.add(l);
        onLaunch(l);
      },
      terminalStartTimeout: const Duration(milliseconds: 600),
      terminalPoll: const Duration(milliseconds: 20),
    );
  });

  tearDown(() async {
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('start_opens_terminal_then_types_first_instruction', () async {
    // A terminal already open in the same folder is not the new one.
    external.entries = [external.entry(pid: 1111, sessionId: 'bbbbbbbb-0000-4000-8000-000000000002', cwd: work.path)];
    final s = await manager.start(cwd: work.path, prompt: 'Say hi', name: 'Greeting', model: 'haiku');
    expect(launches, hasLength(1));
    final l = launches.single;
    expect(l.cwd, work.path);
    expect(l.args.skip(l.args.length - 4), ['-n', 'Greeting', '--model', 'haiku']);
    expect(l.environment.keys, isNot(contains('CLAUDECODE')));
    expect(console.calls.single, (pid: 7777, text: 'Say hi'));
    expect(s.id, 'aaaaaaaa-0000-4000-8000-000000000001');
    expect(s.origin, SessionOrigin.external);
    expect(s.name, 'Greeting');
    final listed = await manager.list();
    expect(listed.where((x) => x.id == s.id), hasLength(1));
    expect(listed.where((x) => x.origin == SessionOrigin.perch), isEmpty);
  });

  test('a_folder_spelled_with_other_capitals_finds_the_new_session', () async {
    // APFS (macOS) and NTFS ignore case: the phone may send ~/Desktop/Work/x while Claude
    // Code reports ~/Desktop/work/x for the same folder.
    if (!Platform.isMacOS && !Platform.isWindows) return markTestSkipped('case-insensitive disks only');
    final asked = '${tmp.path}${sep}WORK';
    expect(Directory(asked).existsSync(), isTrue, reason: 'the disk ignores case');
    final s = await manager.start(cwd: asked, prompt: 'Say hi', name: 'Greeting');
    expect(s.state, isNot(SessionState.blocked), reason: s.reason);
    expect(s.id, 'aaaaaaaa-0000-4000-8000-000000000001');
    expect(s.origin, SessionOrigin.external);
    expect(console.calls.single, (pid: 7777, text: 'Say hi'));
  });

  test('start_reports_trust_dialog_as_blocked', () async {
    console.currentScreen = screen('trust.txt');
    final s = await manager.start(cwd: work.path, prompt: 'Say hi');
    expect(s.state, SessionState.blocked);
    expect(s.reason, 'Trust this folder on the machine to continue');
    expect(s.origin, SessionOrigin.external);
    expect(console.calls, isEmpty);
    expect(launches.single.args, isNot(contains('-n')));
  });

  test('a_session_claude_code_lists_only_after_trust_keeps_its_first_id', () async {
    // Claude Code 2.1.325 lists a session in an untrusted folder only once it is trusted;
    // until then the host lists the process itself, as pid:<pid>.
    onLaunch = (_) => external.entries.add(ExternalSessions.unlistedEntry(7777, work.path, name: 'work'));
    console.currentScreen = screen('trust.txt');
    final s = await manager.start(cwd: work.path, prompt: 'Say hi');
    expect(s.id, 'pid:7777');
    expect(s.state, SessionState.blocked);
    expect(s.reason, 'Trust this folder on the machine to continue');

    // Trusted: Claude Code now lists it under its real id; it stays one session, pid:7777.
    external.entries = [external.entry(pid: 7777, sessionId: 'aaaaaaaa-0000-4000-8000-000000000001', cwd: work.path)];
    console.currentScreen = screen('idle_after_deny.txt');
    final listed = await manager.list();
    expect(listed.map((x) => x.id), ['pid:7777']);
    expect(listed.single.origin, SessionOrigin.external);
  });

  test('interrupting_a_terminal_session_presses_esc_in_its_terminal', () async {
    external.entries = [external.entry(pid: 4242, sessionId: 'cccccccc-0000-4000-8000-000000000003', cwd: work.path, status: 'busy')];
    final id = (await manager.list()).single.id;
    await manager.interrupt(id);
    expect(console.actions, contains('keys:${ConsoleKeys.escape}'));
    console.supported = false;
    await expectLater(manager.interrupt(id), throwsA(isA<CannotType>()));
  });

  test('unlisted_claude_processes_from_ps', () {
    const ps = '''
  7777 ttys004  claude --model haiku -n Perch self-test
  7778 ttys005  /Users/me/.local/bin/claude
  7779 ttys006  claude agents --json
  7780 ttys007  claude -p hello
  7781 ??       claude --model haiku
  7782 ttys008  claudette
  7783 ttys009  claude
''';
    expect(ExternalSessions.unlistedClaudes(ps, {7783}), [(pid: 7777, name: 'Perch'), (pid: 7778, name: null)]);
    final e = ExternalSessions.unlistedEntry(7778, '/w/proj');
    expect(e.summary.id, 'pid:7778');
    expect(e.summary.name, 'proj');
    expect(e.interactive, isTrue);
    expect(e.claudeSessionId, isNull);
    expect(e.summary.state, SessionState.waitingQuestion);
  });

  test('windows_command_lines_split_like_the_c_runtime', () {
    expect(ExternalSessions.windowsCommandLineArgs(r'"C:\Users\me\.local\bin\claude.exe" --model haiku -n "Perch self-test"'),
        [r'C:\Users\me\.local\bin\claude.exe', '--model', 'haiku', '-n', 'Perch self-test']);
    expect(ExternalSessions.windowsCommandLineArgs(r'claude.exe  -n say\"hi\" "a""b"'), ['claude.exe', '-n', 'say"hi"', 'a"b']);
    expect(ExternalSessions.windowsCommandLineArgs(r'claude "C:\dir\\"'), ['claude', r'C:\dir\']);
    expect(ExternalSessions.windowsCommandLineArgs(''), isEmpty);
  });

  test('claude_pids_from_tasklist', () {
    const csv = '"claude.exe","61500","Console","1","412,332 K"\r\n'
        '"claude.exe","700","Console","1","12 K"\r\n'
        'INFO: No tasks are running which match the specified criteria.\r\n';
    expect(ExternalSessions.pidsFromTasklist(csv), {61500, 700});
    expect(ExternalSessions.pidsFromTasklist('INFO: No tasks are running which match the specified criteria.'), isEmpty);
  });

  test('unlisted_claude_processes_on_windows', () {
    // What the Windows process helper prints: each claude.exe with its command line,
    // whether it has a console, and its working folder (with Windows' trailing backslash).
    const json = r'''[
 {"pid":7777,"console":true,"cwd":"D:\\work\\new\\","cmd":"\"C:\\Users\\me\\.local\\bin\\claude.exe\" --model haiku -n \"Perch self-test\""},
 {"pid":7778,"console":true,"cwd":"D:\\work\\other\\","cmd":"C:\\Users\\me\\.local\\bin\\CLAUDE.EXE"},
 {"pid":7779,"console":true,"cwd":"D:\\work\\","cmd":"claude.exe agents --json"},
 {"pid":7780,"console":true,"cwd":"D:\\work\\","cmd":"claude.exe -p hello"},
 {"pid":7781,"console":false,"cwd":"D:\\work\\","cmd":"claude.exe --model haiku"},
 {"pid":7782,"console":true,"cwd":null,"cmd":"claude.exe"},
 {"pid":7783,"console":true,"cwd":"D:\\","cmd":"claude.exe"},
 {"pid":7784,"console":true,"cwd":"C:\\Users\\me\\","cmd":"\"C:\\Users\\me\\AppData\\Local\\AnthropicClaude\\app-1.0\\claude.exe\" --type=renderer"}
]''';
    final out = ExternalSessions.parseWindowsProcesses(json);
    expect(out.unlisted, [
      (pid: 7777, name: 'Perch self-test', cwd: r'D:\work\new'),
      (pid: 7778, name: null, cwd: r'D:\work\other'),
      (pid: 7783, name: null, cwd: r'D:\'),
    ]);
    // Looked at and not sessions, or their folder cannot be read (7782, e.g. another
    // user's process): not asked about again while they run.
    expect(out.rejected, {7779, 7780, 7781, 7782, 7784});
    expect(ExternalSessions.parseWindowsProcesses('not json').unlisted, isEmpty);
    expect(windowsProcessScript.codeUnits.every((c) => c < 128), isTrue, reason: 'PowerShell 5.1 reads it as ANSI');
  });

  test('start_times_out_with_spawn_failed', () async {
    onLaunch = (_) {};
    final s = await manager.start(cwd: work.path, prompt: 'Say hi');
    expect(s.state, SessionState.blocked);
    expect(s.reason, contains('did not start'));
    expect(console.calls, isEmpty);
    expect(await manager.list(), isEmpty);
  });

  test('unsupported_platform_falls_back_to_hidden_session', () async {
    console.supported = false;
    final s = await manager.start(cwd: work.path, prompt: 'echo hello');
    expect(launches, isEmpty);
    expect(s.origin, SessionOrigin.perch);
    expect(console.calls, isEmpty);
  });

  test('command_line_quotes_and_strips_cmd_metacharacters', () {
    expect(terminalCommandLine('claude', ['-n', 'Fix the "login" 100% & more', '--model', 'haiku']),
        'claude -n "Fix the \'login\' 100 & more" --model haiku');
    expect(terminalCommandLine(r'C:\Program Files\claude.exe', []), r'"C:\Program Files\claude.exe"');
  });
}
