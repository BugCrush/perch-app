// Where the host keeps account tokens: protected storage, never host.json. Windows: a
// DPAPI blob per account (current user) in `<state dir>/accounts`; macOS: the login
// Keychain (`security`); elsewhere a file only the owner can read. Tokens never appear in
// a command line or a log: they travel on stdin.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Account ids become file names and Keychain account names: letters, digits, `-`, `_`.
bool validAccountId(String id) => RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id);

void _check(String id) {
  if (!validAccountId(id)) throw ArgumentError('Not an account id: $id');
}

abstract class TokenVault {
  Future<void> put(String accountId, String token);

  /// The token, or null when there is none (or it cannot be read).
  Future<String?> get(String accountId);
  Future<void> remove(String accountId);
}

/// Runs a helper with [args], writes [stdin] to it, returns its stdout.
typedef VaultRunner = Future<String> Function(List<String> args, String stdin);

Future<String> _runWithStdin(String executable, List<String> args, String input) async {
  final p = await Process.start(executable, args);
  p.stdin.write(input);
  await p.stdin.close();
  final err = p.stderr.drain<void>();
  final out = await p.stdout.transform(const Utf8Decoder(allowMalformed: true)).join().timeout(const Duration(seconds: 30));
  await err;
  final code = await p.exitCode;
  if (code != 0) throw StateError('$executable failed ($code)');
  return out;
}

class MemoryTokenVault implements TokenVault {
  final Map<String, String> tokens = {};
  @override
  Future<void> put(String accountId, String token) async {
    _check(accountId);
    tokens[accountId] = token;
  }

  @override
  Future<String?> get(String accountId) async => validAccountId(accountId) ? tokens[accountId] : null;

  @override
  Future<void> remove(String accountId) async => tokens.remove(accountId);
}

/// Windows: `ProtectedData.Protect` (DPAPI, CurrentUser) through PowerShell; the blob is
/// base64 in `<directory>/<id>.dpapi`.
class WindowsDpapiVault implements TokenVault {
  final String directory;
  final VaultRunner _run;
  WindowsDpapiVault({required this.directory, VaultRunner? run})
      : _run = run ?? ((args, input) => _runWithStdin('powershell.exe', args, input));

  static const _entropy = 'perch-claude-account';

  static List<String> _args(String script) => [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        base64Encode([for (final u in script.codeUnits) ...[u & 0xff, u >> 8]]),
      ];

  static const _protect = '''
Add-Type -AssemblyName System.Security
\$in = [Console]::In.ReadToEnd()
\$enc = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes(\$in), [Text.Encoding]::UTF8.GetBytes('$_entropy'), 'CurrentUser')
[Console]::Out.Write([Convert]::ToBase64String(\$enc))
''';

  static const _unprotect = '''
Add-Type -AssemblyName System.Security
\$in = [Console]::In.ReadToEnd().Trim()
\$dec = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String(\$in), [Text.Encoding]::UTF8.GetBytes('$_entropy'), 'CurrentUser')
[Console]::Out.Write([Text.Encoding]::UTF8.GetString(\$dec))
''';

  File _file(String id) => File('$directory${Platform.pathSeparator}$id.dpapi');

  @override
  Future<void> put(String accountId, String token) async {
    _check(accountId);
    final blob = (await _run(_args(_protect), token)).trim();
    if (blob.isEmpty) throw StateError('Windows could not protect the token.');
    Directory(directory).createSync(recursive: true);
    _file(accountId).writeAsStringSync(blob, flush: true);
  }

  @override
  Future<String?> get(String accountId) async {
    if (!validAccountId(accountId)) return null;
    final f = _file(accountId);
    if (!f.existsSync()) return null;
    try {
      final t = await _run(_args(_unprotect), f.readAsStringSync());
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> remove(String accountId) async {
    if (!validAccountId(accountId)) return;
    try {
      _file(accountId).deleteSync();
    } catch (_) {}
  }
}

/// macOS: a generic password in the login Keychain (service `perch-claude-account`,
/// account = the id). Writes go through `security -i` so the token is not on a command line.
class MacKeychainVault implements TokenVault {
  static const service = 'perch-claude-account';
  final VaultRunner _run;
  MacKeychainVault({VaultRunner? run}) : _run = run ?? ((args, input) => _runWithStdin('/usr/bin/security', args, input));

  static String _quote(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  @override
  Future<void> put(String accountId, String token) async {
    _check(accountId);
    await _run(['-i'], 'add-generic-password -U -a $accountId -s $service -w ${_quote(token)}\n');
  }

  @override
  Future<String?> get(String accountId) async {
    if (!validAccountId(accountId)) return null;
    try {
      final t = (await _run(['find-generic-password', '-a', accountId, '-s', service, '-w'], '')).trim();
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> remove(String accountId) async {
    if (!validAccountId(accountId)) return;
    try {
      await _run(['delete-generic-password', '-a', accountId, '-s', service], '');
    } catch (_) {}
  }
}

/// Other platforms: one file per token, readable by the owner only (mode 600).
class FileTokenVault implements TokenVault {
  final String directory;
  FileTokenVault({required this.directory});

  File _file(String id) => File('$directory${Platform.pathSeparator}$id.token');

  @override
  Future<void> put(String accountId, String token) async {
    _check(accountId);
    Directory(directory).createSync(recursive: true);
    final f = _file(accountId);
    f.writeAsStringSync('', flush: true);
    if (!Platform.isWindows) await Process.run('chmod', ['600', f.path]);
    f.writeAsStringSync(token, flush: true);
  }

  @override
  Future<String?> get(String accountId) async {
    if (!validAccountId(accountId)) return null;
    try {
      final t = _file(accountId).readAsStringSync().trim();
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> remove(String accountId) async {
    if (!validAccountId(accountId)) return;
    try {
      _file(accountId).deleteSync();
    } catch (_) {}
  }
}

/// The platform's protected storage for this host's state folder.
TokenVault defaultTokenVault(String stateDir) {
  final dir = '$stateDir${Platform.pathSeparator}accounts';
  if (Platform.isWindows) return WindowsDpapiVault(directory: dir);
  if (Platform.isMacOS) return MacKeychainVault();
  return FileTokenVault(directory: dir);
}
