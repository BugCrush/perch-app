// Saved machines (shared_preferences, key 'machines').
import 'dart:convert';
import 'dart:typed_data';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

const defaultPort = 8787;

/// The longest alias this device accepts for a machine.
const maxAliasLength = 40;

/// Why [raw] cannot be a machine's alias, or null when it can (after trimming).
String? aliasError(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return 'Enter a name';
  if (t.length > maxAliasLength) return 'At most $maxAliasLength characters';
  return null;
}

class Machine {
  /// The machine id from the pairing link (a random id for a machine saved by phase 1).
  final String id;

  /// The machine's own name: from the pairing link, then as the host reports it.
  final String label;

  /// This device's name for the machine (set with Rename…); null: [label].
  final String? alias;

  /// LAN addresses as `host:port`, tried first.
  final List<String> lan;

  /// The relay's base URL, or null for a LAN-only host.
  final String? relayUrl;

  /// The pairing secret (base64url); null for a machine saved by phase 1 with a pairing
  /// code, which must be paired again by QR before it can connect.
  final String? secret;

  /// This device's own key for the machine (base64url), given by the host when the device
  /// was allowed; null until then, or with a host older than device keys. It replaces the
  /// pairing secret in the handshake and opens this device's notifications; the relay still
  /// takes tokens made from the pairing secret.
  final String? deviceKey;

  const Machine(
      {required this.id,
      required this.label,
      this.lan = const [],
      this.relayUrl,
      this.secret,
      this.alias,
      this.deviceKey});

  /// What the app calls the machine: the alias, else its own name.
  String get displayName => alias ?? label;

  factory Machine.fromLink(PairingLink link) => Machine(
      id: link.machineId,
      label: link.name,
      lan: List.unmodifiable(link.lan),
      relayUrl: link.relayUrl,
      secret: base64UrlNoPad(link.secret));

  bool get needsPairing => secretBytes == null;

  Uint8List? get secretBytes {
    final s = secret;
    if (s == null) return null;
    final b = base64UrlDecodeNoPad(s);
    return b != null && b.length == pairingSecretLength ? b : null;
  }

  /// [deviceKey] as bytes (null: none, or not a valid key).
  Uint8List? get keyBytes {
    final k = deviceKey;
    if (k == null) return null;
    final b = base64UrlDecodeNoPad(k);
    return b != null && b.length == pairingSecretLength ? b : null;
  }

  /// What the handshake is keyed with: the device key, else the pairing secret.
  Uint8List? get channelSecret => keyBytes ?? secretBytes;

  /// What the card shows under the name.
  String get address => lan.isNotEmpty ? lan.first : (relayUrl == null ? '' : Uri.parse(relayUrl!).host);

  Machine copyWith(
          {String? label,
          List<String>? lan,
          String? relayUrl,
          bool clearRelay = false,
          String? alias,
          bool clearAlias = false,
          String? deviceKey,
          bool clearDeviceKey = false}) =>
      Machine(
          id: id,
          label: label ?? this.label,
          lan: lan ?? this.lan,
          relayUrl: clearRelay ? null : (relayUrl ?? this.relayUrl),
          secret: secret,
          alias: clearAlias ? null : (alias ?? this.alias),
          deviceKey: clearDeviceKey ? null : (deviceKey ?? this.deviceKey));

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'lan': lan,
        'relayUrl': relayUrl,
        'secret': secret,
        'alias': alias,
        if (deviceKey != null) 'deviceKey': deviceKey,
      };

  static Machine? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! String) return null;
    final lan = <String>[
      if (j['lan'] is List)
        for (final a in j['lan'] as List)
          if (a is String) a,
    ];
    // Saved by phase 1: {id, label, host, port, code}.
    final host = j['host'];
    if (lan.isEmpty && host is String) lan.add('$host:${j['port'] is int ? j['port'] : defaultPort}');
    return Machine(
      id: id,
      label: j['label'] is String ? j['label'] as String : (host is String ? host : id),
      lan: lan,
      relayUrl: j['relayUrl'] is String ? j['relayUrl'] as String : null,
      secret: j['secret'] is String ? j['secret'] as String : null,
      alias: j['alias'] is String && (j['alias'] as String).trim().isNotEmpty ? (j['alias'] as String).trim() : null,
      deviceKey: j['deviceKey'] is String && (j['deviceKey'] as String).isNotEmpty ? j['deviceKey'] as String : null,
    );
  }
}

class MachineStore {
  static const key = 'machines';

  /// [fresh] re-reads the platform's store first: the push handlers use it, since a
  /// background isolate's cached copy misses renames made in the app since it started.
  Future<List<Machine>> load({bool fresh = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (fresh) {
      try {
        await prefs.reload();
      } catch (_) {}
    }
    final raw = prefs.getString(key);
    if (raw == null) return [];
    try {
      final v = jsonDecode(raw);
      if (v is! List) return [];
      return v.map(Machine.fromJson).whereType<Machine>().toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _write(List<Machine> all) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode([for (final m in all) m.toJson()]));
  }

  /// Adds, or replaces the machine with the same id.
  Future<void> save(Machine m) async {
    final all = await load();
    final i = all.indexWhere((x) => x.id == m.id);
    if (i >= 0) {
      all[i] = m;
    } else {
      all.add(m);
    }
    await _write(all);
  }

  Future<void> remove(String id) async {
    final all = await load();
    all.removeWhere((m) => m.id == id);
    await _write(all);
  }
}

/// This app's device id (random, kept in shared_preferences): sent in the handshake and
/// to the relay.
Future<String> loadDeviceId() async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString('deviceId');
  if (existing != null && existing.isNotEmpty) return existing;
  final id = base64UrlNoPad(randomBytes(16));
  await prefs.setString('deviceId', id);
  return id;
}
