// Claude Code accounts (docs/superpowers/specs/2026-11-15-accounts-design.md). An account
// is a long-lived token from `claude setup-token` with the owner's name for it. The token
// itself travels only app <-> host inside the encrypted channel ([AccountWithToken]); every
// other message carries [AccountInfo], which never holds it.

/// The account id that means "the machine's own Claude Code login" (no token: whatever
/// `claude` on that machine is signed in to).
const machineLoginAccountId = 'machine';

/// How long before a token expires the app warns.
const accountExpiryWarning = Duration(days: 14);

/// The longest account name Perch accepts.
const maxAccountLabelLength = 40;

enum AccountExpiry { ok, soon, expired }

String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
int? _ms(Object? v) => v is num && v > 0 ? v.toInt() : null;

/// One account as every device and host may see it (no token).
class AccountInfo {
  final String id;

  /// The owner's name for it ("Personal", "Work").
  final String label;
  final String? email;

  /// Pro, Max, Team… as the owner or Claude Code said; null: not known.
  final String? plan;
  final int createdAtMs;

  /// When the token stops working; null: not known.
  final int? expiresAtMs;

  const AccountInfo(
      {required this.id, required this.label, this.email, this.plan, required this.createdAtMs, this.expiresAtMs});

  AccountExpiry expiry(DateTime now) {
    final at = expiresAtMs;
    if (at == null) return AccountExpiry.ok;
    final end = DateTime.fromMillisecondsSinceEpoch(at);
    if (!now.isBefore(end)) return AccountExpiry.expired;
    if (end.difference(now) <= accountExpiryWarning) return AccountExpiry.soon;
    return AccountExpiry.ok;
  }

  /// `Work · someone@example.com · Max`.
  String describe() => [label, ?email, ?plan].join(' · ');

  AccountInfo copyWith({String? label, String? email, String? plan, int? expiresAtMs, int? createdAtMs}) => AccountInfo(
      id: id,
      label: label ?? this.label,
      email: email ?? this.email,
      plan: plan ?? this.plan,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      expiresAtMs: expiresAtMs ?? this.expiresAtMs);

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'email': ?email,
        'plan': ?plan,
        'createdAtMs': createdAtMs,
        'expiresAtMs': ?expiresAtMs,
      };

  static AccountInfo? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id']), label = _s(j['label']);
    if (id == null || label == null) return null;
    return AccountInfo(
        id: id,
        label: label,
        email: _s(j['email']),
        plan: _s(j['plan']),
        createdAtMs: _ms(j['createdAtMs']) ?? 0,
        expiresAtMs: _ms(j['expiresAtMs']));
  }

  factory AccountInfo.fromJson(Map<String, dynamic> j) =>
      tryFromJson(j) ?? (throw const FormatException('not an account'));
}

/// An account with its token: only in [SyncAccounts] (app -> host) and the finished
/// [AccountSignInUpdate] (host -> app), both inside the encrypted channel.
class AccountWithToken {
  final AccountInfo info;
  final String token;
  const AccountWithToken({required this.info, required this.token});

  Map<String, dynamic> toJson() => {...info.toJson(), 'token': token};

  static AccountWithToken? tryFromJson(Object? j) {
    final info = AccountInfo.tryFromJson(j);
    final token = j is Map ? _s(j['token']) : null;
    return info == null || token == null ? null : AccountWithToken(info: info, token: token);
  }
}

/// What Claude Code on a machine is signed in to by itself (`claude auth status`): the
/// first account (decision 10), without a token.
class MachineLogin {
  final bool loggedIn;
  final String? email;

  /// The subscription (`max`, `pro`, …) as Claude Code reports it.
  final String? plan;
  const MachineLogin({required this.loggedIn, this.email, this.plan});

  Map<String, dynamic> toJson() => {'loggedIn': loggedIn, 'email': ?email, 'plan': ?plan};

  factory MachineLogin.fromJson(Object? j) => j is Map
      ? MachineLogin(loggedIn: j['loggedIn'] == true, email: _s(j['email']), plan: _s(j['plan']))
      : const MachineLogin(loggedIn: false);
}

/// The steps of adding an account (`accountSignIn` from the app).
abstract final class AccountSignInActions {
  /// Start `claude setup-token` hidden on the machine; the host answers with the sign-in link.
  static const start = 'start';

  /// The code the sign-in page showed (the owner copied it on the phone).
  static const code = 'code';

  /// Sign in at the machine instead: a visible terminal runs `claude setup-token`.
  static const atMachine = 'atMachine';
  static const cancel = 'cancel';
  static const all = [start, code, atMachine, cancel];
}

/// Where an account sign-in is (`accountSignIn` from the host).
abstract final class AccountSignInStates {
  /// Open [AccountSignInUpdate.url] on the phone, sign in, and send the code.
  static const url = 'url';

  /// The code was typed; Perch waits for the token.
  static const checking = 'checking';

  /// Waiting for the owner to sign in at the machine.
  static const atMachine = 'atMachine';

  /// Done: [AccountSignInUpdate.account] and its token.
  static const done = 'done';
  static const failed = 'failed';
  static const cancelled = 'cancelled';
  static const all = [url, checking, atMachine, done, failed, cancelled];
}
