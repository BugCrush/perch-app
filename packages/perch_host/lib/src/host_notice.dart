// The host-side notice that remote access is live (PRD 7.9): a console banner, one OS
// notification per connecting device, the S / R / Q keys, and A / W / D for a device that
// asks to pair.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart' show DeviceDecisions;

import 'host_state.dart';
import 'qr_render.dart';
import 'server.dart';

String bannerText({required String address, required int port}) => '''
PERCH HOST — REMOTE ACCESS IS LIVE
A device with this machine's pairing QR code can ask to pair; you allow each one here first.
Address: $address:$port''';

const keysLine = 'Press S to stop remote access, R to resume, Q to quit.';

/// The keys line; while a device waits to pair it also names A / W / D.
String keysLineFor({required bool pending}) => pending
    ? '$keysLine A device is waiting to pair: A = allow full control, W = watch only, D = deny.'
    : keysLine;

String _clock() => DateTime.now().toLocal().toIso8601String().substring(11, 19);

/// Shown instead of the QR code once a device has paired.
const pairHintLine = 'Pair a new device: perch_host pair';

String relayLine(String? url, {String? status}) =>
    url == null ? 'Relay not set' : 'Relay: $url${status == null ? '' : ' ($status)'}';

/// The banner shows the QR code on first run and until a device has ever paired.
bool showQrInBanner(HostState s) => s.createdNow || !s.everPaired;

/// The pairing QR code as text, the link to paste, and where its picture is saved (the
/// picture is written to the state folder).
List<String> pairingLines(HostState state, {required String name, required List<String> lan}) {
  final link = state.link(name: name, lan: lan).toString();
  var saved = '';
  try {
    File(state.pngPath).writeAsBytesSync(qrPng(link));
    saved = 'The same code is saved as a picture: ${state.pngPath}';
  } catch (e) {
    saved = 'Could not save the picture: $e';
  }
  return [
    'Pair a device: in the Perch app tap Add machine and scan this code.',
    qrText(link),
    'On a desktop or in a browser, paste this link instead (keep it private, it is the key):',
    link,
    saved,
  ];
}

/// Printed under the banner when Perch's Claude Code hooks are not installed.
const hooksOffLine = 'Instant updates are off. Install the Perch plugin in Claude Code (README), or run: perch_host hooks install';

const duplicateHooksLine = "Perch's hooks are both in the Perch plugin and in Claude Code's settings.json (or in two "
    'Perch plugins): every event reaches Perch twice. Run: perch_host hooks uninstall';

const notificationTitle = 'Perch: remote access is live';
String notificationBody(String device) => '$device connected. Press S in the Perch window to stop.';

/// Non-loopback IPv4 addresses of this machine.
Future<List<String>> localAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    return [
      for (final i in interfaces)
        for (final a in i.addresses)
          if (!a.isLoopback && !a.isLinkLocal) a.address
    ];
  } catch (_) {
    return const [];
  }
}

/// Shows one OS notification. Failures are logged and ignored.
Future<void> showOsNotification(String title, String body) async {
  try {
    if (Platform.isWindows) {
      String q(String s) => "'${s.replaceAll("'", "''")}'";
      final script = 'Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; '
          r'$n = New-Object System.Windows.Forms.NotifyIcon; '
          r'$n.Icon = [System.Drawing.SystemIcons]::Information; $n.Visible = $true; '
          '\$n.ShowBalloonTip(8000, ${q(title)}, ${q(body)}, [System.Windows.Forms.ToolTipIcon]::Info); '
          r'Start-Sleep -Seconds 9; $n.Dispose()';
      await Process.start('powershell', ['-NoProfile', '-Command', script], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      String q(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
      final r = await Process.run('osascript', ['-e', 'display notification ${q(body)} with title ${q(title)}']);
      if (r.exitCode != 0) stderr.writeln('Notification failed: ${r.stderr}');
    } else {
      final r = await Process.run('notify-send', [title, body]);
      if (r.exitCode != 0) stderr.writeln('Notification failed: ${r.stderr}');
    }
  } catch (e) {
    stderr.writeln('Notification failed: $e');
  }
}

class HostNotice {
  final PerchServer server;
  final HostState state;
  final List<String> addresses;

  /// The server's name now (it changes after `perch_host name set`).
  String get machineName => server.machineName;

  /// Called when Q is pressed.
  final FutureOr<void> Function()? onQuit;

  /// Printed after the banner (for example [hooksOffLine]).
  final List<String> extraLines;

  /// The relay connection's state for the banner (`connected`, `connecting`, ...).
  final String? Function()? relayStatus;

  /// Where lines go (the console).
  final void Function(String line) out;

  HostNotice(this.server,
      {required this.state,
      required this.addresses,
      this.onQuit,
      this.extraLines = const [],
      this.relayStatus,
      void Function(String line)? out})
      : out = out ?? stdout.writeln;

  StreamSubscription<dynamic>? _keys;
  StreamSubscription<String>? _devices;
  StreamSubscription<String>? _deviceNotices;

  /// Acts on one key pressed in the host's window.
  Future<void> handleKey(String key) async {
    switch (key.toUpperCase()) {
      case 'S':
        if (server.remoteAccessLive) {
          await server.stopRemoteAccess();
          out('Remote access stopped');
        }
      case 'R':
        if (!server.remoteAccessLive) {
          server.resumeRemoteAccess();
          out('Remote access resumed');
          _banner();
        }
      case 'A' || 'W' || 'D':
        final decision = switch (key.toUpperCase()) {
          'A' => DeviceDecisions.full,
          'W' => DeviceDecisions.watch,
          _ => DeviceDecisions.deny,
        };
        try {
          if (!await server.decideOldest(decision)) out('No device is waiting to pair.');
        } catch (e) {
          out('Could not decide: $e');
        }
      case 'Q':
        await stop();
        await onQuit?.call();
    }
  }

  List<String> get _lan => [for (final a in addresses) '$a:$_port'];

  void _banner() {
    final shown = addresses.isEmpty ? ['127.0.0.1'] : addresses;
    out('');
    out(bannerText(address: shown.first, port: _port));
    for (final extra in shown.skip(1)) {
      out('Also reachable at: $extra:$_port');
    }
    out(relayLine(state.relayUrl, status: relayStatus?.call()));
    for (final l in extraLines) {
      out(l);
    }
    if (showQrInBanner(state)) {
      for (final l in pairingLines(state, name: machineName, lan: _lan)) {
        out(l);
      }
    } else {
      out(pairHintLine);
    }
    out(keysLineFor(pending: server.pendingDevices.isNotEmpty));
    out('');
  }

  /// Prints the banner again (after the host state was reloaded).
  void reprint() => _banner();

  int _port = 8787;

  /// Prints the banner; on each deviceConnected shows one OS notification; listens for
  /// the S and R keys (and Q to quit).
  void start({int? boundPort}) {
    _port = boundPort ?? server.port;
    _banner();
    _devices = server.deviceConnected.listen((device) {
      out('${_clock()}  $device connected.');
      unawaited(showOsNotification(notificationTitle, notificationBody(device)));
    });
    _deviceNotices = server.deviceNotices.listen((line) => out('${_clock()}  $line'));
    try {
      if (stdin.hasTerminal) {
        stdin.echoMode = false;
        stdin.lineMode = false;
      }
    } catch (_) {}
    _keys = stdin.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) async {
      for (final ch in chunk.split('')) {
        await handleKey(ch);
      }
    });
  }

  Future<void> stop() async {
    await _keys?.cancel();
    await _devices?.cancel();
    await _deviceNotices?.cancel();
    try {
      if (stdin.hasTerminal) {
        stdin.lineMode = true;
        stdin.echoMode = true;
      }
    } catch (_) {}
  }
}
