import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/console_typer.dart';
import 'package:perch_host/src/tmux_console.dart';
import 'package:test/test.dart';

/// Decodes a `-TextB64` argument the way the helper script does (UTF-16LE).
String decodeUtf16le(String b64) {
  final bytes = base64Decode(b64);
  final units = <int>[for (var i = 0; i + 1 < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8)];
  return String.fromCharCodes(units);
}

void main() {
  test('text_is_base64_utf16le_and_survives_quotes_newlines_and_non_ascii', () {
    const text = 'Say "hi" & \'bye\'\nthen ünïcode — 日本 😀 \$env:X %PATH%';
    final b64 = WindowsTerminalConsole.encodeText(text);
    expect(b64, matches(RegExp(r'^[A-Za-z0-9+/=]+$')));
    expect(decodeUtf16le(b64), text);
    // Windows line breaks are normalised to one break.
    expect(decodeUtf16le(WindowsTerminalConsole.encodeText('a\r\nb')), 'a\nb');
  });

  test('arguments_name_script_action_pid_and_encoded_text', () {
    final args = WindowsTerminalConsole.argumentsFor(r'C:\state\perch_console.ps1', 'type', 4242, 'hello');
    expect(args, [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      r'C:\state\perch_console.ps1',
      '-Action',
      'type',
      '-TargetPid',
      '4242',
      '-TextB64',
      WindowsTerminalConsole.encodeText('hello'),
    ]);
    final screenArgs = WindowsTerminalConsole.argumentsFor('s.ps1', 'screen', 7);
    expect(screenArgs.sublist(screenArgs.indexOf('-Action')), ['-Action', 'screen', '-TargetPid', '7', '-TextB64', '']);
  });

  test('screen_output_is_parsed_after_the_ok_line', () {
    expect(WindowsTerminalConsole.parseScreenOutput('ok screen\r\n Do you?\n > 1. Yes\n'), ' Do you?\n > 1. Yes\n');
    expect(WindowsTerminalConsole.parseScreenOutput('ok screen\n'), '');
    expect(WindowsTerminalConsole.parseScreenOutput('error AttachConsole 6'), isNull);
    expect(WindowsTerminalConsole.parseScreenOutput(''), isNull);
  });

  test('helper_script_is_plain_ascii', () {
    // Windows PowerShell 5.1 reads a script without a byte-order mark as ANSI.
    expect(consoleScript.codeUnits.where((u) => u > 0x7f), isEmpty);
  });

  test('special_keys_are_private_use_characters', () {
    expect(ConsoleKeys.down.codeUnitAt(0), 0xE000 + 0x28);
    expect(ConsoleKeys.up.codeUnitAt(0), 0xE000 + 0x26);
    expect(ConsoleKeys.escape.codeUnitAt(0), 0xE000 + 0x1B);
    expect(ConsoleKeys.tab.codeUnitAt(0), 0xE000 + 0x09);
    expect(ConsoleKeys.enter.codeUnitAt(0), 0xE000 + 0x0D);
  });

  test('every_action_runs_the_one_script_and_reads_its_output', () async {
    final tmp = Directory.systemTemp.createTempSync('perch_typer_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final runs = <List<String>>[];
    var output = 'ok records=12\r\n';
    final console = WindowsTerminalConsole(
      stateDir: '${tmp.path}${Platform.pathSeparator}state',
      run: (exe, args) async {
        expect(exe, 'powershell.exe');
        runs.add(args);
        return output;
      },
    );
    String action(int i) => runs[i][runs[i].indexOf('-Action') + 1];
    String text(int i) => decodeUtf16le(runs[i][runs[i].indexOf('-TextB64') + 1]);

    expect(await console.type(42, 'hi'), isTrue);
    final script = File(runs.single[runs.single.indexOf('-File') + 1]);
    expect(script.existsSync(), isTrue);
    expect(script.readAsStringSync(), allOf(contains('WriteConsoleInput'), contains('ReadConsoleOutputCharacter')));
    expect((action(0), text(0)), ('type', 'hi'));

    expect(await console.keys(42, '2'), isTrue);
    expect((action(1), text(1)), ('keys', '2'));
    expect(await console.pressEnter(42), isTrue);
    expect(action(2), 'enter');

    output = 'ok screen\n Do you want to create color.txt?\n > 1. Yes\n';
    expect(await console.screen(42), ' Do you want to create color.txt?\n > 1. Yes\n');
    expect(action(3), 'screen');

    output = 'error AttachConsole 6';
    expect(await console.type(42, 'hi'), isFalse);
    expect(await console.keys(42, '1'), isFalse);
    expect(await console.screen(42), isNull);
    output = '';
    expect(await console.pressEnter(42), isFalse);
    expect(runs.length, 8);
  }, skip: Platform.isWindows ? false : 'Windows only');

  test('unsupported_console_does_nothing', () async {
    final t = UnsupportedTerminalConsole();
    expect(t.supported, isFalse);
    expect(await t.type(1, 'x'), isFalse);
    expect(await t.keys(1, 'x'), isFalse);
    expect(await t.pressEnter(1), isFalse);
    expect(await t.screen(1), isNull);
    // Windows always; elsewhere through tmux, when it is installed.
    expect(defaultTerminalConsole().supported, Platform.isWindows || TmuxTerminalConsole.findTmux() != null);
  });
}
