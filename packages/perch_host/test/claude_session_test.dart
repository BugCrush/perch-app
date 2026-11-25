import 'dart:io';

import 'package:perch_host/src/claude_session.dart';
import 'package:perch_host/src/stream_parser.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late Directory tmp;
  final sessions = <ClaudeSession>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_cs_');
  });
  tearDown(() async {
    for (final s in sessions) {
      await s.stop();
    }
    sessions.clear();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  ClaudeSession make({ClaudeLauncher? launcher}) {
    final s = ClaudeSession(launcher: launcher ?? fakeLauncher(), cwd: tmp.path);
    sessions.add(s);
    return s;
  }

  test('question_round_trip', () async {
    final s = make();
    final events = collectEvents(s);
    await s.start('question');
    await waitForState(s, SessionState.waitingQuestion);
    final p = s.openPrompts.single;
    expect(p.kind, PromptKind.question);
    s.answer(p.promptId, const QuestionAnswer({'Which color?': 'Blue'}));
    await waitForState(s, SessionState.idle);
    expect(events.whereType<AssistantText>().any((e) => e.text.contains('Blue')), isTrue);
    expect(s.openPrompts, isEmpty);
  });

  test('permission_allow_and_deny', () async {
    for (final allow in [true, false]) {
      final s = make();
      final events = collectEvents(s);
      await s.start('permission');
      await waitForState(s, SessionState.waitingPermission);
      s.answer(s.openPrompts.single.promptId, PermissionAnswer(allow: allow));
      await waitForState(s, SessionState.idle);
      expect(events.whereType<TurnEnded>().single.text, allow ? 'allowed' : 'denied');
    }
  });

  test('multi_turn_in_one_process', () async {
    final s = make();
    final events = collectEvents(s);
    await s.start('echo');
    await waitForState(s, SessionState.idle);
    s.sendUser('second');
    await waitUntil(() => events.whereType<AssistantText>().any((e) => e.text == 'echo: second'));
    await waitForState(s, SessionState.idle);
  });

  test('second_answer_to_same_prompt_is_rejected', () async {
    final log = File('${tmp.path}${Platform.pathSeparator}stdin.log');
    final s = make(launcher: fakeLauncher(env: {'FAKE_CLAUDE_STDIN_LOG': log.path}));
    await s.start('question');
    await waitForState(s, SessionState.waitingQuestion);
    final id = s.openPrompts.single.promptId;
    s.answer(id, const QuestionAnswer({'Which color?': 'Red'}));
    expect(() => s.answer(id, const QuestionAnswer({'Which color?': 'Blue'})),
        throwsA(isA<PromptAlreadyAnswered>()));
    await waitForState(s, SessionState.idle);
    final responses = log.readAsLinesSync().where((l) => l.contains('"control_response"')).toList();
    expect(responses.length, 1);
  });

  test('unexpected_exit_marks_finished_with_reason', () async {
    final s = make();
    await s.start('crash');
    await waitForState(s, SessionState.finished);
    expect(s.reason, contains('boom'));
  });

  test('spawn_failure_reports_blocked', () async {
    final s = make(launcher: const ClaudeLauncher('definitely-not-a-program'));
    await s.start('hello');
    expect(s.state, SessionState.blocked);
    expect(s.reason, isNotNull);
    expect(s.reason, isNotEmpty);
  });

  test('interrupt_ends_the_turn', () async {
    final s = make();
    final events = collectEvents(s);
    await s.start('slow');
    await waitUntil(() => s.claudeSessionId != null);
    expect(s.state, SessionState.working);
    s.interrupt();
    await waitForState(s, SessionState.idle);
    expect(events.whereType<TurnEnded>().single.isError, isTrue);
  });

  test('stop_kills_the_process', () async {
    final s = make();
    await s.start('echo');
    await waitForState(s, SessionState.idle);
    await s.stop();
    expect(s.state, SessionState.stopped);
    expect(() => s.sendUser('x'), throwsStateError);
  });

  test('permission_mode_and_resume_are_passed_to_claude', () async {
    final argsFile = File('${tmp.path}${Platform.pathSeparator}args.txt');
    final s = ClaudeSession(
      launcher: fakeLauncher(env: {'FAKE_CLAUDE_ARGS_FILE': argsFile.path}),
      cwd: tmp.path,
      name: 'My name',
      model: 'haiku',
      resumeId: 'abc-123',
      permissionMode: 'auto',
    );
    sessions.add(s);
    await s.start(null);
    await waitUntil(() => argsFile.existsSync() && argsFile.readAsStringSync().isNotEmpty);
    final args = argsFile.readAsLinesSync();
    for (final a in [
      '-p',
      '--input-format',
      'stream-json',
      '--output-format',
      '--verbose',
      '--permission-prompt-tool',
      'stdio',
      '--forward-subagent-text',
    ]) {
      expect(args, contains(a));
    }
    expect(args[args.indexOf('--model') + 1], 'haiku');
    expect(args[args.indexOf('-n') + 1], 'My name');
    expect(args[args.indexOf('--resume') + 1], 'abc-123');
    expect(args[args.indexOf('--permission-mode') + 1], 'auto');
    expect(s.state, SessionState.idle);
  });

  test('no_model_flag_unless_chosen', () async {
    final argsFile = File('${tmp.path}${Platform.pathSeparator}args.txt');
    final s = ClaudeSession(launcher: fakeLauncher(env: {'FAKE_CLAUDE_ARGS_FILE': argsFile.path}), cwd: tmp.path);
    sessions.add(s);
    await s.start('echo');
    await waitForState(s, SessionState.idle);
    expect(argsFile.readAsLinesSync(), isNot(contains('--model')));
  });

  test('lines_stream_carries_usage_and_init', () async {
    final s = make();
    final lines = <ParsedLine>[];
    s.lines.listen(lines.add);
    await s.start('echo');
    await waitForState(s, SessionState.idle);
    expect(lines.whereType<ParsedInit>(), isNotEmpty);
    expect(lines.whereType<ParsedUsage>(), isNotEmpty);
  });

  test('child_environment_drops_inherited_session_markers', () {
    final env = const ClaudeLauncher('claude', [], {'EXTRA': '1'}).childEnvironment();
    for (final m in ClaudeLauncher.inheritedSessionMarkers) {
      expect(env.keys.map((k) => k.toUpperCase()), isNot(contains(m)));
    }
    expect(env['EXTRA'], '1');
    expect(env.keys.map((k) => k.toUpperCase()), contains('PATH'));
  });
}
