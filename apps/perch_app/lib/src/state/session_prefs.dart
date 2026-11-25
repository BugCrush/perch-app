// This phone's own choices about sessions: pinned (at most [maxPinsPerMachine] per
// machine, shown first in that machine's list), hidden (an ended session left out of the
// list until it runs again) and muted (no notifications for it on this phone). Kept in
// shared_preferences under 'sessionPrefs', like the machines and their aliases; the push
// background handler reads the mutes from there itself.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pins allowed per machine.
const maxPinsPerMachine = 5;

/// Pinning one more session on a machine that has [maxPinsPerMachine].
class TooManyPins implements Exception {
  @override
  String toString() => 'At most $maxPinsPerMachine pinned sessions per machine. Unpin one first.';
}

class _MachinePrefs {
  final List<String> pins;
  final Set<String> hidden;
  final Set<String> muted;
  _MachinePrefs({List<String>? pins, Set<String>? hidden, Set<String>? muted})
      : pins = pins ?? [],
        hidden = hidden ?? {},
        muted = muted ?? {};

  bool get isEmpty => pins.isEmpty && hidden.isEmpty && muted.isEmpty;

  Map<String, dynamic> toJson() => {'pins': pins, 'hidden': hidden.toList(), 'muted': muted.toList()};

  static List<String> _strings(Object? v) => [
        if (v is List)
          for (final x in v)
            if (x is String && x.isNotEmpty) x
      ];

  static _MachinePrefs fromJson(Object? j) {
    if (j is! Map) return _MachinePrefs();
    final pins = _strings(j['pins']).toSet().toList();
    return _MachinePrefs(
      pins: pins.length > maxPinsPerMachine ? pins.sublist(0, maxPinsPerMachine) : pins,
      hidden: _strings(j['hidden']).toSet(),
      muted: _strings(j['muted']).toSet(),
    );
  }
}

class SessionPrefs extends ChangeNotifier {
  static const key = 'sessionPrefs';

  /// [persist] false keeps everything in memory (tests, and the fallback without storage).
  SessionPrefs({this.persist = true});
  final bool persist;

  final Map<String, _MachinePrefs> _byMachine = {};

  _MachinePrefs _of(String machineId) => _byMachine[machineId] ?? _MachinePrefs();

  /// Pinned sessions of a machine, in the order pinned.
  List<String> pins(String machineId) => List.unmodifiable(_of(machineId).pins);
  bool isPinned(String machineId, String sessionId) => _of(machineId).pins.contains(sessionId);
  bool isHidden(String machineId, String sessionId) => _of(machineId).hidden.contains(sessionId);
  bool isMuted(String machineId, String sessionId) => _of(machineId).muted.contains(sessionId);

  /// Pins a session on its machine; [TooManyPins] when that machine already has
  /// [maxPinsPerMachine] (other machines do not count).
  Future<void> pin(String machineId, String sessionId) async {
    final m = _byMachine.putIfAbsent(machineId, _MachinePrefs.new);
    if (m.pins.contains(sessionId)) return;
    if (m.pins.length >= maxPinsPerMachine) throw TooManyPins();
    m.pins.add(sessionId);
    await _changed();
  }

  Future<void> unpin(String machineId, String sessionId) async {
    if (_byMachine[machineId]?.pins.remove(sessionId) ?? false) await _changed();
  }

  Future<void> hide(String machineId, String sessionId) async {
    if (_byMachine.putIfAbsent(machineId, _MachinePrefs.new).hidden.add(sessionId)) await _changed();
  }

  Future<void> unhide(String machineId, String sessionId) async {
    if (_byMachine[machineId]?.hidden.remove(sessionId) ?? false) await _changed();
  }

  Future<void> mute(String machineId, String sessionId) async {
    if (_byMachine.putIfAbsent(machineId, _MachinePrefs.new).muted.add(sessionId)) await _changed();
  }

  Future<void> unmute(String machineId, String sessionId) async {
    if (_byMachine[machineId]?.muted.remove(sessionId) ?? false) await _changed();
  }

  /// A session deleted on its machine: nothing about it is kept.
  Future<void> forgetSession(String machineId, String sessionId) async {
    final m = _byMachine[machineId];
    if (m == null) return;
    final changed = m.pins.remove(sessionId) | m.hidden.remove(sessionId) | m.muted.remove(sessionId);
    if (changed) await _changed();
  }

  /// A machine removed from this phone.
  Future<void> forgetMachine(String machineId) async {
    if (_byMachine.remove(machineId) != null) await _changed();
  }

  Future<void> _changed() async {
    _byMachine.removeWhere((_, m) => m.isEmpty);
    notifyListeners();
    if (!persist) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, encode());
    } catch (_) {}
  }

  String encode() => jsonEncode({for (final e in _byMachine.entries) e.key: e.value.toJson()});

  void decode(String? raw) {
    _byMachine.clear();
    if (raw == null) return;
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return;
      for (final e in v.entries) {
        if (e.key is String) _byMachine[e.key as String] = _MachinePrefs.fromJson(e.value);
      }
      _byMachine.removeWhere((_, m) => m.isEmpty);
    } catch (_) {
      _byMachine.clear();
    }
  }

  /// Reads the saved choices; [fresh] re-reads the platform's store first (the push
  /// background isolate, whose cached copy misses changes made in the app).
  Future<void> load({bool fresh = false}) async {
    if (!persist) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (fresh) {
        try {
          await prefs.reload();
        } catch (_) {}
      }
      decode(prefs.getString(key));
      notifyListeners();
    } catch (_) {}
  }
}
