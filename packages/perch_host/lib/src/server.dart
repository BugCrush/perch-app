// The server the app talks to. Every app connection (a LAN WebSocket on /ws, or a device
// behind the relay) runs the encrypted channel from perch_protocol; the JSON wire
// messages travel inside it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'approval_dialog.dart';
import 'board_page.dart';
import 'claude_session.dart';
import 'dir_browser.dart';
import 'frame_link.dart';
import 'host_accounts.dart';
import 'host_board.dart';
import 'host_state.dart';
import 'relay_client.dart' show RelayClient;
import 'local_board.dart';
import 'push_notifier.dart';
import 'qr_render.dart';
import 'self_test.dart';
import 'session_manager.dart';
import 'setup_token.dart';
import 'file_index.dart';
import 'slash_commands.dart';
import 'task_board.dart';
import 'terminal_prompts.dart';

const hostVersion = '1.0.0';

/// Told to a phase 1 app (plaintext pairing code) before closing.
const pairAgainMessage = 'This Perch host was updated. Remove this machine and pair again by scanning its QR code.';

class _Client {
  final FrameLink link;
  SecureSession? session;
  bool authenticated = false;
  bool closed = false;
  String deviceName = '';
  String deviceId = '';

  /// The session this device shows in the foreground (no notifications for it).
  String? focus;
  Timer? helloTimer;
  StreamSubscription<Object>? sub;

  /// Until the app's first data frame: the sessions that hello could be keyed with (its
  /// own device key, the pairing secret); the one that opens the frame is kept.
  List<({SecureSession session, bool deviceKey})>? candidates;

  /// The channel was opened with the device's own key.
  bool usedDeviceKey = false;

  /// What this device may do ([DevicePermissions]).
  String permission = DevicePermissions.watch;

  /// The board page in a browser on this machine (not a stored device).
  bool boardPage = false;

  /// The app keeps the whole board (it sent a summary or records): board changes go to it.
  bool boardSync = false;

  /// This connection, for not echoing a device's own board records back to it.
  final int conn = _nextConn++;
  static var _nextConn = 1;
  _Client(this.link);

  bool get full => permission == DevicePermissions.full;

  void send(HostMessage m) => sendText(encodeHost(m));

  void sendText(String text) {
    final s = session;
    if (s == null || closed) return;
    try {
      for (final f in s.seal(text)) {
        link.send(f);
      }
    } catch (_) {}
  }
}

/// Something besides the LAN listener that brings app connections (the relay client).
abstract class RemoteTransport {
  /// Starts (or restarts) bringing connections to [PerchServer.attach].
  void start();

  /// Stops and drops its connections.
  Future<void> stop();

  /// Why the relay refuses this machine (`inviteRequired`, `poolUsedUp`, …); null: it does
  /// not.
  String? get refusal;
}

/// A device waiting for its request to pair to be decided.
class _Waiting {
  final PendingDevice request;

  /// The app's connection while it waits (null: it went away; it gets its key when it
  /// comes back allowed).
  _Client? client;
  Timer? expiry;
  ApprovalPrompt? prompt;
  _Waiting(this.request, {this.client});
}

class PerchServer {
  final SessionManager manager;
  final HostState state;

  /// The name devices show; changes on reload after `perch_host name set` unless
  /// [nameFixed].
  String machineName;

  /// The name came from `serve --name`: it stays for this run.
  final bool nameFixed;
  final String bindAddress;
  final int port;

  /// LAN addresses (`host:port`) sent in `welcome`.
  List<String> lanAddresses;

  /// Claude Code version reported in `welcome` until a session reports its own.
  String? claudeVersion;

  /// How often the session list is refreshed for connected devices (the safety net under
  /// the hooks).
  final Duration pollInterval;

  /// Whether Perch's Claude Code hooks are installed (sent in `welcome`).
  bool hooksInstalled;

  /// Checks again whether the hooks are installed; called on every reload (`hooks install`
  /// and `hooks uninstall` reload a running host). Null: [hooksInstalled] never changes.
  final bool Function()? checkHooks;

  /// The relay client, when a relay URL is set.
  RemoteTransport? relay;

  PerchServer({
    required this.manager,
    required this.state,
    required this.machineName,
    this.nameFixed = false,
    this.onRenamed,
    this.bindAddress = '0.0.0.0',
    this.port = 8787,
    this.lanAddresses = const [],
    this.claudeVersion,
    this.pollInterval = const Duration(seconds: 5),
    this.hooksInstalled = true,
    this.checkHooks,
    this.onHook,
    this.onReload,
    this.notifier,
    this.selfTester,
    this.onSelfTestHook,
    this.signIns,
    this.board,
    this.boardDir,
    this.approvals,
    PushPoster? relayPoster,
    this.pairingWait = const Duration(minutes: 5),
    SlashCommandCatalog? commands,
    FileIndex? files,
    this.accessibility,
    this.onSwitch,
    this.switchCheck = const Duration(seconds: 10),
  })  : commands = commands ?? SlashCommandCatalog(),
        files = files ?? FileIndex(),
        relayPoster = relayPoster ?? defaultPushPoster {
    manager.machineName = machineName;
  }

  /// This machine's task board (null: none on this host).
  final TaskBoard? board;

  /// macOS: whether the host may press keys in other apps (the Accessibility permission);
  /// null elsewhere.
  final Future<bool?> Function()? accessibility;

  /// Restarts the host into the build `perch_host setup` installed (closes the server,
  /// starts autostart's new build, exits). Null: this host cannot switch by itself.
  final Future<void> Function()? onSwitch;

  /// How often a pending switch checks whether the host is idle.
  final Duration switchCheck;
  Timer? _switchTimer;
  bool _switching = false;

  /// After `switch-when-idle`: restart into the new build once nothing is in flight (no
  /// card open, nothing being typed, no hook held for the phone).
  void switchWhenIdle() {
    final go = onSwitch;
    if (go == null || _switchTimer != null) return;
    _switchTimer = Timer.periodic(switchCheck, (_) async {
      if (_switching || !manager.quiet) return;
      _switching = true;
      _switchTimer?.cancel();
      await go();
    });
  }

  /// What `/perch` shows when the machine has no phone yet, and the Mac's permission.
  Future<Map<String, Object?>> menuStatus() async {
    final trusted = await accessibility?.call();
    return {
      'machine': machineName,
      'version': hostVersion,
      'paired': state.everPaired,
      'accessibility': ?trusted,
      if (relay?.refusal case final why?) ...{
        'relayRefusal': why,
        'relayRefusalText': RelayClient.refusalText(why),
      },
      if (trusted == false)
        'accessibilityHelp': 'Perch cannot press keys in terminals on this Mac yet: System Settings > '
            'Privacy & Security > Accessibility, turn on Terminal (the app the Perch host runs in) and Warp if you use it.',
    };
  }

  /// Shows the Allow / Watch only / Deny dialog for a new device (null: none).
  final ApprovalPrompter? approvals;

  /// Posts to the relay (dropping a removed device's push token).
  final PushPoster relayPoster;

  /// How long a new app waits, connected, for its request to be decided.
  final Duration pairingWait;

  /// What `/perch` in a terminal session asks (`/local/perch/<action>`).
  late final LocalBoard? localBoard = board == null
      ? null
      : LocalBoard(
          board: board!,
          sessionFor: manager.sessionForClaudeId,
          machineId: () => state.machineId,
          machineName: () => machineName,
          modelTable: () => modelTableOf(board!.board.board) ?? state.models);

  /// The header every `/perch` request carries. A page in a browser cannot send it to
  /// another site without asking first (CORS), and the host never says yes.
  static const menuHeader = 'x-perch-menu';

  /// `/local/perch/…` is for the Perch menu inside a Claude Code session on this machine:
  /// loopback, a loopback host name, no other site's page, and the menu's own header.
  static bool menuAllowed(InternetAddress? remote, Uri requested, Map<String, String> headers) =>
      localPageAllowed(remote, requested, headers['origin']) && headers[menuHeader] == '1';

  /// The header `perch_host` sends to `/control`. A page in a browser cannot send it to
  /// another site without asking first (CORS), and the host never says yes.
  static const controlHeader = 'x-perch-control';

  /// `/control` is for `perch_host` commands on this machine: loopback, a loopback host
  /// name, no other site's page, and the control header.
  static bool controlAllowed(InternetAddress? remote, Uri requested, Map<String, String> headers) =>
      localPageAllowed(remote, requested, headers['origin']) && headers[controlHeader] == '1';

  /// The slash commands a session can run (the phone's composer list).
  final SlashCommandCatalog commands;

  /// The files of a session's folder (the phone's `@` list).
  final FileIndex files;

  /// Where the board's web page is built (null: not known; `/` says how to build it).
  final String? boardDir;

  /// The board's web page and its pairing are for a browser on this machine only: the
  /// request comes from loopback, names this machine by a loopback name (a DNS name another
  /// site points at 127.0.0.1 does not), and comes from no other site's page.
  static bool localPageAllowed(InternetAddress? remote, Uri requested, String? origin) {
    if (remote == null || !remote.isLoopback) return false;
    bool local(String host) {
      final h = host.toLowerCase();
      return h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]';
    }

    if (!local(requested.host)) return false;
    if (origin != null && origin.isNotEmpty) {
      final o = Uri.tryParse(origin);
      if (o == null || !local(o.host)) return false;
    }
    return true;
  }

  /// Adding accounts with `claude setup-token` (null: not on this host).
  final AccountSignIns? signIns;

  /// Which device asked for each account sign-in (its updates, with the token at the end,
  /// go to that device only while it is connected).
  final Map<String, _Client> _signInClients = {};

  /// Runs the self-test of a new Claude Code version (null: not available).
  final SelfTester? selfTester;

  /// Called once per self-test session whose hooks are ignored (the console says so).
  final void Function(String claudeSessionId)? onSelfTestHook;
  final Set<String> _ignoredSelfTests = {};

  /// Sends push notifications through the relay (null: none).
  final PushNotifier? notifier;

  /// Devices that show [sessionId] in the foreground now.
  Iterable<String> focusedDevices(String sessionId) => {
        for (final c in _clients)
          if (c.authenticated && !c.closed && c.focus == sessionId) c.deviceId
      };

  /// Called with each hook's input as it arrives (the console's `--log-hooks`).
  final void Function(Map<String, dynamic> input)? onHook;

  /// Called after `/control?action=reload` re-read the host state (a new secret or relay).
  final FutureOr<void> Function()? onReload;

  /// Called with the new name when a reload renamed the machine.
  final void Function(String name)? onRenamed;

  /// Hooks come from Claude Code on this machine only.
  static bool acceptsHookFrom(InternetAddress? remote) => remote != null && remote.isLoopback;

  /// Answers at once with an empty 200 (the hook must never wait), then hands the hook's
  /// input to the session manager. The waiting `PermissionRequest` hook (`?wait=1`) gets
  /// the phone's answer for a terminal Perch cannot type into, as hook output (see
  /// SessionManager.holdPermissionHook); for every other session an empty 200 at once.
  Future<Response> _hook(Request request) async {
    final String body;
    try {
      body = await request.readAsString();
    } catch (_) {
      return Response.ok('');
    }
    Map<String, dynamic>? j;
    try {
      final v = jsonDecode(body);
      if (v is Map) j = v.cast<String, dynamic>();
    } catch (_) {}
    if (j != null && isSelfTestHook(j)) {
      // The self-test session is not the owner's: no card, no state, no notification.
      final sid = j['session_id'] is String ? j['session_id'] as String : '';
      if (_ignoredSelfTests.add(sid)) onSelfTestHook?.call(sid);
      return Response.ok('');
    }
    if (j != null) {
      final input = j;
      onHook?.call(input);
      notifier?.onHook(input);
      if (request.url.queryParameters['wait'] == '1' && input['hook_event_name'] == 'PermissionRequest') {
        Map<String, dynamic>? out;
        try {
          out = await manager.holdPermissionHook(input);
        } catch (_) {
          out = null;
        }
        return out == null
            ? Response.ok('')
            : Response.ok(jsonEncode(out), headers: {'content-type': 'application/json'});
      }
      // A stop check (before or after a tool) is answered at once.
      final stop = request.url.queryParameters['check'] == '1' ? manager.stopCheck(input) : null;
      Timer.run(() => manager.handleHook(input).catchError((Object _) {}));
      if (stop != null) return Response.ok(jsonEncode(stop), headers: {'content-type': 'application/json'});
    }
    return Response.ok('');
  }

  HttpServer? _http;
  final Set<_Client> _clients = {};
  bool _live = true;
  Timer? _refresh;
  final List<StreamSubscription<dynamic>> _subs = [];
  final _deviceConnected = StreamController<String>.broadcast();

  bool get remoteAccessLive => _live;
  int get connectedDevices => _clients.where((c) => c.authenticated).length;

  /// Device names, as they pair.
  Stream<String> get deviceConnected => _deviceConnected.stream;

  /// Returns the bound port (pass 0 to pick a free one).
  Future<int> start() async {
    Future<Response> handler(Request request) async {
      final info = request.context['shelf.io.connection_info'];
      final remote = info is HttpConnectionInfo ? info.remoteAddress : null;
      final address = remote?.address ?? 'unknown';
      final path = request.url.path;
      if (path == 'local/pairing') {
        if (!localPageAllowed(remote, request.requestedUri, request.headers['origin'])) {
          return Response.forbidden('Loopback only.');
        }
        return Response.ok(
            jsonEncode({
              'machineId': state.machineId,
              'name': machineName,
              'secret': base64UrlNoPad(state.secret),
              'port': _http?.port ?? port,
            }),
            headers: {'content-type': 'application/json', 'cache-control': 'no-store'});
      }
      if (path.startsWith('local/perch/')) {
        if (!menuAllowed(remote, request.requestedUri, request.headers)) return Response.forbidden('Loopback only.');
        const json = {'content-type': 'application/json', 'cache-control': 'no-store'};
        if (path == 'local/perch/status') return Response.ok(jsonEncode(await menuStatus()), headers: json);
        if (path == 'local/perch/invite' && request.method == 'POST') {
          // The relay's invite code, typed in /perch; never sent back.
          Object? body;
          try {
            body = jsonDecode(await request.readAsString());
          } catch (_) {}
          final code = body is Map && body['code'] is String ? (body['code'] as String).trim() : '';
          if (code.isEmpty) return Response(400, body: jsonEncode({'error': 'Type the code you were sent.'}), headers: json);
          state.setRelayInvite(code);
          final r = relay;
          await r?.stop();
          if (_live) r?.start();
          // The relay's answer, if it comes within a few seconds.
          bool? accepted;
          if (r is RelayClient) {
            for (var i = 0; i < 30 && accepted == null; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 200));
              if (r.connected) accepted = true;
              if (r.refusal != null) accepted = false;
            }
          }
          return Response.ok(
              jsonEncode({
                'saved': true,
                'accepted': ?accepted,
                if (r?.refusal case final why?) 'refusal': RelayClient.refusalText(why),
              }),
              headers: json);
        }
        if (path == 'local/perch/pairing') {
          // The same QR code and link as the host's banner: shown in the owner's own terminal.
          final link = state.link(name: machineName, lan: lanAddresses).toString();
          return Response.ok(jsonEncode({'link': link, 'qr': qrText(link, border: 1), 'machine': machineName}),
              headers: json);
        }
        final api = localBoard;
        if (api == null) {
          return Response(503,
              body: jsonEncode({'error': 'This Perch host has no task board.'}),
              headers: {'content-type': 'application/json'});
        }
        final r = await api.handle(path.substring('local/perch/'.length), request.method,
            request.url.queryParameters, await request.readAsString());
        return Response(r.status,
            body: jsonEncode(r.body), headers: {'content-type': 'application/json', 'cache-control': 'no-store'});
      }
      switch (path) {
        case 'ws':
          if (!_live) return Response(503, body: 'Remote access is stopped on this host.');
          return webSocketHandler((WebSocketChannel channel, String? _) => attach(WebSocketFrameLink(channel, address)),
              pingInterval: const Duration(seconds: 20))(request);
        case 'hook':
          if (!acceptsHookFrom(remote)) return Response.forbidden('Loopback only.');
          if (request.method != 'POST') return Response(405);
          return _hook(request);
        case 'control':
          if (!controlAllowed(remote, request.requestedUri, request.headers)) {
            return Response.forbidden('Loopback only, from perch_host.');
          }
          final action = request.url.queryParameters['action'];
          final q = request.url.queryParameters;
          if (action != null && action.startsWith('device')) {
            try {
              switch (action) {
                case 'devices':
                  return Response.ok(jsonEncode(devicesJson()), headers: {'content-type': 'application/json'});
                case 'device-decide':
                  await decideDevice(q['id'] ?? '', q['decision'] ?? '');
                case 'device-permission':
                  setDevicePermission(q['id'] ?? '', q['permission'] ?? '');
                case 'device-rename':
                  renameDevice(q['id'] ?? '', q['name'] ?? '');
                case 'device-remove':
                  removeDevice(q['id'] ?? '');
                default:
                  return Response.badRequest(body: 'Unknown action.');
              }
              return Response.ok('OK\n');
            } on ArgumentError catch (e) {
              return Response.badRequest(body: '${e.message}\n');
            }
          }
          if (action == 'stop-remote') {
            await stopRemoteAccess();
            return Response.ok('Remote access stopped\n');
          }
          if (action == 'resume-remote') {
            resumeRemoteAccess();
            return Response.ok('Remote access resumed\n');
          }
          if (action == 'switch-when-idle') {
            if (onSwitch == null) return Response(503, body: 'This host cannot switch by itself.\n');
            switchWhenIdle();
            return Response.ok('OK: switching to the new build when idle\n');
          }
          if (action == 'reload') {
            await reloadState();
            return Response.ok('Host state reloaded\nMachine name: $machineName\n');
          }
          if (action == 'selftest-on' || action == 'selftest-off') {
            setSelfTest(action == 'selftest-on');
            return Response.ok('${selfTestLine(manager.compatibility.current)}\n');
          }
          if (action == 'selftest-status') return Response.ok('${selfTestLine(manager.compatibility.current)}\n');
          if (action == 'selftest-run') {
            final t = selfTester;
            if (t == null) return Response(503, body: 'The self-test is not available on this host.\n');
            return Response.ok('${selfTestResultText(await t.run())}\n');
          }
          return Response.badRequest(body: 'Unknown action.');
      }
      if (request.method != 'GET' && request.method != 'HEAD') return Response.notFound('Not found.');
      if (!localPageAllowed(remote, request.requestedUri, request.headers['origin'])) {
        return Response.forbidden('The Perch board opens on this machine only: http://localhost:$port/');
      }
      return serveBoardFile(boardDir, path);
    }

    _http = await shelf_io.serve(handler, bindAddress, port);
    _subs
      ..add(manager.sessionUpdates.listen((s) => _broadcast(SessionUpdated(session: s))))
      ..add(manager.events.listen((e) => _broadcast(EventMessage(sessionId: e.sessionId, event: e.event))))
      ..add(manager.promptsOpened.listen((p) => _broadcast(PromptOpened(sessionId: p.sessionId, prompt: p.prompt))))
      ..add(manager.promptsClosed.listen((p) => _broadcast(PromptClosed(sessionId: p.sessionId, promptId: p.promptId))))
      ..add(manager.usageUpdates.listen((u) => _broadcast(UsageMessage(usage: u))))
      ..add(manager.compatibility.changes.listen((c) => _broadcast(CompatibilityMessage(compatibility: c))))
      ..add(manager.limits.changes.listen((l) {
        _broadcast(UsageLimitMessage(limit: l));
        if (l == null) notifier?.usageCleared();
      }))
      ..add(manager.limits.usageBack.listen((ids) => notifier?.usageBack(ids)))
      ..add(manager.limits.reports.listen((r) {
        _broadcast(r);
        if (r.changed) notifier?.resumedChanged(r.sessionId, r.text);
      }));
    final b = board;
    if (b != null) {
      _subs
        ..add(b.changes.listen((tasks) => _broadcast(TasksMessage(tasks: tasks))))
        ..add(b.board.changes.listen(_boardChanged));
    }
    final accounts = manager.accounts;
    if (accounts != null) {
      _subs.add(accounts.changes.listen((_) => _broadcast(accounts.message)));
      unawaited(accounts.refreshMachineLogin());
    }
    final flows = signIns;
    if (flows != null) {
      _subs.add(flows.updates.listen((u) {
        final c = _signInClients[u.flowId];
        if (c != null && !c.closed && c.authenticated) {
          c.send(u);
        } else {
          _broadcast(u); // the device that asked went away: any of the owner's devices
        }
        if (u.state == AccountSignInStates.done ||
            u.state == AccountSignInStates.failed ||
            u.state == AccountSignInStates.cancelled) {
          _signInClients.remove(u.flowId);
        }
      }));
    }
    manager.limits.perchTyping ??= (text) => notifier?.perchTyping(text);
    _refresh = Timer.periodic(pollInterval, (_) async {
      if (connectedDevices == 0) return;
      try {
        _broadcast(Sessions(sessions: await manager.list(), usage: manager.usage));
      } catch (_) {}
    });
    final n = notifier;
    if (n != null) {
      n
        ..focusedDevices = focusedDevices
        ..enabled = _live
        ..start();
    }
    if (_live) relay?.start();
    return _http!.port;
  }

  /// Board records changed here or arrived from a device: to every other device that keeps
  /// the board.
  void _boardChanged(BoardChange change) {
    final frame = encodeHost(BoardRecordsFromHost(records: change.records));
    for (final c in _clients) {
      if (c.authenticated && c.boardSync && change.from != 'conn:${c.conn}') c.sendText(frame);
    }
  }

  void _broadcast(HostMessage m) {
    final frame = encodeHost(m);
    for (final c in _clients) {
      if (c.authenticated) c.sendText(frame);
    }
  }

  /// Runs one app connection: the encrypted handshake, then the wire protocol.
  void attach(FrameLink link) {
    final c = _Client(link);
    if (!_live) {
      link.close();
      return;
    }
    _clients.add(c);
    c.helloTimer = Timer(const Duration(seconds: 10), () {
      if (!c.authenticated) _close(c);
    });
    c.sub = link.frames.listen(
      (frame) => _onFrame(c, frame),
      onDone: () => _drop(c),
      onError: (_) => _drop(c),
      cancelOnError: true,
    );
  }

  void _drop(_Client c) {
    final was = c.closed;
    c.closed = true;
    c.helloTimer?.cancel();
    _clients.remove(c);
    for (final w in _waiting.values) {
      if (w.client == c) w.client = null;
    }
    if (!was && c.authenticated && !c.boardPage) {
      if (state.device(c.deviceId) != null) {
        try {
          state.deviceSeen(c.deviceId, DateTime.now().millisecondsSinceEpoch);
        } catch (_) {}
      }
      _devicesChanged();
    }
  }

  void _close(_Client c) {
    _drop(c);
    c.sub?.cancel();
    c.link.close();
  }

  /// Sends an error frame in the clear and closes (the channel is not usable).
  void _fail(_Client c, String reason) {
    if (!c.closed) c.link.send(errorFrame(reason));
    _close(c);
  }

  void _refuse(_Client c, String code, String message) {
    c.send(ErrorMessage(code: code, message: message));
    _close(c);
  }

  Future<void> _onFrame(_Client c, Object frame) async {
    if (c.closed) return;
    if (frame is String) {
      // A phase 1 app sending its pairing code in the clear.
      if (c.session == null) {
        c.link.sendText(encodeHost(const ErrorMessage(code: ErrorCodes.badCode, message: pairAgainMessage)));
      }
      _close(c);
      return;
    }
    final bytes = frame as Uint8List;
    var session = c.session;
    if (session == null && c.candidates == null) {
      try {
        final accepted = HostHandshake.accept(secret: state.secret, machineId: state.machineId, frame: bytes);
        c.deviceId = accepted.deviceId;
        final key = state.device(accepted.deviceId)?.keyBytes;
        c.candidates = [
          if (key != null) (session: accepted.sessionFor(key), deviceKey: true),
          (session: accepted.session, deviceKey: false),
        ];
        c.link.send(accepted.reply);
      } on ChannelError catch (e) {
        _fail(c, e.reason == ChannelErrors.badVersion ? ChannelErrors.badVersion : ChannelErrors.badKey);
      }
      return;
    }
    String? text;
    if (session == null) {
      // The first data frame: whichever candidate key opens it is this connection's.
      for (final cand in c.candidates!) {
        try {
          text = cand.session.open(bytes);
        } on ChannelError {
          continue;
        }
        session = c.session = cand.session;
        c.usedDeviceKey = cand.deviceKey;
        break;
      }
      c.candidates = null;
      if (session == null) {
        // It holds another secret (a rotated pairing, or a removed device's key).
        _fail(c, ChannelErrors.badKey);
        return;
      }
    } else {
      try {
        text = session.open(bytes);
      } on ChannelError {
        if (!c.authenticated) {
          _fail(c, ChannelErrors.badKey);
        } else {
          _close(c);
        }
        return;
      }
    }
    if (text == null) return; // more chunks to come
    final msg = decodeClient(text);
    if (!c.authenticated) {
      if (_waiting.values.any((p) => p.client == c)) return; // waiting for approval: nothing else counts
      if (msg is! Hello) {
        _refuse(c, ErrorCodes.badCode, 'Send hello first.');
        return;
      }
      await _hello(c, msg);
      return;
    }
    if (msg == null) {
      c.send(const ErrorMessage(code: ErrorCodes.badRequest, message: unknownMessageText));
      return;
    }
    if (!c.full && !_watchAllowed(msg)) {
      if (!_isSync(msg)) {
        c.send(ErrorMessage(
            code: ErrorCodes.watchOnly,
            message: 'This device can only watch. Change it at $machineName: perch_host devices full ${c.deviceId}.'));
      }
      return;
    }
    try {
      await _handle(c, msg);
    } catch (e) {
      c.send(_errorFor(e));
    }
  }

  // ------------------------------------------------------------ devices and approval

  /// Requests to pair that wait for a decision, oldest first, by device id.
  final Map<String, _Waiting> _waiting = {};

  final _deviceNotices = StreamController<String>.broadcast();

  /// One line per device event for the console (requests, decisions, removals).
  Stream<String> get deviceNotices => _deviceNotices.stream;

  void _notice(String line) {
    if (!_deviceNotices.isClosed) _deviceNotices.add(line);
  }

  /// Requests waiting for a decision, oldest first.
  List<PendingDevice> get pendingDevices => [for (final w in _waiting.values) w.request];

  bool _onLoopback(_Client c) =>
      c.link is WebSocketFrameLink && (InternetAddress.tryParse(c.link.address)?.isLoopback ?? false);

  Welcome _welcome(_Client c) => Welcome(
        machineName: machineName,
        os: Platform.operatingSystem,
        hostVersion: hostVersion,
        claudeVersion: manager.claudeVersion ?? claudeVersion,
        hooksInstalled: hooksInstalled,
        compatibility: manager.compatibility.current,
        relayUrl: state.relayUrl,
        lanAddresses: lanAddresses,
        permission: c.permission,
        boardSync: board != null,
      );

  /// The first message: lets the device in, makes it wait for approval, or refuses it.
  Future<void> _hello(_Client c, Hello msg) async {
    c.deviceName = msg.deviceName;
    final v2 = (msg.pairing ?? 0) >= 2;
    if (c.deviceId == boardPageDeviceId && _onLoopback(c) && !c.usedDeviceKey) {
      c
        ..boardPage = true
        ..permission = DevicePermissions.full;
      await _admit(c);
      return;
    }
    final rec = state.device(c.deviceId);
    if (c.usedDeviceKey) {
      if (rec == null) {
        _refuse(c, ErrorCodes.deviceRemoved, _removedText());
        return;
      }
      state.confirmKey(rec.id);
      c.permission = rec.permission;
      await _admit(c);
      return;
    }
    // Opened with the pairing secret: it only asks to pair. Apps too old to take their own
    // key are refused (keyless "legacy" access was removed on 2026-11-19).
    if (!v2) {
      _refuse(c, ErrorCodes.updateApp,
          'Update Perch on this device: $machineName only lets in apps that have their own key. Then pair again.');
      return;
    }
    if (rec != null && !rec.keyed && rec.key != null) {
      // Allowed, but it has not connected with its key yet (allowed while it was away, or
      // the connection that should have carried the key dropped): it gets its key now. This
      // connection stays on the pairing secret; once the device has used its key, only the
      // key opens a connection for this id.
      c.permission = rec.permission;
      c.send(DeviceKey(key: rec.key!, permission: rec.permission));
      _sendBoardKey(c);
      await _admit(c);
      return;
    }
    _request(c, msg);
  }

  String _removedText() => '$machineName removed this device. Ask to pair again from the machine menu.';

  /// Puts [c] on the waiting list (or refreshes its request).
  void _request(_Client c, Hello msg) {
    c.helloTimer?.cancel();
    final existing = _waiting[c.deviceId];
    if (existing != null) {
      // The same device again (a reconnect): keep its request, follow the new connection.
      final old = existing.client;
      existing.client = c;
      if (old != null && old != c && !old.closed) _close(old);
      c.send(PairingPending(machineName: machineName));
      return;
    }
    final w = _Waiting(
      PendingDevice(
        id: c.deviceId,
        name: msg.deviceName.trim().isEmpty ? 'Device' : msg.deviceName.trim(),
        route: c.link.address,
        requestedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
      client: c,
    );
    _waiting[c.deviceId] = w;
    w.expiry = Timer(pairingWait, () => _expire(w));
    c.send(PairingPending(machineName: machineName));
    final r = w.request;
    _notice('New device "${r.name}" (${shortDeviceId(r.id)}, ${routeText(r.route)}) wants to pair. '
        'A = allow full control, W = watch only, D = deny.');
    final prompt = approvals?.show(machineName: machineName, request: r);
    if (prompt != null) {
      w.prompt = prompt;
      unawaited(prompt.decision.then((d) async {
        if (d == null || _waiting[r.id] != w) return;
        try {
          await decideDevice(r.id, d);
        } catch (_) {}
      }));
    }
    _devicesChanged();
  }

  void _expire(_Waiting w) {
    if (_waiting[w.request.id] != w) return;
    _waiting.remove(w.request.id);
    w.prompt?.cancel();
    final c = w.client;
    if (c != null && !c.closed) {
      _refuse(c, ErrorCodes.pairingExpired, 'Nobody allowed this device on $machineName in time. Ask again.');
    }
    _notice('The request from "${w.request.name}" (${shortDeviceId(w.request.id)}) expired.');
    _devicesChanged();
  }

  /// Answers the request of the device whose id is (or starts with) [idOrPrefix].
  /// Throws [ArgumentError] when there is no such request.
  Future<void> decideDevice(String idOrPrefix, String decision) async {
    if (!DeviceDecisions.all.contains(decision)) throw ArgumentError('Unknown decision: $decision');
    final w = pickByPrefix(_waiting.values, idOrPrefix, (w) => w.request.id) ??
        (throw ArgumentError('No device is waiting with the id $idOrPrefix.'));
    final r = w.request;
    _waiting.remove(r.id);
    w.expiry?.cancel();
    w.prompt?.cancel();
    final c = w.client;
    if (decision == DeviceDecisions.deny) {
      if (c != null && !c.closed) _refuse(c, ErrorCodes.pairingDenied, 'This device was not allowed on $machineName.');
      _notice('Denied "${r.name}" (${shortDeviceId(r.id)}).');
      _devicesChanged();
      return;
    }
    final rec = state.approveDevice(r.id, name: r.name, permission: decision);
    try {
      state.markPaired();
    } catch (_) {}
    _notice('Allowed "${r.name}" (${shortDeviceId(r.id)}): '
        '${decision == DeviceDecisions.full ? 'full control' : 'watch only'}.');
    if (c != null && !c.closed) {
      c
        ..permission = rec.permission
        ..send(DeviceKey(key: rec.key!, permission: rec.permission));
      _sendBoardKey(c);
      await _admit(c);
    } else {
      _devicesChanged();
    }
  }

  /// Answers the oldest request (the console's A / W / D keys). False: none is waiting.
  Future<bool> decideOldest(String decision) async {
    if (_waiting.isEmpty) return false;
    await decideDevice(_waiting.keys.first, decision);
    return true;
  }

  DeviceRecord _record(String idOrPrefix) =>
      state.findDevice(idOrPrefix) ?? (throw ArgumentError('No device with the id $idOrPrefix.'));

  /// Changes a device's permission; its live connections follow at once.
  void setDevicePermission(String idOrPrefix, String permission) {
    final d = _record(idOrPrefix);
    state.setDevicePermission(d.id, permission);
    for (final c in _clients.toList()) {
      if (c.authenticated && !c.boardPage && c.deviceId == d.id) {
        c.permission = permission;
        unawaited(_sendSnapshot(c));
      }
    }
    _notice('"${d.name}" (${shortDeviceId(d.id)}) now has ${permission == DevicePermissions.full ? 'full control' : 'watch only'}.');
    _devicesChanged();
  }

  void renameDevice(String idOrPrefix, String name) {
    final d = _record(idOrPrefix);
    state.renameDevice(d.id, name);
    _devicesChanged();
  }

  /// Removes a device: closes its connections, drops its push token at the relay.
  void removeDevice(String idOrPrefix) {
    final d = _record(idOrPrefix);
    final before = state.boardKeyVersion;
    state.removeDevice(d.id); // rotates the board key
    _cutOff(d.id);
    _notice('Removed "${d.name}" (${shortDeviceId(d.id)}).');
    _devicesChanged();
    if (state.boardKeyVersion != before) {
      _notice('The board key was replaced: the other devices get the new one.');
      _boardKeyChanged();
    }
  }

  void _cutOff(String id) {
    for (final c in _clients.toList()) {
      if (c.authenticated && !c.boardPage && c.deviceId == id) _refuse(c, ErrorCodes.deviceRemoved, _removedText());
    }
    final url = state.relayUrl;
    if (url == null) return;
    unawaited(Future(() async {
      try {
        await relayPoster(relayHttpUri(url, state.machineId, 'devices/$id/push-token'),
            {'Authorization': 'Bearer ${state.deviceToken}', 'Content-Type': 'application/json'}, '{"token":null}');
      } catch (_) {}
    }));
  }

  bool _connected(String id) => _clients.any((c) => c.authenticated && !c.closed && !c.boardPage && c.deviceId == id);

  /// The device list as [c] sees it (a watch-only device sees only itself).
  DevicesMessage _devicesFor(_Client c) => DevicesMessage(
        devices: [
          for (final d in state.devices)
            if (c.full || d.id == c.deviceId)
              DeviceInfo(
                id: d.id,
                name: d.name,
                permission: d.permission,
                keyed: d.keyed,
                approvedAtMs: d.approvedAtMs,
                lastSeenAtMs: d.lastSeenAtMs,
                connected: _connected(d.id),
                thisDevice: d.id == c.deviceId,
              )
        ],
        pending: c.full ? pendingDevices : const [],
      );

  /// The device list for `/control?action=devices` (no keys).
  Map<String, dynamic> devicesJson() => {
        'devices': [
          for (final d in state.devices)
            {
              'id': d.id,
              'name': d.name,
              'permission': d.permission,
              'keyed': d.keyed,
              'approvedAtMs': d.approvedAtMs,
              'lastSeenAtMs': d.lastSeenAtMs,
              'connected': _connected(d.id),
            }
        ],
        'pending': [for (final p in pendingDevices) p.toJson()],
      };

  /// Tells every full-control device the list changed.
  void _devicesChanged() {
    for (final c in _clients) {
      if (c.authenticated && !c.closed && c.full) c.send(_devicesFor(c));
    }
  }

  /// Lets [c] in with [_Client.permission]: the welcome and the snapshot.
  Future<void> _admit(_Client c) async {
    c.authenticated = true;
    c.helloTimer?.cancel();
    if (!c.boardPage) {
      try {
        state.deviceSeen(c.deviceId, DateTime.now().millisecondsSinceEpoch);
      } catch (_) {}
    }
    await _sendSnapshot(c);
    if (!c.boardPage) _devicesChanged();
    if (!_deviceConnected.isClosed) _deviceConnected.add(c.deviceName);
  }

  /// The welcome and everything a device shows (on connect, and again when its permission
  /// changes: the app takes a welcome as a fresh start).
  Future<void> _sendSnapshot(_Client c) async {
    c.send(_welcome(c));
    try {
      c.send(Sessions(sessions: await manager.list(), usage: manager.usage));
    } catch (_) {
      c.send(Sessions(sessions: const [], usage: manager.usage));
    }
    final limit = manager.limits.current;
    if (limit != null) c.send(UsageLimitMessage(limit: limit));
    final accounts = manager.accounts;
    if (accounts != null) c.send(accounts.message);
    final b = board;
    if (b != null) {
      c.send(TasksMessage(tasks: b.tasks));
      c.send(ModelTableMessage(table: state.models));
      c.send(ProjectsMessage(projects: state.projects));
      // A new app answers with its own summary; an older one ignores this.
      c.send(BoardSummaryFromHost(summary: b.board.board.summary()));
    }
  }

  /// What a watch-only device may send.
  static bool _watchAllowed(ClientMessage m) => switch (m) {
        Hello() ||
        ListSessions() ||
        Subscribe() ||
        LoadEarlier() ||
        FocusSession() ||
        ListTasks() ||
        BoardSummaryFromApp() ||
        ListGitRemotes() ||
        ListCommands() ||
        ListFiles() ||
        SearchSessions() ||
        ListDir() ||
        ListDevices() =>
          true,
        _ => false,
      };

  /// The automatic syncs every app sends on connect: dropped quietly from a watch device.
  static bool _isSync(ClientMessage m) => m is SyncAccounts || m is SyncModelTable || m is SyncProjects;

  Future<void> _handle(_Client c, ClientMessage msg) async {
    switch (msg) {
      case Hello():
        break; // already paired
      case ListDevices():
        c.send(_devicesFor(c));
      case DecideDevice(:final deviceId, :final decision):
        await decideDevice(deviceId, decision);
      case SetDevicePermission(:final deviceId, :final permission):
        setDevicePermission(deviceId, permission);
      case RenameDevice(:final deviceId, :final name):
        renameDevice(deviceId, name);
      case RemoveDevice(:final deviceId):
        removeDevice(deviceId);
      case BoardSummaryFromApp(:final summary):
        c.boardSync = true;
        // The key first: when the answer arrives, the app knows whether this host has one.
        _sendBoardKey(c);
        c.send(BoardRecordsFromHost(records: _board().board.board.newerThan(summary)));
      case BoardRecordsFromApp(:final records):
        c.boardSync = true;
        _board().board.mergeAll(records, from: 'conn:${c.conn}');
      case BoardKeyFromApp(:final boardId, :final key, :final keyVersion):
        if (state.takeBoardKey(boardId, key, keyVersion)) {
          _boardKeyChanged(except: c);
        } else if (state.boardKeyVersion != null && state.boardKeyVersion != keyVersion) {
          _sendBoardKey(c); // the device has an older key: it takes this one
        }
      case ListSessions():
        c.send(Sessions(sessions: await manager.list(), usage: manager.usage));
      case StartSession(:final cwd, :final prompt, :final name, :final model, :final accountId):
        notifier?.perchTyping(prompt);
        final s = await manager.start(cwd: cwd, prompt: prompt, name: name, model: model, accountId: accountId);
        // A terminal session waiting for its folder to be trusted is not a failure: it shows a card.
        if (s.state == SessionState.blocked && s.reason != trustReason) {
          c.send(ErrorMessage(code: ErrorCodes.spawnFailed, message: s.reason ?? 'Could not start Claude Code.'));
        }
      case Subscribe(:final sessionId, :final afterSeq):
        final h = manager.history(sessionId, afterSeq: afterSeq, paged: true);
        c.send(Events(sessionId: sessionId, events: h.events, openPrompts: h.openPrompts, hasEarlier: h.hasEarlier));
      case LoadEarlier(:final sessionId, :final beforeSeq):
        final h = manager.earlier(sessionId, beforeSeq);
        c.send(EarlierEvents(sessionId: sessionId, events: h.events, hasEarlier: h.hasEarlier));
      case SendMessage(:final sessionId, :final text):
        notifier?.perchTyping(text);
        await manager.send(sessionId, text);
      case AnswerPrompt(:final sessionId, :final promptId, :final answer):
        await manager.answerPrompt(sessionId, promptId, answer);
      case Interrupt(:final sessionId):
        await manager.interrupt(sessionId);
      case StopSession(:final sessionId):
        await manager.stop(sessionId);
      case KillAll():
        await manager.killAll();
        c.send(Sessions(sessions: await manager.list(), usage: manager.usage));
      case TakeOver(:final sessionId, :final force):
        await manager.takeOver(sessionId, force: force);
      case ListDir(:final path):
        c.send(await listDir(path, sessionFolders: await manager.recentFolders()));
      case FocusSession(:final sessionId):
        c.focus = sessionId;
      case SetSelfTest(:final enabled):
        setSelfTest(enabled);
        c.send(CompatibilityMessage(compatibility: manager.compatibility.current));
      case RunSelfTest():
        final t = selfTester;
        if (t == null) throw StateError('The self-test is not available on this host.');
        unawaited(t.run());
        c.send(CompatibilityMessage(compatibility: manager.compatibility.current));
      case RenameSession(:final sessionId, :final name):
        notifier?.perchTyping('/rename $name');
        final set = await manager.rename(sessionId, name);
        c.send(SessionActionDone(action: SessionActions.rename, sessionId: sessionId, message: 'Renamed to $set'));
      case DeleteSession(:final sessionId):
        await manager.delete(sessionId);
        c.send(SessionActionDone(action: SessionActions.delete, sessionId: sessionId, message: 'Session deleted'));
        _broadcast(Sessions(sessions: await manager.list(), usage: manager.usage));
      case UsageLimitChoice(:final choice, :final sessionId, :final accountId, :final makeDefault):
        if (choice == LimitChoices.switchAccount) {
          await manager.switchLimitedTo(accountId!, makeDefault: makeDefault);
        } else {
          await manager.limits.choose(choice, sessionId: sessionId);
        }
        c.send(UsageLimitMessage(limit: manager.limits.current));
      case SyncAccounts(:final accounts):
        await _accounts().sync(accounts);
        c.send(_accounts().message);
      case RemoveAccount(:final accountId):
        await _accounts().remove(accountId);
        c.send(_accounts().message);
      case SetActiveAccount(:final accountId):
        _accounts().setActive(accountId);
        c.send(_accounts().message);
      case AccountSignIn():
        final flows = signIns;
        if (flows == null) throw StateError('This Perch host cannot add accounts.');
        _signInClients[msg.flowId] = c;
        await flows.handle(msg);
      case SwitchSessionAccount(:final sessionId, :final accountId):
        final s = await manager.switchAccount(sessionId, accountId);
        c.send(SessionActionDone(
            action: SessionActions.switchAccount,
            sessionId: s.id,
            message: 'Restarted on ${_accounts().labelOf(accountId)} in a new terminal window'));
        _broadcast(Sessions(sessions: await manager.list(), usage: manager.usage));
      case ListTasks():
        c.send(TasksMessage(tasks: _board().tasks));
      case SaveTask(:final task):
        await _board().save(task);
      case MoveTask(:final taskId, :final column):
        _board().move(taskId, column);
      case DeleteTask(:final taskId):
        _board().delete(taskId);
      case RunTask(:final taskId, :final sessionId):
        await _board().run(taskId, sessionId: sessionId);
        _broadcast(Sessions(sessions: await manager.list(), usage: manager.usage));
      case TaskNotes(:final taskId, :final notes):
        await _board().notes(taskId, notes);
      case ListGitRemotes():
        c.send(GitRemotesMessage(folders: await _board().gitRemotes()));
      case SyncModelTable(:final table):
        _legacyModels(table);
        final now = state.models;
        final kept = state.syncModelTable(table);
        if (!identical(kept, now)) {
          _broadcast(ModelTableMessage(table: kept));
        } else {
          c.send(ModelTableMessage(table: kept));
        }
      case ListCommands(:final sessionId):
        final cwd = manager.summaryOf(sessionId)?.cwd ?? '';
        c.send(CommandsMessage(sessionId: sessionId, commands: commands.commandsFor(cwd)));
      case SearchSessions(:final query):
        c.send(await manager.search(query));
      case ListFiles(:final sessionId, :final query):
        final cwd = manager.summaryOf(sessionId)?.cwd ?? '';
        final found = await files.search(cwd, query, limit: 50);
        c.send(FilesMessage(sessionId: sessionId, query: query, files: found.files, truncated: found.truncated));
      case SyncProjects(:final projects):
        _legacyProjects(projects);
        final now = state.projects;
        final kept = state.syncProjects(projects);
        if (!identical(kept, now)) {
          _broadcast(ProjectsMessage(projects: kept));
        } else {
          c.send(ProjectsMessage(projects: kept));
        }
      case SetSessionModel(:final sessionId, :final model):
        if (model != null) notifier?.perchTyping('/model $model');
        final line = await manager.setModel(sessionId, model);
        c.send(SessionActionDone(action: SessionActions.model, sessionId: sessionId, message: line));
      case ResumeSession(:final sessionId):
        final s = await manager.resume(sessionId);
        c.send(SessionActionDone(
            action: SessionActions.resume, sessionId: s.id, message: 'Resumed in a terminal window on the machine'));
        _broadcast(Sessions(sessions: await manager.list(), usage: manager.usage));
    }
  }

  TaskBoard _board() => board ?? (throw StateError('This Perch host has no task board.'));

  final _boardKeys = StreamController<void>.broadcast();

  /// The board key changed (taken from a device, or rotated): the relay copy moves.
  Stream<void> get boardKeyChanges => _boardKeys.stream;

  /// The board key to [c] when it may have it (a full device) and there is one.
  void _sendBoardKey(_Client c) {
    final id = state.boardId, key = state.boardKey, v = state.boardKeyVersion;
    if (!c.full || id == null || key == null || v == null) return;
    c.send(BoardKeyFromHost(boardId: id, key: key, keyVersion: v));
  }

  /// The new key to every connected full device (but [except], which sent it).
  void _boardKeyChanged({_Client? except}) {
    for (final c in _clients) {
      if (c.authenticated && !c.closed && c != except) _sendBoardKey(c);
    }
    if (!_boardKeys.isClosed) _boardKeys.add(null);
  }

  /// An older app's whole project list (newer list wins there): each project goes into the
  /// board at the list's time, so anything newer on the board stays.
  void _legacyProjects(ProjectList list) {
    final b = board;
    if (b == null || list.updatedAtMs <= 0) return;
    final v = Hlc(list.updatedAtMs, 0, 'legacy_app');
    b.board.mergeAll([
      for (final p in list.projects)
        BoardRecord(RecordKinds.project, p.id, {for (final g in projectGroupValues(p).entries) g.key: BoardGroup(g.value, v)})
    ]);
  }

  /// An older app's model table, at its own time.
  void _legacyModels(ModelTable t) {
    final b = board;
    if (b == null || t.updatedAtMs <= 0) return;
    final v = Hlc(t.updatedAtMs, 0, 'legacy_app');
    b.board.mergeAll([
      BoardRecord(RecordKinds.modelTable, modelTableRecordId,
          {for (final g in modelTableGroups(t).entries) g.key: BoardGroup(g.value, v)})
    ]);
  }

  HostAccounts _accounts() => manager.accounts ?? (throw StateError('This Perch host does not support accounts.'));

  /// Turns the self-test of new versions on or off; on, it runs now when it is due.
  void setSelfTest(bool enabled) {
    manager.compatibility.setSelfTestEnabled(enabled);
    if (enabled) unawaited(selfTester?.maybeRun());
  }

  static ErrorMessage _errorFor(Object e) => switch (e) {
        NoSuchSession() => ErrorMessage(code: ErrorCodes.noSuchSession, message: 'This session no longer exists.'),
        ReadOnlySession() => ErrorMessage(code: ErrorCodes.readOnlySession, message: '$e'),
        PromptAlreadyAnswered() =>
          const ErrorMessage(code: ErrorCodes.promptAlreadyAnswered, message: 'Already answered on another device'),
        SessionBusy() => ErrorMessage(code: ErrorCodes.sessionBusy, message: '$e'),
        TakeoverFailed(:final message) => ErrorMessage(code: ErrorCodes.takeoverFailed, message: message),
        CannotType(:final message) => ErrorMessage(code: ErrorCodes.cannotType, message: message),
        CannotAnswerInTerminal(:final message) =>
          ErrorMessage(code: ErrorCodes.cannotAnswerInTerminal, message: message),
        ArgumentError(:final message) => ErrorMessage(code: ErrorCodes.badRequest, message: '${message ?? e}'),
        StateError(:final message) => ErrorMessage(code: ErrorCodes.badRequest, message: message),
        _ => ErrorMessage(code: ErrorCodes.badRequest, message: '$e'),
      };

  void _closeAll({bool tellStopped = false}) {
    for (final c in _clients.toList()) {
      if (tellStopped && c.authenticated) c.send(const RemoteAccessStopped());
      _close(c);
    }
    _clients.clear();
  }

  /// Sends `remoteAccessStopped` to every device, closes them, disconnects from the relay,
  /// and refuses new connections until [resumeRemoteAccess].
  Future<void> stopRemoteAccess() async {
    _live = false;
    notifier?.enabled = false;
    _closeAll(tellStopped: true);
    await relay?.stop();
  }

  void resumeRemoteAccess() {
    if (_live) return;
    _live = true;
    notifier?.enabled = true;
    relay?.start();
  }

  /// Re-reads the host state (after `forget-devices`, `relay set`, `name set` or `hooks
  /// install|uninstall` in another console). A new secret drops every connection, which must pair again; a new name is
  /// told to the connected devices.
  Future<void> reloadState() async {
    final fresh = HostState.load(state.directory);
    final rotated = fresh.machineId != state.machineId || !_sameBytes(fresh.secret, state.secret);
    final relayChanged = fresh.relayUrl != state.relayUrl || fresh.relayInvite != state.relayInvite;
    final nameChanged = fresh.machineName != state.machineName;
    // A board key changed in host.json (a device removed by a command with no host to ask,
    // or by hand): the newer key wins; boards left behind stay listed for the relay.
    final keyBefore = state.boardKeyVersion;
    for (final o in fresh.oldBoards) {
      if (!state.oldBoards.any((b) => b.boardId == o.boardId) && o.boardId != fresh.boardId) state.oldBoards.add(o);
    }
    if (fresh.boardId != null && fresh.boardKey != null && fresh.boardKeyVersion != null) {
      state.takeBoardKey(fresh.boardId!, fresh.boardKey!, fresh.boardKeyVersion!);
    }
    state
      ..machineId = fresh.machineId
      ..secret = fresh.secret
      ..relayUrl = fresh.relayUrl
      ..relayInvite = fresh.relayInvite
      ..everPaired = fresh.everPaired
      ..machineName = fresh.machineName;
    // Devices changed by a CLI command with no host to ask (or by hand): removed ones are
    // cut off, changed permissions apply at once.
    final before = {for (final d in state.devices) d.id: d.permission};
    state.devices = fresh.devices;
    var devicesChanged = before.length != fresh.devices.length;
    for (final id in before.keys) {
      final now = state.device(id);
      if (now == null) {
        if (!rotated) _cutOff(id);
        devicesChanged = true;
      } else if (now.permission != before[id]) {
        devicesChanged = true;
        for (final c in _clients.toList()) {
          if (c.authenticated && !c.boardPage && c.deviceId == id) {
            c.permission = now.permission;
            unawaited(_sendSnapshot(c));
          }
        }
      }
    }
    if (devicesChanged) _devicesChanged();
    if (state.boardKeyVersion != keyBefore) {
      _boardKeyChanged();
    } else if (before.keys.any((id) => state.device(id) == null) && !rotated && state.rotateBoardKey()) {
      _boardKeyChanged(); // a device removed by hand: the key moves on
    }
    // Devices learn the hooks' state only in `welcome`: drop them so they reconnect (within
    // a second) and get a fresh one.
    final hooksNow = checkHooks?.call();
    final hooksChanged = hooksNow != null && hooksNow != hooksInstalled;
    if (hooksNow != null) hooksInstalled = hooksNow;
    if (rotated || hooksChanged) _closeAll();
    if (nameChanged && !nameFixed) rename(serveName(state));
    if (rotated || relayChanged) {
      await relay?.stop();
      if (_live) relay?.start();
    }
    await onReload?.call();
  }

  /// Uses [name] from now on: in `welcome`, as the notification title and in `pair`'s
  /// link; connected devices are told at once.
  void rename(String name) {
    if (name == machineName) return;
    machineName = name;
    manager.machineName = name;
    notifier?.machineName = name;
    try {
      state
        ..lastName = name
        ..save();
    } catch (_) {}
    _broadcast(MachineRenamed(machineName: name));
    onRenamed?.call(name);
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> close() async {
    _refresh?.cancel();
    _switchTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await relay?.stop();
    await notifier?.dispose();
    await signIns?.dispose(); // closes any setup-token console still open
    _closeAll();
    for (final w in _waiting.values) {
      w.expiry?.cancel();
      w.prompt?.cancel();
    }
    _waiting.clear();
    await _http?.close(force: true);
    await _deviceConnected.close();
    await _deviceNotices.close();
  }
}
