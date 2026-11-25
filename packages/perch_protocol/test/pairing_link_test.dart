import 'dart:typed_data';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  final secret = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xff));

  test('encode_then_parse_round_trips', () {
    final link = PairingLink(
      name: 'Desk PC',
      machineId: 'AAECAwQFBgcICQoLDA0ODw',
      secret: secret,
      relayUrl: 'https://perch-relay.example.workers.dev',
      lan: const ['192.168.1.20:8787', '10.0.0.5:8787'],
    );
    final text = link.toString();
    expect(text, startsWith('perch://pair?v=1&'));
    expect(text, contains('&l=192.168.1.20:8787,10.0.0.5:8787'));
    final back = PairingLink.parse(text)!;
    expect(back.name, 'Desk PC');
    expect(back.machineId, 'AAECAwQFBgcICQoLDA0ODw');
    expect(back.secret, secret);
    expect(back.relayUrl, 'https://perch-relay.example.workers.dev');
    expect(back.lan, ['192.168.1.20:8787', '10.0.0.5:8787']);
  });

  test('without_relay_or_lan', () {
    final link = PairingLink(name: 'M', machineId: 'abc_-D', secret: secret);
    expect(link.toString(), isNot(contains('r=')));
    final back = PairingLink.parse('  ${link.toString()}\n')!;
    expect(back.relayUrl, isNull);
    expect(back.lan, isEmpty);
  });

  test('base64url_secret_has_no_padding', () {
    final link = PairingLink(name: 'M', machineId: 'm', secret: secret);
    final k = Uri.parse(link.toString()).queryParameters['k']!;
    expect(k, isNot(contains('=')));
    expect(k.length, 43);
  });

  test('rejects_bad_links', () {
    final good = PairingLink(name: 'M', machineId: 'mid', secret: secret).toString();
    expect(PairingLink.parse(good), isNotNull);
    expect(PairingLink.parse('https://pair?v=1'), isNull);
    expect(PairingLink.parse('perch://other?${Uri.parse(good).query}'), isNull);
    expect(PairingLink.parse(good.replaceFirst('v=1', 'v=2')), isNull);
    expect(PairingLink.parse(good.replaceFirst(RegExp(r'k=[^&]+'), 'k=short')), isNull);
    expect(PairingLink.parse(good.replaceFirst(RegExp(r'm=[^&]+'), 'm=')), isNull);
    expect(PairingLink.parse('$good&r=ftp://x'), isNull);
    expect(PairingLink.parse('$good&l=bad host:1'), isNull);
    expect(PairingLink.parse('not a link at all'), isNull);
    expect(PairingLink.parse(''), isNull);
  });

  test('base64url_helpers', () {
    expect(base64UrlNoPad([0xfb, 0xff]), '-_8');
    expect(base64UrlDecodeNoPad('-_8'), [0xfb, 0xff]);
    expect(base64UrlDecodeNoPad('!!'), isNull);
  });

  test('with a relay the QR holds a web address on it; the secret stays after the #', () {
    final link = PairingLink(
      name: 'Desk PC',
      machineId: 'AAECAwQFBgcICQoLDA0ODw',
      secret: secret,
      relayUrl: 'https://perch-relay.example.workers.dev/',
      lan: const ['192.168.1.20:8787'],
    );
    final web = link.qrText;
    expect(web, startsWith('https://perch-relay.example.workers.dev/pair#v=1&'));
    final u = Uri.parse(web);
    expect(u.query, isEmpty, reason: 'nothing a server would see');
    expect(u.path, '/pair');
    final back = PairingLink.parse(web)!;
    expect(back.secret, secret);
    expect(back.relayUrl, 'https://perch-relay.example.workers.dev/');
    expect(back.lan, ['192.168.1.20:8787']);
    // The perch:// form still parses, and a host without a relay keeps it in its QR.
    expect(PairingLink.parse(link.toString())!.machineId, 'AAECAwQFBgcICQoLDA0ODw');
    final lanOnly = PairingLink(name: 'Box', machineId: 'AAECAwQFBgcICQoLDA0ODw', secret: secret);
    expect(lanOnly.webUrl, isNull);
    expect(lanOnly.qrText, startsWith('perch://pair?'));
    // Other web addresses are not pairing links.
    expect(PairingLink.parse('https://example.com/pair'), isNull);
    expect(PairingLink.parse('https://example.com/other#v=1'), isNull);
  });
}
