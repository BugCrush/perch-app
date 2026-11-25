import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/compatibility.dart';
import 'package:perch_host/src/console_typer.dart';
import 'package:perch_host/src/self_test.dart';
import 'package:perch_host/src/terminal_window.dart';
import 'package:perch_host/src/version_store.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final sep = Platform.pathSeparator;
final rule = '─' * 100;
const claudeId = 'cccccccc-0000-4000-8000-00000000000c';
const pid = 4242;

/// A scripted interactive Claude Code in the self-test window: it draws the screens of
/// Claude Code 2.1.323 (same layout as the fixtures), reacts to keys like the real one,
/// and writes the transcript lines as each step completes.
class FakeSelfTestClaude implements TerminalConsole {
  final FakeExternalSessions external;
  final String folder;
  final File transcript;

  /// Where it starts (`trust` or `idle`) and what it shows after the instruction.
  String phase;
  String afterPrompt;

  /// The AskUserQuestion tool use is in the transcript while the question shows (else it
  /// is written only once answered, as Claude Code does for a session's first turn).
  final bool earlyTranscript;

  /// The AskUserQuestion tool use reaches the transcript while the review step shows, after
  /// the questions were answered from the screen (seen with Claude Code 2.1.325 on Windows).
  final bool transcriptAtReview;

  /// What Claude receives instead of the real answers (an answer that got lost).
  final String? answerOverride;
  final bool rejectPlan;

  /// Where Claude Code writes the plan (it names it in ExitPlanMode's input), or null.
  final String? planFile;

  /// Claude Code 2.1.327: ExitPlanMode's input is empty in the transcript and the plan file
  /// is named only in `plan_mode` / `plan_mode_exit` attachment lines.
  final bool planFileInAttachment;

  final List<String> typed = [];
  final Set<int> ticks = {};
  String colour = '';

  FakeSelfTestClaude({
    required this.external,
    required this.folder,
    required this.transcript,
    this.phase = 'idle',
    this.afterPrompt = 'q1',
    this.earlyTranscript = false,
    this.transcriptAtReview = false,
    this.answerOverride,
    this.rejectPlan = false,
    this.planFile,
    this.planFileInAttachment = false,
  });

  @override
  bool supported = true;

  void _line(Map<String, dynamic> j) {
    transcript.parent.createSync(recursive: true);
    transcript.writeAsStringSync('${jsonEncode({'sessionId': claudeId, 'timestamp': '2026-11-14T10:00:00.000Z', ...j})}\n',
        mode: FileMode.append);
  }

  void _toolUse(String id, String name, Map<String, dynamic> input) => _line({
        'type': 'assistant',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'tool_use', 'id': id, 'name': name, 'input': input}
          ]
        }
      });

  void _toolResult(String id, String text, {bool isError = false}) => _line({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': id, 'content': text, 'is_error': isError}
          ]
        }
      });

  static const askInput = {
    'questions': [
      {
        'question': 'Perch self-test: which colour?',
        'header': 'Colour',
        'options': [
          {'label': 'Red', 'description': ''},
          {'label': 'Blue', 'description': ''}
        ],
        'multiSelect': false
      },
      {
        'question': 'Perch self-test: which fruits?',
        'header': 'Fruit',
        'options': [
          {'label': 'Apple', 'description': ''},
          {'label': 'Pear', 'description': ''},
          {'label': 'Plum', 'description': ''}
        ],
        'multiSelect': true
      }
    ]
  };

  String get _fruits => [
        for (final (i, l) in ['Apple', 'Pear', 'Plum'].indexed)
          if (ticks.contains(i + 1)) l
      ].join(', ');

  @override
  Future<bool> type(int p, String text) async {
    typed.add(text);
    if (text == '/exit') {
      external.entries.removeWhere((e) => e.pid == p);
      return true;
    }
    if (phase == 'idle' && text == selfTestPrompt) {
      phase = afterPrompt;
      _line({
        'type': 'user',
        'message': {'role': 'user', 'content': text}
      });
      if (earlyTranscript && phase == 'q1') _toolUse('ask1', 'AskUserQuestion', askInput);
    }
    return true;
  }

  @override
  Future<bool> keys(int p, String keys) async {
    for (final k in keys.split('')) {
      _key(k);
    }
    return true;
  }

  @override
  Future<bool> pressEnter(int p) async {
    _key('enter');
    return true;
  }

  void _key(String k) {
    switch ((phase, k)) {
      case ('trust', _) when k == ConsoleKeys.down:
        phase = 'trustYes';
      case ('trustYes', 'enter'):
        phase = 'idle';
      case ('q1', '1' || '2'):
        colour = k == '1' ? 'Red' : 'Blue';
        phase = 'q2';
      case ('q2', '1' || '2' || '3'):
        final n = int.parse(k);
        if (!ticks.remove(n)) ticks.add(n);
      case ('q2', _) when k == ConsoleKeys.right:
        phase = 'review';
        if (transcriptAtReview) _toolUse('ask1', 'AskUserQuestion', askInput);
      case ('review', '1'):
        if (!earlyTranscript && !transcriptAtReview) _toolUse('ask1', 'AskUserQuestion', askInput);
        _toolResult(
            'ask1',
            answerOverride ??
                'User has answered your questions: "Perch self-test: which colour?"="$colour", '
                    '"Perch self-test: which fruits?"="$_fruits". You can now continue with the user\'s answers in mind.');
        phase = 'perm';
      case ('perm', '1'):
        File('$folder$sep$selfTestFileName').writeAsStringSync('$selfTestFileText\n');
        _toolUse('write1', 'Write', {'file_path': '$folder$sep$selfTestFileName', 'content': selfTestFileText});
        _toolResult('write1', 'File created successfully at: $folder$sep$selfTestFileName');
        phase = 'plan';
      case ('plan', '1'):
        final pf = planFile;
        if (pf != null) {
          File(pf)
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('Reply DONE.');
        }
        if (planFileInAttachment) {
          _toolUse('plan1', 'ExitPlanMode', {});
          if (pf != null) {
            _line({
              'type': 'attachment',
              'attachment': {'type': 'plan_mode_exit', 'planFilePath': pf, 'planExists': true}
            });
          }
        } else {
          _toolUse('plan1', 'ExitPlanMode', {'plan': 'Reply DONE.', 'planFilePath': ?pf});
        }
        _toolResult('plan1', rejectPlan ? "The user doesn't want to proceed with this tool use." : 'User has approved your plan. You can now start coding.',
            isError: rejectPlan);
        phase = 'done';
      default:
        break;
    }
  }

  @override
  Future<bool> bringForward(int p) async => true;

  @override
  Future<bool> canOperate(int p) async => true;

  @override
  Future<String?> screen(int p) async {
    if (!external.entries.any((e) => e.pid == p)) return null;
    return switch (phase) {
      'trust' || 'trustYes' => [
          rule,
          ' Accessing workspace:',
          ' $folder',
          " Quick safety check: Is this a project you created or one you trust?",
          " Claude Code'll be able to read, edit, and execute files here.",
          ' Security guide',
          phase == 'trust' ? ' ❯ No, exit' : '   No, exit',
          phase == 'trust' ? '   Yes, I trust this folder' : ' ❯ Yes, I trust this folder',
          ' Enter to confirm · Esc to cancel',
        ].join('\n'),
      'idle' || 'done' || 'quiet' => [
          ' ▐▛███▛█   Claude Code v2.1.332',
          if (phase == 'done') '● DONE',
          rule,
          '❯ ',
          '${'─' * 80} Perch self-test ─',
          '  ? for shortcuts',
        ].join('\n'),
      'q1' => [
          rule,
          '←  ☐ Colour  ☐ Fruit  ✔ Submit  →',
          'Perch self-test: which colour?',
          '❯ 1. Red',
          '     Red',
          '  2. Blue',
          '     Blue',
          '  3. Type something.',
          rule,
          '  4. Chat about this',
          'Enter to select · Tab/Arrow keys to navigate · Esc to cancel',
        ].join('\n'),
      'q2' => [
          rule,
          '←  ☒ Colour  ☐ Fruit  ✔ Submit  →',
          'Perch self-test: which fruits?',
          for (final (i, l) in ['Apple', 'Pear', 'Plum'].indexed) ...[
            '${i == 0 ? '❯' : ' '} ${i + 1}. [${ticks.contains(i + 1) ? '✔' : ' '}] $l',
            '         $l',
          ],
          '  4. [ ] Type something',
          '     Submit',
          rule,
          '  5. Chat about this',
          'Enter to select · ↑/↓ to navigate · Esc to cancel',
        ].join('\n'),
      'review' => [
          rule,
          '←  ☒ Colour  ☒ Fruit  ✔ Submit  →',
          'Review your answers',
          ' ● Perch self-test: which colour?',
          '   → $colour',
          ' ● Perch self-test: which fruits?',
          '   → $_fruits',
          'Ready to submit your answers?',
          '❯ 1. Submit answers',
          '  2. Cancel',
        ].join('\n'),
      'perm' => [
          '● Write($selfTestFileName)',
          '',
          rule,
          ' Create file',
          ' $selfTestFileName',
          '╌' * 40,
          '  1 $selfTestFileText',
          '╌' * 40,
          ' Do you want to create $selfTestFileName?',
          ' ❯ 1. Yes',
          '   2. Yes, and switch to accept edits (shift+tab)',
          '   3. No',
          ' Esc to cancel · Tab to amend',
        ].join('\n'),
      'plan' => [
          " Here is Claude's plan:",
          '╌' * 60,
          ' Reply DONE.',
          '╌' * 60,
          rule,
          ' Claude has written up a plan and is ready to execute. Would you like to proceed?',
          ' ❯ 1. Yes, and use auto mode',
          '   2. Yes, manually approve edits',
          '   3. Tell Claude what to change',
          '      shift+tab to approve with this feedback',
          ' ctrl+g to edit in Notepad',
        ].join('\n'),
      'weird' => [
          rule,
          ' Something new?',
          ' ❯ 1. Maybe',
          '   2. Later',
          ' Esc to cancel',
        ].join('\n'),
      _ => '',
    };
  }
}

void main() {
  late Directory tmp;
  late String stateDir;
  late String configDir;
  late FakeExternalSessions external;
  late List<TerminalLaunch> launches;
  late CompatibilityTracker tracker;
  late DateTime now;
  FakeSelfTestClaude? claude;

  /// What opening the window does (default: Claude Code starts in it).
  late void Function(TerminalLaunch) onLaunch;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_selftest_');
    stateDir = '${tmp.path}${sep}state${sep}perch';
    configDir = '${tmp.path}${sep}config';
    external = FakeExternalSessions();
    launches = [];
    now = DateTime(2026, 11, 14, 10);
    tracker = CompatibilityTracker(store: VersionStore.load(stateDir), clock: () => now)..setVersion('2.1.332');
    onLaunch = (l) => external.entries
        .add(external.entry(pid: pid, sessionId: claudeId, cwd: l.cwd, name: selfTestSessionName));
  });

  tearDown(() async {
    await tracker.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  FakeSelfTestClaude fake(
          {String phase = 'idle',
          String afterPrompt = 'q1',
          bool early = false,
          bool atReview = false,
          String? answer,
          bool reject = false,
          String? planFile,
          bool planInAttachment = false}) =>
      claude = FakeSelfTestClaude(
        external: external,
        folder: '$stateDir$sep$selfTestFolderName',
        transcript: File('$configDir${sep}projects${sep}selftest$sep$claudeId.jsonl'),
        phase: phase,
        afterPrompt: afterPrompt,
        earlyTranscript: early,
        transcriptAtReview: atReview,
        answerOverride: answer,
        rejectPlan: reject,
        planFile: planFile,
        planFileInAttachment: planInAttachment,
      );

  SelfTester tester(TerminalConsole console, {List<String>? log}) => SelfTester(
        tracker: tracker,
        launcher: fakeLauncher(),
        external: external,
        console: console,
        stateDir: stateDir,
        configDir: configDir,
        clock: () => now,
        openWindow: (l) async {
          launches.add(l);
          onLaunch(l);
        },
        poll: const Duration(milliseconds: 5),
        answerPoll: const Duration(milliseconds: 5),
        answerTimeout: const Duration(milliseconds: 400),
        startTimeout: const Duration(milliseconds: 400),
        stallTimeout: const Duration(milliseconds: 300),
        transcriptTimeout: const Duration(milliseconds: 200),
        closeTimeout: const Duration(milliseconds: 100),
        log: log?.add,
      );

  /// The clock moves on by itself while a run waits (timeouts use it).
  Timer ticking() => Timer.periodic(const Duration(milliseconds: 5), (_) => now = now.add(const Duration(milliseconds: 5)));

  group('a run', () {
    test('passes_when_every_step_reaches_claude_and_then_cleans_up', () async {
      final c = fake(phase: 'trust');
      final t = ticking();
      final lines = <String>[];
      // Something left from an earlier run is removed first.
      Directory('$stateDir$sep$selfTestFolderName').createSync(recursive: true);
      File('$stateDir$sep$selfTestFolderName${sep}old.txt').writeAsStringSync('x');
      final r = await tester(c, log: lines).run();
      t.cancel();
      expect(r.reason, isNull);
      expect(r.passed, isTrue);
      // The window: Perch's own folder, Haiku, permission prompts on, named, closes with claude.
      final l = launches.single;
      expect(l.cwd, '$stateDir$sep$selfTestFolderName');
      expect(l.args, containsAllInOrder(['--model', 'haiku', '--permission-mode', 'default', '-n', 'Perch self-test']));
      expect(l.keepOpen, isFalse);
      expect(l.title, 'Perch self-test');
      expect(l.environment.keys, isNot(contains('CLAUDECODE')));
      // The answers Claude got, through the same keys as a card.
      expect(c.colour, 'Blue');
      expect(c.ticks, {1, 3});
      expect(c.typed, [selfTestPrompt, '/exit']);
      // Closed: claude asked to exit (nothing killed), the folder emptied.
      expect(external.kills, isEmpty);
      expect(external.entries, isEmpty);
      expect(Directory('$stateDir$sep$selfTestFolderName').listSync(), isEmpty);
      expect(r.evidence, contains('trusted the self-test folder'));
      expect(r.evidence, contains('approved the plan'));
      expect(lines.first, startsWith('Self-test: '));
      // The version is checked now, and stays so.
      expect(tracker.current.status, CompatibilityStatus.ok);
      expect(tracker.current.selfTest!.state, SelfTestState.passed);
      expect(VersionStore.load(stateDir).verified, contains('2.1.332'));
    });

    test('removes_the_plan_file_claude_code_wrote_for_it_and_no_other', () async {
      final plans = '$configDir${sep}plans';
      final other = File('$plans${sep}owners-plan.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('keep');
      final c = fake(phase: 'trust', planFile: '$plans${sep}self-test-plan.md');
      final t = ticking();
      final r = await tester(c).run();
      t.cancel();
      expect(r.passed, isTrue, reason: r.reason);
      expect(File('$plans${sep}self-test-plan.md').existsSync(), isFalse);
      expect(other.readAsStringSync(), 'keep');
    });

    test('removes_the_plan_file_named_only_in_an_attachment_line_claude_code_2_1_327', () async {
      final plans = '$configDir${sep}plans';
      final other = File('$plans${sep}owners-plan.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('keep');
      final c = fake(phase: 'trust', planFile: '$plans${sep}self-test-plan.md', planInAttachment: true);
      final t = ticking();
      final r = await tester(c).run();
      t.cancel();
      expect(r.passed, isTrue, reason: r.reason);
      expect(File('$plans${sep}self-test-plan.md').existsSync(), isFalse);
      expect(other.readAsStringSync(), 'keep');
    });

    test('a_plan_file_outside_the_plans_folder_is_left_alone', () async {
      final elsewhere = '${tmp.path}${sep}elsewhere${sep}plan.md';
      final c = fake(phase: 'trust', planFile: elsewhere);
      final t = ticking();
      final r = await tester(c).run();
      t.cancel();
      expect(r.passed, isTrue, reason: r.reason);
      expect(File(elsewhere).existsSync(), isTrue);
    });

    test('uses_the_card_from_the_transcript_when_claude_code_wrote_it_already', () async {
      final c = fake(early: true);
      final t = ticking();
      final r = await tester(c).run();
      t.cancel();
      expect(r.passed, isTrue, reason: r.evidence);
      expect(r.evidence, contains('answered the questions'));
      expect(c.ticks, {1, 3});
    });

    test('the_review_step_is_answered_from_the_screen_when_the_transcript_catches_up_there', () async {
      // The review lists the questions, so the transcript's card seemed to match it.
      final c = fake(atReview: true);
      final t = ticking();
      final r = await tester(c).run();
      t.cancel();
      expect(r.passed, isTrue, reason: r.evidence);
      expect(r.evidence, contains('a question step read from the screen: Submit answers'));
      expect(c.ticks, {1, 3});
    });

    test('claude_code_not_starting_fails_without_killing_anything', () async {
      onLaunch = (_) {};
      final t = ticking();
      final r = await tester(fake()).run();
      t.cancel();
      expect(r.passed, isFalse);
      expect(r.reason, contains('did not start'));
      expect(external.kills, isEmpty);
      expect(tracker.current.status, CompatibilityStatus.drifted);
      expect(tracker.current.evidence, contains('Self-test steps'));
    });

    test('a_dialog_perch_cannot_read_fails_with_the_screen_and_the_window_is_closed', () async {
      final t = ticking();
      final r = await tester(fake(afterPrompt: 'weird')).run();
      t.cancel();
      expect(r.passed, isFalse);
      expect(r.reason, 'Claude Code shows a dialog Perch cannot recognise.');
      expect(r.evidence, contains('1. Maybe'));
      // Not at its input box, so it is stopped: only the pid it started.
      expect(external.kills, [pid]);
      final c = tracker.current;
      expect(c.status, CompatibilityStatus.drifted);
      expect(c.reason, contains('self-test'));
      expect(c.evidence, contains('1. Maybe'));
      expect(c.selfTest!.state, SelfTestState.failed);
    });

    test('an_answer_that_did_not_reach_claude_fails', () async {
      final t = ticking();
      final r = await tester(fake(answer: 'User has answered your questions: "x"="Red"')).run();
      t.cancel();
      expect(r.passed, isFalse);
      expect(r.reason, contains('did not receive the answer "Blue"'));
    });

    test('a_plan_that_was_not_approved_fails', () async {
      final t = ticking();
      final r = await tester(fake(reject: true)).run();
      t.cancel();
      expect(r.passed, isFalse);
      expect(r.reason, contains('plan approved'));
    });

    test('claude_asking_nothing_fails_after_a_while', () async {
      final t = ticking();
      final r = await tester(fake(afterPrompt: 'quiet')).run();
      t.cancel();
      expect(r.passed, isFalse);
      expect(r.reason, contains('showed nothing to answer'));
      expect(r.reason, contains('the questions'));
    });

    test('a_machine_without_terminal_control_does_not_run_it', () async {
      final c = fake()..supported = false;
      final r = await tester(c).run();
      expect(r.ran, isFalse);
      expect(launches, isEmpty);
      expect(tracker.current.selfTest!.state, SelfTestState.unsupported);
      expect(tracker.current.status, CompatibilityStatus.untested);
    });

    test('a_second_run_while_one_runs_is_the_same_run', () async {
      final t = ticking();
      final st = tester(fake());
      final a = st.run();
      final b = st.run();
      expect(identical(a, b), isTrue);
      expect(tracker.current.selfTest!.state, SelfTestState.running);
      await a;
      t.cancel();
      expect(launches, hasLength(1));
    });
  });

  group('running by itself', () {
    test('only_when_the_setting_is_on_once_per_version_and_once_an_hour', () async {
      final t = ticking();
      final st = tester(fake());
      expect(await st.maybeRun(), isNull); // off by default
      expect(launches, isEmpty);
      tracker.setSelfTestEnabled(true);
      expect((await st.maybeRun())!.passed, isTrue);
      expect(launches, hasLength(1));
      expect(await st.maybeRun(), isNull); // checked now, and tried
      // A new version within the hour waits.
      tracker.setVersion('2.1.333');
      await tracker.releaseNotesDone;
      fake();
      final st2 = tester(claude!);
      expect(await st2.maybeRun(), isNull);
      expect(launches, hasLength(1));
      // An hour later it runs, once.
      now = now.add(const Duration(hours: 1, minutes: 1));
      expect(await st2.maybeRun(), isNotNull);
      expect(launches, hasLength(2));
      expect(await st2.maybeRun(), isNull);
      t.cancel();
      await st.dispose();
      await st2.dispose();
    });

    test('a_version_tried_before_a_restart_is_not_tried_again', () async {
      tracker.store
        ..selfTestNewVersions = true
        ..selfTestAutoTried.add('2.1.332')
        ..save();
      final st = tester(fake());
      expect(await st.maybeRun(), isNull);
      expect(launches, isEmpty);
    });

    test('a_checked_or_drifted_version_is_not_tested', () async {
      tracker.setSelfTestEnabled(true);
      tracker.setVersion('2.1.323');
      final st = tester(fake());
      expect(await st.maybeRun(), isNull);
      tracker.setVersion('2.1.334');
      tracker.drift(reason: 'r', session: 's', expected: 'e');
      expect(await st.maybeRun(), isNull);
      expect(launches, isEmpty);
    });

    test('turning_it_on_starts_it_through_the_status_changes', () async {
      final t = ticking();
      final st = tester(fake())..start();
      tracker.setSelfTestEnabled(true);
      await waitUntil(() => launches.isNotEmpty && !st.running, timeout: const Duration(seconds: 10));
      t.cancel();
      expect(tracker.current.status, CompatibilityStatus.ok);
      await st.dispose();
    });
  });

  group('recognising the self-test', () {
    test('by_its_folder_of_any_host_on_the_machine', () {
      expect(isSelfTestFolder(r'C:\Users\me\AppData\Roaming\perch\selftest'), isTrue);
      expect(isSelfTestFolder(r'D:\projects\perch\.scratch\appdata\perch\selftest'), isTrue);
      expect(isSelfTestFolder(r'C:\Users\me\AppData\Roaming\Perch\SelfTest\'), isTrue);
      expect(isSelfTestFolder('/home/me/.perch/selftest'), isTrue);
      expect(isSelfTestFolder(r'D:\projects\perch'), isFalse);
      expect(isSelfTestFolder(r'D:\projects\selftest'), isFalse);
      expect(isSelfTestFolder(null), isFalse);
      expect(isSelfTestHook({'cwd': r'C:\Users\me\AppData\Roaming\perch\selftest', 'session_id': 'x'}), isTrue);
      expect(isSelfTestHook({'cwd': r'D:\work', 'session_id': 'x'}), isFalse);
    });
  });
}
