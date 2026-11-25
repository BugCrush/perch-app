// The host's sync with the board's encrypted copy in the relay
// (docs/superpowers/specs/2026-11-24-projects-first-board-design.md, section 5): at start,
// a few seconds after a change, and every few minutes. The relay sees only sealed records
// (board_relay.dart). Over the relay's daily limit for the board the host keeps its own copy
// and tries again the next UTC day. After the board key was rotated (a device removed),
// the records go to the new board id, the old board is read one last time and deleted.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

import 'host_board.dart';
import 'host_state.dart';

/// HTTP through dart:io.
Future<({int status, String body})> ioRelayHttp(String method, Uri uri, Map<String, String> headers, String? body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.openUrl(method, uri);
    headers.forEach(req.headers.set);
    if (body != null) req.add(utf8.encode(body));
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
    return (status: res.statusCode, body: text);
  } finally {
    client.close(force: true);
  }
}

/// The next 00:00 UTC after [t] (05:30 IST), when the relay's daily counts start again.
DateTime nextUtcDay(DateTime t) {
  final u = t.toUtc();
  return DateTime.utc(u.year, u.month, u.day + 1);
}

const relayLimitLine =
    'The relay\'s daily limit for this board is reached; the board keeps working here and syncs again after 05:30 IST.';

class HostBoardRelay {
  /// [BoardChange.from] of records that came from the relay.
  static const from = 'relay';

  final HostBoard board;
  final HostState state;
  final RelayHttp http;
  final Duration every;
  final Duration afterChange;
  final DateTime Function() _now;
  final void Function(String line)? log;

  HostBoardRelay({
    required this.board,
    required this.state,
    RelayHttp? http,
    this.every = const Duration(minutes: 3),
    this.afterChange = const Duration(seconds: 5),
    DateTime Function()? now,
    this.log,
  })  : http = http ?? ioRelayHttp,
        _now = now ?? DateTime.now;

  BoardRelaySync? _sync;
  StreamSubscription<BoardChange>? _sub;
  Timer? _timer;
  Timer? _soon;
  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;
  DateTime? _limitedUntil;
  final Map<String, String> _logged = {}; // what -> UTC day it was logged

  void start() {
    _sub = board.changes.listen((c) {
      if (c.from != from) _schedule();
    });
    _timer = Timer.periodic(every, (_) => unawaited(syncNow()));
    unawaited(syncNow());
  }

  /// The board key changed: move the copy soon.
  void keyChanged() => _schedule();

  void _schedule() {
    if (_disposed) return;
    _soon ??= Timer(afterChange, () {
      _soon = null;
      unawaited(syncNow());
    });
  }

  void _logOnce(String what, String line) {
    final day = _now().toUtc().toIso8601String().substring(0, 10);
    if (_logged[what] == day) return;
    _logged[what] = day;
    log?.call(line);
  }

  BoardRelaySync _for(String url, String id, List<int> key) {
    final s = _sync;
    if (s != null && s.relayUrl == url && s.boardId == id) return s;
    return _sync = BoardRelaySync(relayUrl: url, boardId: id, boardKey: key, http: http);
  }

  /// One sync now (after the one running, if any).
  Future<void> syncNow() {
    final r = _running;
    if (r != null) {
      _again = true;
      return r;
    }
    return _running = _syncLoop().whenComplete(() => _running = null);
  }

  Future<void> _syncLoop() async {
    do {
      _again = false;
      await _once();
    } while (_again && !_disposed);
  }

  Future<void> _once() async {
    final url = state.relayUrl, id = state.boardId, key = state.boardKeyBytes;
    if (_disposed || url == null || id == null || key == null) return;
    final until = _limitedUntil;
    if (until != null && _now().isBefore(until)) return;
    _limitedUntil = null;
    try {
      // Boards left behind by a rotation: their last records first (pull only).
      final old = [...state.oldBoards];
      for (final o in old) {
        final k = base64UrlDecodeNoPad(o.key);
        if (k == null) continue;
        try {
          final res = await BoardRelaySync(relayUrl: url, boardId: o.boardId, boardKey: k, http: http)
              .syncOnce(board.board, clock: board.clock, push: false);
          if (res.changed.isNotEmpty) board.announce(res.changed, from: from);
        } on BoardRelayError catch (e) {
          if (e.status != 410 && e.status != 401 && e.status != 404) rethrow;
        }
      }
      final res = await _for(url, id, key).syncOnce(board.board, clock: board.clock);
      if (res.changed.isNotEmpty) board.announce(res.changed, from: from);
      if (res.limited) {
        _limitedUntil = nextUtcDay(_now());
        _logOnce('limit', relayLimitLine);
        return;
      }
      for (final o in old) {
        final k = base64UrlDecodeNoPad(o.key);
        try {
          if (k != null) await BoardRelaySync(relayUrl: url, boardId: o.boardId, boardKey: k, http: http).deleteBoard();
        } on BoardRelayError catch (e) {
          if (e.status != 410 && e.status != 401) rethrow;
        }
        state.forgetOldBoard(o.boardId);
      }
    } on BoardRelayError catch (e) {
      _logOnce('status ${e.status}', switch (e.status) {
        401 => 'The relay does not accept this board\'s key (another board has its id?); the board keeps working here.',
        410 => 'The relay copy of this board was deleted (the board key was replaced); waiting for the new key.',
        _ => 'The relay answered ${e.status} for the board; the board keeps working here and tries again later.',
      });
    } catch (_) {
      // Unreachable relay: the board keeps working here; the next sync tries again.
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _soon?.cancel();
    await _sub?.cancel();
    try {
      await _running;
    } catch (_) {}
  }
}

String _thousands(num n) {
  final s = n.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String _mb(num bytes) => (bytes / (1024 * 1024)).toStringAsFixed(bytes < 1024 * 1024 ? 2 : 1);

/// Watches the relay's shared pool for its owner: a machine the relay counts as the owner's
/// (`exempt`) is told once a UTC day when the pool passes [warnAt] percent.
class RelayPoolWatch {
  final HostState state;
  final void Function(int percent) warn;
  final RelayHttp http;
  final Duration every;
  final int warnAt;
  Timer? _timer;
  String? _warnedDay;

  RelayPoolWatch({
    required this.state,
    required this.warn,
    RelayHttp? http,
    this.every = const Duration(minutes: 30),
    this.warnAt = 80,
  }) : http = http ?? ioRelayHttp;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => unawaited(check()));
    unawaited(check());
  }

  void stop() => _timer?.cancel();

  /// Asks the relay once; warns when due. Returns the percentage used (null: unknown).
  Future<int?> check() async {
    final url = state.relayUrl;
    if (url == null) return null;
    try {
      final r = await http('GET', relayHttpUri(url, state.machineId, 'usage'), {'Authorization': 'Bearer ${state.hostToken}'}, null);
      if (r.status != 200) return null;
      final j = jsonDecode(r.body);
      final pool = j is Map ? j['pool'] : null;
      if (j is! Map || j['exempt'] != true || pool is! Map || pool['used'] is! num || pool['limit'] is! num) return null;
      final limit = pool['limit'] as num;
      if (limit <= 0) return null;
      final pct = ((pool['used'] as num) / limit * 100).floor();
      final day = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      if (pct >= warnAt && _warnedDay != day) {
        _warnedDay = day;
        warn(pct);
      }
      return pct;
    } catch (_) {
      return null;
    }
  }
}

/// `perch_host relay usage`: today's use of the relay by this machine (messages) and by the
/// board (writes, size) against the caps.
Future<List<String>> relayUsageLines(HostState state, {RelayHttp? http}) async {
  final call = http ?? ioRelayHttp;
  final url = state.relayUrl;
  if (url == null) return ['No relay is set (perch_host relay set <url>).'];
  final out = <String>[];
  try {
    final r = await call('GET', relayHttpUri(url, state.machineId, 'usage'), {'Authorization': 'Bearer ${state.hostToken}'}, null);
    final j = r.status == 200 ? jsonDecode(r.body) : null;
    if (j is Map && j['messagesToday'] is num) {
      out.add('This machine today: ${_thousands(j['messagesToday'] as num)} of '
          '${_thousands((j['messageLimit'] as num?) ?? 50000)} relay messages.');
      final pool = j['pool'];
      if (pool is Map && pool['used'] is num && pool['limit'] is num && (pool['limit'] as num) > 0) {
        final pct = ((pool['used'] as num) / (pool['limit'] as num) * 100).round();
        out.add('Shared pool today: $pct% used${pool['shut'] == true ? ' (used up: friends\' machines wait until 00:00 UTC)' : ''}'
            '${j['exempt'] == true ? '; this machine is the relay owner\'s and keeps working' : ''}.');
      }
    } else {
      out.add('This machine: the relay answered ${r.status} (an older relay has no usage count).');
    }
  } catch (e) {
    out.add('This machine: could not reach the relay ($e).');
  }
  final id = state.boardId, key = state.boardKeyBytes;
  if (id == null || key == null) {
    out.add('The board: no board key yet (the app makes one when it first meets this host).');
  } else {
    try {
      final j = await BoardRelaySync(relayUrl: url, boardId: id, boardKey: key, http: call).usage();
      out.add('The board today: ${_thousands((j['writesToday'] as num?) ?? 0)} of ${_thousands((j['writeLimit'] as num?) ?? 5000)} '
          'writes; ${_mb((j['bytes'] as num?) ?? 0)} MB of ${_mb((j['byteLimit'] as num?) ?? 20971520)} MB stored.');
    } on BoardRelayError catch (e) {
      out.add('The board: the relay answered ${e.status}.');
    } catch (e) {
      out.add('The board: could not reach the relay ($e).');
    }
  }
  out.add('The counts start again at 00:00 UTC (05:30 IST); the account\'s total is in the Cloudflare dashboard.');
  return out;
}
