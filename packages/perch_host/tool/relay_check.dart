// End-to-end check through a relay: plays the app's part over the relay only.
//
//   dart run tool/relay_check.dart --link-file <file holding the perch://pair link> [--session-name <name>]
//       [--append-to <transcript.jsonl>] [--relay-log <wrangler output file>]
//       [--marker <text that must never appear at the relay>]...
//
// Pairs with the link (as if its QR code had been scanned), connects to the relay
// (never the LAN), says hello, lists sessions, subscribes to the named session's history,
// then appends a synthetic line to its transcript (when --append-to is given) and waits
// for the live event. Prints frame counts. With --relay-log (the output of
// `wrangler dev --var RELAY_LOG_FRAMES:full`), decodes every frame the Durable Object
// logged and checks that none contains a marker or JSON wire text.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:perch_protocol/perch_protocol.dart';

Future<void> main(List<String> argv) async {
  final args = (ArgParser()
        ..addOption('link')
        ..addOption('link-file', help: 'A file whose first perch://pair link is used (dart.bat splits "&" in arguments)')
        ..addOption('session-name')
        ..addOption('append-to')
        ..addOption('relay-log')
        ..addMultiOption('marker'))
      .parse(argv);
  var text = args['link'] as String? ?? '';
  final linkFile = args['link-file'] as String?;
  if (linkFile != null) {
    text = RegExp(r'perch://pair\?\S+').firstMatch(File(linkFile).readAsStringSync())?.group(0) ?? '';
  }
  final link = PairingLink.parse(text);
  if (link == null || link.relayUrl == null) {
    stderr.writeln('Give --link with a pairing link that has a relay (r=).');
    exit(64);
  }
  const deviceId = 'relay-check-device';
  final uri = relaySocketUri(link.relayUrl!, link.machineId, 'device', {'d': deviceId, 't': relayDeviceToken(link.secret)});
  stdout.writeln('Connecting through the relay: ${uri.replace(queryParameters: {'d': deviceId, 't': '<device token>'})}');

  var framesOut = 0, framesIn = 0, bytesOut = 0, bytesIn = 0, controls = 0;
  final types = <String, int>{};
  final messages = StreamController<HostMessage>.broadcast();
  final ws = await WebSocket.connect(uri.toString());
  final hs = ClientHandshake(secret: link.secret, machineId: link.machineId, deviceId: deviceId);
  SecureSession? session;
  final handshakeDone = Completer<void>();

  void sendFrame(Uint8List f) {
    framesOut++;
    bytesOut += f.length;
    ws.add(f);
  }

  void send(ClientMessage m) {
    for (final f in session!.seal(encodeClient(m))) {
      sendFrame(f);
    }
  }

  ws.listen((data) {
    if (data is String) {
      controls++;
      stdout.writeln('relay says: $data');
      if (data.contains('hostOnline') && !handshakeDone.isCompleted) sendFrame(hs.hello);
      return;
    }
    final bytes = Uint8List.fromList(data as List<int>);
    framesIn++;
    bytesIn += bytes.length;
    if (session == null) {
      session = hs.finish(bytes);
      handshakeDone.complete();
      return;
    }
    final text = session!.open(bytes);
    if (text == null) return;
    final m = decodeHost(text);
    if (m == null) return;
    types[m.type] = (types[m.type] ?? 0) + 1;
    messages.add(m);
  }, onDone: () => stdout.writeln('relay closed the connection (${ws.closeCode})'));

  Future<T> next<T extends HostMessage>({bool Function(T)? where, Duration timeout = const Duration(seconds: 30)}) =>
      messages.stream.where((m) => m is T && (where == null || where(m))).cast<T>().first.timeout(timeout);

  sendFrame(hs.hello);
  await handshakeDone.future.timeout(const Duration(seconds: 30));
  stdout.writeln('handshake done');
  final welcome = next<Welcome>();
  final sessions = next<Sessions>();
  send(const Hello(deviceName: 'relay check'));
  final w = await welcome;
  stdout.writeln('welcome from "${w.machineName}" (host ${w.hostVersion}, relay ${w.relayUrl})');
  final list = await sessions;
  stdout.writeln('sessions listed: ${list.sessions.length} ${list.sessions.map((s) => '"${s.name}"').join(', ')}');

  final name = args['session-name'] as String?;
  final target = name == null ? list.sessions.firstOrNull : list.sessions.where((s) => s.name == name).firstOrNull;
  if (target == null) {
    stdout.writeln('no session to subscribe to');
  } else {
    final events = next<Events>(where: (e) => e.sessionId == target.id);
    send(Subscribe(sessionId: target.id));
    final h = await events;
    final historyBytes = utf8.encode(encodeHost(h)).length;
    stdout.writeln('history: ${h.events.length} events (${(historyBytes / 1024).round()} KB as one message), '
        'hasEarlier ${h.hasEarlier}');
    final append = args['append-to'] as String?;
    if (append != null) {
      final live = next<EventMessage>(where: (e) => e.sessionId == target.id);
      File(append).writeAsStringSync(
          '${jsonEncode({
            'type': 'user',
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'message': {'role': 'user', 'content': 'live line written during the relay check'},
          })}\n',
          mode: FileMode.append);
      final e = await live;
      stdout.writeln('live event received: ${e.event.runtimeType} seq ${e.event.seq}');
    }
  }
  await ws.close();
  stdout.writeln('frames sent $framesOut ($bytesOut bytes), received $framesIn ($bytesIn bytes), relay notices $controls');
  stdout.writeln('messages received by type: $types');

  final logPath = args['relay-log'] as String?;
  if (logPath != null) {
    await Future<void>.delayed(const Duration(seconds: 2)); // let the log flush
    final markers = [...(args['marker'] as List<String>), '"type"', 'sessionId', 'deviceName'];
    var logged = 0, loggedBytes = 0, leaks = 0;
    final byDirection = <String, int>{};
    for (final line in File(logPath).readAsLinesSync()) {
      final i = line.indexOf('{"relayFrame"');
      if (i < 0) continue;
      final Map<String, dynamic> j;
      try {
        j = jsonDecode(line.substring(i)) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final b64 = j['base64'];
      if (b64 is! String) continue;
      final frame = base64.decode(b64);
      logged++;
      loggedBytes += frame.length;
      byDirection['${j['relayFrame']}'] = (byDirection['${j['relayFrame']}'] ?? 0) + 1;
      final asText = latin1.decode(frame);
      for (final m in markers) {
        if (asText.contains(m)) {
          leaks++;
          stdout.writeln('PLAINTEXT AT THE RELAY: "$m" in a ${j['relayFrame']} frame');
        }
      }
    }
    stdout.writeln('relay logged $logged frames ($loggedBytes bytes): $byDirection; '
        'plaintext markers found: $leaks (checked ${markers.length} markers)');
    if (leaks > 0 || logged == 0) exit(1);
  }
  exit(0);
}
