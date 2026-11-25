// Switching a running session's model from the phone (session menu → Model…): a terminal
// session gets `/model <name>` typed when it is idle at its prompt; a session the host runs
// gets Claude Code's set_model control request.
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/dialog_screen.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final sep = Platform.pathSeparator;

String screen(String name) => File('test${sep}fixtures${sep}screens$sep$name').readAsStringSync();

const cid = 'aaaaaaaa-0000-4000-8000-0000000000aa';
final rule = '─' * 40;
final idleScreen = '● Done.\n$rule\n❯\n$rule\n  ? for shortcuts\n';

void main() {
  late Directory tmp;
  late FakeExternalSessions external;
  late FakeConsoleTyper console;
  late SessionManager manager;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_model_');
    external = FakeExternalSessions();
    console = FakeConsoleTyper(currentScreen: idleScreen);
    manager = SessionManager(launcher: fakeLauncher(), external: external, typer: console, claudeConfigDir: tmp.path);
  });

  tearDown(() async {
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> terminalSession() async {
    external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: tmp.path)];
    await manager.list();
  }

  test('a terminal session idle at its prompt gets /model typed', () async {
    await terminalSession();
    expect(await manager.setModel(cid, ' haiku '), 'Model: haiku');
    expect(console.calls.single, (pid: 4242, text: '/model haiku'));
    expect(await manager.setModel(cid, null), 'Model: your default');
    expect(console.calls.last.text, '/model default');
  });

  test('a busy terminal session or one showing a dialog is not typed into', () async {
    await terminalSession();
    console.currentScreen = screen('question_single.txt');
    await expectLater(manager.setModel(cid, 'opus'), throwsA(isA<StateError>()));
    expect(console.calls, isEmpty);
  });

  test('a tab behind another (Warp) is brought forward before its screen is read', () async {
    await terminalSession();
    console.currentScreen = null; // Warp reads only the tab in front
    console.onBringForward = () => console.currentScreen = idleScreen;
    expect(await manager.setModel(cid, 'haiku'), 'Model: haiku');
    expect(console.calls.single.text, '/model haiku');
  });

  test("Claude Code's confirmation of the switch is answered Yes (the owner asked for it)", () async {
    // Claude Code 2.1.326 asks before switching a conversation cached for the current model.
    await terminalSession();
    manager.modelConfirmWait = const Duration(seconds: 2);
    console.onAction = (a) {
      // An earlier switch's answer is still on screen above: it must not end the watch.
      if (a == 'type:/model sonnet') {
        console.currentScreen = '❯ /model haiku\n  ⎿  Set model to Haiku 5.5\n${screen('model_switch_confirm.txt')}';
      }
      if (a == 'keys:1') console.currentScreen = '  ⎿  Set model to Sonnet 5.5\n$idleScreen';
    };
    expect(await manager.setModel(cid, 'sonnet'), 'Model: sonnet');
    expect(console.presses, ['type:/model sonnet', 'keys:1']);
  });

  group("the owner's default model", () {
    // Claude Code 2.1.326: `/model <name>` also saves <name> as the default for new sessions
    // in the user settings. Model… switches one session: the default is put back.
    File settings() => File('${tmp.path}${sep}settings.json');
    Map<String, dynamic> read() => jsonDecode(settings().readAsStringSync()) as Map<String, dynamic>;
    void claudeCodeSaves(String model) {
      final j = read()..['model'] = model;
      settings().writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(j)}\n');
    }

    test('is put back after Claude Code saved the new one', () async {
      settings().writeAsStringSync('{\n  "model": "opus[1m]",\n  "theme": "dark",\n  "hooks": {}\n}\n');
      await terminalSession();
      manager.modelConfirmWait = const Duration(seconds: 2);
      console.onAction = (a) {
        if (a == 'type:/model sonnet') {
          claudeCodeSaves('sonnet');
          console.currentScreen = '  ⎿  Set model to Sonnet 5.5 and saved as your default for new sessions\n$idleScreen';
        }
      };
      expect(await manager.setModel(cid, 'sonnet'), 'Model: sonnet');
      expect(read(), {'model': 'opus[1m]', 'theme': 'dark', 'hooks': {}});
    });

    test('none before: the saved one is removed again', () async {
      settings().writeAsStringSync('{\n  "theme": "dark"\n}\n');
      await terminalSession();
      manager.modelConfirmWait = const Duration(seconds: 2);
      console.onAction = (a) {
        if (a == 'type:/model haiku') console.currentScreen = screen('model_switch_confirm.txt');
        if (a == 'keys:1') {
          claudeCodeSaves('haiku');
          console.currentScreen = '  ⎿  Set model to Haiku 5.5 and saved as your default for new sessions\n$idleScreen';
        }
      };
      await manager.setModel(cid, 'haiku');
      expect(read(), {'theme': 'dark'});
    });

    test('a default Claude Code left alone stays as it is', () async {
      const text = '{\n  "model": "opus",\n  "theme": "dark"\n}\n';
      settings().writeAsStringSync(text);
      await terminalSession();
      manager.modelConfirmWait = const Duration(milliseconds: 300);
      console.onAction = (a) {
        if (a == 'type:/model sonnet') console.currentScreen = '  ⎿  Set model to Sonnet 5.5\n$idleScreen';
      };
      await manager.setModel(cid, 'sonnet');
      expect(settings().readAsStringSync(), text);
    });
  });

  test('without a confirmation nothing else is pressed', () async {
    await terminalSession();
    manager.modelConfirmWait = const Duration(milliseconds: 300);
    console.onAction = (a) {
      if (a == 'type:/model opus') console.currentScreen = '  ⎿  Set model to Opus 5.5\n$idleScreen';
    };
    expect(await manager.setModel(cid, 'opus'), 'Model: opus');
    expect(console.presses, ['type:/model opus']);
  });

  test('the confirmation fixture is not taken for an idle prompt or a known dialog', () {
    final s = screen('model_switch_confirm.txt');
    expect(isModelSwitchConfirm(s), isTrue);
    expect(isModelSwitchConfirm(idleScreen), isFalse);
    expect(isModelSwitchConfirm(screen('question_single.txt')), isFalse);
    // A known dialog: no "Claude Code changed" alert while it shows.
    expect(screenDrift(s), isNull);
  });

  test('a terminal Perch cannot type into is refused with what to type there', () async {
    await terminalSession();
    console.operable = false;
    await expectLater(manager.setModel(cid, 'sonnet'),
        throwsA(isA<CannotType>().having((e) => e.message, 'message', contains('Type /model sonnet there'))));
  });

  test('model names are checked, and an unknown session is refused', () async {
    await terminalSession();
    await expectLater(manager.setModel(cid, 'opus; rm -rf'), throwsArgumentError);
    await expectLater(manager.setModel('nope', 'opus'), throwsA(isA<NoSuchSession>()));
    expect(console.calls, isEmpty);
  });

  test('a session the host runs gets set_model and shows the new model', () async {
    final log = File('${tmp.path}${sep}stdin.txt');
    final m = SessionManager(
        launcher: fakeLauncher(env: {'FAKE_CLAUDE_STDIN_LOG': log.path}), external: FakeExternalSessions());
    addTearDown(m.dispose);
    final s = await m.start(cwd: tmp.path, prompt: 'echo hi');
    await waitUntil(() => m.summaryOf(s.id)!.state == SessionState.idle);
    expect(await m.setModel(s.id, 'haiku'), 'Model: haiku');
    expect(m.summaryOf(s.id)!.model, 'haiku');
    await waitUntil(() => log.existsSync() && log.readAsStringSync().contains('set_model'));
    final req = const LineSplitter()
        .convert(log.readAsStringSync())
        .map((l) => jsonDecode(l) as Map)
        .firstWhere((j) => j['type'] == 'control_request');
    expect(req['request'], {'subtype': 'set_model', 'model': 'haiku'});
    // The session keeps working afterwards (the fake answered the request).
    await m.send(s.id, 'echo again');
    await waitUntil(() => m.history(s.id).events.whereType<AssistantText>().any((e) => e.text == 'echo: echo again'));
  });
}
