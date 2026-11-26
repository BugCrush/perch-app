// Attachments from the phone: the wire messages that carry a file in pieces, and the
// `@perch-attachments/…` mentions added to the message text.
import 'dart:convert';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  ClientMessage? viaClient(ClientMessage m) => decodeClient(jsonEncode(m.toJson()));
  HostMessage? viaHost(HostMessage m) => decodeHost(jsonEncode(m.toJson()));

  group('client messages', () {
    test('AttachStart with a session round-trips', () {
      final m = viaClient(const AttachStart(
          uploadId: 'u1', sessionId: 's1', name: 'photo.jpg', size: 1234, mime: 'image/jpeg')) as AttachStart;
      expect(m.uploadId, 'u1');
      expect(m.sessionId, 's1');
      expect(m.cwd, isNull);
      expect(m.name, 'photo.jpg');
      expect(m.size, 1234);
      expect(m.mime, 'image/jpeg');
    });

    test('AttachStart with a folder round-trips', () {
      final m = viaClient(const AttachStart(uploadId: 'u2', cwd: '/tmp/x', name: 'a.pdf', size: 9)) as AttachStart;
      expect(m.sessionId, isNull);
      expect(m.cwd, '/tmp/x');
      expect(m.mime, '');
    });

    test('AttachStart needs exactly one of session and folder, and a size', () {
      String frame(Map<String, dynamic> extra) =>
          jsonEncode({'type': 'attachStart', 'uploadId': 'u', 'name': 'a', 'size': 3, ...extra});
      expect(decodeClient(frame({'sessionId': 's', 'cwd': '/x'})), isNull);
      expect(decodeClient(frame({})), isNull);
      expect(decodeClient(frame({'sessionId': '', 'cwd': ''})), isNull);
      expect(decodeClient(frame({'sessionId': 's', 'size': 0})), isNull);
      expect(decodeClient(frame({'sessionId': 's'})), isA<AttachStart>());
    });

    test('AttachChunk, AttachEnd and AttachCancel round-trip', () {
      final c = viaClient(const AttachChunk(uploadId: 'u', index: 3, data: 'AAEC')) as AttachChunk;
      expect((c.uploadId, c.index, c.data), ('u', 3, 'AAEC'));
      final e = viaClient(const AttachEnd(uploadId: 'u', sha256: 'abc')) as AttachEnd;
      expect((e.uploadId, e.sha256), ('u', 'abc'));
      final x = viaClient(const AttachCancel(uploadId: 'u')) as AttachCancel;
      expect(x.uploadId, 'u');
    });
  });

  group('host messages', () {
    test('accepted, progress, done and failed round-trip', () {
      final a = viaHost(const AttachAccepted(uploadId: 'u', path: 'perch-attachments/a.png')) as AttachAccepted;
      expect((a.uploadId, a.path), ('u', 'perch-attachments/a.png'));
      final p = viaHost(const AttachProgress(uploadId: 'u', received: 2048)) as AttachProgress;
      expect((p.uploadId, p.received), ('u', 2048));
      final d = viaHost(const AttachDone(uploadId: 'u', path: 'perch-attachments/a.png')) as AttachDone;
      expect((d.uploadId, d.path), ('u', 'perch-attachments/a.png'));
      final f = viaHost(const AttachFailed(uploadId: 'u', reason: 'Files up to 20 MB')) as AttachFailed;
      expect((f.uploadId, f.reason), ('u', 'Files up to 20 MB'));
    });

    test('welcome carries attachments only when true', () {
      const on = Welcome(machineName: 'm', os: 'macos', hostVersion: '1', attachments: true);
      expect((viaHost(on) as Welcome).attachments, isTrue);
      const off = Welcome(machineName: 'm', os: 'macos', hostVersion: '1');
      expect(off.toJson().containsKey('attachments'), isFalse);
      expect((viaHost(off) as Welcome).attachments, isFalse);
    });
  });

  group('mentions', () {
    test('withAttachments adds a line of mentions', () {
      expect(withAttachments('Look at this', ['perch-attachments/a.png', 'perch-attachments/b.pdf']),
          'Look at this\n@perch-attachments/a.png @perch-attachments/b.pdf');
      expect(withAttachments('  ', ['perch-attachments/a.png']), '@perch-attachments/a.png');
      expect(withAttachments('hi', []), 'hi');
      expect(attachmentMention('perch-attachments/a.png'), '@perch-attachments/a.png');
    });

    test('splitAttachments is the inverse', () {
      final a = splitAttachments('Look at this\n@perch-attachments/a.png @perch-attachments/b.pdf');
      expect(a.text, 'Look at this');
      expect(a.paths, ['perch-attachments/a.png', 'perch-attachments/b.pdf']);
      final b = splitAttachments('@perch-attachments/a.png');
      expect(b.text, '');
      expect(b.paths, ['perch-attachments/a.png']);
      final c = splitAttachments('hi');
      expect(c.text, 'hi');
      expect(c.paths, isEmpty);
      final d = splitAttachments('see @src/main.dart');
      expect(d.text, 'see @src/main.dart');
      expect(d.paths, isEmpty);
    });
  });

  test('pieces and relay messages', () {
    expect(attachmentPieces(1), 1);
    expect(attachmentPieces(512 * 1024), 1);
    expect(attachmentPieces(512 * 1024 + 1), 2);
    expect(attachmentRelayMessages(20 * 1024 * 1024), 54);
    expect(maxAttachmentBytes, 20 * 1024 * 1024);
    expect(attachmentFolder, 'perch-attachments');
  });
}
