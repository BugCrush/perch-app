import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/connection/machine_store.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// The pairing secret of every test machine.
final List<int> testSecret = List.unmodifiable(List.generate(32, (i) => i * 3 & 0xff));

Machine testMachine(
        {String id = 'm1',
        String? label,
        List<String> lan = const ['192.168.1.20:8787'],
        String? relayUrl,
        List<int>? secret,
        String? alias}) =>
    Machine(
        id: id,
        label: label ?? id,
        lan: lan,
        relayUrl: relayUrl,
        secret: base64UrlNoPad(secret ?? testSecret),
        alias: alias);

/// A pairing link for a test machine.
String testLink({String id = 'mid-1', String name = 'Desk', List<String> lan = const ['192.168.1.20:8787'], String? relay}) =>
    PairingLink(name: name, machineId: id, secret: Uint8List.fromList(testSecret), lan: lan, relayUrl: relay)
        .toString();

class _FakeSink implements WebSocketSink {
  final StreamSink<dynamic> inner;
  _FakeSink(this.inner);
  @override
  void add(dynamic data) => inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) => inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<dynamic> stream) => inner.addStream(stream);
  @override
  Future<void> close([int? closeCode, String? closeReason]) => inner.close();
  @override
  Future<void> get done => inner.done;
}

/// A WebSocketChannel backed by an in-memory StreamChannel.
class FakeWebSocket with StreamChannelMixin<dynamic> implements WebSocketChannel {
  final StreamChannel<dynamic> inner;
  FakeWebSocket(this.inner);
  @override
  Stream<dynamic> get stream => inner.stream;
  @override
  WebSocketSink get sink => _FakeSink(inner.sink);
  @override
  Future<void> get ready => Future.value();
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
}

/// How a fake endpoint behaves.
enum FakeMode {
  /// A Perch host that completes the encrypted handshake.
  host,

  /// Accepts the connection and never answers (an unreachable address that hangs).
  silent,

  /// The connection fails at once.
  refuse,

  /// A host with another secret: it answers the hello, then cannot open the app's frames.
  wrongSecret,
}

/// The host side of one fake connection: it runs the host end of the encrypted channel.
/// [frames] are the app's decrypted messages; [send] encrypts.
class FakeHostSide {
  final StreamChannelController<dynamic> controller;
  final Uri uri;
  final FakeMode mode;
  final List<String> frames = [];

  /// Text frames the app sent (relay control) and anything that arrived raw.
  final List<Object> raw = [];
  final List<String> _pending = [];
  SecureSession? session;
  String? deviceId;
  bool closedByClient = false;

  /// Device keys the host knows: the first data frame is tried with each, then the pairing
  /// secret (like the real host).
  final List<List<int>> deviceKeys;

  /// The key that opened the channel (null: the pairing secret, or not open yet).
  List<int>? usedKey;
  HostAccepted? _accepted;

  FakeHostSide(this.controller, this.uri, this.mode, {this.deviceKeys = const []}) {
    controller.local.stream.listen(_onFrame, onDone: () => closedByClient = true);
    if (mode == FakeMode.refuse) {
      controller.local.sink.addError(Exception('connection refused'));
      controller.local.sink.close();
    }
  }

  static String _machineIdOf(Uint8List hello) {
    final len = hello[2 + handshakeNonceLength];
    final start = 3 + handshakeNonceLength;
    return utf8.decode(hello.sublist(start, start + len));
  }

  void _onFrame(dynamic f) {
    raw.add(f as Object);
    if (mode == FakeMode.silent || mode == FakeMode.refuse) return;
    if (f is String) return;
    final bytes = Uint8List.fromList((f as List).cast<int>());
    final s = session;
    if (s == null) {
      final secret = mode == FakeMode.wrongSecret ? List.filled(32, 0xEE) : testSecret;
      final acc = HostHandshake.accept(secret: secret, machineId: _machineIdOf(bytes), frame: bytes);
      session = acc.session;
      _accepted = acc;
      deviceId = acc.deviceId;
      controller.local.sink.add(acc.reply);
      for (final p in _pending) {
        _seal(p);
      }
      _pending.clear();
      return;
    }
    final acc = _accepted;
    if (acc != null && frames.isEmpty && deviceKeys.isNotEmpty) {
      // The first data frame: a device key, else the pairing secret.
      _accepted = null;
      for (final k in deviceKeys) {
        final candidate = acc.sessionFor(k);
        try {
          final text = candidate.open(bytes);
          session = candidate;
          usedKey = k;
          if (text != null) frames.add(text);
          return;
        } on ChannelError {
          continue;
        }
      }
    }
    _accepted = null;
    try {
      final text = s.open(bytes);
      if (text != null) frames.add(text);
    } on ChannelError {
      controller.local.sink.add(errorFrame(ChannelErrors.badKey));
      controller.local.sink.close();
    }
  }

  void _seal(String text) {
    for (final f in session!.seal(text)) {
      controller.local.sink.add(f);
    }
  }

  List<ClientMessage> get messages => frames.map(decodeClient).whereType<ClientMessage>().toList();

  /// Encrypts and sends (queued until the handshake is done).
  void send(HostMessage m) => sendText(encodeHost(m));

  void sendText(String text) {
    if (session == null) {
      _pending.add(text);
    } else {
      _seal(text);
    }
  }

  /// Sends a frame as is (plaintext from an old host, or relay control text).
  void sendRaw(Object frame) => controller.local.sink.add(frame);

  Future<void> close() => controller.local.sink.close();
}

/// A ChannelFactory that records every channel it hands out.
class FakeChannels {
  final List<FakeHostSide> hosts = [];

  /// How the endpoint at a URI behaves (default: a working host).
  FakeMode Function(Uri uri) modeFor;

  /// Device keys every fake host knows.
  List<List<int>> deviceKeys = [];
  FakeChannels({FakeMode Function(Uri uri)? modeFor}) : modeFor = modeFor ?? ((_) => FakeMode.host);

  ChannelFactory get factory => (Uri uri) {
        final c = StreamChannelController<dynamic>(allowForeignErrors: false);
        hosts.add(FakeHostSide(c, uri, modeFor(uri), deviceKeys: List.of(deviceKeys)));
        return FakeWebSocket(c.foreign);
      };
  FakeHostSide get last => hosts.last;

  /// The last channel opened to a URI starting with [prefix].
  FakeHostSide lastTo(String prefix) => hosts.lastWhere((h) => h.uri.toString().startsWith(prefix));
}

Future<void> pump([int ms = 10]) => Future<void>.delayed(Duration(milliseconds: ms));

Future<void> eventually(bool Function() cond, {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await pump(10);
  }
}

const welcome = Welcome(machineName: 'devbox', os: 'windows', hostVersion: '0.1.0', claudeVersion: '2.1.322');

SessionSummary summary(String id,
        {SessionState state = SessionState.idle,
        SessionOrigin origin = SessionOrigin.perch,
        String name = 'Session',
        String cwd = r'D:\projects\perch',
        int openPrompts = 0,
        int startedAtMs = 1,
        bool live = true,
        String? reason,
        int? lastPromptAtMs}) =>
    SessionSummary(
        id: id,
        name: name,
        cwd: cwd,
        origin: origin,
        state: state,
        startedAtMs: startedAtMs,
        openPrompts: openPrompts,
        live: live,
        reason: reason,
        lastPromptAtMs: lastPromptAtMs);

/// A machine's board on top of a [FakeHostSide]: answers the app's summary (its key first,
/// then the records the app lacks), keeps the records and the newest key the app sends, and
/// can change records itself. Call [serve] (or run [start]) to handle what arrived.
class FakeBoardHost {
  final FakeHostSide side;
  final Board board = Board();
  final HlcClock clock;
  ({String boardId, String key, String keyVersion})? key;
  int _seen = 0;
  Timer? _timer;
  FakeBoardHost(this.side, {String writer = 'host'}) : clock = HlcClock(writer);

  void start() => _timer = Timer.periodic(const Duration(milliseconds: 5), (_) => serve());
  void stop() => _timer?.cancel();

  void serve() {
    final ms = side.messages;
    for (; _seen < ms.length; _seen++) {
      switch (ms[_seen]) {
        case BoardSummaryFromApp(:final summary):
          final k = key;
          if (k != null) side.send(BoardKeyFromHost(boardId: k.boardId, key: k.key, keyVersion: k.keyVersion));
          side.send(BoardRecordsFromHost(records: board.newerThan(summary)));
        case BoardRecordsFromApp(:final records):
          for (final r in records) {
            board.merge(r, clock: clock);
          }
        case BoardKeyFromApp(:final boardId, key: final k, :final keyVersion):
          final mine = key;
          if (mine == null || Hlc.parse(keyVersion)! > Hlc.parse(mine.keyVersion)!) {
            key = (boardId: boardId, key: k, keyVersion: keyVersion);
          }
        default:
          break;
      }
    }
  }

  /// A change made on the machine, sent to the app.
  void edit(String kind, String id, Map<String, Map<String, dynamic>> groups) {
    final r = board.put(kind, id, groups, clock);
    side.send(BoardRecordsFromHost(records: [r]));
  }
}

const boardWelcome =
    Welcome(machineName: 'devbox', os: 'windows', hostVersion: '0.4.0', claudeVersion: '2.1.328', boardSync: true);
