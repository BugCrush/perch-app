// Claude Code transcript files (<config dir>/projects/<encoded cwd>/<session id>.jsonl).
import 'dart:convert';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

import 'inbox.dart';
import 'stream_parser.dart';

sealed class TranscriptLine {
  const TranscriptLine();
}

class TranscriptEvents extends TranscriptLine {
  final List<ConversationEvent> events;

  /// When this line is a message the owner sent the session (typed at the terminal, or
  /// sent from Perch, also through the inbox): the line's time. Null for everything else
  /// (Claude's replies, tool results, meta lines, other sessions' messages, summaries).
  final int? ownerPromptAtMs;
  const TranscriptEvents(this.events, {this.ownerPromptAtMs});
}

/// type "ai-title" -> aiTitle; or, with [custom], the name the owner gave the session
/// (`-n`, `/rename`, the resume list's rename): type "custom-title" -> customTitle and
/// type "agent-name" -> agentName. A custom name wins over Claude's titles.
class TranscriptTitle extends TranscriptLine {
  final String title;
  final bool custom;
  const TranscriptTitle(this.title, {this.custom = false});
}

/// type "permission-mode".
class TranscriptPermissionMode extends TranscriptLine {
  final String mode;
  const TranscriptPermissionMode(this.mode);
}

class TranscriptSkip extends TranscriptLine {
  const TranscriptSkip();
}

/// A line of a known type (user, assistant) whose shape Perch cannot read: a sign the
/// transcript format changed.
class TranscriptMalformed extends TranscriptLine {
  final String reason;
  const TranscriptMalformed(this.reason);
}

const _skippedUserPrefixes = ['<system-reminder>', '<command-name>', '<local-command', '<task-notification>'];

bool _isHarnessText(String text) {
  final t = text.trimLeft();
  return _skippedUserPrefixes.any(t.startsWith);
}

final _commandName = RegExp(r'<command-name>\s*(/?[^<\s]+)\s*</command-name>');
final _commandArgs = RegExp(r'<command-args>([\s\S]*?)</command-args>');
final _commandOut = RegExp(r'^\s*<local-command-(stdout|stderr)>([\s\S]*)</local-command-\1>\s*$');
final _ansi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)');

/// Terminal colour and cursor codes removed.
String stripAnsi(String s) => s.replaceAll(_ansi, '');

/// The text of a user message's content (a string, or its text blocks joined).
String? _contentText(Object? content) {
  if (content is String) return content;
  if (content is! List) return null;
  final parts = [
    for (final b in content)
      if (b is Map && b['type'] == 'text' && b['text'] is String) b['text'] as String
  ];
  return parts.isEmpty ? null : parts.join('\n');
}

/// A slash command the owner ran (`<command-name>`) or what a local one printed
/// (`<local-command-stdout>` / `-stderr`), as conversation events; null for anything else
/// (the caveat line included). Output that printed nothing gives no event.
List<ConversationEvent>? commandEvents(String text) {
  final t = text.trimLeft();
  final name = _commandName.firstMatch(t);
  if (name != null && (t.startsWith('<command-name>') || t.startsWith('<command-message>'))) {
    var n = name.group(1)!;
    if (!n.startsWith('/')) n = '/$n';
    final args = _commandArgs.firstMatch(t)?.group(1)?.trim() ?? '';
    return [SlashCommand(n, args)];
  }
  final out = _commandOut.firstMatch(t);
  if (out != null) {
    final body = stripAnsi(out.group(2)!).replaceAll('\r', '').trim();
    if (body.isEmpty) return const [];
    return [CommandOutput(body, isError: out.group(1) == 'stderr')];
  }
  return null;
}

/// A transcript line's ISO `timestamp` in milliseconds since the epoch, or null.
int? transcriptTimeMs(Object? v) {
  if (v is! String || v.isEmpty) return null;
  return DateTime.tryParse(v)?.millisecondsSinceEpoch;
}

TranscriptLine parseTranscriptLine(String line, {String? parentToolUseId}) {
  final j = decodeJsonObject(line);
  if (j == null) return const TranscriptSkip();
  try {
    switch (j['type']) {
      case 'ai-title':
        final t = j['aiTitle'];
        return t is String && t.isNotEmpty ? TranscriptTitle(t) : const TranscriptSkip();
      case 'custom-title':
      case 'agent-name':
        final t = j['type'] == 'custom-title' ? j['customTitle'] : j['agentName'];
        return t is String && t.trim().isNotEmpty ? TranscriptTitle(t.trim(), custom: true) : const TranscriptSkip();
      case 'permission-mode':
        final m = j['permissionMode'];
        return m is String && m.isNotEmpty ? TranscriptPermissionMode(m) : const TranscriptSkip();
      case 'system':
        // Claude Code 2.1.325 writes a local slash command and what it printed as system
        // lines (subtype local_command); older versions as user lines (below).
        final content = j['content'];
        if (j['subtype'] != 'local_command' || content is! String) return const TranscriptSkip();
        final cmd = commandEvents(content);
        if (cmd == null || cmd.isEmpty) return const TranscriptSkip();
        final at = transcriptTimeMs(j['timestamp']);
        if (at != null) {
          for (final e in cmd) {
            e.atMs = at;
          }
        }
        return TranscriptEvents(cmd);
      case 'user':
      case 'assistant':
        final message = j['message'];
        if (message is! Map) return TranscriptMalformed('a ${j['type']} line without a message object');
        final content = message['content'];
        if (content is! String && content is! List) {
          return TranscriptMalformed('a ${j['type']} message without content');
        }
        // Sidechain lines in the main file belong to subagents (they have their own files).
        if (j['isSidechain'] == true && parentToolUseId == null) return const TranscriptSkip();
        if (j['type'] == 'user') {
          // A slash command and what it printed: shown as the owner's command and its output.
          final text = _contentText(content);
          final cmd = text == null ? null : commandEvents(text);
          if (cmd != null) {
            if (cmd.isEmpty) return const TranscriptSkip();
            final at = transcriptTimeMs(j['timestamp']);
            if (at != null) {
              for (final e in cmd) {
                e.atMs = at;
              }
            }
            return TranscriptEvents(cmd);
          }
        }
        if (j['type'] == 'user' && j['isMeta'] == true) {
          // A message Perch sent through the session's inbox: the owner's own message.
          // Everything else marked meta (other sessions' messages included) stays hidden.
          final sent = content is String ? perchInboxText(j, content) : null;
          if (sent == null || sent.trim().isEmpty) return const TranscriptSkip();
          final e = UserMessage(sent);
          final at = transcriptTimeMs(j['timestamp']);
          if (at != null) e.atMs = at;
          return TranscriptEvents([e], ownerPromptAtMs: at);
        }
        final events = contentToEvents(j['type'] as String, message['content'], parentToolUseId,
                includeTopLevelUserText: true)
            .where((e) => !(e is UserMessage && _isHarnessText(e.text)))
            .toList();
        // The line's own time; 0 when it has none (the reader fills it in).
        final at = transcriptTimeMs(j['timestamp']);
        if (at != null) {
          for (final e in events) {
            e.atMs = at;
          }
        }
        if (events.isEmpty) return const TranscriptSkip();
        final byOwner = j['type'] == 'user' &&
            j['isCompactSummary'] != true &&
            j['isVisibleInTranscriptOnly'] != true &&
            events.any((e) => e is UserMessage);
        return TranscriptEvents(events, ownerPromptAtMs: byOwner ? at : null);
    }
  } catch (e) {
    final type = j['type'];
    return type == 'user' || type == 'assistant'
        ? TranscriptMalformed('a $type line that could not be read ($e)')
        : const TranscriptSkip();
  }
  return const TranscriptSkip();
}

/// The time of the latest message the owner sent the session ([TranscriptEvents.ownerPromptAtMs]),
/// read from the end of the transcript (up to [maxBack] bytes back), or null.
int? latestOwnerPromptMs(File f, {int maxBack = 4 * 1024 * 1024}) {
  RandomAccessFile? raf;
  try {
    raf = f.openSync();
    final len = raf.lengthSync();
    const chunk = 64 * 1024;
    var start = len;
    var carry = <int>[];
    while (start > 0 && len - start < maxBack) {
      final from = start - chunk < 0 ? 0 : start - chunk;
      raf.setPositionSync(from);
      final bytes = [...raf.readSync(start - from), ...carry];
      final firstNl = from == 0 ? -1 : bytes.indexOf(10);
      final whole = firstNl < 0 ? bytes : bytes.sublist(firstNl + 1);
      carry = firstNl < 0 ? <int>[] : bytes.sublist(0, firstNl + 1);
      int? best;
      for (final line in utf8.decode(whole, allowMalformed: true).split('\n')) {
        if (!line.contains('"user"')) continue;
        final t = parseTranscriptLine(line.trim());
        final at = t is TranscriptEvents ? t.ownerPromptAtMs : null;
        if (at != null && (best == null || at > best)) best = at;
      }
      // Lines are written in time order: the latest owner message is in the last chunk
      // that has one (the chunk is read whole, ordered by timestamp).
      if (best != null) return best;
      start = from;
    }
  } catch (_) {
    // unreadable: unknown
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {}
  }
  return null;
}

/// `CLAUDE_CONFIG_DIR` or `<home>/.claude`.
String claudeConfigDir() {
  final env = Platform.environment;
  final configured = env['CLAUDE_CONFIG_DIR'];
  if (configured != null && configured.trim().isNotEmpty) return configured.trim();
  final home = (Platform.isWindows ? env['USERPROFILE'] : env['HOME']) ?? env['HOME'] ?? '.';
  return '$home${Platform.pathSeparator}.claude';
}

/// `<configDir>/projects/*/<id>.jsonl`, or null. The same id can sit in more than one
/// project folder (a stale copy left by an older run); the most recently written one wins.
File? findTranscript(String claudeSessionId, {String? configDir}) {
  final sep = Platform.pathSeparator;
  final projects = Directory('${configDir ?? claudeConfigDir()}${sep}projects');
  if (!projects.existsSync()) return null;
  File? best;
  DateTime? bestAt;
  try {
    for (final d in projects.listSync(followLinks: false)) {
      if (d is! Directory) continue;
      final f = File('${d.path}$sep$claudeSessionId.jsonl');
      try {
        final at = f.lastModifiedSync();
        if (bestAt == null || at.isAfter(bestAt)) {
          best = f;
          bestAt = at;
        }
      } catch (_) {
        // not there
      }
    }
  } catch (_) {}
  return best;
}

/// The latest `ai-title` in a transcript, read from the end of the file (up to 2 MB back),
/// or null.
String? latestAiTitle(File f) => latestTitles(f).ai;

/// The latest custom name (`custom-title` or `agent-name`) and `ai-title` in a transcript,
/// read from the end of the file (up to 2 MB back).
({String? custom, String? ai}) latestTitles(File f) {
  String? custom;
  String? ai;
  RandomAccessFile? raf;
  try {
    raf = f.openSync();
    final len = raf.lengthSync();
    const chunk = 64 * 1024;
    var start = len;
    var carry = <int>[];
    while (start > 0 && len - start < 2 * 1024 * 1024) {
      final from = start - chunk < 0 ? 0 : start - chunk;
      raf.setPositionSync(from);
      final bytes = [...raf.readSync(start - from), ...carry];
      // Keep the partial first line for the next (earlier) chunk.
      final firstNl = from == 0 ? -1 : bytes.indexOf(10);
      final whole = firstNl < 0 ? bytes : bytes.sublist(firstNl + 1);
      carry = firstNl < 0 ? <int>[] : bytes.sublist(0, firstNl + 1);
      final lines = utf8.decode(whole, allowMalformed: true).split('\n');
      for (final line in lines.reversed) {
        if (!line.contains('"ai-title"') && !line.contains('"custom-title"') && !line.contains('"agent-name"')) {
          continue;
        }
        final t = parseTranscriptLine(line.trim());
        if (t is! TranscriptTitle) continue;
        if (t.custom) {
          custom ??= t.title;
        } else {
          ai ??= t.title;
        }
        if (custom != null && ai != null) return (custom: custom, ai: ai);
      }
      start = from;
    }
  } catch (_) {
    // unreadable: no title
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {}
  }
  return (custom: custom, ai: ai);
}
