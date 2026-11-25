// The files and folders a session's composer offers after `@`, as Claude Code's own `@` list
// does: in a git repository what git sees (tracked and untracked files, ignored ones left
// out), elsewhere a bounded walk that skips hidden and heavy folders. Paths are relative to
// the session's folder with `/` between parts; the list is capped and kept per folder for a
// short while (typing asks again for every few letters).
import 'dart:convert';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

/// Folders a walk never enters (hidden ones, starting with a dot, are skipped too).
const heavyFolders = {
  'node_modules', 'build', 'dist', 'target', 'obj', 'coverage', '__pycache__', 'venv', 'Pods',
  'DerivedData',
};

class FileIndex {
  /// The most files and folders listed for one folder.
  final int cap;

  /// How long a folder's list is reused.
  final Duration life;

  /// How deep a walk goes.
  final int maxDepth;

  FileIndex({this.cap = 20000, this.life = const Duration(seconds: 30), this.maxDepth = 12});

  final Map<String, ({DateTime at, Future<({List<FileMention> files, bool truncated})> list})> _cache = {};

  /// Everything [cwd] offers, at most [cap] entries.
  Future<({List<FileMention> files, bool truncated})> filesIn(String cwd) {
    final key = Platform.isWindows || Platform.isMacOS ? cwd.toLowerCase() : cwd;
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.at) < life) return hit.list;
    _cache.removeWhere((_, v) => DateTime.now().difference(v.at) >= life);
    final list = _read(cwd);
    _cache[key] = (at: DateTime.now(), list: list);
    return list;
  }

  /// The best [limit] matches for [query] in [cwd].
  Future<({List<FileMention> files, bool truncated})> search(String cwd, String query, {int limit = 50}) async {
    final all = await filesIn(cwd);
    return (files: matchFiles(all.files, query, limit: limit), truncated: all.truncated);
  }

  Future<({List<FileMention> files, bool truncated})> _read(String cwd) async {
    if (cwd.isEmpty || !await Directory(cwd).exists()) return (files: const <FileMention>[], truncated: false);
    return await _fromGit(cwd) ?? await _walk(cwd);
  }

  /// git's files under [cwd] (relative to it), with their folders; null outside a repository
  /// or without git.
  Future<({List<FileMention> files, bool truncated})?> _fromGit(String cwd) async {
    ProcessResult r;
    try {
      r = await Process.run(
          'git', ['-c', 'core.quotepath=off', 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--deduplicate'],
          workingDirectory: cwd, stdoutEncoding: utf8, stderrEncoding: utf8);
    } catch (_) {
      return null;
    }
    if (r.exitCode != 0) return null;
    final out = <FileMention>[];
    final dirs = <String>{};
    var truncated = false;
    for (final p in (r.stdout as String).split('\x00')) {
      if (p.isEmpty) continue;
      if (out.length >= cap) {
        truncated = true;
        break;
      }
      // Its folders first, once each.
      var at = p.indexOf('/');
      while (at > 0 && out.length < cap) {
        final d = p.substring(0, at);
        if (dirs.add(d)) out.add(FileMention(path: d, dir: true));
        at = p.indexOf('/', at + 1);
      }
      if (out.length < cap) out.add(FileMention(path: p));
    }
    // Nothing: a folder git ignores as a whole (a scratch folder) is walked instead.
    if (out.isEmpty) return null;
    return (files: out, truncated: truncated);
  }

  /// A breadth-first walk of [cwd]: nearer files first, hidden and heavy folders skipped.
  Future<({List<FileMention> files, bool truncated})> _walk(String cwd) async {
    final out = <FileMention>[];
    var level = <(Directory, String)>[(Directory(cwd), '')];
    for (var depth = 0; depth <= maxDepth && level.isNotEmpty; depth++) {
      final next = <(Directory, String)>[];
      for (final (dir, rel) in level) {
        List<FileSystemEntity> items;
        try {
          items = await dir.list(followLinks: false).toList();
        } catch (_) {
          continue;
        }
        items.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
        for (final e in items) {
          final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (name.startsWith('.')) continue;
          final path = rel.isEmpty ? name : '$rel/$name';
          if (e is Directory) {
            if (heavyFolders.contains(name)) continue;
            out.add(FileMention(path: path, dir: true));
            next.add((e, path));
          } else if (e is File) {
            out.add(FileMention(path: path));
          }
          if (out.length >= cap) return (files: out, truncated: true);
        }
      }
      level = next;
    }
    return (files: out, truncated: false);
  }
}
