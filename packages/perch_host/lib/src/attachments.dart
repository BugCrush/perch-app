// Attachments from the phone: files written in pieces into `<session folder>/perch-attachments/`
// under a safe, never-overwriting name, checked by length and SHA-256, and kept out of git through
// the repository's local exclude. Partial files never outlive their upload.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';
import 'package:perch_protocol/perch_protocol.dart';

/// Reasons the phone shows as they are.
abstract final class AttachmentReasons {
  static const tooBig = 'Files up to 20 MB';
  static const sessionEnded = 'This session has ended';
  static const diskFull = "The machine's disk is full";
  static const notAFolder = 'perch-attachments is not a folder';
  static const wentWrong = 'The upload went wrong; try again';
}

/// An upload refused or broken; nothing of it is left on disk.
class AttachmentRefused implements Exception {
  final String reason;
  const AttachmentRefused(this.reason);
  @override
  String toString() => 'AttachmentRefused: $reason';
}

/// An upload the store accepted; [path] is relative to the session's folder
/// (`perch-attachments/<final name>`, forward slashes).
class Upload {
  final String uploadId;
  final String path;

  /// The file's size in bytes, as announced.
  final int size;

  /// The session folder the attachment goes into.
  final String folder;
  const Upload({required this.uploadId, required this.path, required this.size, this.folder = ''});
}

const _maxNameChars = 80;
const _maxExtensionChars = 16;
const _timePrefixLength = 'yyyy-MM-dd_HHmm_'.length;

/// The name an attachment called [original] gets: its last path segment without control
/// characters, separators, characters Windows refuses and leading dots, spaces turned into `-`
/// (an `@` mention ends at a space), cut to 80 characters keeping the extension (`file` when
/// nothing is left), after the local time `yyyy-MM-dd_HHmm_`.
String attachmentFileName(String original, DateTime now) {
  final segment = original.split(RegExp(r'[/\\]')).last;
  var name = segment
      // Spaces end an @ mention; Claude Code may read `#…` after a path as a line range.
      .replaceAll(RegExp(r'[\s#]+'), '-')
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f:<>"|?*]'), '')
      .replaceFirst(RegExp(r'^\.+'), '')
      // Windows drops trailing dots from file names.
      .replaceFirst(RegExp(r'\.+$'), '');
  if (name.isEmpty) name = 'file';
  // Counted and cut by characters as people see them (an emoji with a skin tone, a flag,
  // an accented letter made of two code points stays whole).
  if (name.characters.length > _maxNameChars) {
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot) : '';
    final keep = ext.characters.length <= _maxExtensionChars ? ext : '';
    final base = (keep.isEmpty ? name : name.substring(0, dot)).characters.take(_maxNameChars - keep.characters.length);
    name = base.toString() + keep;
  }
  String two(int n) => n.toString().padLeft(2, '0');
  return '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}_${two(now.hour)}${two(now.minute)}_$name';
}

typedef GitRunner = Future<ProcessResult> Function(String executable, List<String> arguments,
    {String? workingDirectory});

Future<ProcessResult> _processRun(String executable, List<String> arguments, {String? workingDirectory}) =>
    // git prints paths as UTF-8; the default (the Windows code page) garbled a non-Latin folder
    // name, so its exclude line matched nothing.
    Process.run(executable, arguments, workingDirectory: workingDirectory, stdoutEncoding: utf8, stderrEncoding: utf8);

class _Open {
  final String uploadId;
  final String dir;
  final String finalName;
  final int size;
  final File partial;
  final RandomAccessFile raf;
  final _DigestSink digest = _DigestSink();
  late final ByteConversionSink hasher = sha256.startChunkedConversion(digest);
  int next = 0;
  int written = 0;
  Future<void> tail = Future.value();
  _Open(this.uploadId, this.dir, this.finalName, this.size, this.partial, this.raf);
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

final _uploadIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Owns the uploads in progress (one partial file each).
class AttachmentStore {
  final DateTime Function() _clock;
  final GitRunner _run;
  final _open = <String, _Open>{};

  AttachmentStore({DateTime Function()? clock, GitRunner? run})
      : _clock = clock ?? DateTime.now,
        _run = run ?? _processRun;

  String get _sep => Platform.pathSeparator;

  /// Opens an upload of [size] bytes called [name] into [folder]`/perch-attachments/`.
  Future<Upload> begin(
      {required String uploadId, required String folder, required String name, required int size}) async {
    if (size > maxAttachmentBytes) throw const AttachmentRefused(AttachmentReasons.tooBig);
    if (size <= 0 || !_uploadIdPattern.hasMatch(uploadId) || _open.containsKey(uploadId)) {
      throw const AttachmentRefused(AttachmentReasons.wentWrong);
    }
    if (!Directory(folder).existsSync()) throw const AttachmentRefused(AttachmentReasons.sessionEnded);
    final dir = '$folder$_sep$attachmentFolder';
    final kind = FileSystemEntity.typeSync(dir, followLinks: false);
    if (kind != FileSystemEntityType.notFound && kind != FileSystemEntityType.directory) {
      throw const AttachmentRefused(AttachmentReasons.notAFolder);
    }
    await sweep(folder);
    final File partial;
    final RandomAccessFile raf;
    final String finalName;
    try {
      Directory(dir).createSync(recursive: true);
      finalName = _freeName(dir, attachmentFileName(name, _clock()));
      partial = File('$dir$_sep.partial-$uploadId');
      raf = partial.openSync(mode: FileMode.write);
    } on FileSystemException catch (e) {
      throw AttachmentRefused(_reasonFor(e));
    }
    _open[uploadId] = _Open(uploadId, dir, finalName, size, partial, raf);
    await _exclude(folder);
    return Upload(uploadId: uploadId, path: '$attachmentFolder/$finalName', size: size, folder: folder);
  }

  /// Writes piece [index] (the next one in order); returns the bytes written so far.
  Future<int> add(String uploadId, int index, List<int> bytes) =>
      _serial(uploadId, (u) async {
        if (index != u.next || u.written + bytes.length > u.size) {
          throw const AttachmentRefused(AttachmentReasons.wentWrong);
        }
        try {
          await u.raf.writeFrom(bytes);
        } on FileSystemException catch (e) {
          throw AttachmentRefused(_reasonFor(e));
        }
        u.hasher.add(bytes);
        u.next++;
        u.written += bytes.length;
        return u.written;
      });

  /// Checks the length and [sha256] (hex), gives the file its final name and returns its path
  /// relative to the session's folder.
  Future<String> finish(String uploadId, String sha256) => _serial(uploadId, (u) async {
        await u.raf.close();
        u.hasher.close();
        if (u.written != u.size || u.digest.value.toString() != sha256.toLowerCase()) {
          throw const AttachmentRefused(AttachmentReasons.wentWrong);
        }
        _open.remove(uploadId);
        var name = u.finalName;
        if (FileSystemEntity.typeSync('${u.dir}$_sep$name', followLinks: false) != FileSystemEntityType.notFound) {
          name = _freeName(u.dir, name);
        }
        try {
          await u.partial.rename('${u.dir}$_sep$name');
        } on FileSystemException catch (e) {
          _deleteQuietly(u.partial);
          throw AttachmentRefused(_reasonFor(e));
        }
        return '$attachmentFolder/$name';
      });

  /// Drops an unfinished upload and its partial file (nothing for an unknown one).
  Future<void> cancel(String uploadId) async {
    final u = _open.remove(uploadId);
    if (u == null) return;
    try {
      await u.tail;
    } catch (_) {}
    await _discard(u);
  }

  /// Whether [uploadId] is open.
  bool isOpen(String uploadId) => _open.containsKey(uploadId);

  /// Deletes partial files in [folder]`/perch-attachments/` older than [olderThan] (left by a
  /// host that stopped mid-upload); finished attachments are never touched.
  Future<void> sweep(String folder, {Duration olderThan = const Duration(hours: 1)}) async {
    final dir = Directory('$folder$_sep$attachmentFolder');
    if (FileSystemEntity.typeSync(dir.path, followLinks: false) != FileSystemEntityType.directory) return;
    final cutoff = DateTime.now().subtract(olderThan);
    final mine = {for (final u in _open.values) u.partial.path};
    try {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (!name.startsWith('.partial-') || mine.contains(e.path)) continue;
        try {
          if (e.lastModifiedSync().isBefore(cutoff)) e.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<T> _serial<T>(String uploadId, Future<T> Function(_Open u) op) {
    final u = _open[uploadId];
    if (u == null) return Future.error(const AttachmentRefused(AttachmentReasons.wentWrong));
    final result = u.tail.then((_) async {
      if (!identical(_open[uploadId], u)) throw const AttachmentRefused(AttachmentReasons.wentWrong);
      try {
        return await op(u);
      } on AttachmentRefused {
        if (identical(_open[uploadId], u)) _open.remove(uploadId);
        await _discard(u);
        rethrow;
      }
    });
    u.tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _discard(_Open u) async {
    try {
      await u.raf.close();
    } catch (_) {}
    _deleteQuietly(u.partial);
  }

  void _deleteQuietly(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// [wanted], or `-2`, `-3`… before its extension while a file or an open upload has the name
  /// (case folded: the Mac's and Windows' file systems ignore case).
  String _freeName(String dir, String wanted) {
    final taken = {
      for (final u in _open.values)
        if (u.dir == dir) u.finalName.toLowerCase()
    };
    final dot = wanted.lastIndexOf('.');
    // The extension is after the last dot of the cleaned name (after `yyyy-MM-dd_HHmm_`).
    final hasExt = dot > _timePrefixLength;
    final base = hasExt ? wanted.substring(0, dot) : wanted;
    final ext = hasExt ? wanted.substring(dot) : '';
    for (var n = 1;; n++) {
      final name = n == 1 ? wanted : '$base-$n$ext';
      if (taken.contains(name.toLowerCase())) continue;
      if (FileSystemEntity.typeSync('$dir$_sep$name', followLinks: false) != FileSystemEntityType.notFound) continue;
      return name;
    }
  }

  String _reasonFor(FileSystemException e) {
    final code = e.osError?.errorCode;
    // ENOSPC on Linux and the Mac; ERROR_DISK_FULL and ERROR_HANDLE_DISK_FULL on Windows.
    final full = Platform.isWindows ? (code == 112 || code == 39) : code == 28;
    return full ? AttachmentReasons.diskFull : AttachmentReasons.wentWrong;
  }

  /// Adds `/<folder relative to the work tree's top>/perch-attachments/` to the repository's
  /// local exclude (`info/exclude`, never committed) once, when [folder] is in a git work tree.
  Future<void> _exclude(String folder) async {
    try {
      final r = await _run('git', ['rev-parse', '--is-inside-work-tree', '--show-prefix', '--git-path', 'info/exclude'],
          workingDirectory: folder);
      if (r.exitCode != 0) return;
      final lines = (r.stdout as String).replaceAll('\r', '').split('\n');
      if (lines.length < 3 || lines[0].trim() != 'true') return;
      final prefix = lines[1].trim();
      final excludePath = lines[2].trim();
      if (excludePath.isEmpty) return;
      final file = File(File(excludePath).isAbsolute ? excludePath : '$folder$_sep$excludePath');
      final line = '/${gitPatternEscape(prefix)}$attachmentFolder/';
      final existing = file.existsSync() ? file.readAsStringSync() : '';
      if (existing.replaceAll('\r', '').split('\n').any((l) => l.trim() == line)) return;
      file.parent.createSync(recursive: true);
      final lead = existing.isEmpty || existing.endsWith('\n') ? '' : '\n';
      file.writeAsStringSync('$lead$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Git missing or the exclude not writable: the upload still works, git may list the file.
    }
  }
}

/// [path] as a literal in a gitignore pattern: `[ ] * ? \` and `!` / `#` are escaped with a
/// backslash, and a trailing space too (git would drop it).
String gitPatternEscape(String path) {
  final out = StringBuffer();
  for (final ch in path.characters) {
    if (const ['[', ']', '*', '?', '\\', '!', '#'].contains(ch)) out.write('\\');
    out.write(ch);
  }
  final s = out.toString();
  return s.endsWith(' ') ? '${s.substring(0, s.length - 1)}\\ ' : s;
}
