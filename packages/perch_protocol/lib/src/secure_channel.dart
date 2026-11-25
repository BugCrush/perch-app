// The encrypted channel between the app and a host. One layer for every transport (the
// direct LAN WebSocket and the relay alike): the transport only moves binary frames.
//
// Handshake
//   app  -> host  clientHello  [1][version][16-byte app nonce][machine id length][machine id][device id]
//   host -> app   serverHello  [2][version][16-byte host nonce]
//   Both derive one key per direction with HKDF-SHA256 over the pairing secret, salted
//   with both nonces. A host that does not recognise the machine id, or cannot open the
//   app's first frame, answers with an error frame [3][reason] and closes.
//
// Data frames
//   [4][AES-256-GCM ciphertext][16-byte tag], the header byte as associated data. The
//   96-bit nonce is a per-direction counter (4 zero bytes, 8 bytes big-endian) that is
//   never sent: a replayed, reordered, dropped or altered frame fails to decrypt, and
//   any failure closes the channel for good.
//   The plaintext is [flag][UTF-8 message]: flag 0 = a whole message; 1 = a chunk with
//   more to follow; 2 = the last chunk. Messages over [maxChunkPlaintext] bytes are split
//   so every frame stays under the relay's 1 MiB limit.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' show Mac, SecretBox, SecretKeyData;
import 'package:cryptography/dart.dart' show DartAesGcm;

const channelVersion = 1;
const handshakeNonceLength = 16;
const pairingSecretLength = 32;

/// Plaintext bytes per data frame (900 KiB); larger messages are chunked.
const maxChunkPlaintext = 900 * 1024;

/// A reassembled message larger than this closes the channel.
const maxMessageBytes = 64 * 1024 * 1024;

abstract final class FrameType {
  static const clientHello = 1;
  static const serverHello = 2;
  static const error = 3;
  static const data = 4;
}

abstract final class ChannelErrors {
  /// The host does not recognise this pairing (wrong machine, rotated or wrong secret).
  static const badKey = 'badKey';
  static const badVersion = 'badVersion';
  static const badFrame = 'badFrame';
  static const decryptFailed = 'decryptFailed';
  static const tooLarge = 'tooLarge';
}

class ChannelError implements Exception {
  /// One of [ChannelErrors], or the reason in an error frame from the other side.
  final String reason;
  const ChannelError(this.reason);
  @override
  String toString() => 'ChannelError($reason)';
}

// ---------------------------------------------------------------- helpers

/// Base64url without padding.
String base64UrlNoPad(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Null when [s] is not base64url.
Uint8List? base64UrlDecodeNoPad(String s) {
  try {
    return base64Url.decode(base64Url.normalize(s.trim()));
  } catch (_) {
    return null;
  }
}

/// HKDF-SHA256 (RFC 5869).
Uint8List hkdfSha256(List<int> ikm, {List<int> salt = const [], required List<int> info, int length = 32}) {
  final prk = crypto.Hmac(crypto.sha256, salt.isEmpty ? List.filled(32, 0) : salt).convert(ikm).bytes;
  final out = BytesBuilder(copy: false);
  var t = <int>[];
  for (var i = 1; out.length < length; i++) {
    t = crypto.Hmac(crypto.sha256, prk).convert([...t, ...info, i]).bytes;
    out.add(t);
  }
  return Uint8List.fromList(out.takeBytes().sublist(0, length));
}

Uint8List _derive(List<int> secret, String label, {List<int> salt = const []}) =>
    hkdfSha256(secret, salt: salt, info: utf8.encode(label));

/// The token the host presents to the relay.
String relayHostToken(List<int> secret) => base64UrlNoPad(_derive(secret, 'perch v1 relay host token'));

/// The token devices present to the relay.
String relayDeviceToken(List<int> secret) => base64UrlNoPad(_derive(secret, 'perch v1 relay device token'));

/// What the relay stores for a token: lowercase hex SHA-256 of its UTF-8 text.
String tokenHash(String token) => crypto.sha256.convert(utf8.encode(token)).toString();

Uint8List randomBytes(int n, [Random? random]) {
  final r = random ?? Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// An error frame carrying [reason] (sent in the clear, then the sender closes).
Uint8List errorFrame(String reason) => Uint8List.fromList([FrameType.error, ...utf8.encode(reason)]);

String _errorReason(Uint8List frame) => utf8.decode(frame.sublist(1), allowMalformed: true);

// ---------------------------------------------------------------- session

/// The keys and counters of one connection after the handshake.
class SecureSession {
  static final _aes = DartAesGcm.with256bits();
  static const _aad = [FrameType.data];

  final SecretKeyData _sendKey;
  final SecretKeyData _recvKey;
  int _sendCounter = 0;
  int _recvCounter = 0;
  BytesBuilder? _partial;
  bool _closed = false;

  SecureSession._(List<int> sendKey, List<int> recvKey)
    : _sendKey = SecretKeyData(sendKey),
      _recvKey = SecretKeyData(recvKey);

  factory SecureSession._derive(List<int> secret, List<int> appNonce, List<int> hostNonce, {required bool host}) {
    final salt = [...appNonce, ...hostNonce];
    final appToHost = _derive(secret, 'perch v1 app->host', salt: salt);
    final hostToApp = _derive(secret, 'perch v1 host->app', salt: salt);
    return host ? SecureSession._(hostToApp, appToHost) : SecureSession._(appToHost, hostToApp);
  }

  /// True after any failure: the connection must be closed.
  bool get closed => _closed;

  List<int> get sendKeyForTest => _sendKey.bytes;
  List<int> get receiveKeyForTest => _recvKey.bytes;

  static List<int> _nonce(int counter) {
    // Two 32-bit halves: compiled to JavaScript (the board's web page) ByteData has no
    // 64-bit setter. Counters stay far below 2^53.
    final n = Uint8List(12);
    final view = ByteData.view(n.buffer);
    view.setUint32(4, counter ~/ 0x100000000);
    view.setUint32(8, counter % 0x100000000);
    return n;
  }

  /// Encrypts one message into one or more data frames (send them in order).
  List<Uint8List> seal(String message) {
    if (_closed) throw const ChannelError(ChannelErrors.decryptFailed);
    final body = utf8.encode(message);
    if (body.length <= maxChunkPlaintext) return [_frame(0, body, 0, body.length)];
    final frames = <Uint8List>[];
    for (var start = 0; start < body.length; start += maxChunkPlaintext) {
      final end = min(start + maxChunkPlaintext, body.length);
      frames.add(_frame(end == body.length ? 2 : 1, body, start, end));
    }
    return frames;
  }

  Uint8List _frame(int flag, List<int> body, int start, int end) {
    final plain = Uint8List(end - start + 1)
      ..[0] = flag
      ..setRange(1, end - start + 1, body, start);
    final box = _aes.encryptSync(plain, secretKeyData: _sendKey, nonce: _nonce(_sendCounter++), aad: _aad);
    final out = Uint8List(1 + box.cipherText.length + box.mac.bytes.length)
      ..[0] = FrameType.data
      ..setRange(1, 1 + box.cipherText.length, box.cipherText)
      ..setRange(1 + box.cipherText.length, 1 + box.cipherText.length + box.mac.bytes.length, box.mac.bytes);
    return out;
  }

  Never _fail(String reason) {
    _closed = true;
    _partial = null;
    throw ChannelError(reason);
  }

  /// Decrypts one frame. Returns the message, or null while a chunked message is still
  /// incomplete. Throws [ChannelError] on any failure (and stays closed afterwards).
  String? open(Uint8List frame) {
    if (_closed) throw const ChannelError(ChannelErrors.decryptFailed);
    if (frame.isEmpty) _fail(ChannelErrors.badFrame);
    if (frame[0] == FrameType.error) _fail(_errorReason(frame));
    if (frame[0] != FrameType.data || frame.length < 1 + 1 + 16) _fail(ChannelErrors.badFrame);
    final List<int> plain;
    try {
      plain = _aes.decryptSync(
        SecretBox(
          frame.sublist(1, frame.length - 16),
          nonce: _nonce(_recvCounter),
          mac: Mac(frame.sublist(frame.length - 16)),
        ),
        secretKeyData: _recvKey,
        aad: _aad,
      );
    } catch (_) {
      _fail(ChannelErrors.decryptFailed);
    }
    _recvCounter++;
    final flag = plain[0];
    final body = plain.sublist(1);
    switch (flag) {
      case 0:
        if (_partial != null) _fail(ChannelErrors.badFrame);
        return utf8.decode(body, allowMalformed: true);
      case 1:
        final p = _partial ??= BytesBuilder(copy: false);
        p.add(body);
        if (p.length > maxMessageBytes) _fail(ChannelErrors.tooLarge);
        return null;
      case 2:
        final p = _partial;
        if (p == null) _fail(ChannelErrors.badFrame);
        p.add(body);
        _partial = null;
        if (p.length > maxMessageBytes) _fail(ChannelErrors.tooLarge);
        return utf8.decode(p.takeBytes(), allowMalformed: true);
      default:
        _fail(ChannelErrors.badFrame);
    }
  }
}

// ---------------------------------------------------------------- handshake

/// The app's side of the handshake.
class ClientHandshake {
  final List<int> secret;
  final String machineId;
  final String deviceId;
  final Uint8List nonce;

  ClientHandshake({required this.secret, required this.machineId, required this.deviceId, Random? random})
    : nonce = randomBytes(handshakeNonceLength, random);

  /// The first frame to send.
  Uint8List get hello {
    final m = utf8.encode(machineId);
    final d = utf8.encode(deviceId);
    if (m.length > 255) throw ArgumentError('machine id too long');
    return Uint8List.fromList([FrameType.clientHello, channelVersion, ...nonce, m.length, ...m, ...d]);
  }

  /// Takes the host's reply; throws [ChannelError] for an error frame or garbage.
  SecureSession finish(Uint8List reply) {
    if (reply.isEmpty) throw const ChannelError(ChannelErrors.badFrame);
    if (reply[0] == FrameType.error) throw ChannelError(_errorReason(reply));
    if (reply[0] != FrameType.serverHello || reply.length != 2 + handshakeNonceLength) {
      throw const ChannelError(ChannelErrors.badFrame);
    }
    if (reply[1] != channelVersion) throw const ChannelError(ChannelErrors.badVersion);
    return SecureSession._derive(secret, nonce, reply.sublist(2), host: false);
  }
}

/// What the host learns from a valid client hello.
class HostAccepted {
  final String deviceId;
  final Uint8List reply;

  /// The session keyed with the secret passed to [HostHandshake.accept].
  final SecureSession session;
  final Uint8List appNonce;
  final Uint8List hostNonce;
  const HostAccepted(this.deviceId, this.reply, this.session, {required this.appNonce, required this.hostNonce});

  /// A fresh host-side session for this hello keyed with [secret] (a device's own key, or
  /// the pairing secret): the host tries each candidate on the app's first data frame and
  /// keeps the one that opens it.
  SecureSession sessionFor(List<int> secret) => SecureSession._derive(secret, appNonce, hostNonce, host: true);
}

/// A new device key: 32 random bytes, base64url without padding.
String newDeviceKey([Random? random]) => base64UrlNoPad(randomBytes(pairingSecretLength, random));

abstract final class HostHandshake {
  /// Checks the app's hello and answers it. Throws [ChannelError]: [ChannelErrors.badKey]
  /// when the hello names another machine (send [errorFrame] and close).
  static HostAccepted accept({
    required List<int> secret,
    required String machineId,
    required Uint8List frame,
    Random? random,
  }) {
    if (frame.length < 2 + handshakeNonceLength + 1 || frame[0] != FrameType.clientHello) {
      throw const ChannelError(ChannelErrors.badFrame);
    }
    if (frame[1] != channelVersion) throw const ChannelError(ChannelErrors.badVersion);
    final appNonce = frame.sublist(2, 2 + handshakeNonceLength);
    final mLen = frame[2 + handshakeNonceLength];
    final mStart = 3 + handshakeNonceLength;
    if (frame.length < mStart + mLen) throw const ChannelError(ChannelErrors.badFrame);
    final String mid, deviceId;
    try {
      mid = utf8.decode(frame.sublist(mStart, mStart + mLen));
      deviceId = utf8.decode(frame.sublist(mStart + mLen));
    } catch (_) {
      throw const ChannelError(ChannelErrors.badFrame);
    }
    if (mid != machineId) throw const ChannelError(ChannelErrors.badKey);
    final hostNonce = randomBytes(handshakeNonceLength, random);
    final reply = Uint8List.fromList([FrameType.serverHello, channelVersion, ...hostNonce]);
    return HostAccepted(deviceId, reply, SecureSession._derive(secret, appNonce, hostNonce, host: true),
        appNonce: appNonce, hostNonce: hostNonce);
  }
}
