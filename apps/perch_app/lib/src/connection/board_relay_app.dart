// The app's sync with the board's encrypted copy in the relay
// (docs/superpowers/specs/2026-11-24-projects-first-board-design.md, section 5): so an idea
// written while every machine is off still reaches them, and any of the owner's devices can
// reach the board. At start, when the app comes to the foreground, 5 s after an edit made
// here and every 3 minutes while in the foreground. Quiet on failure (the board keeps
// working on the phone, and the "Saved on this phone" note covers it); over the board's
// daily limit (429) it waits for the next UTC day. Not used on the board page (web).
import 'dart:async';

import 'package:http/http.dart' as http_pkg;
import 'package:perch_protocol/perch_protocol.dart';

import 'board_file.dart';

/// HTTP through package:http.
Future<({int status, String body})> packageRelayHttp(String method, Uri uri, Map<String, String> headers, String? body) async {
  final req = http_pkg.Request(method, uri)..headers.addAll(headers);
  if (body != null) req.body = body;
  final res = await http_pkg.Response.fromStream(await req.send().timeout(const Duration(seconds: 20)))
      .timeout(const Duration(seconds: 30));
  return (status: res.statusCode, body: res.body);
}

class AppBoardRelay {
  final BoardFile file;

  /// The relay of any paired machine (null: none).
  final String? Function() relayUrl;
  final RelayHttp http;
  final Duration every;
  final Duration afterChange;

  AppBoardRelay({
    required this.file,
    required this.relayUrl,
    RelayHttp? http,
    this.every = const Duration(minutes: 3),
    this.afterChange = const Duration(seconds: 5),
  }) : http = http ?? packageRelayHttp;

  BoardRelaySync? _sync;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _timer;
  Timer? _soon;
  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;
  bool _foreground = true;
  DateTime? _limitedUntil;

  void start() {
    _subs
      ..add(file.changes.listen((c) {
        if (c.origin == null) _schedule();
      }))
      ..add(file.keyChanges.listen((_) => _schedule()));
    _restartTimer();
    unawaited(syncNow());
  }

  /// The app came to the foreground (sync now, then every few minutes) or left it.
  set foreground(bool value) {
    if (value == _foreground) return;
    _foreground = value;
    _restartTimer();
    if (value) unawaited(syncNow());
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = _foreground && !_disposed ? Timer.periodic(every, (_) => unawaited(syncNow())) : null;
  }

  void _schedule() {
    if (_disposed) return;
    _soon ??= Timer(afterChange, () {
      _soon = null;
      unawaited(syncNow());
    });
  }

  /// One sync now (after the one running, if any).
  Future<void> syncNow() {
    final r = _running;
    if (r != null) {
      _again = true;
      return r;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _once();
    } while (_again && !_disposed);
  }

  Future<void> _once() async {
    final url = relayUrl(), k = file.boardKey;
    if (_disposed || url == null || k == null) return;
    final until = _limitedUntil;
    if (until != null && DateTime.now().isBefore(until)) return;
    _limitedUntil = null;
    var s = _sync;
    if (s == null || s.boardId != k.boardId || s.relayUrl != url) {
      s = _sync = BoardRelaySync(relayUrl: url, boardId: k.boardId, boardKey: k.key, http: http);
    }
    try {
      final res = await s.syncOnce(file.board, clock: file.clock);
      if (res.changed.isNotEmpty) file.announce(res.changed, origin: this);
      if (res.limited) {
        final now = DateTime.now().toUtc();
        _limitedUntil = DateTime.utc(now.year, now.month, now.day + 1);
        return;
      }
      file.markSynced();
    } catch (_) {
      // The relay is not reachable (or refused): the board keeps working here.
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _soon?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
  }
}
