import 'dart:async';
import 'dart:io';

import 'package:perch_host/src/dir_browser.dart';
import 'package:test/test.dart';

void main() {
  final sep = Platform.pathSeparator;
  late Directory tmp;
  late String root; // resolved path of tmp

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_dirs_');
    root = tmp.resolveSymbolicLinksSync();
    for (final name in ['beta', 'Alpha', 'gamma', '.hidden', r'$system']) {
      Directory('$root$sep$name').createSync();
    }
    File('$root${sep}a-file.txt').writeAsStringSync('x');
    Directory('$root${sep}beta${sep}inner').createSync();
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('lists_only_directories_sorted_with_parent', () async {
    final l = await listDir(root, sessionFolders: const []);
    expect(l.path, root);
    expect(l.parent, tmp.parent.resolveSymbolicLinksSync());
    expect(l.entries.map((e) => e.name).toList(), ['Alpha', 'beta', 'gamma']);
    expect(l.entries[1].path, '$root${sep}beta');

    final inner = await listDir(l.entries[1].path, sessionFolders: const []);
    expect(inner.parent, root);
    expect(inner.entries.single.name, 'inner');
  });

  test('missing_or_file_path_errors', () async {
    await expectLater(listDir('$root${sep}nope', sessionFolders: const []),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains('does not exist'))));
    await expectLater(
        listDir('$root${sep}a-file.txt', sessionFolders: const []), throwsA(isA<ArgumentError>()));
  });

  test('entries_are_capped', () async {
    final big = Directory('$root${sep}big')..createSync();
    for (var i = 0; i < maxDirEntries + 20; i++) {
      Directory('${big.path}${sep}d${i.toString().padLeft(4, '0')}').createSync();
    }
    final l = await listDir(big.path, sessionFolders: const []);
    expect(l.entries.length, maxDirEntries);
    expect(l.entries.first.name, 'd0000');
  });

  test('roots_and_suggestions', () async {
    final l = await listDir(null, sessionFolders: ['$root${sep}beta', '$root${sep}gamma', '$root${sep}BETA', '$root${sep}gone']);
    expect(l.path, '');
    expect(l.parent, isNull);
    if (Platform.isWindows) {
      expect(l.entries.map((e) => e.path), contains(r'C:\'));
      expect(l.entries.every((e) => RegExp(r'^[A-Z]:\\$').hasMatch(e.path)), isTrue);
    } else {
      expect(l.entries.single.path, '/');
    }
    // Recent session folders first (de-duplicated, existing only), home last.
    final s = l.suggested.map((e) => e.path).toList();
    expect(s.first, '$root${sep}beta');
    expect(s[1], '$root${sep}gamma');
    expect(s.length, 3);
    expect(l.suggested.last.name, 'Home');
    expect(Directory(s.last).existsSync(), isTrue);

    final many = await listDir('', sessionFolders: [for (final n in ['Alpha', 'beta', 'gamma', '.hidden', r'$system', 'beta${sep}inner']) '$root$sep$n']);
    expect(many.suggested.length, 6); // at most 5 session folders plus home
    expect(many.suggested.last.name, 'Home');

    // A drive root has no parent.
    final top = await listDir(l.entries.first.path, sessionFolders: const []);
    expect(top.parent, isNull);
  });

  test('mac_root_skips_system_folders', () async {
    if (!Platform.isMacOS) return markTestSkipped('macOS only');
    final names = (await listDir('/', sessionFolders: const [])).entries.map((e) => e.name).toList();
    expect(names, contains('Users'));
    expect(names, isNot(contains('System')));
    expect(names, isNot(contains('private')));
  });

  test('mac_root_skips_automount_folders', () async {
    // /home and /net are automount points: never project folders, and from a host run in
    // Terminal.app listing /home never finished, so "/" got no answer (found 2026-11-17).
    if (!Platform.isMacOS) return markTestSkipped('macOS only');
    final names = (await listDir('/', sessionFolders: const [])).entries.map((e) => e.name).toList();
    expect(names, isNot(contains('home')));
    expect(names, isNot(contains('net')));
  });

  test('a_folder_whose_check_never_answers_does_not_block_the_listing', () async {
    final never = Completer<bool>().future;
    final sw = Stopwatch()..start();
    final l = await listDir(root,
        sessionFolders: const [],
        readable: (p) => p.endsWith('${sep}beta') ? never : Future.value(true),
        readableTimeout: const Duration(milliseconds: 200));
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    expect(l.entries.map((e) => e.name).toList(), ['Alpha', 'gamma']);
  });
}
