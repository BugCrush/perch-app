// Push notifications, sealed by the host and opened by the app. The relay, FCM and
// Google only ever see the sealed text.
//
// Sealed payload (standard base64): [version 1][12-byte random nonce][AES-256-GCM
// ciphertext][16-byte tag]. The key is HKDF-SHA256 over the pairing secret with a label
// of its own (not the channel's or a relay token's); the associated data names the
// machine, so a payload cannot be passed off as another machine's.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' show Mac, SecretBox, SecretKeyData;
import 'package:cryptography/dart.dart' show DartAesGcm;

import 'secure_channel.dart';

const pushPayloadVersion = 1;

/// What a notification is about.
abstract final class PushKinds {
  static const question = 'question';
  static const permission = 'permission';
  static const plan = 'plan';
  static const blocked = 'blocked';
  static const usageLimit = 'usageLimit';
  static const finished = 'finished';

  /// A machine's usage limit reset (one per machine; [PushNote.sessionIds] are the
  /// sessions still paused). Actions: Continue and Open.
  static const usageBack = 'usageBack';

  /// A session resumed after a usage limit but not the same way (without its subagent).
  static const resumedChanged = 'resumedChanged';

  /// The relay's shared pool is 80% used today (to the relay owner's devices only).
  static const relayPool = 'relayPool';

  /// Removes the session's notification.
  static const withdraw = 'withdraw';
}

/// The session id of a machine's own usage-limit notification ("Usage is back"): one per
/// machine, replaced by the next.
const usageLimitPushId = 'perch:usage-limit';

/// The "session" of the relay pool's notification (about the machine, not a session).
const relayPoolPushId = 'perch:relay-pool';

/// The notification inside the sealed payload.
class PushNote {
  final String title;
  final String body;
  final String machineId;
  final String sessionId;

  /// One of [PushKinds].
  final String kind;

  /// The card the notification is about, when it is one.
  final String? promptId;

  /// The sessions a machine-wide notification is about (a session muted on the phone is
  /// left out; when every one is muted, nothing shows).
  final List<String> sessionIds;

  const PushNote({
    this.title = '',
    this.body = '',
    required this.machineId,
    required this.sessionId,
    required this.kind,
    this.promptId,
    this.sessionIds = const [],
  });

  bool get isWithdraw => kind == PushKinds.withdraw;

  Map<String, dynamic> toJson() => {
        'title': title,
        'body': body,
        'machineId': machineId,
        'sessionId': sessionId,
        'kind': kind,
        if (promptId != null) 'promptId': promptId,
        if (sessionIds.isNotEmpty) 'sessionIds': sessionIds,
      };

  static PushNote? fromJson(Object? j) {
    if (j is! Map) return null;
    final machineId = j['machineId'], sessionId = j['sessionId'], kind = j['kind'];
    if (machineId is! String || sessionId is! String || kind is! String) return null;
    return PushNote(
      title: j['title'] is String ? j['title'] as String : '',
      body: j['body'] is String ? j['body'] as String : '',
      machineId: machineId,
      sessionId: sessionId,
      kind: kind,
      promptId: j['promptId'] is String ? j['promptId'] as String : null,
      sessionIds: [
        for (final s in (j['sessionIds'] is List ? j['sessionIds'] as List : const []))
          if (s is String) s
      ],
    );
  }
}

final _aes = DartAesGcm.with256bits();

/// The key notifications are sealed with.
Uint8List pushKey(List<int> secret) => hkdfSha256(secret, info: utf8.encode('perch v1 push payload'));

/// The collapse key for a session's notifications: the same for every notification of
/// that session, and meaningless to anyone without the secret.
String pushTag(List<int> secret, String sessionId) {
  final key = hkdfSha256(secret, info: utf8.encode('perch v1 push tag'));
  final mac = crypto.Hmac(crypto.sha256, key).convert(utf8.encode(sessionId)).bytes;
  return base64UrlNoPad(mac.sublist(0, 16));
}

List<int> _aad(String machineId) => utf8.encode('perch v1 push $machineId');

/// Seals [note] for the devices paired with [machineId].
String sealPush(List<int> secret, String machineId, PushNote note) {
  final nonce = randomBytes(12);
  final box = _aes.encryptSync(utf8.encode(jsonEncode(note.toJson())),
      secretKeyData: SecretKeyData(pushKey(secret)), nonce: nonce, aad: _aad(machineId));
  return base64.encode([pushPayloadVersion, ...nonce, ...box.cipherText, ...box.mac.bytes]);
}

/// The notification in [sealed], or null when it does not open with this machine's secret.
PushNote? openPush(List<int> secret, String machineId, String sealed) {
  try {
    final b = base64.decode(sealed.trim());
    if (b.length < 1 + 12 + 16 + 1 || b[0] != pushPayloadVersion) return null;
    final plain = _aes.decryptSync(
      SecretBox(b.sublist(13, b.length - 16), nonce: b.sublist(1, 13), mac: Mac(b.sublist(b.length - 16))),
      secretKeyData: SecretKeyData(pushKey(secret)),
      aad: _aad(machineId),
    );
    final note = PushNote.fromJson(jsonDecode(utf8.decode(plain)));
    return note?.machineId == machineId ? note : null;
  } catch (_) {
    return null;
  }
}
