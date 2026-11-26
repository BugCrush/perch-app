// Attachments over the channel: a full device uploads a file in pieces into a session's folder
// (or a folder chosen for a new session); watch-only devices are refused; a dropped connection
// leaves no partial file behind.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'server_test.dart' show TestClient;

final sep = Platform.pathSeparator;

void main() {
  late Directory tmp;
  late Directory work;
  late SessionManager manager;
  late HostState state;
  late PerchServer server;
  late int port;
  final clients = <TestClient>[];

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_srv_attach_');
    work = Directory('${tmp.path}${sep}work')..createSync();
    manager = SessionManager(launcher: fakeLauncher(), external: FakeExternalSessions());
    state = HostState.load('${tmp.path}${sep}state')
      ..approveDevice('dev-test', name: 'Phone', permission: DevicePermissions.full)
      ..approveDevice('dev-watch', name: 'Tablet', permission: DevicePermissions.watch);
    server = PerchServer(manager: manager, state: state, machineName: 'm', bindAddress: '127.0.0.1', port: 0);
    port = await server.start();
  });

  tearDown(() async {
    for (final c in clients) {
      await c.close();
    }
    clients.clear();
    await server.close();
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<TestClient> phone({String deviceId = 'dev-test'}) async {
    final c = await TestClient.connect(port, state, deviceId: deviceId);
    clients.add(c);
    c.send(const Hello(deviceName: 'Phone', pairing: 2));
    await c.next<Sessions>();
    return c;
  }

  List<int> bytesOf(int n, [int seed = 1]) {
    final r = Random(seed);
    return [for (var i = 0; i < n; i++) r.nextInt(256)];
  }

  Directory attachments(Directory folder) => Directory('${folder.path}$sep$attachmentFolder');
  List<String> names(Directory d) =>
      d.existsSync() ? [for (final e in d.listSync()) e.uri.pathSegments.lastWhere((s) => s.isNotEmpty)] : [];

  void sendPieces(TestClient c, String id, List<int> bytes, {int from = 0, int? to}) {
    final pieces = attachmentPieces(bytes.length);
    for (var i = from; i < (to ?? pieces); i++) {
      final end = min((i + 1) * attachmentPieceBytes, bytes.length);
      c.send(AttachChunk(uploadId: id, index: i, data: base64Encode(bytes.sublist(i * attachmentPieceBytes, end))));
    }
  }

  test('the welcome says the host takes attachments', () async {
    final c = await phone();
    expect(c.received.whereType<Welcome>().single.attachments, isTrue);
  });

  test('a full device uploads 9 pieces into a session folder', () async {
    final c = await phone();
    final s = await manager.start(cwd: work.path, prompt: 'echo hi');
    final bytes = bytesOf(8 * attachmentPieceBytes + 1000);
    c.send(AttachStart(uploadId: 'up1', sessionId: s.id, name: 'big photo.jpg', size: bytes.length));
    final accepted = await c.next<AttachAccepted>();
    expect(accepted.path, startsWith('perch-attachments/'));
    expect(accepted.path, endsWith('_big-photo.jpg'));
    sendPieces(c, 'up1', bytes);
    c.send(AttachEnd(uploadId: 'up1', sha256: sha256.convert(bytes).toString()));
    final done = await c.next<AttachDone>();
    expect(done.path, accepted.path);
    expect(c.received.whereType<AttachProgress>().map((p) => p.received),
        [4 * attachmentPieceBytes, 8 * attachmentPieceBytes, bytes.length]);
    expect(File('${work.path}$sep${done.path.replaceAll('/', sep)}').readAsBytesSync(), bytes);
    expect(names(attachments(work)), [done.path.split('/').last]);
  });

  test('pieces sent right after the start, without waiting, still land', () async {
    final c = await phone();
    final bytes = bytesOf(3 * attachmentPieceBytes);
    c.send(AttachStart(uploadId: 'fast', cwd: work.path, name: 'a.bin', size: bytes.length));
    sendPieces(c, 'fast', bytes);
    c.send(AttachEnd(uploadId: 'fast', sha256: sha256.convert(bytes).toString()));
    final done = await c.next<AttachDone>();
    expect(File('${work.path}/${done.path}').readAsBytesSync(), bytes);
  });

  test('a folder for a new session instead of a session', () async {
    final c = await phone();
    final bytes = bytesOf(1000);
    c.send(AttachStart(uploadId: 'up2', cwd: work.path, name: 'shot.png', size: bytes.length));
    await c.next<AttachAccepted>();
    sendPieces(c, 'up2', bytes);
    c.send(AttachEnd(uploadId: 'up2', sha256: sha256.convert(bytes).toString()));
    final done = await c.next<AttachDone>();
    expect(File('${work.path}/${done.path}').readAsBytesSync(), bytes);
  });

  test('a folder that does not exist is refused', () async {
    final c = await phone();
    c.send(AttachStart(uploadId: 'up3', cwd: '${tmp.path}${sep}nope', name: 'a.png', size: 3));
    final f = await c.next<AttachFailed>();
    expect((f.uploadId, f.reason), ('up3', 'That folder does not exist'));
  });

  test('a watch-only device is refused and nothing is created', () async {
    final c = await phone(deviceId: 'dev-watch');
    c.send(AttachStart(uploadId: 'w', cwd: work.path, name: 'a.png', size: 3));
    final e = await c.next<ErrorMessage>();
    expect(e.code, ErrorCodes.watchOnly);
    expect(attachments(work).existsSync(), isFalse);
    expect(c.received.whereType<AttachAccepted>(), isEmpty);
  });

  test('a device switched to watch only mid-upload is refused and the partial deleted', () async {
    final c = await phone();
    final bytes = bytesOf(2 * attachmentPieceBytes);
    c.send(AttachStart(uploadId: 'sw', cwd: work.path, name: 'a.bin', size: bytes.length));
    await c.next<AttachAccepted>();
    sendPieces(c, 'sw', bytes, to: 1);
    await waitUntil(() => names(attachments(work)).contains('.partial-sw'));
    server.setDevicePermission('dev-test', DevicePermissions.watch);
    await c.next<Welcome>(where: (w) => w.permission == DevicePermissions.watch);
    sendPieces(c, 'sw', bytes, from: 1);
    expect((await c.next<ErrorMessage>()).code, ErrorCodes.watchOnly);
    await waitUntil(() => names(attachments(work)).isEmpty);
  });

  test('an unknown session is refused', () async {
    final c = await phone();
    c.send(const AttachStart(uploadId: 'u', sessionId: 'nope', name: 'a.png', size: 3));
    final f = await c.next<AttachFailed>();
    expect(f.reason, 'This session has ended');
  });

  test('a refusal from the store reaches the phone with its reason', () async {
    final c = await phone();
    c.send(AttachStart(uploadId: 'big', cwd: work.path, name: 'a.png', size: maxAttachmentBytes + 1));
    expect((await c.next<AttachFailed>()).reason, 'Files up to 20 MB');
    c.send(AttachStart(uploadId: 'bad', cwd: work.path, name: 'a.png', size: 4));
    await c.next<AttachAccepted>();
    c.send(AttachChunk(uploadId: 'bad', index: 1, data: base64Encode([1, 2])));
    expect((await c.next<AttachFailed>(where: (f) => f.uploadId == 'bad')).reason, 'The upload went wrong; try again');
    expect(names(attachments(work)), isEmpty);
  });

  test('closing the connection mid-upload deletes the partial', () async {
    final c = await phone();
    final bytes = bytesOf(4 * attachmentPieceBytes);
    c.send(AttachStart(uploadId: 'drop', cwd: work.path, name: 'a.bin', size: bytes.length));
    await c.next<AttachAccepted>();
    sendPieces(c, 'drop', bytes, to: 2);
    await waitUntil(() => names(attachments(work)).contains('.partial-drop'));
    await c.close();
    await waitUntil(() => names(attachments(work)).isEmpty);
  });

  test('cancel deletes the partial', () async {
    final c = await phone();
    c.send(AttachStart(uploadId: 'cx', cwd: work.path, name: 'a.bin', size: 10));
    await c.next<AttachAccepted>();
    c.send(const AttachCancel(uploadId: 'cx'));
    await waitUntil(() => names(attachments(work)).isEmpty);
  });

  test('two uploads interleaved on one connection land as two correct files', () async {
    final c = await phone();
    final x = bytesOf(2 * attachmentPieceBytes, 1), y = bytesOf(2 * attachmentPieceBytes, 2);
    c.send(AttachStart(uploadId: 'x', cwd: work.path, name: 'same.bin', size: x.length));
    c.send(AttachStart(uploadId: 'y', cwd: work.path, name: 'same.bin', size: y.length));
    sendPieces(c, 'x', x, to: 1);
    sendPieces(c, 'y', y, to: 1);
    sendPieces(c, 'x', x, from: 1);
    sendPieces(c, 'y', y, from: 1);
    c.send(AttachEnd(uploadId: 'x', sha256: sha256.convert(x).toString()));
    c.send(AttachEnd(uploadId: 'y', sha256: sha256.convert(y).toString()));
    final dx = await c.next<AttachDone>(where: (d) => d.uploadId == 'x');
    final dy = await c.next<AttachDone>(where: (d) => d.uploadId == 'y');
    expect(dx.path, isNot(dy.path));
    expect(File('${work.path}/${dx.path}').readAsBytesSync(), x);
    expect(File('${work.path}/${dy.path}').readAsBytesSync(), y);
  });
}
