// Pairing links opened from outside the app: a phone camera scanning a host's QR code
// (https://<relay>/pair#… or perch://pair?…) starts or wakes Perch with the link
// (MainActivity, channel "perch/links"). The newest one waits in [pending] until the app
// can show Add machine with it (after the app lock).
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:perch_protocol/perch_protocol.dart';

class PairLinks {
  static const channel = MethodChannel('perch/links');

  /// A pairing link waiting to be opened.
  final ValueNotifier<String?> pending = ValueNotifier(null);

  /// Listens for links and asks for the one that started the app. Anything that is not a
  /// pairing link is ignored.
  Future<void> start() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'link') offer(call.arguments);
    });
    try {
      offer(await channel.invokeMethod<String>('initialLink'));
    } catch (_) {
      // No Android side (tests, the board page): nothing to receive.
    }
  }

  void offer(Object? link) {
    if (link is String && PairingLink.parse(link) != null) pending.value = link;
  }

  /// The waiting link, once.
  String? take() {
    final v = pending.value;
    pending.value = null;
    return v;
  }
}
