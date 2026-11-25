import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

Uint8List bytes(int n, int seed) => Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed) & 0xff));

/// Runs a full handshake and returns (app side, host side).
({SecureSession app, SecureSession host, String deviceId}) pair({
  List<int>? appSecret,
  List<int>? hostSecret,
  String machineId = 'machine-1',
}) {
  final secret = bytes(32, 1);
  final client = ClientHandshake(secret: appSecret ?? secret, machineId: machineId, deviceId: 'dev-1');
  final accepted = HostHandshake.accept(secret: hostSecret ?? secret, machineId: 'machine-1', frame: client.hello);
  final app = client.finish(accepted.reply);
  return (app: app, host: accepted.session, deviceId: accepted.deviceId);
}

void main() {
  group('hkdf', () {
    test('matches_rfc5869_test_case_1', () {
      final ikm = List.filled(22, 0x0b);
      final salt = [for (var i = 0; i <= 0x0c; i++) i];
      final info = [for (var i = 0xf0; i <= 0xf9; i++) i];
      final okm = hkdfSha256(ikm, salt: salt, info: info, length: 42);
      expect(
        okm.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
        '34007208d5b887185865',
      );
    });
  });

  group('secure channel', () {
    test('round_trip_both_directions', () {
      final p = pair();
      expect(p.deviceId, 'dev-1');
      for (final m in ['{"type":"hello"}', 'second', '']) {
        final frames = p.app.seal(m);
        expect(frames, hasLength(1));
        expect(p.host.open(frames.single), m);
      }
      final back = p.host.seal('{"type":"welcome","machineName":"ünïcode ✓"}');
      expect(p.app.open(back.single), '{"type":"welcome","machineName":"ünïcode ✓"}');
    });

    test('ciphertext_does_not_contain_the_plaintext', () {
      final p = pair();
      const secret = 'a very recognisable sentence about the project';
      final frame = p.app.seal(secret).single;
      expect(latin1.decode(frame, allowInvalid: true).contains('recognisable'), isFalse);
      expect(frame.first, FrameType.data);
    });

    test('tampered_frame_closes', () {
      final p = pair();
      final frame = p.app.seal('hello').single;
      frame[frame.length - 3] ^= 1;
      expect(() => p.host.open(frame), throwsA(isA<ChannelError>()));
      // After a failure the session stays closed, even for a good frame.
      final good = p.app.seal('next').single;
      expect(() => p.host.open(good), throwsA(isA<ChannelError>()));
      expect(p.host.closed, isTrue);
    });

    test('replayed_frame_closes', () {
      final p = pair();
      final f = p.app.seal('one').single;
      expect(p.host.open(f), 'one');
      expect(() => p.host.open(Uint8List.fromList(f)), throwsA(isA<ChannelError>()));
    });

    test('reordered_frames_close', () {
      final p = pair();
      final a = p.app.seal('a').single;
      final b = p.app.seal('b').single;
      expect(() => p.host.open(b), throwsA(isA<ChannelError>()));
      expect(() => p.host.open(a), throwsA(isA<ChannelError>()));
    });

    test('wrong_secret_fails_the_handshake', () {
      final p = pair(appSecret: bytes(32, 99));
      final f = p.app.seal('{"type":"hello"}').single;
      expect(() => p.host.open(f), throwsA(isA<ChannelError>()));
    });

    test('wrong_machine_id_is_refused_by_the_host', () {
      final client = ClientHandshake(secret: bytes(32, 1), machineId: 'other', deviceId: 'd');
      expect(
        () => HostHandshake.accept(secret: bytes(32, 1), machineId: 'machine-1', frame: client.hello),
        throwsA(isA<ChannelError>().having((e) => e.reason, 'reason', ChannelErrors.badKey)),
      );
    });

    test('keys_differ_per_direction', () {
      final p = pair();
      // A frame the app sealed cannot be opened as if the host had sealed it.
      final fromApp = p.app.seal('x').single;
      expect(() => p.app.open(fromApp), throwsA(isA<ChannelError>()));
      final p2 = pair();
      final fromHost = p2.host.seal('x').single;
      expect(() => p2.host.open(fromHost), throwsA(isA<ChannelError>()));
      expect(p.app.sendKeyForTest, isNot(equals(p.app.receiveKeyForTest)));
      expect(p.app.sendKeyForTest, p.host.receiveKeyForTest);
      expect(p.app.receiveKeyForTest, p.host.sendKeyForTest);
    });

    test('fresh_nonces_give_fresh_keys_per_connection', () {
      final a = pair();
      final b = pair();
      expect(a.app.sendKeyForTest, isNot(equals(b.app.sendKeyForTest)));
      final f = a.app.seal('x').single;
      expect(() => b.host.open(f), throwsA(isA<ChannelError>()));
    });

    test('error_frame_is_reported', () {
      final client = ClientHandshake(secret: bytes(32, 1), machineId: 'm', deviceId: 'd');
      expect(
        () => client.finish(errorFrame(ChannelErrors.badKey)),
        throwsA(isA<ChannelError>().having((e) => e.reason, 'reason', ChannelErrors.badKey)),
      );
      final p = pair();
      expect(
        () => p.app.open(errorFrame('stopped')),
        throwsA(isA<ChannelError>().having((e) => e.reason, 'reason', 'stopped')),
      );
    });

    test('garbage_hello_is_refused', () {
      expect(
        () => HostHandshake.accept(secret: bytes(32, 1), machineId: 'm', frame: Uint8List.fromList([1, 2, 3])),
        throwsA(isA<ChannelError>()),
      );
      expect(
        () => HostHandshake.accept(secret: bytes(32, 1), machineId: 'm', frame: Uint8List(0)),
        throwsA(isA<ChannelError>()),
      );
    });

    test('large_messages_are_chunked_and_reassembled', () {
      final p = pair();
      final r = Random(7);
      final big = String.fromCharCodes(List.generate(2 * 1024 * 1024 + 123, (_) => 97 + r.nextInt(26)));
      final frames = p.host.seal(big);
      expect(frames.length, 3);
      for (final f in frames) {
        expect(f.length, lessThanOrEqualTo(maxChunkPlaintext + 64));
      }
      expect(p.app.open(frames[0]), isNull);
      expect(p.app.open(frames[1]), isNull);
      expect(p.app.open(frames[2]), big);
      // The channel continues normally afterwards.
      expect(p.app.open(p.host.seal('after').single), 'after');
    });

    test('a_dropped_chunk_closes', () {
      final p = pair();
      final big = 'x' * (maxChunkPlaintext + 10);
      final frames = p.host.seal(big);
      expect(frames.length, 2);
      expect(() => p.app.open(frames[1]), throwsA(isA<ChannelError>()));
    });
  });

  group('relay tokens', () {
    test('host_and_device_tokens_differ_and_are_stable', () {
      final s = bytes(32, 5);
      expect(relayHostToken(s), relayHostToken(s));
      expect(relayHostToken(s), isNot(relayDeviceToken(s)));
      expect(relayHostToken(s), isNot(relayHostToken(bytes(32, 6))));
      expect(tokenHash(relayHostToken(s)), hasLength(64));
    });
  });
}
