import 'dart:convert';

import 'package:perch_host/src/console_typer.dart';
import 'package:perch_host/src/mac_console.dart';
import 'package:perch_host/src/mac_helper.dart';
import 'package:perch_host/src/terminal_window.dart';
import 'package:test/test.dart';

const terminalApp = '/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal';
const warpApp = '/Applications/Warp.app/Contents/MacOS/stable';

/// ps rows: Terminal (100) > login (110) > zsh (120) > claude (130) on ttys004;
/// Warp (200) > Warp helper (210) > zsh (220, 240) > claude (230 on ttys001, 250 on ttys002);
/// a claude (300) with no terminal.
const ps = '''
  100     1 ??       $terminalApp
  110   100 ttys004  login
  120   110 ttys004  -zsh
  130   120 ttys004  claude
  200     1 ??       $warpApp
  210   200 ??       $warpApp
  220   210 ttys001  -zsh
  230   220 ttys001  claude
  240   210 ttys002  -zsh
  250   240 ttys002  claude
  300     1 ??       claude
''';

/// A Warp with windows of tabs: titles per tab, the front tab per window, a session's
/// title change when its tty gets a marker, and Cmd-Shift-] / Cmd-n tab switching.
class FakeHelper extends MacHelper {
  FakeHelper() : super(binDir: '/nonexistent');

  /// Window → tabs (front window first); each tab: tty and title.
  final List<List<({String tty, String title})>> tabs = [];
  final List<int> front = [];

  /// Ttys whose title Warp shows as its own (waiting for an answer): markers do not show.
  final Set<String> overridden = {};
  final List<List<KeyStep>> posted = [];
  final Map<String, String> screens = {};

  void setTitle(String tty, String title) {
    if (overridden.contains(tty)) return;
    for (final w in tabs) {
      for (var i = 0; i < w.length; i++) {
        if (w[i].tty == tty) w[i] = (tty: tty, title: title);
      }
    }
  }

  ({String tty, String title}) frontTab(int w) => tabs[w][front[w]];

  @override
  Future<List<String>?> titles(int pid) async => [for (var w = 0; w < tabs.length; w++) frontTab(w).title];

  @override
  Future<List<AxWindow>?> windows(int pid) async =>
      [for (var w = 0; w < tabs.length; w++) AxWindow(frontTab(w).title, screens[frontTab(w).tty] ?? '')];

  bool isTrusted = true;

  @override
  Future<bool> trusted() async => isTrusted;

  @override
  Future<({int? index, List<String> before})?> mark(int pid, String tty, String marker) async {
    final before = (await titles(pid))!;
    setTitle(tty, marker);
    final i = (await titles(pid))!.indexOf(marker);
    return (index: i < 0 ? null : i, before: before);
  }

  @override
  Future<bool> raise(int pid, int index) async {
    tabs.insert(0, tabs.removeAt(index));
    front.insert(0, front.removeAt(index));
    return true;
  }

  @override
  Future<bool> post(int pid, List<KeyStep> steps) async {
    posted.add(steps);
    for (final s in steps) {
      if (s is KeyPress && s.flags == (MacKeys.command | MacKeys.shift)) {
        final d = s.code == MacKeys.rightBracket ? 1 : -1;
        front[0] = (front[0] + d) % tabs[0].length;
      } else if (s is KeyPress && s.flags == MacKeys.command) {
        front[0] = MacTerminalConsole.digitKeys.indexOf(s.code);
      }
    }
    return true;
  }
}

void main() {
  late FakeHelper helper;
  late List<List<String>> runs;
  late String terminalOut;
  late String warpDbOut;
  late Map<int, String> cwds;
  late MacTerminalConsole console;

  setUp(() {
    helper = FakeHelper();
    runs = [];
    terminalOut = 'ok\n';
    warpDbOut = '';
    cwds = {};
    console = MacTerminalConsole(
      helper: helper,
      available: true,
      settle: Duration.zero,
      beforeSubmit: Duration.zero,
      warpDb: '/db',
      run: (exe, args) async {
        runs.add([exe, ...args]);
        if (exe == '/bin/ps') return (exitCode: 0, stdout: ps);
        if (exe == '/usr/bin/osascript') return (exitCode: 0, stdout: terminalOut);
        if (exe == '/usr/sbin/lsof') return (exitCode: 0, stdout: 'p1\nfcwd\nn${cwds[int.parse(args[2])] ?? '/x'}\n');
        if (exe == '/usr/bin/sqlite3') return (exitCode: 0, stdout: warpDbOut);
        return (exitCode: 1, stdout: '');
      },
      writeTty: (tty, data) async {
        final m = RegExp(r'^\x1b\]0;(.*)\x1b\\$').firstMatch(data);
        if (m != null) helper.setTitle(tty, m[1]!);
      },
    );
  });

  test('finds_the_terminal_app_from_the_claude_process', () {
    final rows = MacTerminalConsole.parsePs(ps);
    expect(MacTerminalConsole.targetFrom(rows, 130).toString(), 'MacTarget(MacTerminalApp.terminal, 100, /dev/ttys004)');
    // Warp: the topmost Warp process is the app.
    expect(MacTerminalConsole.targetFrom(rows, 250).toString(), 'MacTarget(MacTerminalApp.warp, 200, /dev/ttys002)');
    expect(MacTerminalConsole.targetFrom(rows, 300), isNull);
    expect(MacTerminalConsole.targetFrom(rows, 999), isNull);
  });

  test('keys_become_key_codes_and_text', () {
    final steps = MacTerminalConsole.stepsFor('2${ConsoleKeys.down}${ConsoleKeys.down}é ✓${ConsoleKeys.enter}');
    expect(steps.map((s) => s.arg).toList(), [
      TextStep('2').arg,
      'k:${MacKeys.down}',
      'k:${MacKeys.down}',
      't:${base64Encode(utf8.encode('é ✓'))}',
      'k:${MacKeys.enter}',
    ]);
    expect(MacTerminalConsole.pasteOf('a\r\nb'), '\x1b[200~a\nb\x1b[201~');
  });

  test('screen_text_keeps_the_last_rows', () {
    expect(MacTerminalConsole.screenText('a  \n\nb\nc\n\n\n', rows: 2), 'b\nc\n');
    expect(MacTerminalConsole.screenText('\n\n'), '');
  });

  group('terminal_app', () {
    test('screen_is_the_tabs_contents_found_by_tty', () async {
      terminalOut = 'ok\n❯ 1. Yes\n  2. No\n';
      expect(await console.screen(130), '❯ 1. Yes\n  2. No\n');
      final call = runs.lastWhere((r) => r.first == '/usr/bin/osascript');
      expect(call.sublist(call.length - 2), ['/dev/ttys004', 'screen']);
      expect(call[2], MacTerminalConsole.terminalScript);
    });

    test('keys_bring_the_tab_forward_then_post_to_terminal', () async {
      expect(await console.keys(130, '2'), isTrue);
      expect(runs.lastWhere((r) => r.first == '/usr/bin/osascript').last, 'front');
      expect(helper.posted.single.map((s) => s.arg), [TextStep('2').arg]);
    });

    test('a_tab_that_cannot_be_brought_forward_gets_nothing', () async {
      terminalOut = 'error not-front';
      expect(await console.keys(130, '2'), isFalse);
      expect(await console.type(130, 'hi'), isFalse);
      expect(helper.posted, isEmpty);
    });

    test('type_pastes_then_presses_enter_separately', () async {
      expect(await console.type(130, 'two\nlines'), isTrue);
      expect(helper.posted.map((p) => p.map((s) => s.arg).toList()), [
        [TextStep('\x1b[200~two\nlines\x1b[201~').arg],
        ['k:${MacKeys.enter}'],
      ]);
    });
  });

  test('without_the_accessibility_permission_nothing_is_typed', () async {
    final lines = <String>[];
    console = MacTerminalConsole(
        helper: helper..isTrusted = false,
        available: true,
        log: lines.add,
        run: (exe, args) async => exe == '/bin/ps' ? (exitCode: 0, stdout: ps) : (exitCode: 0, stdout: 'ok\n'));
    expect(await console.type(130, 'hi'), isFalse);
    expect(helper.posted, isEmpty);
    expect(lines.single, contains('Accessibility'));
  });

  test('no_terminal_means_no_typing', () async {
    expect(await console.type(300, 'hi'), isFalse);
    expect(await console.screen(300), isNull);
    expect(await console.bringForward(300), isFalse);
    expect(helper.posted, isEmpty);
  });

  group('warp', () {
    setUp(() {
      helper.tabs.add([(tty: '/dev/ttys001', title: 'One'), (tty: '/dev/ttys002', title: 'Two')]);
      helper.front.add(0);
      helper.screens['/dev/ttys001'] = 'screen one';
      helper.screens['/dev/ttys002'] = 'screen two';
    });

    test('front_tab_is_read_and_its_title_put_back', () async {
      expect(await console.screen(230), 'screen one\n');
      expect(helper.tabs[0][0].title, 'One');
      expect(helper.posted, isEmpty);
    });

    test('a_background_tab_is_never_switched_to_for_reading', () async {
      expect(await console.screen(250), isNull);
      expect(helper.front, [0]);
      expect(helper.posted, isEmpty);
    });

    test('typing_switches_to_the_sessions_tab_by_its_marker', () async {
      expect(await console.type(250, 'hello'), isTrue);
      expect(helper.front, [1]);
      final typed = helper.posted.where((p) => p.any((s) => s is TextStep || s.arg == 'k:${MacKeys.enter}')).toList();
      expect(typed.map((p) => p.single.arg), [TextStep(MacTerminalConsole.pasteOf('hello')).arg, 'k:${MacKeys.enter}']);
      expect(await console.screen(250), 'screen two\n');
    });

    test('a_session_in_no_tab_is_not_typed_into_and_tabs_are_put_back', () async {
      helper.tabs[0][1] = (tty: '/dev/ttys009', title: 'Other');
      expect(await console.type(250, 'hello'), isFalse);
      expect(helper.front, [0]);
      expect(helper.posted.expand((p) => p).whereType<TextStep>(), isEmpty);
    });

    test('a_tab_in_another_window_is_found_by_raising_it', () async {
      helper.tabs.insert(0, [(tty: '/dev/ttys007', title: 'Seven')]);
      helper.front.insert(0, 0);
      expect(await console.bringForward(250), isTrue);
      expect(helper.frontTab(0).tty, '/dev/ttys002');
    });

    test('while_warp_shows_its_own_title_answering_finds_the_tab_by_folder', () async {
      helper.overridden.add('/dev/ttys002');
      cwds[250] = '/work/b';
      warpDbOut = '1\t1\t/work/a\t0\n1\t2\t/work/b\t0\n';
      // Answering: Cmd-2, then the screen can be read while Warp says it is in front.
      expect(await console.bringForward(250), isTrue);
      expect(helper.front, [1]);
      warpDbOut = '1\t1\t/work/a\t1\n1\t2\t/work/b\t1\n';
      expect(await console.screen(250), 'screen two\n');
      expect(await console.keys(250, '1'), isTrue);

      // A message by folder match needs Claude Code's input box on that tab.
      helper.posted.clear();
      expect(await console.type(250, 'hello'), isFalse);
      expect(helper.posted, isEmpty);
      final rule = '─' * 80;
      helper.screens['/dev/ttys002'] = '$rule\n❯ \n$rule\n';
      expect(await console.type(250, 'hello'), isTrue);
      expect(helper.posted.map((p) => p.single.arg), [TextStep(MacTerminalConsole.pasteOf('hello')).arg, 'k:${MacKeys.enter}']);
    });

    test('folder_match_needs_exactly_one_tab_in_one_window', () async {
      helper.overridden.add('/dev/ttys002');
      cwds[250] = '/work/a';
      warpDbOut = '1\t1\t/work/a\t0\n1\t2\t/work/a\t0\n';
      expect(await console.bringForward(250), isFalse);
      expect(helper.front, [0]);
    });
  });

  test('warp_tabs_from_its_database', () {
    final tabs = MacTerminalConsole.parseWarpTabs('1\t4\t/a\t1\n1\t4\t/a2\t1\n1\t9\t/b\t1\n2\t3\t/c\t0\nbad\n');
    expect(tabs.map((t) => '${t.window}:${t.index}:${t.cwd}:${t.active}').toList(), ['1:0:/a:1', '1:1:/b:1', '2:0:/c:0']);
  });

  test('terminal_app_window_command', () {
    const l = TerminalLaunch(cwd: "/w/it's here", executable: '/bin/claude', args: ['-n', 'my task'], environment: {});
    expect(terminalAppCommand(l), r"cd '/w/it'\''s here' && '/bin/claude' '-n' 'my task'");
    expect(terminalAppCommand(l, extraEnv: {'CLAUDE_CONFIG_DIR': '/c d'}),
        r"cd '/w/it'\''s here' && env CLAUDE_CONFIG_DIR='/c d' '/bin/claude' '-n' 'my task'");
    const closing = TerminalLaunch(cwd: '/w', executable: 'claude', args: [], environment: {}, keepOpen: false);
    expect(terminalAppCommand(closing), "cd '/w' && 'claude'; exit");
  });

  test('helper_output_parsing', () {
    expect(MacHelper.parseWindows('[{"title":"A","text":"x"}]')!.single.title, 'A');
    expect(MacHelper.parseWindows('error not-trusted'), isNull);
    expect(MacHelper.fileName, startsWith('perch-mac-helper-'));
  });
}
