// The host's one outgoing WebSocket to the relay. Each device behind the relay becomes a
// FrameLink handed to the server, which runs the same encrypted channel as for the LAN.
//
// Relay protocol (see relay/src/protocol.ts): binary frames are
// [device id length][device id][frame]; text frames from the relay are
// {"t":"open","d":id} and {"t":"close","d":id}; the host sends {"t":"close","d":id} to
// drop a device and "ping" every 30 s (the relay answers "pong").
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:perch_protocol/perch_protocol.dart';

import 'frame_link.dart';
import 'host_board_relay.dart' show ioRelayHttp;
import 'host_state.dart';
import 'server.dart';

/// Opens a WebSocket (replaced in tests).
typedef RelayConnector = Future<WebSocket> Function(Uri uri, Map<String, String> headers);

Future<WebSocket> defaultRelayConnector(Uri uri, Map<String, String> headers) =>
    WebSocket.connect(uri.toString(), headers: headers).timeout(const Duration(seconds: 20));

Uint8List relayEnvelope(String deviceId, List<int> frame) {
  final id = utf8.encode(deviceId);
  return Uint8List(1 + id.length + frame.length)
    ..[0] = id.length
    ..setRange(1, 1 + id.length, id)
    ..setRange(1 + id.length, 1 + id.length + frame.length, frame);
}

({String deviceId, Uint8List frame})? openRelayEnvelope(List<int> data) {
  if (data.isEmpty) return null;
  final len = data[0];
  if (len == 0 || data.length < 1 + len) return null;
  try {
    final id = utf8.decode(data.sublist(1, 1 + len));
    return (deviceId: id, frame: Uint8List.fromList(data.sublist(1 + len)));
  } catch (_) {
    return null;
  }
}

class _RelayDeviceLink implements FrameLink {
  final RelayClient client;
  final String deviceId;
  final _frames = StreamController<Object>();
  bool _closed = false;
  _RelayDeviceLink(this.client, this.deviceId);

  @override
  Stream<Object> get frames => _frames.stream;

  @override
  String get address => 'relay';

  void deliver(Uint8List frame) {
    if (!_closed) _frames.add(frame);
  }

  /// The relay said the device went away.
  void ended() {
    if (_closed) return;
    _closed = true;
    _frames.close();
  }

  @override
  void send(Uint8List frame) {
    if (!_closed) client._sendBinary(relayEnvelope(deviceId, frame));
  }

  @override
  void sendText(String text) {} // only phase 1 apps get text, and they never use the relay

  @override
  void close() {
    if (_closed) return;
    ended();
    client._links.remove(deviceId);
    client._sendText(jsonEncode({'t': 'close', 'd': deviceId}));
  }
}

class RelayClient implements RemoteTransport {
  final HostState state;
  final void Function(FrameLink link) onDevice;
  final RelayConnector connector;
  final Duration pingInterval;
  final Duration maxBackoff;

  /// Asks the relay why a connection was refused (`GET /m/<id>/check`; replaced in tests).
  final RelayHttp http;

  /// How long a machine the relay refuses for its invite waits before trying again (a new
  /// code from `/perch` or `relay invite` reconnects at once).
  final Duration inviteRetry;

  RelayClient({
    required this.state,
    required this.onDevice,
    RelayConnector? connector,
    RelayHttp? http,
    this.pingInterval = const Duration(seconds: 30),
    this.maxBackoff = const Duration(seconds: 60),
    this.inviteRetry = const Duration(minutes: 5),
  })  : connector = connector ?? defaultRelayConnector,
        http = http ?? ioRelayHttp;

  /// Why the relay refuses this machine: `inviteRequired`, `inviteInvalid`, `inviteFull`,
  /// `inviteRevoked` or `poolUsedUp`; null while it does not.
  @override
  String? refusal;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${state.hostToken}',
        'X-Perch-Device-Token-Hash': tokenHash(state.deviceToken),
        if (state.relayInvite != null) 'X-Perch-Invite': state.relayInvite!,
      };

  static const _inviteErrors = {'inviteRequired', 'inviteInvalid', 'inviteFull', 'inviteRevoked'};

  /// What the owner reads for a refusal.
  static String refusalText(String refusal) => switch (refusal) {
        'inviteRequired' => 'this relay needs an invite code (/perch, or perch_host relay invite <code>)',
        'inviteInvalid' => 'the relay does not know this invite code',
        'inviteFull' => 'this invite code is already used by as many machines as it allows',
        'inviteRevoked' => 'this machine\'s invite was revoked by the relay\'s owner',
        'poolUsedUp' => 'the shared relay pool is used up for today: devices reach this machine on its network only until 00:00 UTC',
        _ => refusal,
      };

  /// After a failed connection: the relay's reason, if it gives one it means.
  Future<String?> _reason() async {
    final url = state.relayUrl;
    if (url == null) return null;
    try {
      final r = await http('GET', relayHttpUri(url, state.machineId, 'check'), _headers, null);
      if (r.status == 200) return null;
      final j = jsonDecode(r.body);
      final e = j is Map ? j['error'] : null;
      return e is String && (_inviteErrors.contains(e) || e == 'poolUsedUp') ? e : null;
    } catch (_) {
      return null;
    }
  }

  /// Waits until the next 00:00 UTC (and a little), then connects again.
  void _waitForNewDay() {
    final now = DateTime.now().toUtc();
    final until = DateTime.utc(now.year, now.month, now.day + 1);
    limitedUntil = until;
    _retry?.cancel();
    _retry = Timer(until.difference(now) + Duration(seconds: 5 + Random().nextInt(60)), () {
      limitedUntil = null;
      refusal = null;
      _backoff = const Duration(seconds: 1);
      unawaited(_connect());
    });
  }

  /// Refused by the relay for [why]: says so and waits (a day for the pool, a while for an
  /// invite).
  void _refused(String why) {
    refusal = why;
    _setStatus(refusalText(why));
    if (why == 'poolUsedUp') {
      _waitForNewDay();
      return;
    }
    _retry?.cancel();
    _retry = Timer(inviteRetry, () => unawaited(_connect()));
  }

  final Map<String, _RelayDeviceLink> _links = {};
  final _status = StreamController<String>.broadcast();
  WebSocket? _socket;
  bool _running = false;
  Timer? _retry;
  Timer? _ping;
  DateTime _lastPong = DateTime.now();
  Duration _backoff = const Duration(seconds: 1);
  String _statusText = 'not connected';
  int _connections = 0;

  /// `connected`, `connecting`, `retrying in 4 s (...)`, `stopped`, `not set`.
  String get status => _statusText;
  Stream<String> get statusChanges => _status.stream;
  bool get connected => _socket != null;

  /// How many times a connection to the relay was established (for tests and logs).
  int get connections => _connections;

  void _setStatus(String s) {
    if (s == _statusText) return;
    _statusText = s;
    if (!_status.isClosed) _status.add(s);
  }

  @override
  void start() {
    if (_running) return;
    _running = true;
    _backoff = const Duration(seconds: 1);
    unawaited(_connect());
  }

  @override
  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    _ping?.cancel();
    _dropLinks();
    final s = _socket;
    _socket = null;
    if (s != null) {
      try {
        await s.close(1000, 'host stopped');
      } catch (_) {}
    }
    _setStatus(state.relayUrl == null ? 'not set' : 'stopped');
  }

  Future<void> dispose() async {
    await stop();
    await _status.close();
  }

  Future<void> _connect() async {
    if (!_running) return;
    final url = state.relayUrl;
    if (url == null) {
      _running = false;
      _setStatus('not set');
      return;
    }
    _setStatus('connecting');
    final WebSocket ws;
    try {
      ws = await connector(relaySocketUri(url, state.machineId, 'host'), _headers);
    } catch (e) {
      final why = await _reason();
      if (!_running) return;
      if (why != null) {
        _refused(why);
      } else {
        _scheduleRetry('$e');
      }
      return;
    }
    refusal = null;
    if (!_running) {
      unawaited(ws.close(1000, 'host stopped'));
      return;
    }
    _socket = ws;
    _connections++;
    _backoff = const Duration(seconds: 1);
    _lastPong = DateTime.now();
    _setStatus('connected');
    _ping?.cancel();
    _ping = Timer.periodic(pingInterval, (_) {
      if (DateTime.now().difference(_lastPong) > pingInterval * 2 + const Duration(seconds: 5)) {
        // No pong for two rounds: the path is dead even if the socket has not noticed.
        unawaited(ws.close(4002, 'no pong'));
        return;
      }
      _sendText('ping');
    });
    ws.listen(
      (data) => _onMessage(data),
      onDone: () => _onClosed(ws),
      onError: (_) => _onClosed(ws),
      cancelOnError: true,
    );
  }

  void _scheduleRetry(String why) {
    if (!_running) return;
    final wait = _backoff;
    final next = _backoff * 2;
    _backoff = next > maxBackoff ? maxBackoff : next;
    final jitter = Duration(milliseconds: Random().nextInt(250));
    _setStatus('retrying in ${wait.inSeconds} s');
    _retry?.cancel();
    _retry = Timer(wait + jitter, () => unawaited(_connect()));
  }

  /// Over the relay's daily message cap for this machine (close code 4029): devices reach it
  /// on the LAN only until then (the next 00:00 UTC).
  DateTime? limitedUntil;

  void _onClosed(WebSocket ws) {
    if (!identical(ws, _socket)) return;
    _socket = null;
    _ping?.cancel();
    _dropLinks();
    if (ws.closeCode == 4029) {
      _setStatus('daily limit reached: devices reach this machine on its network only until 05:30 IST (00:00 UTC)');
      _waitForNewDay();
      return;
    }
    if (ws.closeCode == 4030) return _refused('poolUsedUp');
    if (ws.closeCode == 4031) return _refused('inviteRevoked');
    _scheduleRetry('closed ${ws.closeCode ?? ''}');
  }

  void _dropLinks() {
    for (final l in _links.values.toList()) {
      l.ended();
    }
    _links.clear();
  }

  void _onMessage(dynamic data) {
    if (data is String) {
      if (data == 'pong') {
        _lastPong = DateTime.now();
        return;
      }
      Object? m;
      try {
        m = jsonDecode(data);
      } catch (_) {
        return;
      }
      if (m is! Map) return;
      final id = m['d'];
      if (id is! String) return;
      switch (m['t']) {
        case 'open':
          _links.remove(id)?.ended();
          final link = _RelayDeviceLink(this, id);
          _links[id] = link;
          onDevice(link);
        case 'close':
          _links.remove(id)?.ended();
      }
      return;
    }
    final e = openRelayEnvelope(data as List<int>);
    if (e == null) return;
    final link = _links[e.deviceId];
    if (link == null) {
      _sendText(jsonEncode({'t': 'close', 'd': e.deviceId}));
      return;
    }
    link.deliver(e.frame);
  }

  void _sendBinary(Uint8List data) {
    try {
      _socket?.add(data);
    } catch (_) {}
  }

  void _sendText(String text) {
    try {
      _socket?.add(text);
    } catch (_) {}
  }
}
