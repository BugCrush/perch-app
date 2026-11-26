// Uploading attachments over the connection: start, pieces with at most four unacknowledged,
// the end with the file's SHA-256; failures, retry, the 20 MB limit and a dropped link.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perch_app/src/connection/attachment_upload.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'fakes.dart';

void main() {
  final machine = testMachine(id: 'm1', label: 'Desk');
  late FakeChannels channels;
  late HostConnection conn;
  late AttachmentUploader up;

  setUp(() {
    channels = FakeChannels();
    conn = HostConnection(machine, channelFactory: channels.factory, deviceName: 'Pixel', deviceId: 'dev-7');
    up = AttachmentUploader(conn);
  });
  tearDown(() {
    up.dispose();
    conn.dispose();
  });

  const attachWelcome = Welcome(machineName: 'devbox', os: 'macos', hostVersion: '1.1.0', attachments: true);

  Future<void> online([Welcome w = attachWelcome]) async {
    conn.connect();
    channels.last.send(w);
    await eventually(() => conn.link.value == LinkState.online);
  }

  Uint8List bytesOf(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + 7) & 0xff]);
  List<T> sent<T extends ClientMessage>() => channels.last.messages.whereType<T>().toList();

  test('welcome with attachments: true says so; an older welcome does not', () async {
    await online();
    expect(conn.attachments, isTrue);
    channels.last.send(welcome);
    await eventually(() => !conn.attachments);
  });

  test('a 1.2 MB file: start, three pieces, end with its SHA-256, then done', () async {
    await online();
    final bytes = bytesOf(1200 * 1024);
    final a = up.add(name: 'shot.png', bytes: bytes, mime: 'image/png', sessionId: 's1');
    expect(a.state, AttachmentState.uploading);
    expect(a.isImage, isTrue);
    expect(up.items, [a]);
    await eventually(() => sent<AttachStart>().isNotEmpty);
    final start = sent<AttachStart>().single;
    expect((start.name, start.size, start.sessionId, start.cwd, start.mime), ('shot.png', bytes.length, 's1', null, 'image/png'));
    expect(base64Url.decode(base64Url.normalize(start.uploadId)), hasLength(16));
    expect(sent<AttachChunk>(), isEmpty, reason: 'pieces wait for the host to accept');
    channels.last.send(AttachAccepted(uploadId: start.uploadId, path: 'perch-attachments/2026-11-26_1612_shot.png'));
    await eventually(() => sent<AttachEnd>().isNotEmpty);
    final chunks = sent<AttachChunk>();
    expect(chunks.map((c) => c.index), [0, 1, 2]);
    expect([for (final c in chunks) ...base64Decode(c.data)], bytes);
    expect(sent<AttachEnd>().single.sha256, sha256.convert(bytes).toString());
    channels.last.send(AttachProgress(uploadId: start.uploadId, received: bytes.length));
    channels.last.send(AttachDone(uploadId: start.uploadId, path: 'perch-attachments/2026-11-26_1612_shot.png'));
    await eventually(() => a.state == AttachmentState.done);
    expect(a.path, 'perch-attachments/2026-11-26_1612_shot.png');
    expect(a.sent, bytes.length);
    expect(up.donePaths, ['perch-attachments/2026-11-26_1612_shot.png']);
  });

  test('at most four pieces are unacknowledged', () async {
    await online();
    final bytes = bytesOf(5 * attachmentPieceBytes + 10);
    final a = up.add(name: 'big.bin', bytes: bytes, cwd: '/work');
    await eventually(() => sent<AttachStart>().isNotEmpty);
    final id = sent<AttachStart>().single.uploadId;
    expect(sent<AttachStart>().single.cwd, '/work');
    channels.last.send(AttachAccepted(uploadId: id, path: 'perch-attachments/big.bin'));
    await eventually(() => sent<AttachChunk>().length == 4);
    await pump(50);
    expect(sent<AttachChunk>(), hasLength(4));
    channels.last.send(AttachProgress(uploadId: id, received: 4 * attachmentPieceBytes));
    await eventually(() => sent<AttachEnd>().isNotEmpty);
    expect(sent<AttachChunk>().map((c) => c.index), [0, 1, 2, 3, 4, 5]);
    expect(a.sent, 4 * attachmentPieceBytes);
  });

  test('a refusal fails the attachment with its reason; retry starts a new upload', () async {
    await online();
    final a = up.add(name: 'a.png', bytes: bytesOf(10), sessionId: 's1');
    await eventually(() => sent<AttachStart>().isNotEmpty);
    final first = sent<AttachStart>().single.uploadId;
    channels.last.send(AttachFailed(uploadId: first, reason: 'This session has ended'));
    await eventually(() => a.state == AttachmentState.failed);
    expect(a.error, 'This session has ended');
    up.retry(a);
    expect(a.state, AttachmentState.uploading);
    await eventually(() => sent<AttachStart>().length == 2);
    expect(sent<AttachStart>().last.uploadId, isNot(first));
  });

  test('over 20 MB fails at once and sends nothing', () async {
    await online();
    final a = up.add(name: 'huge.mov', bytes: Uint8List(maxAttachmentBytes + 1), sessionId: 's1');
    expect(a.state, AttachmentState.failed);
    expect(a.error, 'Files up to 20 MB');
    await pump(30);
    expect(sent<AttachStart>(), isEmpty);
  });

  test('the link going offline fails what is uploading', () async {
    await online();
    final a = up.add(name: 'a.png', bytes: bytesOf(10), sessionId: 's1');
    await eventually(() => sent<AttachStart>().isNotEmpty);
    await channels.last.close();
    await eventually(() => a.state == AttachmentState.failed);
    expect(a.error, 'Connection lost; tap Retry');
  });

  test('remove cancels an upload in progress and drops it from the list', () async {
    await online();
    final a = up.add(name: 'a.png', bytes: bytesOf(10), sessionId: 's1');
    await eventually(() => sent<AttachStart>().isNotEmpty);
    up.remove(a);
    expect(up.items, isEmpty);
    await eventually(() => sent<AttachCancel>().isNotEmpty);
    expect(sent<AttachCancel>().single.uploadId, sent<AttachStart>().single.uploadId);
  });

  test('a new welcome mid-upload (relay to LAN switch) fails what is uploading', () async {
    await online();
    final a = up.add(name: 'a.png', bytes: bytesOf(10), sessionId: 's1');
    await eventually(() => sent<AttachStart>().isNotEmpty);
    channels.last.send(attachWelcome);
    await eventually(() => a.state == AttachmentState.failed);
    expect(a.error, 'Connection lost; tap Retry');
  });

  test('switched to watch only mid-upload: the chip says so', () async {
    await online();
    final a = up.add(name: 'a.png', bytes: bytesOf(10), sessionId: 's1');
    await eventually(() => sent<AttachStart>().isNotEmpty);
    channels.last.send(const Welcome(
        machineName: 'devbox', os: 'macos', hostVersion: '1.1.0', attachments: true, permission: DevicePermissions.watch));
    await eventually(() => a.state == AttachmentState.failed);
    expect(a.error, 'This device can only watch');
  });

  test('an empty file is refused on the phone', () async {
    await online();
    final a = up.add(name: 'empty.txt', bytes: Uint8List(0), sessionId: 's1');
    expect(a.state, AttachmentState.failed);
    expect(a.error, 'Empty file');
    await pump(30);
    expect(sent<AttachStart>(), isEmpty);
  });
}
