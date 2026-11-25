@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:perch_host/src/console_typer.dart';
import 'package:perch_host/src/tmux_console.dart';
import 'package:test/test.dart';

/// A stand-in for tmux and ps: answers `list-panes`, `capture-pane` and `ps`, records the rest.
class FakeTmux {
  /// Pane process id → pane id, per socket path.
  final Map<String, Map<int, String>> panes = {};

  /// Process id → parent process id.
  final Map<int, int> parents = {};
  String screen = '';
  final List<List<String>> calls = [];
  int failSendKeys = 0;

  Future<TmuxResult> run(String exe, List<String> args) async {
    if (exe == 'ps') {
      return (exitCode: 0, stdout: [for (final e in parents.entries) '  ${e.key}   ${e.value}'].join('\n'));
    }
    calls.add(args);
    final socket = args[1];
    final cmd = args[2];
    if (cmd == 'list-panes') {
      final p = panes[socket];
      if (p == null) return (exitCode: 1, stdout: '');
      return (exitCode: 0, stdout: [for (final e in p.entries) '${e.key} ${e.value}'].join('\n'));
    }
    if (cmd == 'capture-pane') return (exitCode: 0, stdout: screen);
    if (cmd == 'send-keys' && failSendKeys > 0) {
      failSendKeys--;
      return (exitCode: 1, stdout: '');
    }
    return (exitCode: 0, stdout: '');
  }
}

void main() {
  late Directory dir;
  late List<ServerSocket> sockets;
  late FakeTmux fake;
  late TmuxTerminalConsole console;

  Future<String> socket(String name) async {
    final path = '${dir.path}/$name';
    sockets.add(await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0));
    return path;
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('perch_tmux_');
    sockets = [];
    fake = FakeTmux();
    console = TmuxTerminalConsole(
        tmux: 'tmux', socketDirs: [dir.path], run: fake.run, available: true, keyGap: Duration.zero);
  });

  tearDown(() async {
    for (final s in sockets) {
      await s.close();
    }
    dir.deleteSync(recursive: true);
  });

  test('finds_the_pane_whose_process_is_claude_or_its_ancestor', () async {
    final a = await socket('perch-1-2');
    final b = await socket('default');
    File('${dir.path}/not-a-socket').writeAsStringSync('');
    fake.panes[a] = {500: '%0'};
    fake.panes[b] = {700: '%3', 710: '%4'};
    // claude 900 was started from the shell 710 in pane %4 (through a wrapper 800).
    fake.parents.addAll({900: 800, 800: 710, 710: 1, 501: 1});

    expect(await console.paneOf(500), (socket: a, pane: '%0'));
    expect(await console.paneOf(900), (socket: b, pane: '%4'));
    expect(await console.paneOf(501), isNull);
    expect(await console.paneOf(4242), isNull);
  });

  test('no_tmux_servers_means_no_pane_and_nothing_typed', () async {
    expect(await console.paneOf(500), isNull);
    expect(await console.type(500, 'hi'), isFalse);
    expect(await console.keys(500, '2'), isFalse);
    expect(await console.screen(500), isNull);
  });

  test('type_pastes_the_message_then_presses_enter_separately', () async {
    final a = await socket('perch-1-2');
    fake.panes[a] = {500: '%0'};
    expect(await console.type(500, 'first line\r\nsecond "line" ; \$HOME'), isTrue);
    final sent = fake.calls.where((c) => c[2] != 'list-panes').toList();
    expect(sent, [
      ['-S', a, 'set-buffer', '-b', 'perch-message', '--', 'first line\nsecond "line" ; \$HOME', ';', //
        'paste-buffer', '-p', '-d', '-b', 'perch-message', '-t', '%0'],
      ['-S', a, 'send-keys', '-t', '%0', 'Enter'],
    ]);
  });

  test('keys_are_pressed_one_call_at_a_time_with_special_keys_by_name', () async {
    final a = await socket('perch-1-2');
    fake.panes[a] = {500: '%0'};
    expect(await console.keys(500, '${ConsoleKeys.down}${ConsoleKeys.down}Enter;x${ConsoleKeys.escape}'), isTrue);
    final sent = fake.calls.where((c) => c[2] == 'send-keys').map((c) => c.sublist(5)).toList();
    expect(sent, [
      ['Down'],
      ['Down'],
      // Literal text is sent with -l, so "Enter" is the five letters, not the key.
      ['-l', '--', 'Enter;x'],
      ['Escape'],
    ]);
    expect(await console.pressEnter(500), isTrue);
    expect(fake.calls.last.sublist(5), ['Enter']);
  });

  test('a_failed_key_press_stops_and_reports_failure', () async {
    final a = await socket('perch-1-2');
    fake.panes[a] = {500: '%0'};
    fake.failSendKeys = 1;
    expect(await console.keys(500, '12'), isFalse);
    expect(await console.type(500, ''), isTrue);
  });

  test('screen_has_the_windows_shape', () async {
    final a = await socket('perch-1-2');
    fake.panes[a] = {500: '%0'};
    fake.screen = '\n ❯ No, exit   \n\n   Yes, I trust this folder\n\n\n';
    expect(await console.screen(500), ' ❯ No, exit\n   Yes, I trust this folder\n');
    fake.screen = '\n\n';
    expect(await console.screen(500), '');
    expect(TmuxTerminalConsole.screenText(''), '');
  });

  test('unsupported_console_does_nothing', () async {
    final off = TmuxTerminalConsole(tmux: 'tmux', socketDirs: [dir.path], run: fake.run, available: false);
    expect(off.supported, isFalse);
    expect(await off.paneOf(1), isNull);
    expect(fake.calls, isEmpty);
  });

  test('socket_dirs_follow_tmux_tmpdir', () {
    final d = TmuxTerminalConsole.defaultSocketDirs(environment: {'TMUX_TMPDIR': '/x'}, uid: 7);
    expect(d, ['/x/tmux-7', '/tmp/tmux-7', '/private/tmp/tmux-7']);
  });
}
