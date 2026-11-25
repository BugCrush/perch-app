import 'dart:io';

import 'package:perch_host/src/token_vault.dart';
import 'package:test/test.dart';

const token = 'sk-ant-oat01-SYNTHETIC-vault-test-000000000000000000000000000000000000000';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('perch_vault_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('ids are checked before they reach a file name or a command', () {
    expect(validAccountId('acc-1_A'), isTrue);
    expect(validAccountId('../x'), isFalse);
    expect(validAccountId(''), isFalse);
    expect(validAccountId('a b'), isFalse);
    expect(validAccountId('x' * 65), isFalse);
  });

  test('memory vault', () async {
    final v = MemoryTokenVault();
    await v.put('a', token);
    expect(await v.get('a'), token);
    await v.remove('a');
    expect(await v.get('a'), isNull);
  });

  test('windows vault keeps only a DPAPI blob on disk (real PowerShell)', () async {
    final v = WindowsDpapiVault(directory: tmp.path);
    await v.put('acc-1', token);
    final files = Directory(tmp.path).listSync(recursive: true).whereType<File>().toList();
    expect(files, hasLength(1));
    final onDisk = files.single.readAsStringSync();
    expect(onDisk, isNot(contains('sk-ant')));
    expect(onDisk, isNot(contains('SYNTHETIC')));
    expect(await v.get('acc-1'), token);
    expect(await v.get('acc-2'), isNull);
    await v.remove('acc-1');
    expect(await v.get('acc-1'), isNull);
    expect(Directory(tmp.path).listSync(recursive: true).whereType<File>(), isEmpty);
  }, skip: Platform.isWindows ? false : 'Windows only');

  test('windows vault passes the token on stdin, never in the arguments', () async {
    final calls = <({List<String> args, String stdin})>[];
    final v = WindowsDpapiVault(
        directory: tmp.path,
        run: (args, input) async {
          calls.add((args: args, stdin: input));
          return 'QkxPQg=='; // "BLOB"
        });
    await v.put('acc-1', token);
    expect(calls.single.stdin, token);
    expect(calls.single.args.join(' '), isNot(contains('sk-ant')));
  });

  test('mac keychain vault sends commands on stdin and reads with -w', () async {
    final calls = <({List<String> args, String stdin})>[];
    final v = MacKeychainVault(run: (args, input) async {
      calls.add((args: args, stdin: input));
      if (args.contains('find-generic-password')) return '$token\n';
      return '';
    });
    await v.put('acc-1', token);
    expect(calls.single.args, ['-i']);
    expect(calls.single.stdin, contains('add-generic-password'));
    expect(calls.single.stdin, contains('-s perch-claude-account'));
    expect(calls.single.stdin, contains('-a acc-1'));
    expect(await v.get('acc-1'), token);
    expect(calls.last.args, containsAllInOrder(['find-generic-password', '-a', 'acc-1', '-s', 'perch-claude-account', '-w']));
  });

  test('file vault (other platforms) writes a file only the owner can read', () async {
    final v = FileTokenVault(directory: tmp.path);
    await v.put('acc-1', token);
    expect(await v.get('acc-1'), token);
    await v.remove('acc-1');
    expect(await v.get('acc-1'), isNull);
  });

  test('a bad id is refused', () async {
    final v = MemoryTokenVault();
    expect(() => v.put('../x', token), throwsArgumentError);
  });
}
