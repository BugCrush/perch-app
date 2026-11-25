// Follows a terminal session's transcript and its subagent files.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

import 'transcript.dart';

/// Reads appended bytes from one file and hands out complete lines.
class _FileFollower {
  final File file;
  int offset;
  final List<int> _pending = [];

  _FileFollower(this.file) : offset = 0;

  List<String> readNewLines() {
    final out = <String>[];
    RandomAccessFile? raf;
    try {
      if (!file.existsSync()) return out;
      raf = file.openSync();
      final len = raf.lengthSync();
      if (len < offset) {
        // Truncated or replaced: start again.
        offset = 0;
        _pending.clear();
      }
      if (len == offset) return out;
      raf.setPositionSync(offset);
      final bytes = raf.readSync(len - offset);
      offset += bytes.length;
      _pending.addAll(bytes);
      var start = 0;
      for (var i = 0; i < _pending.length; i++) {
        if (_pending[i] == 10) {
          var end = i;
          if (end > start && _pending[end - 1] == 13) end--;
          out.add(utf8.decode(_pending.sublist(start, end), allowMalformed: true));
          start = i + 1;
        }
      }
      _pending.removeRange(0, start);
    } catch (_) {
      // The file may be locked or mid-write; try again next poll.
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
    return out;
  }
}

class _Subagent {
  final String agentId;
  final String toolUseId;
  final _FileFollower follower;
  final File meta;
  bool finished = false;
  String description = 'Subagent';
  String agentType = 'agent';

  /// The time of its latest event (for lines without a timestamp).
  int lastMs = 0;
  _Subagent(this.agentId, this.toolUseId, this.follower, this.meta);
}

class TranscriptTailer {
  final File transcript;
  final Duration poll;

  /// When true, content already in the files is skipped (used on hand-back).
  final bool fromEnd;

  TranscriptTailer(this.transcript, {this.poll = const Duration(milliseconds: 500), this.fromEnd = false})
      : _main = _FileFollower(transcript) {
    _controller = StreamController<TranscriptLine>(sync: true, onListen: _begin, onCancel: close);
  }

  final _FileFollower _main;
  late final StreamController<TranscriptLine> _controller;
  final Map<String, _Subagent> _subagents = {};
  final Set<String> _ignored = {};
  Timer? _timer;
  String? _lastPermissionMode;
  bool _closed = false;

  /// Everything already in the file, then appended lines as they are written.
  /// Lines that carry nothing ([TranscriptSkip]) are not emitted.
  Stream<TranscriptLine> get lines => _controller.stream;
  String? get lastPermissionMode => _lastPermissionMode;

  Directory get _subagentDir {
    final p = transcript.path;
    final base = p.toLowerCase().endsWith('.jsonl') ? p.substring(0, p.length - 6) : p;
    return Directory('$base${Platform.pathSeparator}subagents');
  }

  void _begin() {
    if (fromEnd) {
      // Skip what is there, but keep the permission mode up to date.
      for (final l in _main.readNewLines()) {
        final t = parseTranscriptLine(l);
        if (t is TranscriptPermissionMode) _lastPermissionMode = t.mode;
      }
      for (final f in _subagentFiles()) {
        _ignored.add(f.path);
      }
    }
    // The first read runs right after listen() returns (a caller may also call pollNow()
    // itself straight away to get the existing lines synchronously).
    Timer.run(pollNow);
    _timer = Timer.periodic(poll, (_) => pollNow());
  }

  List<File> _subagentFiles() {
    final dir = _subagentDir;
    try {
      if (!dir.existsSync()) return const [];
      final files = dir
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) {
            final name = f.uri.pathSegments.last;
            return name.startsWith('agent-') && name.endsWith('.jsonl');
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      return files;
    } catch (_) {
      return const [];
    }
  }

  void _emit(TranscriptLine l) {
    if (l is TranscriptPermissionMode) _lastPermissionMode = l.mode;
    if (l is TranscriptSkip || _closed) return;
    _controller.add(l);
  }

  /// Whether the first read (everything already on disk) has been done.
  bool _backlogDone = false;

  /// The time of each Agent tool call seen in the main file (tool_use id -> ms).
  final Map<String, int> _callTimes = {};

  /// Parses [raw] lines of one file, giving events without a timestamp the time of the
  /// event before them in that file. Returns the lines and the last known time.
  (List<TranscriptLine>, int) _parse(List<String> raw, int lastMs, {String? parent}) {
    final out = <TranscriptLine>[];
    for (final l in raw) {
      final t = parseTranscriptLine(l, parentToolUseId: parent);
      if (t is TranscriptEvents) {
        for (final e in t.events) {
          if (e.atMs == 0) {
            e.atMs = lastMs;
          } else {
            lastMs = e.atMs;
          }
          if (parent == null && e is ToolCall) _callTimes[e.toolUseId] = e.atMs;
        }
      }
      if (t is TranscriptPermissionMode) _lastPermissionMode = t.mode;
      if (t is! TranscriptSkip) out.add(t);
    }
    return (out, lastMs);
  }

  int _mainMs = 0;

  _Subagent _newSubagent(File f) {
    final name = f.uri.pathSegments.last;
    final agentId = name.substring('agent-'.length, name.length - '.jsonl'.length);
    final meta = File(f.path.replaceRange(f.path.length - '.jsonl'.length, null, '.meta.json'));
    final m = _readMeta(meta);
    final toolUseId = _s(m['toolUseId']) ?? 'agent:$agentId';
    final sub = _Subagent(agentId, toolUseId, _FileFollower(f), meta)
      ..description = _s(m['description']) ?? 'Subagent'
      ..agentType = _s(m['agentType']) ?? 'agent';
    _subagents[f.path] = sub;
    return sub;
  }

  SubagentStarted _started(_Subagent sub, int atMs) =>
      SubagentStarted(sub.agentId, sub.toolUseId, sub.description, sub.agentType, atMs: atMs);

  /// Whether the subagent has just finished (its meta file says so).
  bool _justFinished(_Subagent sub) {
    if (sub.finished || _readMeta(sub.meta)['finished'] != true) return false;
    sub.finished = true;
    return true;
  }

  /// Reads everything already on disk (main file and every subagent file) and emits it
  /// merged by time, so the session manager numbers it in the order it happened.
  void _readBacklog() {
    final streams = <List<(int, TranscriptLine)>>[];
    final (mainLines, mainMs) = _parse(_main.readNewLines(), 0);
    _mainMs = mainMs;
    streams.add(_timed(mainLines, 0));
    for (final f in _subagentFiles()) {
      if (_ignored.contains(f.path)) continue;
      final sub = _newSubagent(f);
      final (lines, lastMs) = _parse(sub.follower.readNewLines(), 0, parent: sub.toolUseId);
      sub.lastMs = lastMs;
      var first = 0;
      for (final l in lines) {
        if (l is TranscriptEvents && l.events.any((e) => e.atMs != 0)) {
          first = l.events.firstWhere((e) => e.atMs != 0).atMs;
          break;
        }
      }
      final call = _callTimes[sub.toolUseId];
      if (call != null && (first == 0 || call < first)) first = call;
      final timed = [(first, TranscriptEvents([_started(sub, first)]) as TranscriptLine), ..._timed(lines, first)];
      if (_justFinished(sub)) {
        timed.add((lastMs, TranscriptEvents([SubagentFinished(sub.agentId, 'completed', atMs: lastMs)])));
      }
      streams.add(timed);
    }
    // Merge, keeping each file's own order; on equal times the earlier file (main first) wins.
    final heads = List.filled(streams.length, 0);
    while (true) {
      var best = -1;
      for (var i = 0; i < streams.length; i++) {
        if (heads[i] >= streams[i].length) continue;
        if (best < 0 || streams[i][heads[i]].$1 < streams[best][heads[best]].$1) best = i;
      }
      if (best < 0) break;
      _emit(streams[best][heads[best]++].$2);
    }
  }

  /// Pairs each line with a sort time: its first event's time, else the time before it.
  static List<(int, TranscriptLine)> _timed(List<TranscriptLine> lines, int startMs) {
    var last = startMs;
    return [
      for (final l in lines)
        if (l is TranscriptEvents && l.events.isNotEmpty) (last = l.events.first.atMs, l) else (last, l)
    ];
  }

  /// Reads whatever is new right now (also called by the timer).
  void pollNow() {
    if (_closed) return;
    if (!_backlogDone) {
      _backlogDone = true;
      _readBacklog();
      return;
    }
    // Later lines arrive in the order they are read (they are live).
    final (mainLines, mainMs) = _parse(_main.readNewLines(), _mainMs);
    _mainMs = mainMs;
    mainLines.forEach(_emit);
    for (final f in _subagentFiles()) {
      if (_ignored.contains(f.path) || _subagents.containsKey(f.path)) continue;
      final sub = _newSubagent(f);
      _emit(TranscriptEvents([_started(sub, _callTimes[sub.toolUseId] ?? 0)]));
    }
    for (final sub in _subagents.values) {
      final (lines, lastMs) = _parse(sub.follower.readNewLines(), sub.lastMs, parent: sub.toolUseId);
      sub.lastMs = lastMs;
      lines.forEach(_emit);
      if (_justFinished(sub)) _emit(TranscriptEvents([SubagentFinished(sub.agentId, 'completed')]));
    }
  }

  static String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;

  static Map<String, dynamic> _readMeta(File f) {
    try {
      if (!f.existsSync()) return const {};
      final v = jsonDecode(f.readAsStringSync());
      return v is Map ? v.cast<String, dynamic>() : const {};
    } catch (_) {
      return const {};
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    // Not awaited: when the listener has already cancelled, the done future may never fire.
    unawaited(_controller.close());
  }
}
