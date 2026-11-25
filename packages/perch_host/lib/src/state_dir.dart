import 'dart:io';

/// Where the host keeps its own files: `PERCH_STATE_DIR` when set (a test host beside the
/// owner's), else `%APPDATA%\perch` on Windows, `~/.perch` elsewhere.
String stateDirectory({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final own = env['PERCH_STATE_DIR'];
  if (own != null && own.isNotEmpty) return own;
  if (Platform.isWindows) {
    final appData = env['APPDATA'] ?? (env['USERPROFILE'] ?? '.') + r'\AppData\Roaming';
    return '$appData${Platform.pathSeparator}perch';
  }
  return '${env['HOME'] ?? '.'}/.perch';
}

/// The file in the state folder that names the port `serve` listens on. The Perch plugin's
/// hooks and its `/perch` menu read it, so one plugin serves every machine and port.
const perchPortFile = 'port';

/// Writes [port] to the state folder's port file (digits and a newline, nothing else, so a
/// shell's `read` takes it).
void writePortFile(String stateDir, int port) {
  try {
    Directory(stateDir).createSync(recursive: true);
    File('$stateDir${Platform.pathSeparator}$perchPortFile').writeAsStringSync('$port\n');
  } catch (_) {}
}

/// The port in the state folder's port file, or null.
int? readPortFile(String stateDir) {
  try {
    return int.tryParse(File('$stateDir${Platform.pathSeparator}$perchPortFile').readAsStringSync().trim());
  } catch (_) {
    return null;
  }
}
