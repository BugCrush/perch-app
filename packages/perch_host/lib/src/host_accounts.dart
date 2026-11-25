// The accounts this host can start sessions on (docs/superpowers/specs/2026-11-15-accounts-
// design.md): the machine's own Claude Code login (decision 10, no token) and the token
// accounts the phone gave it (decision 6). Names, emails and dates live in host.json; tokens
// only in the [TokenVault]. Also which account new sessions start on (decision 2) and which
// account each session Perch started runs on (decision 8).
import 'dart:async';
import 'dart:convert';

import 'package:perch_protocol/perch_protocol.dart';

import 'claude_session.dart';
import 'token_vault.dart';

/// The environment variable Claude Code takes a long-lived token from.
const oauthTokenVariable = 'CLAUDE_CODE_OAUTH_TOKEN';

/// Where the account list is kept between runs (host.json).
abstract interface class AccountsPersistence {
  Map<String, dynamic>? loadAccounts();
  void saveAccounts(Map<String, dynamic> json);
}

class HostAccounts {
  final TokenVault vault;
  final AccountsPersistence? store;
  final ClaudeLauncher launcher;
  final DateTime Function() clock;

  /// How many sessions' accounts are remembered.
  static const maxSessions = 500;

  HostAccounts({required this.vault, this.store, required this.launcher, DateTime Function()? clock})
      : clock = clock ?? DateTime.now {
    _load();
  }

  final List<AccountInfo> _accounts = [];
  String _active = machineLoginAccountId;
  final Map<String, String> _sessions = {};
  MachineLogin _machine = const MachineLogin(loggedIn: false);
  final _changes = StreamController<void>.broadcast();
  bool _disposed = false;

  List<AccountInfo> get accounts => List.unmodifiable(_accounts);
  String get activeId => _active;
  MachineLogin get machineLogin => _machine;

  /// After every change (the server tells the devices).
  Stream<void> get changes => _changes.stream;

  AccountsMessage get message => AccountsMessage(machineLogin: _machine, activeAccountId: _active, accounts: accounts);

  AccountInfo? byId(String id) => _accounts.where((a) => a.id == id).firstOrNull;

  /// `Work`, or `This machine's login`.
  String labelOf(String id) => id == machineLoginAccountId ? "This machine's login" : (byId(id)?.label ?? 'an account');

  void _load() {
    final j = store?.loadAccounts();
    if (j == null) return;
    for (final a in (j['list'] is List ? j['list'] as List : const [])) {
      final info = AccountInfo.tryFromJson(a);
      if (info != null && validAccountId(info.id)) _accounts.add(info);
    }
    final active = j['active'];
    if (active is String && (active == machineLoginAccountId || byId(active) != null)) _active = active;
    final sessions = j['sessions'];
    if (sessions is Map) {
      for (final e in sessions.entries) {
        if (e.key is String && e.value is String) _sessions[e.key as String] = e.value as String;
      }
    }
  }

  void _save() {
    store?.saveAccounts({
      'list': [for (final a in _accounts) a.toJson()],
      'active': _active,
      'sessions': _sessions,
    });
  }

  void _changed() {
    _save();
    if (!_disposed) _changes.add(null);
  }

  /// Adds or updates each account (its token into the vault). Never removes one.
  Future<void> sync(List<AccountWithToken> incoming) async {
    var any = false;
    for (final a in incoming) {
      if (!validAccountId(a.info.id) || a.info.id == machineLoginAccountId) continue;
      await vault.put(a.info.id, a.token);
      _put(a.info);
      any = true;
    }
    if (any) _changed();
  }

  void _put(AccountInfo info) {
    final i = _accounts.indexWhere((x) => x.id == info.id);
    if (i >= 0) {
      _accounts[i] = info;
    } else {
      _accounts.add(info);
    }
  }

  /// A sign-in on this machine finished.
  Future<void> add(AccountInfo info, String token) => sync([AccountWithToken(info: info, token: token)]);

  Future<void> remove(String id) async {
    if (id == machineLoginAccountId) throw ArgumentError("This machine's login cannot be removed from Perch.");
    await vault.remove(id);
    _accounts.removeWhere((a) => a.id == id);
    if (_active == id) _active = machineLoginAccountId;
    _changed();
  }

  /// The account new sessions start on. Throws [ArgumentError] for an unknown one.
  void setActive(String id) {
    if (id != machineLoginAccountId && byId(id) == null) throw ArgumentError('This machine does not have that account.');
    if (_active == id) return;
    _active = id;
    _changed();
  }

  /// The token to start a session on [id] with; null for the machine's own login. Throws
  /// [StateError] (with words for the owner) when the account cannot be used.
  Future<String?> tokenFor(String id) async {
    if (id == machineLoginAccountId) return null;
    final a = byId(id);
    if (a == null) throw StateError('This machine does not have that account. Open Accounts in the app to add it again.');
    if (a.expiry(clock()) == AccountExpiry.expired) {
      throw StateError('The sign-in for ${a.label} has expired. Sign in again from Accounts in the app.');
    }
    final t = await vault.get(id);
    if (t == null) throw StateError("Perch cannot read ${a.label}'s sign-in on this machine. Sign in again from Accounts.");
    return t;
  }

  /// The environment for a `claude` on account [id]: [base] with that account's token (the
  /// machine's own login: [base] without one).
  Future<Map<String, String>> environmentFor(String id, Map<String, String> base) async {
    final token = await tokenFor(id);
    final env = Map<String, String>.of(base);
    if (token != null) env[oauthTokenVariable] = token;
    return env;
  }

  /// The account a Claude Code session (by its id) was started on by Perch.
  String? accountOf(String? claudeSessionId) => claudeSessionId == null ? null : _sessions[claudeSessionId];

  void recordSession(String claudeSessionId, String accountId) {
    if (_sessions[claudeSessionId] == accountId) return;
    _sessions.remove(claudeSessionId);
    _sessions[claudeSessionId] = accountId;
    while (_sessions.length > maxSessions) {
      _sessions.remove(_sessions.keys.first);
    }
    _save();
  }

  /// Reads the machine's own login (`claude auth status --json`, without any token in the
  /// environment so it reports the stored login).
  Future<MachineLogin> refreshMachineLogin() async {
    MachineLogin next = const MachineLogin(loggedIn: false);
    try {
      final env = launcher.childEnvironment()..remove(oauthTokenVariable);
      final r = await launcher.run(['auth', 'status', '--json'], environment: env).timeout(const Duration(seconds: 20));
      next = parseAuthStatus('${r.stdout}');
    } catch (_) {}
    final changed = next.loggedIn != _machine.loggedIn || next.email != _machine.email || next.plan != _machine.plan;
    _machine = next;
    if (changed && !_disposed) _changes.add(null);
    return next;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _changes.close();
  }
}

/// `claude auth status --json`: signed in or not, and for a stored claude.ai login its
/// email and subscription. A token login carries neither (Claude Code 2.1.325).
MachineLogin parseAuthStatus(String out) {
  try {
    final start = out.indexOf('{');
    if (start < 0) return const MachineLogin(loggedIn: false);
    final j = jsonDecode(out.substring(start));
    if (j is! Map) return const MachineLogin(loggedIn: false);
    String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    return MachineLogin(loggedIn: j['loggedIn'] == true, email: s(j['email']), plan: s(j['subscriptionType']));
  } catch (_) {
    return const MachineLogin(loggedIn: false);
  }
}
