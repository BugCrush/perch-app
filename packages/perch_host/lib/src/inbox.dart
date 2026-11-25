// Claude Code's per-session inbox (cross-session messaging, Claude Code 2.1.224 and later):
// every interactive session listens on a Unix socket on macOS and Linux, where other
// sessions on the machine deliver messages. Perch uses it to send the phone's message to
// a terminal session it cannot type into (VS Code's or Cursor's terminal, iTerm2, …): the
// session stays where it is, an idle one starts a turn, a busy one reads it between tool
// calls. See docs/superpowers/specs/2026-11-14-inbox-hybrid-research.md.
//
// Wire format: one JSON object per line, `{"type":"user","message":{"role":"user",
// "content":"…"}}`; on macOS and Linux no auth line is needed. Claude Code tells the
// receiving Claude that the message came from another session on the user's behalf; it
// can never approve a pending dialog.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The sender name Perch's messages carry (the terminal shows "Message from @perch-phone").
const perchSenderName = 'perch-phone';

const _tag = 'cross-session-message';

/// Told to Claude at the end of each message, inside the wrapper (text after the wrapper
/// makes Claude Code stop recognising it) and stripped again before the phone shows it:
/// perch-phone has no inbox, so a SendMessage reply to it fails with "Not sent", and the
/// phone reads the answer from this session's conversation anyway.
const inboxReplyNote = 'Perch relays this message from the user\'s phone and the phone reads this session\'s '
    'conversation directly, so answer here as usual. Do not use SendMessage to reply to perch-phone: it has no '
    'inbox and cannot receive messages.';


/// [text] wrapped so Claude Code shows it as a message from [perchSenderName] and keeps
/// the text itself in the transcript line's `origin.body`. A closing tag inside the text is
/// escaped as Claude Code does it (otherwise the wrapper would not be recognised).
String wrapInboxText(String text) =>
    '<$_tag from-name="$perchSenderName">\n${text.replaceAll('</$_tag', '<\\/$_tag')}\n\n$inboxReplyNote\n</$_tag>';

/// The message's text as Perch sent it, from a transcript line's `origin.body` or, failing
/// that, from the wrapper in its content.
String unescapeInboxBody(String body) {
  final b = body.endsWith('\n\n$inboxReplyNote') ? body.substring(0, body.length - inboxReplyNote.length - 2) : body;
  return b.replaceAll('<\\/$_tag', '</$_tag');
}

/// The text Perch sent, from a transcript `user` line that came through the inbox, or null
/// when the line is not a message from Perch.
String? perchInboxText(Map<String, dynamic> line, String content) {
  final origin = line['origin'];
  if (origin is! Map || origin['kind'] != 'peer') return null;
  final name = origin['name'];
  if (name != null && name != perchSenderName) return null;
  if (name == perchSenderName && origin['body'] is String) return unescapeInboxBody(origin['body'] as String);
  final open = '<$_tag from-name="$perchSenderName">\n';
  final start = content.indexOf(open);
  if (start < 0) return null;
  final end = content.indexOf('\n</$_tag>', start + open.length);
  if (end < 0) return null;
  return unescapeInboxBody(content.substring(start + open.length, end));
}

/// Whether a `UserPromptSubmit` hook's prompt is a message Perch delivered through the
/// inbox (Claude Code fires that hook for inbox messages too, with the wrapper).
bool isPerchInboxPrompt(String prompt) => prompt.contains('<$_tag from-name="$perchSenderName">');

/// The JSON line that delivers [text].
String inboxLine(String text) => '${jsonEncode({
      'type': 'user',
      'message': {'role': 'user', 'content': wrapInboxText(text)},
    })}\n';

/// Writes [line] to the Unix socket at [path]; true when it was written.
typedef InboxWriter = Future<bool> Function(String path, String line);

Future<bool> writeUnixSocket(String path, String line) async {
  Socket? s;
  try {
    s = await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0,
        timeout: const Duration(seconds: 3));
    s.add(utf8.encode(line));
    await s.flush().timeout(const Duration(seconds: 3));
    return true;
  } catch (_) {
    return false;
  } finally {
    try {
      await s?.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
    s?.destroy();
  }
}

/// Delivers messages to sessions' inboxes.
class ClaudeInbox {
  /// Claude Code's config folder (`~/.claude`), which holds `sessions/<pid>.json`.
  final String configDir;
  final InboxWriter _write;
  final bool _available;

  ClaudeInbox({required this.configDir, InboxWriter? write, bool? available})
      : _write = write ?? writeUnixSocket,
        // Windows uses a named pipe that requires an auth line; not built yet (the console
        // adapter types into every Windows session).
        _available = available ?? !Platform.isWindows;

  bool get supported => _available;

  /// The inbox socket of the session with process id [pid], from Claude Code's own
  /// registry (`<config>/sessions/<pid>.json`, `messagingSocketPath`), or null.
  String? socketPathFor(int pid) {
    final f = File('$configDir${Platform.pathSeparator}sessions${Platform.pathSeparator}$pid.json');
    try {
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map || j['pid'] != pid) return null;
      var p = j['messagingSocketPath'];
      if (p is! String || p.isEmpty) return null;
      if (p.startsWith('uds:')) p = p.substring(4);
      return p.startsWith('/') ? p : null;
    } catch (_) {
      return null;
    }
  }

  /// Sends [text] to the session with process id [pid]; true when it was written to its
  /// inbox (Claude Code sends no receipt).
  Future<bool> send(int pid, String text) async {
    if (!supported || text.trim().isEmpty) return false;
    final path = socketPathFor(pid);
    if (path == null) return false;
    return _write(path, inboxLine(text));
  }
}
