// The pairing link a host shows as a QR code:
//   perch://pair?v=1&n=<machine name>&m=<machine id>&k=<secret, base64url>&r=<relay URL>&l=<host:port,...>
import 'dart:typed_data';

import 'secure_channel.dart';

/// `https://relay.example` -> `wss://relay.example/m/<machine id>/<endpoint>[?query]`.
Uri relaySocketUri(String relayUrl, String machineId, String endpoint, [Map<String, String>? query]) {
  final base = Uri.parse(relayUrl);
  final scheme = switch (base.scheme) { 'https' || 'wss' => 'wss', _ => 'ws' };
  final prefix = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
  return base.replace(scheme: scheme, path: '$prefix/m/$machineId/$endpoint', queryParameters: query);
}

/// `https://relay.example` (or `wss://…`) -> `https://relay.example/m/<machine id>/<path>`.
Uri relayHttpUri(String relayUrl, String machineId, String path) {
  final base = Uri.parse(relayUrl);
  final scheme = switch (base.scheme) { 'wss' || 'https' => 'https', _ => 'http' };
  final prefix = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
  return base.replace(scheme: scheme, path: '$prefix/m/$machineId/$path');
}

class PairingLink {
  final String name;
  final String machineId;
  final Uint8List secret;

  /// The relay's base URL (https://...), or null for a LAN-only host.
  final String? relayUrl;

  /// LAN addresses as `host:port`.
  final List<String> lan;

  const PairingLink({
    required this.name,
    required this.machineId,
    required this.secret,
    this.relayUrl,
    this.lan = const [],
  });

  @override
  String toString() {
    final q = <String>[
      'v=1',
      'n=${Uri.encodeQueryComponent(name)}',
      'm=${Uri.encodeQueryComponent(machineId)}',
      'k=${base64UrlNoPad(secret)}',
      if (relayUrl != null) 'r=${Uri.encodeQueryComponent(relayUrl!)}',
      if (lan.isNotEmpty) 'l=${lan.join(',')}',
    ];
    return 'perch://pair?${q.join('&')}';
  }

  static final _hostPort = RegExp(r'^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?:\d{1,5}$');
  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  static bool validRelayUrl(String s) {
    final u = Uri.tryParse(s);
    return u != null && const ['https', 'http', 'wss', 'ws'].contains(u.scheme) && u.host.isNotEmpty;
  }

  /// Null when [text] is not a valid version 1 pairing link.
  static PairingLink? parse(String text) {
    final s = text.trim();
    final u = Uri.tryParse(s);
    if (u == null || u.scheme != 'perch' || u.host != 'pair') return null;
    final Map<String, String> q;
    try {
      q = u.queryParameters;
    } catch (_) {
      return null;
    }
    if (q['v'] != '1') return null;
    final m = q['m'] ?? '';
    if (!_id.hasMatch(m)) return null;
    final k = base64UrlDecodeNoPad(q['k'] ?? '');
    if (k == null || k.length != pairingSecretLength) return null;
    final r = q['r'];
    if (r != null && r.isNotEmpty && !validRelayUrl(r)) return null;
    final lan = [
      for (final a in (q['l'] ?? '').split(','))
        if (a.trim().isNotEmpty) a.trim(),
    ];
    if (lan.any((a) => !_hostPort.hasMatch(a))) return null;
    final n = (q['n'] ?? '').trim();
    return PairingLink(
      name: n.isEmpty ? 'Machine' : n,
      machineId: m,
      secret: k,
      relayUrl: (r == null || r.isEmpty) ? null : r,
      lan: lan,
    );
  }
}
