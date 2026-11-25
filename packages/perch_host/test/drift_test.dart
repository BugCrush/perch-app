import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/compatibility.dart';
import 'package:perch_host/src/dialog_screen.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/stream_parser.dart';
import 'package:perch_host/src/terminal_prompts.dart';
import 'package:perch_host/src/transcript.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const sid = '55555555-6666-4777-8888-999999999999';
final sep = Platform.pathSeparator;

String screen(String name) => File('test${sep}fixtures${sep}screens$sep$name').readAsStringSync();

/// A dialog whose options parse but whose kind Perch cannot tell.
const unknownDialog = ' Pick a theme for this session\n ❯ 1. Dark\n   2. Light\n Esc to cancel\n';

/// A dialog footer with choices drawn in a way Perch cannot read.
const unreadableChoices = ' Do you want to proceed?\n ❯ [Yes]  [No]\n Esc to cancel\n';

String toolUse(String id, String name, Map<String, dynamic> input) => jsonEncode({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'tool_use', 'id': id, 'name': name, 'input': input}
        ]
      }
    });

void main() {
  group('screens', () {
    test('drift_reasons_from_a_screen', () {
      expect(screenDrift(unknownDialog), contains('cannot recognise'));
      expect(screenDrift(unreadableChoices), contains('cannot read'));
      for (final ok in [
        'permission_create.txt',
        'question_single.txt',
        'multiselect.txt',
        'ms_other_typed.txt',
        'ms_other_submit_row.txt',
        'question_multi_review.txt',
        'plan.txt',
        'trust.txt',
        'idle.txt',
        'idle_after_deny.txt',
      ]) {
        expect(screenDrift(screen(ok)), isNull, reason: ok);
      }
    });
  });

  group('sessions', () {
    late Directory tmp;
    late File transcript;
    late FakeExternalSessions external;
    late FakeConsoleTyper console;
    late CompatibilityTracker compat;
    late SessionManager manager;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('perch_dr_');
      final project = Directory('${tmp.path}${sep}config${sep}projects${sep}D--projects-example')
        ..createSync(recursive: true);
      transcript = File('${project.path}$sep$sid.jsonl')
        ..writeAsStringSync('${jsonEncode({
          'type': 'user',
          'message': {'role': 'user', 'content': 'Do the thing.'}
        })}\n');
      external = FakeExternalSessions();
      console = FakeConsoleTyper();
      compat = CompatibilityTracker()..setVersion('2.1.323');
      manager = SessionManager(
        launcher: fakeLauncher(),
        external: external,
        typer: console,
        claudeConfigDir: '${tmp.path}${sep}config',
        answerPoll: const Duration(milliseconds: 5),
        answerTimeout: const Duration(milliseconds: 200),
        compatibility: compat,
      );
    });

    tearDown(() async {
      await manager.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    void waiting({String waitingFor = 'permission prompt'}) {
      external.entries = [
        external.entry(pid: 4242, sessionId: sid, cwd: r'D:\projects\example', status: 'waiting', waitingFor: waitingFor, name: 'work')
      ];
    }

    Future<void> poll() async {
      await manager.list();
      manager.history(sid);
      await manager.list();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    test('an_unrecognised_dialog_while_waiting_is_drift', () async {
      waiting();
      console.currentScreen = unknownDialog;
      await poll();
      final c = compat.current;
      expect(c.status, CompatibilityStatus.drifted);
      expect(c.reason, contains('cannot recognise'));
      expect(c.evidence, contains('Session: work ($sid)'));
      expect(c.evidence, contains('Expected: a permission request'));
      expect(c.evidence, contains('2. Light'));
      expect(c.evidence, contains('Claude Code: 2.1.323'));
    });

    test('a_dialog_whose_choices_cannot_be_read_is_drift', () async {
      waiting(waitingFor: 'input needed');
      console.currentScreen = unreadableChoices;
      await poll();
      expect(compat.current.status, CompatibilityStatus.drifted);
      expect(compat.current.reason, contains('cannot read'));
    });

    test('a_dialog_seen_once_and_then_gone_is_not_drift', () async {
      waiting();
      // The second read finds the dialog gone (it was mid-change).
      final flaky = _FlakyConsole([unknownDialog, screen('idle_after_deny.txt')]);
      final m = SessionManager(
        launcher: fakeLauncher(),
        external: external,
        typer: flaky,
        claudeConfigDir: '${tmp.path}${sep}config',
        answerPoll: const Duration(milliseconds: 5),
        compatibility: compat,
      );
      addTearDown(m.dispose);
      await m.list();
      m.history(sid);
      await m.list();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(flaky.reads, greaterThanOrEqualTo(2));
      expect(compat.current.status, CompatibilityStatus.ok);
    });

    test('not_waiting_is_not_drift', () async {
      external.entries = [external.entry(pid: 4242, sessionId: sid, cwd: r'D:\projects\example', status: 'busy')];
      console.currentScreen = unknownDialog;
      await poll();
      expect(compat.current.status, CompatibilityStatus.ok);
    });

    test('a_dialog_that_disappeared_before_the_answer_is_not_drift', () async {
      transcript.writeAsStringSync('${toolUse('toolu_W', 'Write', {'file_path': 'a.txt'})}\n', mode: FileMode.append);
      waiting();
      console.currentScreen = screen('permission_create.txt');
      await poll();
      final p = manager.history(sid).openPrompts.single;
      console.currentScreen = screen('idle_after_deny.txt'); // answered at the machine meanwhile
      await expectLater(manager.answerPrompt(sid, p.promptId, const PermissionAnswer(allow: true)),
          throwsA(isA<CannotAnswerInTerminal>()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(compat.current.status, CompatibilityStatus.ok);
    });

    test('an_answer_that_meets_an_unrecognised_dialog_raises_drift', () async {
      transcript.writeAsStringSync('${toolUse('toolu_W', 'Write', {'file_path': 'a.txt'})}\n', mode: FileMode.append);
      waiting();
      console.currentScreen = screen('permission_create.txt');
      await poll();
      final p = manager.history(sid).openPrompts.single;
      console.currentScreen = unknownDialog; // what a changed Claude Code might draw
      await expectLater(manager.answerPrompt(sid, p.promptId, const PermissionAnswer(allow: true)),
          throwsA(isA<CannotAnswerInTerminal>()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(compat.current.status, CompatibilityStatus.drifted);
      expect(console.presses, isEmpty);
    });

    test('a_hook_without_its_required_fields_is_drift', () async {
      waiting();
      await manager.list();
      await manager.handleHook({'session_id': sid, 'hook_event_name': 'PreToolUse', 'tool_name': 'AskUserQuestion'});
      expect(compat.current.status, CompatibilityStatus.drifted);
      expect(compat.current.reason, contains('hook'));
      expect(compat.current.evidence, contains('tool_input'));
    });

    test('an_unknown_hook_event_is_not_drift', () async {
      await manager.handleHook({'session_id': sid, 'hook_event_name': 'SomethingNew'});
      expect(compat.current.status, CompatibilityStatus.ok);
    });

    test('three_unreadable_transcript_lines_in_one_session_are_drift', () async {
      external.entries = [external.entry(pid: 4242, sessionId: sid, cwd: r'D:\projects\example', status: 'busy', name: 'work')];
      await manager.list();
      manager.history(sid);
      String bad(String type) => jsonEncode({'type': type, 'message': 'not an object'});
      transcript.writeAsStringSync('${bad('assistant')}\n${bad('user')}\n', mode: FileMode.append);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(compat.current.status, CompatibilityStatus.ok);
      transcript.writeAsStringSync('${jsonEncode({'type': 'assistant', 'message': {'role': 'assistant'}})}\n', mode: FileMode.append);
      await waitUntil(() => compat.current.status == CompatibilityStatus.drifted, timeout: const Duration(seconds: 5));
      expect(compat.current.reason, contains('transcript'));
    });

    test('a_stream_request_without_its_fields_is_drift', () async {
      console.supported = false;
      final s = await manager.start(cwd: tmp.path, prompt: 'malformed');
      await waitUntil(() => compat.current.status == CompatibilityStatus.drifted, timeout: const Duration(seconds: 30));
      expect(compat.current.reason, contains('request'));
      await manager.stop(s.id);
    });
  });

  test('parsers_report_malformed_lines_of_known_types', () {
    expect(parseTranscriptLine(jsonEncode({'type': 'assistant', 'message': 'x'})), isA<TranscriptMalformed>());
    expect(parseTranscriptLine(jsonEncode({'type': 'user', 'message': {'role': 'user'}})), isA<TranscriptMalformed>());
    expect(parseTranscriptLine(jsonEncode({'type': 'something-new', 'x': 1})), isA<TranscriptSkip>());
    expect(parseTranscriptLine('{partial'), isA<TranscriptSkip>());
    expect(
        parseClaudeLine(jsonEncode({
          'type': 'control_request',
          'request_id': 'r1',
          'request': {'subtype': 'can_use_tool', 'input': {}}
        })),
        isA<ParsedMalformed>());
    expect(
        parseClaudeLine(jsonEncode({
          'type': 'control_request',
          'request': {'subtype': 'can_use_tool', 'tool_name': 'Bash', 'input': {}}
        })),
        isA<ParsedMalformed>());
  });
}

/// Shows the given screens in turn (the last one stays).
class _FlakyConsole extends FakeConsoleTyper {
  final List<String> screens;
  int reads = 0;
  _FlakyConsole(this.screens);

  @override
  Future<String?> screen(int pid) async {
    final s = screens[reads < screens.length ? reads : screens.length - 1];
    reads++;
    return s;
  }
}
