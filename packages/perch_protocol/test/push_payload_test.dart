import 'dart:convert';
import 'dart:typed_data';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

Uint8List bytes(int n, int seed) => Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed) & 0xff));

void main() {
  final secret = bytes(32, 1);
  const note = PushNote(
    title: 'Desk',
    body: 'Fix login: asked 2 questions',
    machineId: 'machine-1',
    sessionId: 'session-1',
    kind: PushKinds.question,
    promptId: 'toolu_1',
  );

  test('seals and opens a notification', () {
    final sealed = sealPush(secret, 'machine-1', note);
    final back = openPush(secret, 'machine-1', sealed);
    expect(back, isNotNull);
    expect(back!.toJson(), note.toJson());
  });

  test('nothing readable in the sealed text, and a new nonce every time', () {
    final a = sealPush(secret, 'machine-1', note);
    final b = sealPush(secret, 'machine-1', note);
    expect(a, isNot(b));
    final raw = latin1.decode(base64.decode(a));
    for (final s in ['Desk', 'Fix login', 'session-1', 'toolu_1', 'question', 'machine-1']) {
      expect(raw.contains(s), isFalse, reason: s);
      expect(a.contains(s), isFalse, reason: s);
    }
  });

  test('a wrong secret, another machine, or garbage opens to null', () {
    final sealed = sealPush(secret, 'machine-1', note);
    expect(openPush(bytes(32, 2), 'machine-1', sealed), isNull);
    expect(openPush(secret, 'machine-2', sealed), isNull);
    expect(openPush(secret, 'machine-1', 'not base64!'), isNull);
    expect(openPush(secret, 'machine-1', ''), isNull);
    final tampered = base64.decode(sealed)..[20] ^= 1;
    expect(openPush(secret, 'machine-1', base64.encode(tampered)), isNull);
  });

  test('the push key is not the channel key or a relay token', () {
    final key = pushKey(secret);
    expect(key.length, 32);
    expect(base64UrlNoPad(key), isNot(relayHostToken(secret)));
    expect(base64UrlNoPad(key), isNot(relayDeviceToken(secret)));
  });

  test('the collapse tag is stable per session and reveals nothing', () {
    final t1 = pushTag(secret, 'session-1');
    expect(pushTag(secret, 'session-1'), t1);
    expect(pushTag(secret, 'session-2'), isNot(t1));
    expect(pushTag(bytes(32, 2), 'session-1'), isNot(t1));
    expect(t1.contains('session'), isFalse);
    expect(RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(t1), isTrue);
  });

  test('a withdraw note round-trips', () {
    const w = PushNote(machineId: 'machine-1', sessionId: 'session-1', kind: PushKinds.withdraw);
    final back = openPush(secret, 'machine-1', sealPush(secret, 'machine-1', w));
    expect(back!.kind, PushKinds.withdraw);
    expect(back.title, '');
    expect(back.isWithdraw, isTrue);
  });
}
