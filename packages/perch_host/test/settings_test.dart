// Settings instead of the owner's values in the code: a new host takes its relay from
// PERCH_RELAY_URL, else from the build (`dart compile exe -DPERCH_DEFAULT_RELAY=<url>`, which
// the release workflow fills from a repository variable), else none (LAN only until
// `relay set`). An existing host keeps what it has; `relay clear` stays cleared.
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_state.dart';
import 'package:test/test.dart';

final sep = Platform.pathSeparator;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('perch_settings_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a_new_host_takes_the_relay_from_the_environment', () {
    final s = HostState.load('${tmp.path}${sep}a', environment: {'PERCH_RELAY_URL': 'https://relay.example.workers.dev'});
    expect(s.createdNow, isTrue);
    expect(s.relayUrl, 'https://relay.example.workers.dev');
    final saved = jsonDecode(File('${tmp.path}${sep}a${sep}host.json').readAsStringSync()) as Map;
    expect(saved['relayUrl'], 'https://relay.example.workers.dev');
  });

  test('without_a_setting_a_new_host_has_no_relay', () {
    expect(defaultRelayUrl(const {}), builtInRelayUrl.isEmpty ? isNull : builtInRelayUrl);
    final s = HostState.load('${tmp.path}${sep}b', environment: const {});
    expect(s.relayUrl, builtInRelayUrl.isEmpty ? isNull : builtInRelayUrl);
  });

  test('a_url_that_is_not_a_relay_is_ignored', () {
    expect(defaultRelayUrl({'PERCH_RELAY_URL': 'ftp://nope'}), builtInRelayUrl.isEmpty ? isNull : builtInRelayUrl);
    expect(defaultRelayUrl({'PERCH_RELAY_URL': 'http://127.0.0.1:8789'}), 'http://127.0.0.1:8789');
  });

  test('an_existing_host_keeps_its_relay_or_none', () {
    final dir = '${tmp.path}${sep}c';
    final first = HostState.load(dir, environment: const {})..setRelay(null);
    expect(first.relayUrl, isNull);
    final again = HostState.load(dir, environment: {'PERCH_RELAY_URL': 'https://relay.example.workers.dev'});
    expect(again.createdNow, isFalse);
    expect(again.relayUrl, isNull, reason: 'relay clear stays cleared; the default is for new hosts');
  });
}
