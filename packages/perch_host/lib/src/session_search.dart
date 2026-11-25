// Full-text search across the conversations Claude Code kept on this machine: every
// transcript in `<config dir>/projects/*/<id>.jsonl` (subagent transcripts and self-test
// sessions left out), newest first. Only the owner's messages and Claude's replies are
// searched, not tool output.
//
// Transcripts are large (gigabytes, almost all of it tool output and pictures in very long
// lines), so the host keeps an index: per conversation, a small JSON file with just its
// messages and replies, its folder and names, and how far into the transcript it has read.
// A search first brings the index up to date (reading only what was appended since), within
// its time budget, then searches the index. Lines longer than [maxIndexedLine] characters
// are skipped without being decoded. Runs in its own isolate (see SessionManager).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:perch_protocol/perch_protocol.dart';

import 'self_test.dart' show isSelfTestFolder;
import 'stream_parser.dart' show decodeJsonObject;
import 'transcript.dart';

/// One matching message.
class TranscriptHit {
  final String claudeId;
  final String name;
  final String cwd;
  final int atMs;
  final bool fromUser;
  final String snippet;
  const TranscriptHit({
    required this.claudeId,
    required this.name,
    required this.cwd,
    required this.atMs,
    required this.fromUser,
    required this.snippet,
  });
}

/// What a search found; [truncated]: more matched than shown, or it ran out of time (then
/// some conversations were not searched yet).
class TranscriptSearch {
  final List<TranscriptHit> hits;
  final bool truncated;
  const TranscriptSearch(this.hits, {this.truncated = false});
}

final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// Whether [id] is a Claude Code session id (a UUID): only such ids are ever turned into a
/// transcript (or index) file name.
bool isClaudeSessionId(String id) => _uuid.hasMatch(id);

/// The shortest search Perch runs.
const minSearchLength = 2;

/// Lines longer than this (tool output, pictures, written files) are not indexed.
const maxIndexedLine = 100000;

/// The index's format; an index file of another version is rebuilt.
const _indexVersion = 1;

/// One conversation in the index.
class _Entry {
  String path;
  int size;
  int modifiedMs;
  int offset;
  String cwd;
  String? custom;
  String? ai;
  String? first;
  bool skip;

  /// [fromUser 0/1, atMs, text].
  final List<List<Object>> msgs;
  _Entry({
    required this.path,
    this.size = 0,
    this.modifiedMs = 0,
    this.offset = 0,
    this.cwd = '',
    this.custom,
    this.ai,
    this.first,
    this.skip = false,
    List<List<Object>>? msgs,
  }) : msgs = msgs ?? [];

  Map<String, dynamic> toJson() => {
        'v': _indexVersion,
        'path': path,
        'size': size,
        'modifiedMs': modifiedMs,
        'offset': offset,
        'cwd': cwd,
        'custom': ?custom,
        'ai': ?ai,
        'first': ?first,
        if (skip) 'skip': true,
        'msgs': msgs,
      };

  static _Entry? fromJson(Object? j) {
    if (j is! Map || j['v'] != _indexVersion || j['path'] is! String) return null;
    try {
      return _Entry(
        path: j['path'] as String,
        size: (j['size'] as num).toInt(),
        modifiedMs: (j['modifiedMs'] as num).toInt(),
        offset: (j['offset'] as num).toInt(),
        cwd: j['cwd'] is String ? j['cwd'] as String : '',
        custom: j['custom'] as String?,
        ai: j['ai'] as String?,
        first: j['first'] as String?,
        skip: j['skip'] == true,
        msgs: [
          for (final m in (j['msgs'] as List))
            if (m is List && m.length == 3) [(m[0] as num).toInt(), (m[1] as num).toInt(), '${m[2]}']
        ],
      );
    } catch (_) {
      return null;
    }
  }

  String get name => custom ?? ai ?? _short(first ?? '', 60);
}

/// The newest copy of every conversation under [configDir], newest first.
List<(String id, File file, DateTime modified)> _transcripts(String configDir) {
  final sep = Platform.pathSeparator;
  final projects = Directory('$configDir${sep}projects');
  final newest = <String, (File, DateTime)>{};
  if (!projects.existsSync()) return const [];
  try {
    for (final d in projects.listSync(followLinks: false)) {
      if (d is! Directory) continue;
      for (final f in d.listSync(followLinks: false)) {
        if (f is! File || !f.path.endsWith('.jsonl')) continue;
        final name = f.uri.pathSegments.last;
        final id = name.substring(0, name.length - '.jsonl'.length);
        if (!isClaudeSessionId(id)) continue;
        DateTime at;
        try {
          at = f.lastModifiedSync();
        } catch (_) {
          continue;
        }
        final seen = newest[id];
        if (seen == null || at.isAfter(seen.$2)) newest[id] = (f, at);
      }
    }
  } catch (_) {}
  return [for (final e in newest.entries) (e.key, e.value.$1, e.value.$2)]..sort((a, b) => b.$3.compareTo(a.$3));
}

File _indexFile(String indexDir, String id) => File('$indexDir${Platform.pathSeparator}$id.json');

_Entry? _loadEntry(String indexDir, String id) {
  try {
    final f = _indexFile(indexDir, id);
    if (!f.existsSync()) return null;
    return _Entry.fromJson(jsonDecode(f.readAsStringSync()));
  } catch (_) {
    return null;
  }
}

void _saveEntry(String indexDir, String id, _Entry e) {
  try {
    Directory(indexDir).createSync(recursive: true);
    final f = _indexFile(indexDir, id);
    final tmp = File('${f.path}.tmp')..writeAsStringSync(jsonEncode(e.toJson()));
    tmp.renameSync(f.path);
  } catch (_) {}
}

/// Brings [prev] up to date with transcript [f]: reads only what was appended since (or the
/// whole file when it was replaced or shrank). Returns null when the file cannot be read.
_Entry? _update(File f, DateTime modified, _Entry? prev) {
  int size;
  try {
    size = f.lengthSync();
  } catch (_) {
    return null;
  }
  final at = modified.millisecondsSinceEpoch;
  var e = prev;
  if (e != null && e.path == f.path && e.size == size && e.modifiedMs == at) return e;
  if (e == null || e.path != f.path || size < e.offset) e = _Entry(path: f.path);
  if (e.skip) {
    e
      ..size = size
      ..modifiedMs = at;
    return e;
  }
  RandomAccessFile? raf;
  try {
    raf = f.openSync();
    raf.setPositionSync(e.offset);
    const chunk = 8 * 1024 * 1024;
    var carry = BytesBuilder(copy: false);
    var carryLen = 0; // bytes of the current (unfinished) line seen so far
    var tooLong = false;
    var pos = e.offset;
    while (true) {
      final data = raf.readSync(chunk);
      if (data.isEmpty) break;
      var start = 0;
      while (true) {
        final nl = data.indexOf(10, start);
        if (nl < 0) {
          final rest = data.length - start;
          carryLen += rest;
          if (!tooLong && carryLen > maxIndexedLine * 4) {
            tooLong = true;
            carry = BytesBuilder(copy: false);
          }
          if (!tooLong) carry.add(Uint8List.sublistView(data, start));
          break;
        }
        final len = carryLen + (nl - start);
        if (!tooLong && len <= maxIndexedLine * 4) {
          carry.add(Uint8List.sublistView(data, start, nl));
          final line = utf8.decode(carry.takeBytes(), allowMalformed: true);
          if (line.length <= maxIndexedLine) _index(e, line);
          if (e.skip) {
            e
              ..size = size
              ..modifiedMs = at
              ..msgs.clear();
            return e;
          }
        }
        carry = BytesBuilder(copy: false);
        carryLen = 0;
        tooLong = false;
        pos += len + 1;
        start = nl + 1;
      }
    }
    // An unfinished last line is read again next time.
    e
      ..offset = pos
      ..size = size
      ..modifiedMs = at;
    return e;
  } catch (_) {
    return null;
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {}
  }
}

/// Takes one transcript line into [e].
void _index(_Entry e, String line) {
  final isTitle = line.contains('"custom-title"') || line.contains('"agent-name"') || line.contains('"ai-title"');
  final isMessage = line.contains('"user"') || line.contains('"assistant"');
  if (!isTitle && !isMessage && e.cwd.isNotEmpty) return;
  final j = decodeJsonObject(line);
  if (j == null) return;
  if (e.cwd.isEmpty && j['cwd'] is String) {
    e.cwd = j['cwd'] as String;
    if (isSelfTestFolder(e.cwd)) {
      e.skip = true;
      return;
    }
  }
  if (!isTitle && !isMessage) return;
  final t = parseTranscriptLine(line);
  if (t is TranscriptTitle) {
    if (t.custom) {
      e.custom = t.title;
    } else {
      e.ai = t.title;
    }
    return;
  }
  if (t is! TranscriptEvents) return;
  final at = transcriptTimeMs(j['timestamp']) ?? 0;
  for (final ev in t.events) {
    if (ev is UserMessage) {
      if (ev.text.trim().isEmpty) continue;
      e.first ??= ev.text;
      e.msgs.add([1, at, ev.text]);
    } else if (ev is AssistantText) {
      if (ev.text.trim().isEmpty) continue;
      e.msgs.add([0, at, ev.text]);
    }
  }
}

/// Brings the whole index in [indexDir] up to date (the host does this in the background
/// when it starts, so the first search is quick) and drops entries of conversations that
/// are gone.
void updateSearchIndex({required String configDir, required String indexDir}) {
  final all = _transcripts(configDir);
  for (final (id, f, at) in all) {
    final prev = _loadEntry(indexDir, id);
    if (prev != null && prev.path == f.path && prev.modifiedMs == at.millisecondsSinceEpoch) continue;
    final next = _update(f, at, prev);
    if (next != null) _saveEntry(indexDir, id, next);
  }
  _prune(indexDir, {for (final t in all) t.$1});
}

void _prune(String indexDir, Set<String> keep) {
  try {
    final d = Directory(indexDir);
    if (!d.existsSync()) return;
    for (final f in d.listSync()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      final name = f.uri.pathSegments.last;
      final id = name.substring(0, name.length - '.json'.length);
      if (!keep.contains(id)) f.deleteSync();
    }
  } catch (_) {}
}

/// Searches the conversations under [configDir] for [query] (case-insensitive). At most
/// [perSession] hits per conversation (its newest messages first) and [limit] in all. With
/// [indexDir] the index there is used and brought up to date while [budget] lasts (a
/// conversation not indexed yet when it runs out is left out, and the result is marked
/// truncated); without, every transcript is read.
TranscriptSearch searchTranscripts({
  required String configDir,
  required String query,
  String? indexDir,
  int limit = 40,
  int perSession = 3,
  Duration budget = const Duration(seconds: 4),
  DateTime Function() clock = DateTime.now,
}) {
  final q = query.trim().toLowerCase();
  if (q.length < minSearchLength) return const TranscriptSearch([]);
  final started = clock();
  final all = _transcripts(configDir);
  final hits = <TranscriptHit>[];
  var truncated = false;
  for (final (id, f, at) in all) {
    if (hits.length >= limit) {
      truncated = true;
      break;
    }
    final prev = indexDir == null ? null : _loadEntry(indexDir, id);
    _Entry? e = prev;
    final fresh = prev != null && prev.path == f.path && prev.modifiedMs == at.millisecondsSinceEpoch;
    if (!fresh) {
      if (clock().difference(started) > budget) {
        // Out of time: an older index entry is still searched; a missing one is not.
        truncated = true;
      } else {
        e = _update(f, at, prev);
        if (e != null && indexDir != null) _saveEntry(indexDir, id, e);
      }
    }
    if (e == null || e.skip) continue;
    final found = [
      for (final m in e.msgs.reversed)
        if ((m[2] as String).toLowerCase().contains(q)) m
    ];
    if (found.isEmpty) continue;
    if (found.length > perSession) truncated = true;
    for (final m in found.take(perSession)) {
      if (hits.length >= limit) {
        truncated = true;
        break;
      }
      hits.add(TranscriptHit(
        claudeId: id,
        name: e.name,
        cwd: e.cwd,
        atMs: m[1] as int,
        fromUser: m[0] == 1,
        snippet: snippetAround(m[2] as String, q),
      ));
    }
  }
  if (indexDir != null) _prune(indexDir, {for (final t in all) t.$1});
  return TranscriptSearch(hits, truncated: truncated);
}

String _flat(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

String _short(String s, int max) {
  final f = _flat(s);
  return f.length <= max ? f : '${f.substring(0, max - 1).trimRight()}…';
}

/// The words around the first match of [q] (lowercase) in [text]: up to 60 characters
/// before and 100 after, on one line, with … where it was cut.
String snippetAround(String text, String q) {
  final f = _flat(text);
  final i = f.toLowerCase().indexOf(q);
  if (i < 0) return _short(f, 160);
  final from = i - 60 < 0 ? 0 : i - 60;
  final to = i + q.length + 100 > f.length ? f.length : i + q.length + 100;
  return '${from > 0 ? '…' : ''}${f.substring(from, to).trim()}${to < f.length ? '…' : ''}';
}
