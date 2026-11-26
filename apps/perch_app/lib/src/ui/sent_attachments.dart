// The images this phone sent as attachments, kept so the conversation can show them small
// under the message (the machine has the originals; the phone only keeps its own copy).
// In memory for this run (bounded), and on disk in the app's cache folder for later runs.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

abstract final class SentAttachmentCache {
  /// At most this many bytes of images in memory (the oldest go first).
  static int memoryLimit = 48 * 1024 * 1024;

  /// The folder of the disk copies (replaced in tests; null: the app's cache folder).
  static Future<Directory?> Function() folder = _defaultFolder;

  static final _memory = <String, Uint8List>{};
  static int _bytes = 0;

  /// Machine, session folder and path: the same file name sent into two sessions' folders in
  /// the same minute is two attachments.
  static String _key(String machineId, String folder, String path) => '$machineId\n$folder\n$path';

  static Future<Directory?> _defaultFolder() async {
    if (kIsWeb) return null;
    try {
      return Directory('${(await getApplicationCacheDirectory()).path}${Platform.pathSeparator}sent-attachments');
    } catch (_) {
      return null;
    }
  }

  static Future<File?> _file(String machineId, String folder, String path) async {
    final dir = await SentAttachmentCache.folder();
    if (dir == null) return null;
    final name = sha256.convert(utf8.encode(_key(machineId, folder, path))).toString();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  /// Keeps [bytes] as the image of [path] (relative to the session's [folder]) on [machineId].
  static void put(String machineId, String folder, String path, Uint8List bytes) {
    _remember(machineId, folder, path, bytes);
    _write(machineId, folder, path, bytes);
  }

  static void _remember(String machineId, String folder, String path, Uint8List bytes) {
    final key = _key(machineId, folder, path);
    final old = _memory.remove(key);
    if (old != null) _bytes -= old.length;
    _memory[key] = bytes;
    _bytes += bytes.length;
    while (_bytes > memoryLimit && _memory.length > 1) {
      final first = _memory.keys.first;
      _bytes -= _memory.remove(first)!.length;
    }
  }

  static Future<void> _write(String machineId, String folder, String path, Uint8List bytes) async {
    try {
      final f = await _file(machineId, folder, path);
      if (f == null) return;
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
    } catch (_) {}
  }

  /// The image kept in memory for [path], if any.
  static Uint8List? get(String machineId, String folder, String path) => _memory[_key(machineId, folder, path)];

  /// The image for [path] from memory, else from the disk copy (null: this phone did not send
  /// it, or the copy is gone).
  static Future<Uint8List?> read(String machineId, String folder, String path) async {
    final hit = get(machineId, folder, path);
    if (hit != null) return hit;
    try {
      final f = await _file(machineId, folder, path);
      if (f == null || !await f.exists()) return null;
      final bytes = await f.readAsBytes();
      _remember(machineId, folder, path, bytes); // later rebuilds find it in memory
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Forgets everything in memory (tests).
  @visibleForTesting
  static void clearMemory() {
    _memory.clear();
    _bytes = 0;
  }
}
