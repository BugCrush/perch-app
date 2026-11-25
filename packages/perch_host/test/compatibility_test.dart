import 'dart:async';
import 'dart:io';

import 'package:perch_host/src/compatibility.dart';
import 'package:perch_host/src/release_notes.dart';
import 'package:perch_host/src/version_store.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('version_comparison', () {
    expect(compareVersions('2.1.323', '2.1.323'), 0);
    expect(compareVersions('2.1.326', '2.1.323'), greaterThan(0));
    expect(compareVersions('2.2.0', '2.1.999'), greaterThan(0));
    expect(compareVersions('2.1.9', '2.1.10'), lessThan(0));
    expect(compareVersions('3.0', '2.9.9'), greaterThan(0));
    expect(newestCheckedClaudeVersion, checkedClaudeVersions.reduce((a, b) => compareVersions(a, b) >= 0 ? a : b));
    expect(checkedClaudeVersions, contains('2.1.323'));
  });

  test('status_follows_the_installed_version', () {
    final t = CompatibilityTracker();
    expect(t.current.status, CompatibilityStatus.ok);
    t.setVersion('2.1.323');
    expect(t.current.status, CompatibilityStatus.ok);
    expect(t.current.claudeVersion, '2.1.323');
    t.setVersion('2.1.322');
    expect(t.current.status, CompatibilityStatus.ok);
    t.setVersion('2.1.332');
    expect(t.current.status, CompatibilityStatus.untested);
    t.setVersion(null); // could not run claude --version: keep what is known
    expect(t.current.status, CompatibilityStatus.untested);
  });

  test('drift_is_raised_once_and_cleared_when_the_version_changes', () async {
    final t = CompatibilityTracker()..setVersion('2.1.323');
    final changes = <Compatibility>[];
    final sub = t.changes.listen(changes.add);
    t.drift(reason: 'Claude Code shows a dialog Perch cannot recognise.', session: 'work (abc)', expected: 'a question', screen: 'line 1\n> 1. Maybe\n');
    t.drift(reason: 'Another reason', session: 's', expected: 'e');
    await Future<void>.delayed(Duration.zero);
    expect(t.current.status, CompatibilityStatus.drifted);
    expect(t.current.reason, 'Claude Code shows a dialog Perch cannot recognise.');
    expect(t.current.evidence, contains('Session: work (abc)'));
    expect(t.current.evidence, contains('Expected: a question'));
    expect(t.current.evidence, contains('Claude Code: 2.1.323'));
    expect(t.current.evidence, contains('> 1. Maybe'));
    expect(changes, hasLength(1));

    t.setVersion('2.1.323'); // same version: still drifted
    expect(t.current.status, CompatibilityStatus.drifted);
    t.setVersion('2.1.334');
    await Future<void>.delayed(Duration.zero);
    expect(t.current.status, CompatibilityStatus.untested);
    expect(changes.last.status, CompatibilityStatus.untested);
    await sub.cancel();
  });

  test('evidence_keeps_the_bottom_of_the_screen', () {
    final t = CompatibilityTracker()..setVersion('2.1.323');
    final screen = [for (var i = 1; i <= 40; i++) 'row $i'].join('\n');
    t.drift(reason: 'r', session: 's', expected: 'e', screen: screen);
    expect(t.current.evidence, contains('row 40'));
    expect(t.current.evidence, isNot(contains('row 10\n')));
  });

  test('the_version_is_read_again_on_a_timer', () async {
    var v = '2.1.323';
    final t = CompatibilityTracker();
    final timer = t.watchVersion(() async => v, every: const Duration(milliseconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(t.current.claudeVersion, '2.1.323');
    v = '2.1.400';
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(t.current.status, CompatibilityStatus.untested);
    timer.cancel();
  });

  group('learning from real use', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('perch_learn_'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('each_kind_that_works_is_recorded_and_all_three_make_the_version_checked', () async {
      final store = VersionStore.load(tmp.path);
      final t = CompatibilityTracker(store: store)..setVersion('2.1.332');
      final changes = <Compatibility>[];
      final sub = t.changes.listen(changes.add);
      expect(t.current.status, CompatibilityStatus.untested);
      t.recordWorking(WorkingKinds.question);
      t.recordWorking(WorkingKinds.question); // again: nothing new
      t.recordWorking(WorkingKinds.transcript);
      t.recordWorking(WorkingKinds.permission);
      await Future<void>.delayed(Duration.zero);
      expect(t.current.status, CompatibilityStatus.untested);
      expect(t.current.seenWorking, unorderedEquals(['question', 'transcript', 'permission']));
      expect(seenWorkingLine(t.current), 'Seen working on 2.1.332: questions ✓, permissions ✓, plans —');
      expect(changes, hasLength(3));
      t.recordWorking(WorkingKinds.plan);
      await Future<void>.delayed(Duration.zero);
      expect(t.current.status, CompatibilityStatus.ok);
      expect(changes.last.status, CompatibilityStatus.ok);
      expect(store.verified, contains('2.1.332'));
      // Persisted: a restarted host knows.
      final again = CompatibilityTracker(store: VersionStore.load(tmp.path))..setVersion('2.1.332');
      expect(again.current.status, CompatibilityStatus.ok);
      // A newer version is unchecked again; the notes are read from after the verified one.
      again.setVersion('2.1.333');
      expect(again.current.status, CompatibilityStatus.untested);
      expect(again.newestChecked, '2.1.332');
      await sub.cancel();
    });

    test('progress_survives_a_restart', () {
      CompatibilityTracker(store: VersionStore.load(tmp.path))
        ..setVersion('2.1.332')
        ..recordWorking(WorkingKinds.plan);
      final t = CompatibilityTracker(store: VersionStore.load(tmp.path))..setVersion('2.1.332');
      expect(t.current.seenWorking, ['plan']);
      expect(seenWorkingLine(t.current), 'Seen working on 2.1.332: questions —, permissions —, plans ✓');
    });

    test('nothing_is_recorded_for_a_checked_version', () {
      final store = VersionStore.load(tmp.path);
      final t = CompatibilityTracker(store: store)..setVersion('2.1.323');
      t.recordWorking(WorkingKinds.question);
      expect(store.working('2.1.323'), isEmpty);
      expect(t.current.seenWorking, isEmpty);
    });

    test('a_drift_on_the_version_stops_it_from_being_promoted_even_after_a_restart', () {
      final store = VersionStore.load(tmp.path);
      final t = CompatibilityTracker(store: store)..setVersion('2.1.332');
      t.recordWorking(WorkingKinds.question);
      t.drift(reason: 'r', session: 's', expected: 'e');
      t.recordWorking(WorkingKinds.permission);
      expect(t.current.status, CompatibilityStatus.drifted);
      final again = CompatibilityTracker(store: VersionStore.load(tmp.path))..setVersion('2.1.332');
      expect(again.current.status, CompatibilityStatus.untested); // the red banner clears on restart
      again
        ..recordWorking(WorkingKinds.question)
        ..recordWorking(WorkingKinds.permission)
        ..recordWorking(WorkingKinds.plan);
      expect(again.current.status, CompatibilityStatus.untested);
    });

    test('release_notes_are_read_for_an_unchecked_version_and_shown', () async {
      var fetches = 0;
      final store = VersionStore.load(tmp.path);
      final t = CompatibilityTracker(
          store: store,
          releaseNotes: ReleaseNotesScanner(
              store: store,
              fetch: (_) async {
                fetches++;
                return '# Changelog\n\n## 2.1.333\n\n- Fixed permission prompts wrapping\n\n## 2.1.332\n\n- Faster MCP\n';
              }));
      t.setVersion('2.1.323');
      await t.releaseNotesDone;
      expect(fetches, 0); // a checked version needs no notes
      t.setVersion('2.1.333');
      expect(t.current.releaseNotes, isNull); // still reading
      await t.releaseNotesDone;
      final f = t.current.releaseNotes!;
      expect(f.checked, isTrue);
      expect(f.versions, ['2.1.332', '2.1.333']);
      expect(f.relevantLines, ['Fixed permission prompts wrapping']);
    });

    test('self_test_results_and_the_setting_show_in_the_status', () async {
      final store = VersionStore.load(tmp.path);
      final t = CompatibilityTracker(store: store, clock: () => DateTime.fromMillisecondsSinceEpoch(1000))
        ..setVersion('2.1.332');
      expect(t.current.selfTest!.enabled, isFalse);
      expect(t.current.selfTest!.state, SelfTestState.idle);
      t.setSelfTestEnabled(true);
      expect(VersionStore.load(tmp.path).selfTestNewVersions, isTrue);
      t.selfTestStarted();
      expect(t.current.selfTest!.state, SelfTestState.running);
      t.selfTestFinished(version: '2.1.332', passed: false, reason: 'The plan was not approved.', evidence: 'Step: plan');
      expect(t.current.status, CompatibilityStatus.drifted);
      expect(t.current.reason, contains('self-test'));
      expect(t.current.evidence, contains('Step: plan'));
      expect(t.current.selfTest!.state, SelfTestState.failed);
      expect(t.current.selfTest!.reason, 'The plan was not approved.');
      expect(VersionStore.load(tmp.path).selfTests['2.1.332']!.passed, isFalse);

      final u = CompatibilityTracker(store: VersionStore.load(tmp.path))..setVersion('2.1.333');
      u.selfTestStarted();
      u.selfTestFinished(version: '2.1.333', passed: true);
      expect(u.current.status, CompatibilityStatus.ok);
      expect(u.current.selfTest!.state, SelfTestState.passed);
      expect(VersionStore.load(tmp.path).verified, contains('2.1.333'));
    });
  });
}
