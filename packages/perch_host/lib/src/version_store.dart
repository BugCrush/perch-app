// What the host has learned about Claude Code versions, in `<state dir>/versions.json`:
// versions verified on this machine (by real use or the self-test), versions where drift
// was seen, which kinds of interaction have worked on each unchecked version, release-notes
// findings by version, the self-test setting and when it last ran.
import 'dart:convert';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

class SelfTestRecord {
  final bool passed;
  final String? reason;
  final int atMs;
  const SelfTestRecord({required this.passed, this.reason, required this.atMs});

  Map<String, dynamic> toJson() => {'passed': passed, if (reason != null) 'reason': reason, 'atMs': atMs};

  static SelfTestRecord? fromJson(Object? v) {
    if (v is! Map || v['atMs'] is! num) return null;
    return SelfTestRecord(
        passed: v['passed'] == true, reason: v['reason'] is String ? v['reason'] as String : null, atMs: (v['atMs'] as num).toInt());
  }
}

class VersionStore {
  /// The state directory; null keeps everything in memory (tests, and when no state is wanted).
  final String? directory;

  bool selfTestNewVersions = false;

  /// Versions verified on this machine (with the built-in list, they decide `ok`).
  final Set<String> verified = {};

  /// Versions on which drift was seen: real use never promotes them.
  final Set<String> drifted = {};

  /// Per version, the [WorkingKinds] seen working.
  final Map<String, Set<String>> _working = {};
  final Map<String, ReleaseNotesFindings> _notes = {};

  /// Per version, the last self-test result.
  final Map<String, SelfTestRecord> selfTests = {};

  /// When any self-test last started (for the once-an-hour limit).
  int? lastSelfTestAtMs;

  /// Versions the self-test already ran for by itself (never twice).
  final Set<String> selfTestAutoTried = {};

  VersionStore._(this.directory);

  /// Memory only.
  VersionStore.memory() : directory = null;

  static const fileName = 'versions.json';

  File? get _file => directory == null ? null : File('$directory${Platform.pathSeparator}$fileName');

  static VersionStore load(String directory) {
    final s = VersionStore._(directory);
    try {
      final f = s._file!;
      if (!f.existsSync()) return s;
      final v = jsonDecode(f.readAsStringSync());
      if (v is! Map) return s;
      s.selfTestNewVersions = v['selfTestNewVersions'] == true;
      s.verified.addAll(_strings(v['verified']));
      s.drifted.addAll(_strings(v['drifted']));
      final w = v['seenWorking'];
      if (w is Map) {
        w.forEach((k, kinds) {
          if (k is String) s._working[k] = _strings(kinds).toSet();
        });
      }
      final n = v['releaseNotes'];
      if (n is Map) {
        n.forEach((k, f) {
          if (k is String && f is Map) s._notes[k] = ReleaseNotesFindings.fromJson(f.cast<String, dynamic>());
        });
      }
      final t = v['selfTests'];
      if (t is Map) {
        t.forEach((k, r) {
          final rec = SelfTestRecord.fromJson(r);
          if (k is String && rec != null) s.selfTests[k] = rec;
        });
      }
      if (v['lastSelfTestAtMs'] is num) s.lastSelfTestAtMs = (v['lastSelfTestAtMs'] as num).toInt();
      s.selfTestAutoTried.addAll(_strings(v['selfTestAutoTried']));
    } catch (_) {
      // unreadable: start afresh
    }
    return s;
  }

  static List<String> _strings(Object? v) => [
        for (final x in (v is List ? v : const []))
          if (x is String) x
      ];

  void save() {
    final f = _file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
        'selfTestNewVersions': selfTestNewVersions,
        'verified': (verified.toList()..sort()),
        'drifted': (drifted.toList()..sort()),
        'seenWorking': {
          for (final e in _working.entries) e.key: (e.value.toList()..sort()),
        },
        'releaseNotes': {for (final e in _notes.entries) e.key: e.value.toJson()},
        'selfTests': {for (final e in selfTests.entries) e.key: e.value.toJson()},
        'lastSelfTestAtMs': lastSelfTestAtMs,
        'selfTestAutoTried': (selfTestAutoTried.toList()..sort()),
      }));
    } catch (_) {
      // a full disk must not stop the host
    }
  }

  Set<String> working(String version) => Set.unmodifiable(_working[version] ?? const <String>{});

  /// Records that [kind] worked on [version]; true when it is new.
  bool addWorking(String version, String kind) {
    final added = (_working[version] ??= {}).add(kind);
    if (added) save();
    return added;
  }

  ReleaseNotesFindings? releaseNotes(String version) => _notes[version];

  void setReleaseNotes(String version, ReleaseNotesFindings f) {
    _notes[version] = f;
    save();
  }
}
