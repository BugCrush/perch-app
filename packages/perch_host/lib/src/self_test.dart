// The self-test of a new Claude Code version. Off by default: it starts a short Claude Code
// session (Haiku) and so uses a little of the owner's plan.
//
// In a folder of its own inside the host state (`<state>/selftest`) it opens a visible
// terminal window running interactive `claude`, answers its folder-trust dialog if shown,
// and types one instruction that makes Claude ask two questions (one single choice, one
// multi-select), write a file (a permission request) and present a plan. Each dialog is
// answered with the same code that answers the app's cards in a terminal (TerminalAnswerer),
// then the transcript is checked: the answers reached Claude, the file was written, the
// plan was approved, and every line could be read. Pass: the version counts as checked.
// Failure: drift, with what the self-test saw. Afterwards it closes the window and its
// `claude` (only the process it started) and empties its folder.
//
// The session list, push notifications and hook handling leave the self-test out: it is
// recognised by its folder (`perch/selftest`, any host's) and by its name.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

import 'claude_session.dart';
import 'compatibility.dart';
import 'console_typer.dart';
import 'dialog_screen.dart';
import 'external_sessions.dart';
import 'terminal_prompts.dart';
import 'terminal_window.dart';
import 'transcript.dart';

const selfTestSessionName = 'Perch self-test';
const selfTestFolderName = 'selftest';
const selfTestFileName = 'perch-selftest.txt';
const selfTestFileText = 'perch self-test ok';

/// The one instruction. No "1." numbering: a numbered line on screen would look like a
/// dialog option.
const selfTestPrompt = 'This is an automated Perch self-test. Follow these steps exactly and in order, and ask nothing '
    'else. Step A: call the AskUserQuestion tool once with two questions. The first has header Colour, question '
    "'Perch self-test: which colour?', options Red and Blue, single choice. The second has header Fruit, question "
    "'Perch self-test: which fruits?', options Apple, Pear and Plum, multiSelect true. Step B: use the Write tool to "
    'create the file $selfTestFileName in the current folder containing the single line: $selfTestFileText. '
    'Step C: call the EnterPlanMode tool, then call ExitPlanMode with this plan: Reply DONE. Step D: once the plan '
    'is approved, reply with the single word DONE and use no tool.';

/// Whether [path] is a Perch self-test folder (`…/perch/selftest` or `…/.perch/selftest`,
/// or inside one), of this host or another one on the machine.
bool isSelfTestFolder(String? path) {
  if (path == null || path.isEmpty) return false;
  final parts = [
    for (final p in path.replaceAll('\\', '/').split('/'))
      if (p.isNotEmpty) p.toLowerCase()
  ];
  for (var i = 1; i < parts.length; i++) {
    if (parts[i] == selfTestFolderName && (parts[i - 1] == 'perch' || parts[i - 1] == '.perch')) return true;
  }
  return false;
}

/// Whether a session from `claude agents --json` is a self-test.
bool isSelfTestEntry(ExternalEntry e) => isSelfTestFolder(e.summary.cwd) || e.summary.name == selfTestSessionName;

/// Whether a Claude Code hook's input comes from a self-test session.
bool isSelfTestHook(Map<String, dynamic> j) => isSelfTestFolder(j['cwd'] is String ? j['cwd'] as String : null);

class SelfTestOutcome {
  /// False when it could not run at all (not supported here, version unknown).
  final bool ran;
  final bool passed;
  final String? reason;

  /// What the self-test saw, step by step, and the bottom of the screen on failure.
  final String evidence;
  const SelfTestOutcome({required this.ran, required this.passed, this.reason, this.evidence = ''});
}

/// The setting and the last result, in one line (the console and `perch_host selftest`).
String selfTestLine(Compatibility c) {
  final t = c.selfTest;
  if (t == null) return 'Self-test: not available.';
  final setting = t.enabled
      ? 'on (runs by itself once for each new Claude Code version)'
      : 'off (run it with: perch_host selftest run)';
  final last = switch (t.state) {
    SelfTestState.idle => '',
    SelfTestState.running => ' Running now.',
    SelfTestState.passed => ' Passed on Claude Code ${t.version}.',
    SelfTestState.failed => ' Failed on Claude Code ${t.version}: ${t.reason}',
    SelfTestState.unsupported => ' ${t.reason}',
  };
  return 'Self-test of new Claude Code versions: $setting.$last';
}

String selfTestResultText(SelfTestOutcome r) {
  if (!r.ran) return 'The self-test did not run: ${r.reason}';
  return [r.passed ? 'Self-test passed.' : 'Self-test failed: ${r.reason}', if (r.evidence.isNotEmpty) r.evidence]
      .join('\n');
}

class _Fail implements Exception {
  final String reason;
  _Fail(this.reason);
}

class SelfTester {
  final CompatibilityTracker tracker;
  final ClaudeLauncher launcher;
  final ExternalSessions external;
  final TerminalConsole console;
  final TerminalWindowOpener openWindow;

  /// The host state directory; the self-test works in `<stateDir>/selftest`.
  final String stateDir;
  final String? configDir;
  final DateTime Function() _clock;

  /// How often to look at the screen; how long Claude Code may take to start; how long it
  /// may go without asking anything; the whole run; how long the transcript may lag.
  final Duration poll;
  final Duration startTimeout;
  final Duration stallTimeout;
  final Duration runTimeout;
  final Duration transcriptTimeout;
  final Duration answerPoll;
  final Duration answerTimeout;
  final Duration closeTimeout;

  /// At most one automatic run per this long.
  final Duration minInterval;

  /// One line per step, as it happens (the console).
  final void Function(String line)? log;

  SelfTester({
    required this.tracker,
    required this.launcher,
    required this.external,
    required this.console,
    required this.stateDir,
    TerminalWindowOpener? openWindow,
    this.configDir,
    DateTime Function()? clock,
    this.poll = const Duration(seconds: 1),
    this.startTimeout = const Duration(seconds: 60),
    this.stallTimeout = const Duration(seconds: 120),
    this.runTimeout = const Duration(minutes: 6),
    this.transcriptTimeout = const Duration(seconds: 30),
    this.answerPoll = const Duration(milliseconds: 300),
    this.answerTimeout = const Duration(seconds: 8),
    this.closeTimeout = const Duration(seconds: 8),
    this.minInterval = const Duration(hours: 1),
    this.log,
  })  : openWindow = openWindow ?? openTerminalWindow,
        _clock = clock ?? DateTime.now;

  String get folder => '$stateDir${Platform.pathSeparator}$selfTestFolderName';

  Future<SelfTestOutcome>? _running;
  StreamSubscription<Compatibility>? _sub;
  Timer? _later;

  bool get running => _running != null;

  /// Runs by itself when the setting is on and the installed version is unchecked.
  void start() {
    if (!console.supported) tracker.selfTestUnsupported('The self-test needs a terminal Perch can operate (Windows, or Terminal.app on a Mac).');
    _sub = tracker.changes.listen((_) => unawaited(maybeRun()));
    unawaited(maybeRun());
  }

  /// Runs now when the setting is on, the version is unchecked and has not been tried by
  /// itself, and no self-test started in the last [minInterval] (else it waits for that).
  Future<SelfTestOutcome?> maybeRun() async {
    final store = tracker.store;
    final v = tracker.version;
    if (!store.selfTestNewVersions || _running != null || !console.supported) return null;
    if (v == null || !tracker.untested || tracker.current.status == CompatibilityStatus.drifted) return null;
    if (store.selfTestAutoTried.contains(v) || store.selfTests.containsKey(v)) return null;
    final last = store.lastSelfTestAtMs;
    if (last != null) {
      final wait = Duration(milliseconds: last + minInterval.inMilliseconds - _clock().millisecondsSinceEpoch);
      if (wait > Duration.zero) {
        _later?.cancel();
        _later = Timer(wait, () => unawaited(maybeRun()));
        return null;
      }
    }
    store
      ..selfTestAutoTried.add(v)
      ..save();
    return run();
  }

  /// Runs the self-test now (one at a time; a second call gets the running one).
  Future<SelfTestOutcome> run() {
    final r = _running;
    if (r != null) return r;
    final f = _run().whenComplete(() => _running = null);
    _running = f;
    return f;
  }

  void _say(List<String> steps, String line) {
    steps.add(line);
    log?.call('Self-test: $line');
  }

  Future<SelfTestOutcome> _run() async {
    final v = tracker.version;
    if (!console.supported) {
      const why = 'The self-test needs a terminal Perch can operate (Windows, or Terminal.app on a Mac).';
      tracker.selfTestUnsupported(why);
      return const SelfTestOutcome(ran: false, passed: false, reason: why);
    }
    if (v == null) {
      return const SelfTestOutcome(ran: false, passed: false, reason: 'The Claude Code version is not known.');
    }
    tracker.selfTestStarted();
    final steps = <String>[];
    String? lastScreen;
    int? pid;
    String? runClaudeId;
    final started = _clock();
    SelfTestOutcome outcome;
    try {
      await _empty();
      Directory(folder).createSync(recursive: true);
      final before = {
        for (final e in await external.listEntries())
          if (e.pid != null) e.pid!
      };
      await openWindow(TerminalLaunch(
        cwd: folder,
        executable: launcher.executable,
        args: [
          ...launcher.leadingArgs,
          '--model',
          'haiku',
          '--permission-mode',
          'default',
          '-n',
          selfTestSessionName,
        ],
        environment: launcher.childEnvironment(),
        title: selfTestSessionName,
        keepOpen: false,
      ));
      _say(steps, 'opened a terminal window running claude in $folder');
      final entry = await _find(before);
      if (entry == null) throw _Fail('Claude Code did not start in the self-test window within ${startTimeout.inSeconds} s.');
      pid = entry.pid!;
      var claudeId = entry.claudeSessionId;
      runClaudeId = claudeId;
      _say(steps, 'claude started (pid $pid)');
      final answerer = TerminalAnswerer(console, pid, poll: answerPoll, timeout: answerTimeout);

      // The input box, or first the folder-trust dialog (this is Perch's own folder).
      var screen = await _waitScreen(pid, (s) => isPromptReady(s) || detectDialog(s) == DialogKind.trust, startTimeout,
          (s) => lastScreen = s);
      if (screen == null) throw _Fail('Claude Code did not show its input box.');
      if (detectDialog(screen) == DialogKind.trust) {
        await _answer(answerer, trustPrompt('selftest', folder), const PermissionAnswer(allow: true));
        _say(steps, 'trusted the self-test folder');
        screen = await _waitScreen(pid, isPromptReady, startTimeout, (s) => lastScreen = s);
        if (screen == null) throw _Fail('Claude Code did not show its input box after the folder was trusted.');
      }
      // Found before Claude Code listed it (it lists a session in an untrusted folder only
      // once trusted, and a new one a moment after it starts): its id comes from the listing.
      claudeId ??= await _claudeIdOf(pid);
      runClaudeId = claudeId;
      if (!await console.type(pid, selfTestPrompt)) throw _Fail('Could not type the instruction into the terminal.');
      _say(steps, 'typed the instruction');

      final expected = <String>[];
      var asked = false, permitted = false, planned = false;
      var progressAt = _clock();
      while (true) {
        final now = _clock();
        if (now.difference(started) > runTimeout) {
          throw _Fail('The self-test did not finish within ${runTimeout.inMinutes} minutes.');
        }
        final s = await console.screen(pid);
        if (s == null) throw _Fail('Could not read the self-test terminal.');
        lastScreen = s;
        switch (detectDialog(s)) {
          case DialogKind.question:
            final call = _pending(claudeId);
            var card = call != null && call.name == 'AskUserQuestion' ? promptForToolUse(call) : null;
            final first = card == null ? null : _questions(card).firstOrNull?['question'];
            // The review step lists every question, so it "shows" the first one too: once
            // the questions were answered step by step, it is answered from the screen.
            if (first is! String || !dialogShows(s, first) || isReviewScreen(s)) card = null;
            card ??= screenPrompt(s, 'selftest');
            if (card == null) throw _Fail('Claude Code shows a question Perch cannot read.');
            final answers = _choose(card, expected);
            await _answer(answerer, card, QuestionAnswer(answers));
            _say(steps, 'answered ${card.input['fromScreen'] == true ? 'a question step read from the screen' : 'the questions'}: '
                '${answers.values.join(' | ')}');
            asked = true;
            progressAt = _clock();
          case DialogKind.permission:
            final card = screenPrompt(s, 'selftest');
            if (card == null) throw _Fail('Claude Code shows a permission request Perch cannot read.');
            final call = _pending(claudeId);
            final tool = call?.name ?? card.toolName;
            final write = !permitted && (tool == 'Write' || s.contains(selfTestFileName));
            final plan = tool == 'EnterPlanMode' || s.toLowerCase().contains('plan mode');
            await _answer(answerer, card, PermissionAnswer(allow: write || plan));
            if (write) {
              permitted = true;
              _say(steps, 'allowed writing $selfTestFileName');
            } else {
              _say(steps, plan ? 'allowed entering plan mode' : 'refused an unexpected request ($tool)');
            }
            progressAt = _clock();
          case DialogKind.plan:
            final card = screenPrompt(s, 'selftest');
            if (card == null) throw _Fail('Claude Code shows a plan Perch cannot read.');
            await _answer(answerer, card, const PlanAnswer(approve: true));
            _say(steps, 'approved the plan');
            planned = true;
            progressAt = _clock();
          case DialogKind.trust:
            await _answer(answerer, trustPrompt('selftest', folder), const PermissionAnswer(allow: true));
            _say(steps, 'trusted the self-test folder');
            progressAt = _clock();
          case DialogKind.none:
            if (screenDrift(s) != null) {
              // A dialog mid-change is not drift: look again a moment later.
              await Future<void>.delayed(answerPoll);
              final again = await console.screen(pid);
              final why = again == null ? null : screenDrift(again);
              if (why != null) {
                lastScreen = again;
                throw _Fail(why);
              }
            }
            if (!(asked && permitted && planned) && _clock().difference(progressAt) > stallTimeout) {
              final missing = [if (!asked) 'the questions', if (!permitted) 'the permission request', if (!planned) 'the plan'];
              throw _Fail('Claude Code showed nothing to answer for ${stallTimeout.inSeconds} s '
                  '(still expected ${missing.join(', ')}).');
            }
        }
        if (asked && permitted && planned && isPromptReady(s)) break;
        await Future<void>.delayed(poll);
      }
      _say(steps, 'Claude finished; checking the transcript');
      claudeId ??= await _claudeIdOf(pid);
      await _verify(claudeId, expected);
      _say(steps, 'the transcript shows the answers, the file and the approved plan');
      outcome = SelfTestOutcome(ran: true, passed: true, evidence: _evidence(steps, null));
    } on _Fail catch (e) {
      _say(steps, 'failed: ${e.reason}');
      outcome = SelfTestOutcome(ran: true, passed: false, reason: e.reason, evidence: _evidence(steps, lastScreen));
    } catch (e) {
      _say(steps, 'failed: $e');
      outcome = SelfTestOutcome(ran: true, passed: false, reason: '$e', evidence: _evidence(steps, lastScreen));
    } finally {
      await _close(pid, steps);
      _removePlanFile(runClaudeId);
      await _empty();
    }
    tracker.selfTestFinished(version: v, passed: outcome.passed, reason: outcome.reason, evidence: outcome.evidence);
    return outcome;
  }

  String _evidence(List<String> steps, String? screen) {
    final b = StringBuffer('Self-test steps:\n');
    for (final s in steps) {
      b.writeln('- $s');
    }
    final lines = (screen ?? '').replaceAll('\r', '').split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isNotEmpty) {
      final shown = lines.length > evidenceScreenLines ? lines.sublist(lines.length - evidenceScreenLines) : lines;
      b.writeln('Screen (last ${shown.length} lines):');
      for (final l in shown) {
        b.writeln(l);
      }
    }
    return b.toString().trimRight();
  }

  Future<void> _answer(TerminalAnswerer a, PromptRequest p, PromptAnswer answer) async {
    try {
      await a.answer(p, answer);
    } on CannotAnswerInTerminal catch (e) {
      throw _Fail(e.message);
    }
  }

  static bool _samePath(String a, String b) {
    String norm(String p) {
      var n = p.replaceAll('\\', '/');
      while (n.length > 1 && n.endsWith('/')) {
        n = n.substring(0, n.length - 1);
      }
      return Platform.isWindows || Platform.isMacOS ? n.toLowerCase() : n;
    }

    return norm(a) == norm(b);
  }

  /// The new terminal session in the self-test folder.
  Future<ExternalEntry?> _find(Set<int> before) async {
    final end = _clock().add(startTimeout);
    while (true) {
      final found = (await external.listEntries())
          .where((e) => e.interactive && e.pid != null && !before.contains(e.pid) && _samePath(e.summary.cwd, folder))
          .firstOrNull;
      if (found != null) return found;
      if (_clock().isAfter(end)) return null;
      await Future<void>.delayed(poll);
    }
  }

  Future<String?> _claudeIdOf(int pid) async {
    final end = _clock().add(startTimeout);
    while (true) {
      final id = (await external.listEntries()).where((e) => e.pid == pid).firstOrNull?.claudeSessionId;
      if (id != null || _clock().isAfter(end)) return id;
      await Future<void>.delayed(poll);
    }
  }

  Future<String?> _waitScreen(int pid, bool Function(String) ok, Duration timeout, void Function(String) seen) async {
    final end = _clock().add(timeout);
    while (true) {
      final s = await console.screen(pid);
      if (s != null) {
        seen(s);
        if (ok(s)) return s;
      }
      if (_clock().isAfter(end)) return null;
      await Future<void>.delayed(poll);
    }
  }

  static List<Map<String, dynamic>> _questions(PromptRequest p) {
    final raw = p.input['questions'];
    return [
      for (final q in (raw is List ? raw : const []))
        if (q is Map) q.cast<String, dynamic>()
    ];
  }

  static List<String> _labels(Map<String, dynamic> q) => [
        for (final o in (q['options'] is List ? q['options'] as List : const []))
          if (o is Map && o['label'] is String) o['label'] as String
      ];

  /// The answers the self-test gives: Blue (or the last option) for a single choice; Apple
  /// and Plum (or the first and the last) for a multi-select; Submit on a review step. The
  /// labels Claude must receive are added to [expected].
  static Map<String, String> _choose(PromptRequest card, List<String> expected) {
    final out = <String, String>{};
    for (final q in _questions(card)) {
      final text = '${q['question'] ?? ''}';
      final labels = _labels(q);
      if (labels.isEmpty) continue;
      final submit = labels.where((l) => l.toLowerCase().startsWith('submit')).firstOrNull;
      if (submit != null) {
        out[text] = submit;
        continue;
      }
      if (q['multiSelect'] == true) {
        final want = labels.contains('Apple') && labels.contains('Plum') ? ['Apple', 'Plum'] : {labels.first, labels.last}.toList();
        out[text] = [for (final l in labels) if (want.contains(l)) l].join(', ');
        expected.addAll(want);
      } else {
        final pick = labels.contains('Blue') ? 'Blue' : labels.last;
        out[text] = pick;
        expected.add(pick);
      }
    }
    return out;
  }

  /// The transcript's events, or null when it is not there yet.
  ({List<ConversationEvent> events, int malformed})? _read(String? claudeId) {
    if (claudeId == null) return null;
    final f = findTranscript(claudeId, configDir: configDir);
    if (f == null) return null;
    try {
      final events = <ConversationEvent>[];
      var malformed = 0;
      for (final line in f.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        final t = parseTranscriptLine(line);
        if (t is TranscriptEvents) events.addAll(t.events);
        if (t is TranscriptMalformed) malformed++;
      }
      return (events: events, malformed: malformed);
    } catch (_) {
      return null;
    }
  }

  ToolCall? _pending(String? claudeId) {
    final r = _read(claudeId);
    return r == null ? null : pendingToolUse(r.events);
  }

  /// What the transcript must show; null when it does, else what is missing.
  String? _missing(String? claudeId, List<String> expected) {
    if (claudeId == null) return 'Claude Code listed the self-test session without its session id.';
    final r = _read(claudeId);
    if (r == null) return 'The self-test session has no transcript.';
    if (r.malformed > 0) return "${r.malformed} transcript lines could not be read.";
    final results = {for (final e in r.events) if (e is ToolResult) e.toolUseId: e};
    ToolResult? resultOf(String tool) {
      for (final e in r.events) {
        if (e is ToolCall && e.name == tool && results.containsKey(e.toolUseId)) return results[e.toolUseId];
      }
      return null;
    }

    final asked = resultOf('AskUserQuestion');
    if (asked == null || asked.isError) return 'The transcript has no answered AskUserQuestion.';
    for (final label in expected) {
      if (!asked.text.contains(label)) return 'Claude did not receive the answer "$label" (it got: ${asked.text}).';
    }
    final wrote = resultOf('Write');
    if (wrote == null || wrote.isError) return 'The transcript shows no successful Write.';
    final file = File('$folder${Platform.pathSeparator}$selfTestFileName');
    if (!file.existsSync()) return '$selfTestFileName was not written.';
    final plan = resultOf('ExitPlanMode');
    if (plan == null || plan.isError || !plan.text.toLowerCase().contains('approved')) {
      return 'The transcript does not show the plan approved${plan == null ? '' : ' (it shows: ${plan.text})'}.';
    }
    return null;
  }

  Future<void> _verify(String? claudeId, List<String> expected) async {
    final end = _clock().add(transcriptTimeout);
    while (true) {
      final missing = _missing(claudeId, expected);
      if (missing == null) return;
      if (_clock().isAfter(end)) throw _Fail(missing);
      await Future<void>.delayed(poll);
    }
  }

  /// Ends the `claude` this self-test started (asks it to exit, then stops it), which also
  /// closes its window.
  Future<void> _close(int? pid, List<String> steps) async {
    if (pid == null) return;
    try {
      final tty = await ttyOf(pid);
      final s = await console.screen(pid);
      if (s != null && isPromptReady(s)) await console.type(pid, '/exit');
      final end = _clock().add(closeTimeout);
      while (await external.pidAlive(pid)) {
        if (_clock().isAfter(end)) {
          await external.killPid(pid);
          _say(steps, 'stopped claude (pid $pid)');
          return;
        }
        await Future<void>.delayed(poll);
      }
      // macOS: Terminal keeps a window whose shell ended; close it (Windows: `cmd /c` did).
      if (tty != null) await closeFinishedTerminalWindow(tty);
      _say(steps, 'claude exited and its window closed');
    } catch (_) {}
  }

  /// Deletes the plan file Claude Code wrote for this run, so self-tests leave nothing in
  /// `<config dir>/plans`. Claude Code 2.1.326 named it in ExitPlanMode's input; 2.1.327
  /// writes that input empty and names the file only in `plan_mode` / `plan_mode_exit`
  /// attachment lines. Only a file directly in that folder is deleted.
  void _removePlanFile(String? claudeId) {
    try {
      if (claudeId == null) return;
      final r = _read(claudeId);
      final paths = <String>{
        for (final e in r?.events ?? const <ConversationEvent>[])
          if (e is ToolCall && e.name == 'ExitPlanMode' && e.input['planFilePath'] is String)
            e.input['planFilePath'] as String,
      };
      final t = findTranscript(claudeId, configDir: configDir);
      if (t != null) {
        for (final line in t.readAsLinesSync()) {
          if (!line.contains('"planFilePath"')) continue;
          try {
            final j = jsonDecode(line);
            final a = j is Map ? j['attachment'] : null;
            if (a is Map && a['planFilePath'] is String) paths.add(a['planFilePath'] as String);
          } catch (_) {}
        }
      }
      final plans = '${configDir ?? claudeConfigDir()}${Platform.pathSeparator}plans';
      for (final path in paths) {
        if (!path.toLowerCase().endsWith('.md')) continue;
        final f = File(path);
        if (f.parent.absolute.path != Directory(plans).absolute.path) continue;
        if (f.existsSync()) f.deleteSync();
      }
    } catch (_) {}
  }

  /// Deletes what is in the self-test folder (a file still held open is retried briefly).
  Future<void> _empty() async {
    final dir = Directory(folder);
    for (var attempt = 0; attempt < 5; attempt++) {
      if (!dir.existsSync()) return;
      var left = false;
      for (final e in dir.listSync()) {
        try {
          e.deleteSync(recursive: true);
        } catch (_) {
          left = true;
        }
      }
      if (!left) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> dispose() async {
    _later?.cancel();
    await _sub?.cancel();
  }
}
