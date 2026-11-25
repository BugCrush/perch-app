// The owner's Claude Code accounts on this phone (docs/superpowers/specs/2026-11-15-
// accounts-design.md, decision 6): names, emails, dates and tokens, kept in the platform's
// keystore-backed storage (flutter_secure_storage: Android Keystore), never in shared
// preferences. Every paired machine is given them over its encrypted channel.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'host_connection.dart' show AccountSource;

/// Where secrets are kept (the keystore on the phone; memory in tests).
abstract class SecretBox {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class KeystoreSecretBox implements SecretBox {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemorySecretBox implements SecretBox {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// A new account id (also the sign-in flow's id): letters and digits only.
String newAccountId() => 'acc-${base64UrlNoPad(randomBytes(9)).replaceAll(RegExp(r'[^A-Za-z0-9]'), 'x')}';

class PhoneAccounts extends ChangeNotifier implements AccountSource {
  static const key = 'perch.accounts';
  final SecretBox box;
  PhoneAccounts({SecretBox? box}) : box = box ?? KeystoreSecretBox();

  final List<AccountWithToken> _accounts = [];

  /// Accounts removed on this phone that a machine may still hold (told when it connects).
  final Set<String> _removed = {};
  bool _perSession = false;
  bool _loaded = false;

  List<AccountInfo> get accounts => [for (final a in _accounts) a.info];
  bool get loaded => _loaded;

  /// "Choose account per session": the new-session sheet asks which account.
  bool get perSession => _perSession;
  @override
  Set<String> get removed => Set.unmodifiable(_removed);

  AccountInfo? byId(String id) => _accounts.where((a) => a.info.id == id).firstOrNull?.info;

  /// Every account with its token (what machines are given).
  @override
  List<AccountWithToken> get withTokens => List.unmodifiable(_accounts);

  Future<void> load() async {
    try {
      final raw = await box.read(key);
      if (raw != null) {
        final j = jsonDecode(raw);
        if (j is Map) {
          _accounts
            ..clear()
            ..addAll([for (final a in (j['accounts'] is List ? j['accounts'] as List : const [])) ?AccountWithToken.tryFromJson(a)]);
          _removed
            ..clear()
            ..addAll([for (final r in (j['removed'] is List ? j['removed'] as List : const [])) if (r is String) r]);
          _perSession = j['perSession'] == true;
        }
      }
    } catch (_) {
      // Unreadable (a restored backup without its keystore key): start empty.
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    await box.write(
        key,
        jsonEncode({
          'accounts': [for (final a in _accounts) a.toJson()],
          'removed': _removed.toList(),
          'perSession': _perSession,
        }));
    notifyListeners();
  }

  /// Adds the account, or replaces it (a fresh sign-in for the same account).
  Future<void> put(AccountInfo info, String token) async {
    final i = _accounts.indexWhere((a) => a.info.id == info.id);
    final a = AccountWithToken(info: info, token: token);
    if (i >= 0) {
      _accounts[i] = a;
    } else {
      _accounts.add(a);
    }
    _removed.remove(info.id);
    await _save();
  }

  Future<void> remove(String id) async {
    _accounts.removeWhere((a) => a.info.id == id);
    _removed.add(id);
    await _save();
  }

  /// A machine no longer holds [id]: nothing left to tell.
  Future<void> forgotten(String id) async {
    if (_removed.remove(id)) await _save();
  }

  Future<void> setPerSession(bool value) async {
    if (_perSession == value) return;
    _perSession = value;
    await _save();
  }
}

/// `Work`, `This machine's login`, or the id's account on the machine.
String accountLabel(String? id, {List<AccountInfo> known = const []}) {
  if (id == null || id == machineLoginAccountId) return "This machine's login";
  return known.where((a) => a.id == id).firstOrNull?.label ?? 'Another account';
}

/// `Expires 15 Nov 2027`, `Expires in 9 days`, `Expired`.
String expiryLine(AccountInfo a, DateTime now) {
  final at = a.expiresAtMs;
  if (at == null) return '';
  final end = DateTime.fromMillisecondsSinceEpoch(at);
  return switch (a.expiry(now)) {
    AccountExpiry.expired => 'Sign-in expired',
    AccountExpiry.soon => () {
        final days = end.difference(now).inHours ~/ 24;
        return days <= 0 ? 'Sign-in expires today' : 'Sign-in expires in $days ${days == 1 ? 'day' : 'days'}';
      }(),
    AccountExpiry.ok => 'Valid until ${end.day} ${_months[end.month - 1]} ${end.year}',
  };
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// `Max`, `Pro`: Claude Code's subscription words, capitalised.
String planLabel(String? plan) {
  if (plan == null || plan.isEmpty) return '';
  return plan[0].toUpperCase() + plan.substring(1);
}
