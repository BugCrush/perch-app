// Folder browsing for the app's "New session" sheet.
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

/// At most this many sub-folders are returned for one folder.
const maxDirEntries = 500;

/// At most this many recent session folders are suggested (the home folder comes after).
const maxSuggestedSessionFolders = 5;

const _systemNames = {'system volume information', 'recovery', 'config.msi', 'msdownld.tmp'};

/// macOS system folders at the top of the disk: never a project folder. `home` and `net`
/// are automount points; listing `/home` from a host run in Terminal.app never finished.
const _macRootSystemNames = {'System', 'private', 'cores', 'dev', 'sbin', 'bin', 'usr', 'etc', 'var', 'tmp', 'home', 'net'};

/// How long a folder may take to show it can be read before it is left out of a listing
/// (a stuck mount must not keep the whole listing from the phone).
const readableCheckTimeout = Duration(seconds: 2);

/// Lists the sub-folders of [path], or the roots (drives on Windows, `/` elsewhere) when
/// [path] is null or empty. [sessionFolders] are working folders of current and recent
/// sessions, most recent first; they become the `suggested` shortcuts, followed by home.
/// Throws [ArgumentError] with a readable message for a missing or unreadable folder.
Future<DirListing> listDir(String? path,
    {required List<String> sessionFolders,
    Future<bool> Function(String path)? readable,
    Duration readableTimeout = readableCheckTimeout}) async {
  final check = readable ?? _readable;
  final suggested = _suggestions(sessionFolders);
  if (path == null || path.trim().isEmpty) {
    return DirListing(path: '', entries: _roots(), suggested: suggested);
  }
  var p = path.trim();
  if (Platform.isWindows && RegExp(r'^[A-Za-z]:$').hasMatch(p)) p = '$p\\';
  final dir = Directory(p);
  if (!dir.existsSync()) throw ArgumentError('The folder $p does not exist on this machine.');
  final String resolved;
  try {
    resolved = dir.resolveSymbolicLinksSync();
  } on FileSystemException catch (e) {
    throw ArgumentError('Cannot open the folder $p: ${e.osError?.message ?? e.message}');
  }

  final children = <DirEntry>[];
  try {
    await for (final e in Directory(resolved).list(followLinks: false)) {
      if (e is File) continue;
      final name = _lastSegment(e.path);
      if (_hidden(name) || (Platform.isMacOS && resolved == '/' && _macRootSystemNames.contains(name))) continue;
      final full = _join(resolved, name);
      if (e is Link && !FileSystemEntity.isDirectorySync(full)) continue;
      children.add(DirEntry(name: name, path: full));
    }
  } on FileSystemException catch (e) {
    throw ArgumentError('Cannot read the folder $resolved: ${e.osError?.message ?? e.message}');
  }
  children.sort((a, b) {
    final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return c != 0 ? c : a.name.compareTo(b.name);
  });

  // Keep readable folders only, checking in small batches until the cap is reached.
  final entries = <DirEntry>[];
  for (var i = 0; i < children.length && entries.length < maxDirEntries; i += 50) {
    final batch = children.sublist(i, i + 50 > children.length ? children.length : i + 50);
    final ok = await Future.wait(
        batch.map((e) => check(e.path).timeout(readableTimeout, onTimeout: () => false).catchError((Object _) => false)));
    for (var j = 0; j < batch.length && entries.length < maxDirEntries; j++) {
      if (ok[j]) entries.add(batch[j]);
    }
  }
  return DirListing(path: resolved, parent: _parent(resolved), entries: entries, suggested: suggested);
}

Future<bool> _readable(String path) async {
  try {
    await Directory(path).list().isEmpty;
    return true;
  } catch (_) {
    return false;
  }
}

bool _hidden(String name) =>
    name.startsWith('.') || name.startsWith(r'$') || (Platform.isWindows && _systemNames.contains(name.toLowerCase()));

bool _isRoot(String p) => Platform.isWindows ? RegExp(r'^[A-Za-z]:\\$').hasMatch(p) : p == '/';

String? _parent(String p) {
  if (_isRoot(p)) return null;
  final parent = Directory(p).parent.path;
  if (parent == p) return null;
  if (Platform.isWindows && RegExp(r'^[A-Za-z]:$').hasMatch(parent)) return '$parent\\';
  return parent;
}

String _join(String dir, String name) =>
    dir.endsWith(Platform.pathSeparator) ? '$dir$name' : '$dir${Platform.pathSeparator}$name';

String _lastSegment(String path) {
  final parts = path.split(RegExp(r'[\\/]+')).where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

List<DirEntry> _roots() {
  if (!Platform.isWindows) return const [DirEntry(name: '/', path: '/')];
  return [
    for (var c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++)
      if (Directory('${String.fromCharCode(c)}:\\').existsSync())
        DirEntry(name: '${String.fromCharCode(c)}:', path: '${String.fromCharCode(c)}:\\'),
  ];
}

String? homeFolder() {
  final env = Platform.environment;
  final h = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
  return (h == null || h.isEmpty) ? null : h;
}

List<DirEntry> _suggestions(List<String> sessionFolders) {
  String key(String p) {
    var k = p.replaceAll(RegExp(r'[\\/]+$'), '');
    if (Platform.isWindows) k = k.replaceAll('/', r'\').toLowerCase();
    // macOS disks ignore case too (APFS's default).
    if (Platform.isMacOS) k = k.toLowerCase();
    return k;
  }

  final home = homeFolder();
  final seen = <String>{if (home != null) key(home)};
  final out = <DirEntry>[];
  for (final f in sessionFolders) {
    if (out.length >= maxSuggestedSessionFolders) break;
    final p = f.trim();
    if (p.isEmpty || !seen.add(key(p)) || !Directory(p).existsSync()) continue;
    out.add(DirEntry(name: _lastSegment(p), path: p));
  }
  if (home != null && Directory(home).existsSync()) out.add(DirEntry(name: 'Home', path: home));
  return out;
}
