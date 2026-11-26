// Whether Perch still understands the installed Claude Code. A Claude Code update can
// change its dialogs or its output; Perch then says so loudly instead of silently
// failing to answer.
//
// A version newer than every checked one is `untested` until Perch has judged it: its
// release notes are read for lines about what Perch relies on, real use on this machine
// counts as evidence (a question, a permission request and a plan answered in a terminal
// make it checked), and the optional self-test (self_test.dart) can check it at once.
import 'dart:async';
import 'dart:convert';

import 'package:perch_protocol/perch_protocol.dart';

import 'release_notes.dart';
import 'version_store.dart';

/// Claude Code versions this Perch build was checked against (update with each check).
const checkedClaudeVersions = ['2.1.323', '2.1.325', '2.1.326', '2.1.327', '2.1.328', '2.1.329', '2.1.330', '2.1.331', '2.1.332'];

/// Compares dotted versions; negative when a < b.
int compareVersions(String a, String b) {
  final pa = a.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  final pb = b.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final d = (i < pa.length ? pa[i] : 0) - (i < pb.length ? pb[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

String _newest(Iterable<String> versions) => versions.reduce((a, b) => compareVersions(a, b) >= 0 ? a : b);

/// The newest version in the built-in list.
String get newestCheckedClaudeVersion => _newest(checkedClaudeVersions);

/// Lines of the screen kept as evidence (the bottom, where Claude Code draws its dialogs).
const evidenceScreenLines = 15;

class CompatibilityTracker {
  /// What this machine learned about versions (memory only unless loaded from the state).
  final VersionStore store;
  final ReleaseNotesScanner? _scanner;
  final DateTime Function() _clock;

  CompatibilityTracker({VersionStore? store, ReleaseNotesScanner? releaseNotes, DateTime Function()? clock})
      : store = store ?? VersionStore.memory(),
        _scanner = releaseNotes,
        _clock = clock ?? DateTime.now;

  String? _version;
  Compatibility? _drift;
  ReleaseNotesFindings? _notes;
  String? _notesFor;
  Future<void>? _scanning;
  bool _selfTestRunning = false;
  String? _selfTestUnsupported;
  final _changes = StreamController<Compatibility>.broadcast();

  /// Each new status.
  Stream<Compatibility> get changes => _changes.stream;

  String? get version => _version;

  /// The newest version known to work: the built-in list and the versions verified here.
  String get newestChecked => _newest([...checkedClaudeVersions, ...store.verified]);

  /// Whether [v] is newer than every checked version.
  bool isUntested(String? v) => v != null && compareVersions(v, newestChecked) > 0;

  bool get untested => isUntested(_version);

  SelfTestStatus get selfTestStatus {
    final v = _version;
    final rec = v == null ? null : store.selfTests[v];
    final enabled = store.selfTestNewVersions;
    if (_selfTestRunning) return SelfTestStatus(enabled: enabled, state: SelfTestState.running, version: v);
    if (rec != null) {
      return SelfTestStatus(
          enabled: enabled,
          state: rec.passed ? SelfTestState.passed : SelfTestState.failed,
          version: v,
          reason: rec.reason,
          atMs: rec.atMs);
    }
    final why = _selfTestUnsupported;
    if (why != null) return SelfTestStatus(enabled: enabled, state: SelfTestState.unsupported, reason: why);
    return SelfTestStatus(enabled: enabled);
  }

  Compatibility get current {
    final v = _version;
    final open = untested;
    final notes = open && _notesFor == v ? _notes : null;
    final working = open && v != null ? (store.working(v).toList()..sort()) : const <String>[];
    final d = _drift;
    return Compatibility(
      status: d != null ? CompatibilityStatus.drifted : (open ? CompatibilityStatus.untested : CompatibilityStatus.ok),
      claudeVersion: v,
      reason: d?.reason,
      evidence: d?.evidence,
      releaseNotes: notes,
      seenWorking: working,
      selfTest: selfTestStatus,
    );
  }

  /// The installed Claude Code version (null: unknown, nothing changes). A new version
  /// clears an earlier drift and, when it is unchecked, has its release notes read.
  void setVersion(String? version) {
    if (version == null || version == _version) return;
    final before = current;
    _version = version;
    _drift = null;
    _announce(before);
    if (untested) unawaited(refreshReleaseNotes());
  }

  /// Reads the release notes for the installed version unless they were read already.
  Future<void> refreshReleaseNotes() {
    final running = _scanning;
    if (running != null) return running;
    final scanner = _scanner;
    final v = _version;
    if (scanner == null || v == null || !untested) return Future.value();
    if (_notesFor == v && (_notes?.checked ?? false)) return Future.value();
    final f = () async {
      try {
        final found = await scanner.scan(installed: v, newestChecked: newestChecked);
        if (_version != v) return;
        final before = current;
        _notes = found;
        _notesFor = v;
        _announce(before);
      } catch (_) {}
    }();
    _scanning = f.whenComplete(() => _scanning = null);
    return _scanning!;
  }

  /// Completes when no release-notes read is running (tests).
  Future<void> get releaseNotesDone => _scanning ?? Future.value();

  /// A real interaction of [kind] (see [WorkingKinds]) worked on the installed version. When
  /// the required kinds have all worked and no drift was seen on it, the version is checked.
  void recordWorking(String kind) {
    final v = _version;
    if (v == null || !untested || _drift != null || store.drifted.contains(v)) return;
    final before = current;
    if (!store.addWorking(v, kind)) return;
    final seen = store.working(v);
    if (WorkingKinds.required.every(seen.contains)) _verify(v);
    _announce(before);
  }

  void _verify(String v) {
    store.verified.add(v);
    store.save();
  }

  /// Raises `drifted` with [reason] and the evidence. The first drift stays until the
  /// version changes or the host restarts.
  void drift({required String reason, required String session, required String expected, String? screen}) {
    final lines = (screen ?? '').replaceAll('\r', '').split('\n').where((l) => l.trim().isNotEmpty).toList();
    final shown = lines.length > evidenceScreenLines ? lines.sublist(lines.length - evidenceScreenLines) : lines;
    final evidence = StringBuffer()
      ..writeln('Session: $session')
      ..writeln('Expected: $expected')
      ..writeln('Claude Code: ${_version ?? 'unknown'}');
    if (shown.isNotEmpty) {
      evidence.writeln('Screen (last ${shown.length} lines):');
      for (final l in shown) {
        evidence.writeln(l);
      }
    }
    _raise(reason, evidence.toString().trimRight());
  }

  void _raise(String reason, String evidence) {
    if (_drift != null) return;
    final before = current;
    final v = _version;
    if (v != null && store.drifted.add(v)) store.save();
    _drift = Compatibility(status: CompatibilityStatus.drifted, claudeVersion: v, reason: reason, evidence: evidence);
    _announce(before);
  }

  // ------------------------------------------------------------ self-test

  void setSelfTestEnabled(bool enabled) {
    if (store.selfTestNewVersions == enabled) return;
    final before = current;
    store
      ..selfTestNewVersions = enabled
      ..save();
    _announce(before);
  }

  /// This machine cannot run the self-test ([reason] says why); null clears it.
  void selfTestUnsupported(String? reason) {
    final before = current;
    _selfTestUnsupported = reason;
    _announce(before);
  }

  void selfTestStarted() {
    final before = current;
    _selfTestRunning = true;
    store
      ..lastSelfTestAtMs = _clock().millisecondsSinceEpoch
      ..save();
    _announce(before);
  }

  /// The self-test for [version] ended. Passed: the version is checked. Failed: drift, with
  /// the self-test's [evidence].
  void selfTestFinished({required String version, required bool passed, String? reason, String? evidence}) {
    final before = current;
    _selfTestRunning = false;
    store.selfTests[version] = SelfTestRecord(passed: passed, reason: reason, atMs: _clock().millisecondsSinceEpoch);
    store.save();
    if (passed) {
      _verify(version);
      _announce(before);
      return;
    }
    if (version != _version) {
      _announce(before);
      return;
    }
    _announce(before);
    _raise('The self-test of Claude Code $version failed: ${reason ?? 'unknown reason'}',
        [if (evidence != null && evidence.isNotEmpty) evidence, 'Claude Code: $version'].join('\n'));
  }

  void _announce(Compatibility before) {
    final now = current;
    if (jsonEncode(now.toJson()) == jsonEncode(before.toJson())) return;
    if (!_changes.isClosed) _changes.add(now);
  }

  /// Reads the version now and then every [every] (the host passes 30 minutes). Release
  /// notes that could not be read are tried again on each read.
  Timer watchVersion(Future<String?> Function() read, {Duration every = const Duration(minutes: 30)}) {
    Future<void> once() async {
      try {
        setVersion(await read());
        await refreshReleaseNotes();
      } catch (_) {}
    }

    unawaited(once());
    return Timer.periodic(every, (_) => once());
  }

  Future<void> close() => _changes.close();
}
