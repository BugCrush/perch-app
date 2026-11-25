// Tells each paired machine's relay where this device receives push messages: its FCM
// token, stored by the relay under this device id (POST /m/<id>/devices/<device>/push-token
// with the device token). Again when the token changes, and `null` when a machine is removed.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/machine_store.dart';

/// Posts [body]; returns the HTTP status (replaced in tests).
typedef HttpPost = Future<int> Function(Uri uri, Map<String, String> headers, String body);

Future<int> defaultHttpPost(Uri uri, Map<String, String> headers, String body) async {
  final r = await http.post(uri, headers: headers, body: body).timeout(const Duration(seconds: 20));
  return r.statusCode;
}

class PushRegistrar {
  final String deviceId;
  final HttpPost post;
  PushRegistrar({required this.deviceId, HttpPost? post}) : post = post ?? defaultHttpPost;

  /// Machine, relay, secret and token already registered in this run.
  final Set<String> _done = {};

  static bool canRegister(Machine m) => m.relayUrl != null && m.secretBytes != null;

  Future<int?> _send(Machine m, String? token) async {
    final uri = relayHttpUri(m.relayUrl!, m.id, 'devices/$deviceId/push-token');
    try {
      return await post(
        uri,
        {'Authorization': 'Bearer ${relayDeviceToken(m.secretBytes!)}', 'Content-Type': 'application/json'},
        jsonEncode({'token': token}),
      );
    } catch (_) {
      return null;
    }
  }

  /// Registers [token] with [m]'s relay (once per run for the same pairing and token).
  Future<bool> register(Machine m, String token) async {
    if (!canRegister(m)) return false;
    final key = '${m.id}|${m.relayUrl}|${m.secret}|$token';
    if (_done.contains(key)) return true;
    final status = await _send(m, token);
    if (status != 200) return false;
    _done.add(key);
    return true;
  }

  /// Registers [token] with every machine that has a relay.
  Future<void> sync(Iterable<Machine> machines, String? token) async {
    if (token == null || token.isEmpty) return;
    for (final m in machines) {
      await register(m, token);
    }
  }

  /// Tells [m]'s relay to forget this device's token (the machine was removed).
  Future<void> unregister(Machine m) async {
    if (!canRegister(m)) return;
    _done.removeWhere((k) => k.startsWith('${m.id}|'));
    await _send(m, null);
  }
}
