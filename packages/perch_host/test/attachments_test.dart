// Attachments from the phone: safe names inside `perch-attachments/`, files written in pieces
// and checked, nothing left behind on any refusal, and the folder kept out of git.
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:perch_host/src/attachments.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  final at = DateTime(2026, 11, 26, 16, 12);
  final sep = Platform.pathSeparator;

  group('attachmentFileName', () {
    test('spaces, traversal, dots, empty, Windows paths, unicode', () {
      expect(attachmentFileName('My photo (1).JPG', at), '2026-11-26_1612_My-photo-(1).JPG');
      expect(attachmentFileName('../../etc/passwd', at), '2026-11-26_1612_passwd');
      expect(attachmentFileName('.hidden', at), '2026-11-26_1612_hidden');
      expect(attachmentFileName('', at), '2026-11-26_1612_file');
      // A long name is cut by whole characters as people see them: an emoji with a skin
      // tone, a flag or an accented letter made of two code points stays whole.
      // 80 characters in all: 75 letters, then the one at the cut, then `.png`.
      for (final tail in ['👍🏽', '🇮🇳', 'é']) {
        expect(attachmentFileName('${'a' * 75}${tail}zzzz.png', at), '2026-11-26_1612_${'a' * 75}$tail.png',
            reason: 'kept whole: $tail');
      }
      // Claude Code may read `#…` after a path as a line range.
      expect(attachmentFileName('bug#2 shot.png', at), '2026-11-26_1612_bug-2-shot.png');
      expect(attachmentFileName('..', at), '2026-11-26_1612_file');
      expect(attachmentFileName('C:\\x\\y.png', at), '2026-11-26_1612_y.png');
      expect(attachmentFileName('фото.jpg', at), '2026-11-26_1612_фото.jpg');
      expect(attachmentFileName('a\tb\u0001c.txt', at), '2026-11-26_1612_a-bc.txt');
      expect(attachmentFileName('x:y.png', at), '2026-11-26_1612_xy.png');
    });

    test('a long name is cut to 80 characters and keeps its extension', () {
      final name = attachmentFileName('${'a' * 196}.png', at);
      expect(name, endsWith('.png'));
      final cleaned = name.substring('2026-11-26_1612_'.length);
      expect(cleaned.length, 80);
    });

    test('the time is padded', () {
      expect(attachmentFileName('a.png', DateTime(2026, 1, 2, 3, 4)), '2026-01-02_0304_a.png');
    });
  });

  group('AttachmentStore', () {
    late Directory tmp;
    late AttachmentStore store;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('perch_attach_');
      store = AttachmentStore(clock: () => at);
    });
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    String hex(List<int> bytes) => sha256.convert(bytes).toString();
    List<int> bytesOf(int n) {
      final r = Random(7);
      return [for (var i = 0; i < n; i++) r.nextInt(256)];
    }

    Directory attachDir([String? folder]) => Directory('${folder ?? tmp.path}$sep$attachmentFolder');
    List<String> namesIn(Directory d) =>
        d.existsSync() ? [for (final e in d.listSync()) e.uri.pathSegments.lastWhere((s) => s.isNotEmpty)] : [];

    Future<String> upload(String id, String name, List<int> bytes, {String? folder, int pieces = 1}) async {
      final u = await store.begin(uploadId: id, folder: folder ?? tmp.path, name: name, size: bytes.length);
      final step = (bytes.length / pieces).ceil();
      for (var i = 0, at = 0; at < bytes.length; i++, at += step) {
        await store.add(id, i, bytes.sublist(at, min(at + step, bytes.length)));
      }
      final path = await store.finish(id, hex(bytes));
      expect(path, u.path);
      return path;
    }

    test('a file in three pieces lands under its final name with the same bytes', () async {
      final bytes = bytesOf(3000);
      final path = await upload('u1', 'photo.jpg', bytes, pieces: 3);
      expect(path, 'perch-attachments/2026-11-26_1612_photo.jpg');
      final f = File('${tmp.path}$sep${path.replaceAll('/', sep)}');
      expect(f.readAsBytesSync(), bytes);
      expect(namesIn(attachDir()), ['2026-11-26_1612_photo.jpg']);
    });

    test('add returns the bytes so far', () async {
      await store.begin(uploadId: 'u', folder: tmp.path, name: 'a', size: 10);
      expect(await store.add('u', 0, bytesOf(4)), 4);
      expect(await store.add('u', 1, bytesOf(6)), 10);
    });

    test('the same name in the same minute gets -2, also while the first is still uploading', () async {
      final a = await store.begin(uploadId: 'a', folder: tmp.path, name: 'photo.jpg', size: 1);
      final b = await store.begin(uploadId: 'b', folder: tmp.path, name: 'photo.jpg', size: 1);
      expect(a.path, 'perch-attachments/2026-11-26_1612_photo.jpg');
      expect(b.path, 'perch-attachments/2026-11-26_1612_photo-2.jpg');
      await store.add('a', 0, [1]);
      await store.finish('a', hex([1]));
      await store.cancel('b');
      final c = await store.begin(uploadId: 'c', folder: tmp.path, name: 'photo.jpg', size: 1);
      expect(c.path, 'perch-attachments/2026-11-26_1612_photo-2.jpg');
    });

    test('two uploads at once do not mix their pieces', () async {
      final x = bytesOf(100), y = [for (var i = 0; i < 100; i++) 255 - x[i]];
      await store.begin(uploadId: 'x', folder: tmp.path, name: 'x.bin', size: 100);
      await store.begin(uploadId: 'y', folder: tmp.path, name: 'y.bin', size: 100);
      await store.add('x', 0, x.sublist(0, 50));
      await store.add('y', 0, y.sublist(0, 50));
      await store.add('x', 1, x.sublist(50));
      await store.add('y', 1, y.sublist(50));
      final px = await store.finish('x', hex(x));
      final py = await store.finish('y', hex(y));
      expect(File('${tmp.path}/$px').readAsBytesSync(), x);
      expect(File('${tmp.path}/$py').readAsBytesSync(), y);
    });

    Future<void> refused(Future<Object?> Function() f, String reason) async {
      await expectLater(f(), throwsA(isA<AttachmentRefused>().having((e) => e.reason, 'reason', reason)));
      expect(namesIn(attachDir()), isEmpty, reason: 'nothing left behind');
    }

    test('over 20 MB is refused', () async {
      await refused(
          () => store.begin(uploadId: 'u', folder: tmp.path, name: 'a', size: maxAttachmentBytes + 1),
          'Files up to 20 MB');
    });

    test('a piece out of order is refused and the partial deleted', () async {
      await store.begin(uploadId: 'u', folder: tmp.path, name: 'a', size: 10);
      await store.add('u', 0, bytesOf(5));
      await refused(() => store.add('u', 2, bytesOf(5)), 'The upload went wrong; try again');
      await refused(() => store.add('u', 1, bytesOf(5)), 'The upload went wrong; try again');
    });

    test('more bytes than announced are refused', () async {
      await store.begin(uploadId: 'u', folder: tmp.path, name: 'a', size: 4);
      await refused(() => store.add('u', 0, bytesOf(5)), 'The upload went wrong; try again');
    });

    test('a wrong hash or a short file is refused', () async {
      await store.begin(uploadId: 'u', folder: tmp.path, name: 'a', size: 4);
      await store.add('u', 0, [1, 2, 3, 4]);
      await refused(() => store.finish('u', hex([1, 2, 3, 5])), 'The upload went wrong; try again');
      await store.begin(uploadId: 'v', folder: tmp.path, name: 'a', size: 4);
      await store.add('v', 0, [1, 2, 3]);
      await refused(() => store.finish('v', hex([1, 2, 3])), 'The upload went wrong; try again');
    });

    test('an unknown upload or a bad upload id is refused', () async {
      await refused(() => store.add('nope', 0, [1]), 'The upload went wrong; try again');
      await refused(
          () => store.begin(uploadId: '../x', folder: tmp.path, name: 'a', size: 1), 'The upload went wrong; try again');
    });

    test('a folder that is gone is refused', () async {
      await expectLater(store.begin(uploadId: 'u', folder: '${tmp.path}${sep}gone', name: 'a', size: 1),
          throwsA(isA<AttachmentRefused>().having((e) => e.reason, 'reason', 'This session has ended')));
      expect(Directory('${tmp.path}${sep}gone').existsSync(), isFalse);
    });

    test('perch-attachments that is a file or a symbolic link is refused', () async {
      File('${tmp.path}$sep$attachmentFolder').writeAsStringSync('x');
      await expectLater(store.begin(uploadId: 'u', folder: tmp.path, name: 'a', size: 1),
          throwsA(isA<AttachmentRefused>().having((e) => e.reason, 'reason', 'perch-attachments is not a folder')));
      File('${tmp.path}$sep$attachmentFolder').deleteSync();
      final elsewhere = Directory('${tmp.path}${sep}elsewhere')..createSync();
      Link('${tmp.path}$sep$attachmentFolder').createSync(elsewhere.path);
      await expectLater(store.begin(uploadId: 'u', folder: tmp.path, name: 'a', size: 1),
          throwsA(isA<AttachmentRefused>().having((e) => e.reason, 'reason', 'perch-attachments is not a folder')));
      expect(elsewhere.listSync(), isEmpty);
    });

    test('cancel deletes the partial', () async {
      await store.begin(uploadId: 'u', folder: tmp.path, name: 'a', size: 10);
      await store.add('u', 0, bytesOf(5));
      expect(namesIn(attachDir()), ['.partial-u']);
      await store.cancel('u');
      expect(namesIn(attachDir()), isEmpty);
    });

    test('sweep deletes partials older than an hour only', () async {
      final d = attachDir()..createSync();
      final old = File('${d.path}$sep.partial-old')..writeAsStringSync('x');
      old.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
      File('${d.path}$sep.partial-fresh').writeAsStringSync('x');
      final done = File('${d.path}${sep}2026-01-01_0000_a.png')..writeAsStringSync('x');
      done.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 30)));
      await store.sweep(tmp.path);
      expect(namesIn(d)..sort(), ['.partial-fresh', '2026-01-01_0000_a.png']);
    });

    group('git', () {
      Future<String> git(List<String> args, {String? dir}) async {
        final r = await Process.run('git', args, workingDirectory: dir ?? tmp.path);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return (r.stdout as String).trim();
      }

      Future<void> repo([String? dir]) async {
        await git(['init', '-q'], dir: dir);
        await git(['config', 'user.email', 'test@example.invalid'], dir: dir);
        await git(['config', 'user.name', 'Test'], dir: dir);
      }

      List<String> excludeLines(String path) =>
          File(path).existsSync() ? File(path).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList() : [];

      test('a folder outside git gets no exclude', () async {
        await upload('u', 'a.png', [1, 2]);
        expect(Directory('${tmp.path}$sep.git').existsSync(), isFalse);
      });

      test('the repository top: one exclude line after two uploads, and git status stays clean', () async {
        await repo();
        await upload('u', 'a.png', [1, 2]);
        await upload('v', 'b.png', [3, 4]);
        final lines = excludeLines('${tmp.path}/.git/info/exclude');
        expect(lines.where((l) => l == '/perch-attachments/'), hasLength(1));
        expect(await git(['status', '--porcelain']), isEmpty);
      });

      test('a subfolder of a repository', () async {
        await repo();
        final sub = Directory('${tmp.path}${sep}sub${sep}dir')..createSync(recursive: true);
        await upload('u', 'a.png', [1, 2], folder: sub.path);
        expect(excludeLines('${tmp.path}/.git/info/exclude'), contains('/sub/dir/perch-attachments/'));
        expect(await git(['status', '--porcelain']), isEmpty);
      });

      // Git reads exclude lines as patterns: `[ ] * ? \` in a folder's name must be escaped,
      // or the line matches something else (or nothing) and git lists the attachment.
      test('a folder with glob characters, spaces and non-Latin letters stays out of git', () async {
        await repo();
        final name = Platform.isWindows ? 'a[1] b фото' : 'a[1] b*c?d фото';
        final sub = Directory('${tmp.path}$sep$name')..createSync(recursive: true);
        await upload('u', 'a.png', [1, 2], folder: sub.path);
        expect(await git(['status', '--porcelain', '--untracked-files=all']), isEmpty);
        expect(excludeLines('${tmp.path}/.git/info/exclude').where((l) => !l.startsWith('#')).single, startsWith(r'/a\[1\]'));
      });

      test('a linked worktree uses its own info/exclude', () async {
        await repo();
        File('${tmp.path}${sep}README').writeAsStringSync('x');
        await git(['add', 'README']);
        await git(['commit', '-qm', 'init']);
        final wt = '${tmp.path}${sep}wt';
        await git(['worktree', 'add', '-q', '-b', 'side', wt]);
        await upload('u', 'a.png', [1, 2], folder: wt);
        final own = await git(['rev-parse', '--git-path', 'info/exclude'], dir: wt);
        final ownPath = File(own).isAbsolute ? own : '$wt$sep$own';
        expect(excludeLines(ownPath), contains('/perch-attachments/'));
        expect(await git(['status', '--porcelain'], dir: wt), isEmpty);
      });
    });
  });
}
