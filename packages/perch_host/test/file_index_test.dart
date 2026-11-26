// The files a session's composer offers after `@`: git's view of a repository (ignored files
// left out), a bounded walk of any other folder (hidden and heavy folders skipped), a cap, and
// a short cache per folder.
import 'dart:io';

import 'package:perch_host/src/file_index.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  final sep = Platform.pathSeparator;
  setUp(() => tmp = Directory.systemTemp.createTempSync('perch_files_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void file(String rel, [String text = 'x']) {
    final f = File('${tmp.path}$sep${rel.replaceAll('/', sep)}');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  Future<bool> git(List<String> args) async {
    try {
      final r = await Process.run('git', args, workingDirectory: tmp.path);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  test('a plain folder: a walk without hidden and heavy folders', () async {
    file('notes.txt');
    file('src/app.dart');
    file('src/deep/x.dart');
    file('node_modules/pkg/index.js');
    file('build/out.bin');
    file('.hidden/secret.txt');
    file('.env');
    final idx = FileIndex();
    final all = await idx.filesIn(tmp.path);
    final paths = all.files.map((f) => f.path).toSet();
    expect(paths, containsAll(['notes.txt', 'src', 'src/app.dart', 'src/deep', 'src/deep/x.dart']));
    expect(paths.where((p) => p.startsWith('node_modules') || p.startsWith('build') || p.startsWith('.')), isEmpty);
    expect(all.files.firstWhere((f) => f.path == 'src').dir, isTrue);
    expect(all.truncated, isFalse);
  });

  test('a git repository: ignored files left out, untracked ones in', () async {
    if (!await git(['init', '-q'])) return markTestSkipped('no git');
    file('.gitignore', 'secret/\n*.log\n');
    file('tracked.txt');
    file('lib/a.dart');
    file('secret/key.txt');
    file('debug.log');
    file('node_modules/kept-when-not-ignored.js');
    await git(['add', 'tracked.txt']);
    final all = await FileIndex().filesIn(tmp.path);
    final paths = all.files.map((f) => f.path).toSet();
    expect(paths, containsAll(['tracked.txt', 'lib', 'lib/a.dart', '.gitignore']));
    expect(paths, isNot(contains('secret/key.txt')));
    expect(paths, isNot(contains('debug.log')));
    expect(paths, contains('node_modules/kept-when-not-ignored.js'), reason: 'git decides in a repository');
  });

  test('a subfolder of a repository lists its own files, relative to it', () async {
    if (!await git(['init', '-q'])) return markTestSkipped('no git');
    file('top.txt');
    file('app/inner.txt');
    final all = await FileIndex().filesIn('${tmp.path}${sep}app');
    expect(all.files.map((f) => f.path), ['inner.txt']);
  });

  test('a folder git ignores as a whole is walked instead', () async {
    if (!await git(['init', '-q'])) return markTestSkipped('no git');
    file('.gitignore', 'scratch/\n');
    file('scratch/live/notes.txt');
    final all = await FileIndex().filesIn('${tmp.path}${sep}scratch$sep' 'live');
    expect(all.files.map((f) => f.path), ['notes.txt']);
  });

  test('capped, and searched with the shared matcher', () async {
    for (var i = 0; i < 30; i++) {
      file('f$i.txt');
    }
    file('notes.txt');
    final idx = FileIndex(cap: 10);
    final all = await idx.filesIn(tmp.path);
    expect(all.files, hasLength(10));
    expect(all.truncated, isTrue);
    final hits = await FileIndex().search(tmp.path, 'notes', limit: 5);
    expect(hits.files.first.path, 'notes.txt');
    expect(hits.files.length, lessThanOrEqualTo(5));
  });

  test('cached per folder for a short while', () async {
    file('a.txt');
    final idx = FileIndex(life: const Duration(minutes: 1));
    expect((await idx.filesIn(tmp.path)).files.map((f) => f.path), ['a.txt']);
    file('b.txt');
    expect((await idx.filesIn(tmp.path)).files.map((f) => f.path), ['a.txt'], reason: 'from the cache');
    final fresh = FileIndex(life: Duration.zero);
    expect((await fresh.filesIn(tmp.path)).files.map((f) => f.path), containsAll(['a.txt', 'b.txt']));
  });

  group('perch-attachments', () {
    void attachments() {
      file('perch-attachments/2026-11-26_1500_old.png');
      file('perch-attachments/2026-11-26_1612_photo.jpg');
      file('perch-attachments/.partial-abc');
      File('${tmp.path}${sep}perch-attachments${sep}2026-11-26_1500_old.png')
          .setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
    }

    const old = 'perch-attachments/2026-11-26_1500_old.png';
    const photo = 'perch-attachments/2026-11-26_1612_photo.jpg';

    test('listed newest first even though git ignores them, without partials', () async {
      if (!await git(['init', '-q'])) return markTestSkipped('no git');
      file('.git/info/exclude', '/perch-attachments/\n');
      file('src/a.dart');
      attachments();
      final all = await FileIndex().filesIn(tmp.path);
      final paths = all.files.map((f) => f.path).toList();
      expect(paths.where((p) => p.startsWith('perch-attachments/')), [photo, old]);
      expect(paths.indexOf(photo), lessThan(paths.indexOf('src/a.dart')));
      expect(paths.where((p) => p == 'perch-attachments'), hasLength(1));
      expect(paths, isNot(contains('perch-attachments/.partial-abc')));
      final none = await FileIndex().search(tmp.path, '');
      expect(none.files.map((f) => f.path), containsAll([photo, old]));
      final hit = await FileIndex().search(tmp.path, 'photo');
      expect(hit.files.first.path, photo);
    });

    test('a repository that does not ignore them lists each once', () async {
      if (!await git(['init', '-q'])) return markTestSkipped('no git');
      file('src/a.dart');
      attachments();
      final paths = (await FileIndex().filesIn(tmp.path)).files.map((f) => f.path).toList();
      expect(paths.where((p) => p == photo), hasLength(1));
      expect(paths.where((p) => p == 'perch-attachments'), hasLength(1));
    });

    test('a plain folder lists each once', () async {
      file('notes.txt');
      attachments();
      final paths = (await FileIndex().filesIn(tmp.path)).files.map((f) => f.path).toList();
      expect(paths.where((p) => p.startsWith('perch-attachments/')), [photo, old]);
      expect(paths.where((p) => p == 'perch-attachments'), hasLength(1));
    });
  });

  test('forget drops a folder from the cache so a new attachment shows at once', () async {
    file('notes.txt');
    final idx = FileIndex();
    expect((await idx.filesIn(tmp.path)).files.map((f) => f.path), isNot(contains('perch-attachments/new.png')));
    file('perch-attachments/new.png');
    expect((await idx.filesIn(tmp.path)).files.map((f) => f.path), isNot(contains('perch-attachments/new.png')),
        reason: 'cached for 30 s');
    idx.forget(tmp.path);
    expect((await idx.filesIn(tmp.path)).files.map((f) => f.path), contains('perch-attachments/new.png'));
  });

  test('no folder, or one that is gone: nothing', () async {
    expect((await FileIndex().filesIn('')).files, isEmpty);
    expect((await FileIndex().filesIn('${tmp.path}${sep}gone')).files, isEmpty);
  });
}
