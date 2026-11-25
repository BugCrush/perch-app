// Messages typed in a conversation and not sent yet, per machine and session, kept on the
// phone (like a messaging app's drafts): leaving the conversation, opening the board or
// closing the app keeps them; sending clears them.
import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

abstract final class Drafts {
  static const prefsKey = 'perch.drafts';

  static final Map<String, String> _all = {};
  static Future<void>? _loading;
  static Timer? _save;

  static String _key(String machineId, String sessionId) => '$machineId/$sessionId';

  /// Reads the saved drafts (at start, with the other stores).
  static Future<void> load() => _loading ??= () async {
        try {
          final prefs = await SharedPreferences.getInstance();
          final raw = prefs.getString(prefsKey);
          if (raw == null) return;
          final j = jsonDecode(raw);
          if (j is! Map) return;
          for (final e in j.entries) {
            if (e.key is String && e.value is String && (e.value as String).isNotEmpty) {
              _all.putIfAbsent(e.key as String, () => e.value as String);
            }
          }
        } catch (_) {
          // Unreadable drafts are dropped.
        }
      }();

  /// The draft of [sessionId] on [machineId] ('' when none).
  static String get(String machineId, String sessionId) => _all[_key(machineId, sessionId)] ?? '';

  /// Keeps [text] as the draft (empty: no draft). Saved shortly after the last change.
  static void set(String machineId, String sessionId, String text) {
    final k = _key(machineId, sessionId);
    if (text.isEmpty) {
      if (_all.remove(k) == null) return;
    } else {
      if (_all[k] == text) return;
      _all[k] = text;
    }
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 400), () => unawaited(flush()));
  }

  /// Saves now.
  static Future<void> flush() async {
    _save?.cancel();
    _save = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(_all));
    } catch (_) {}
  }

  /// Tests: forgets the drafts in memory (what is saved stays; a test resets the
  /// preferences itself).
  static void reset() {
    _save?.cancel();
    _save = null;
    _all.clear();
    _loading = null;
  }
}
