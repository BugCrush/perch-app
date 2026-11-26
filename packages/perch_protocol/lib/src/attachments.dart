// Attachments from the phone: files uploaded in pieces into `<session folder>/perch-attachments/`
// and mentioned with `@` in the message, so Claude looks at them in the same turn.

/// The folder, directly in the session's folder, that holds the phone's attachments.
const attachmentFolder = 'perch-attachments';

/// At most 20 MB per file (checked on the phone and on the host).
const maxAttachmentBytes = 20 * 1024 * 1024;

/// One piece of a file: 512 KB raw, base64 in the message.
const attachmentPieceBytes = 512 * 1024;

/// The host acknowledges every 4th piece and the last one.
const attachmentAckEvery = 4;

/// The phone keeps at most this many pieces unacknowledged.
const attachmentWindow = 4;

/// The `@` mention of an attachment's [path] (relative to the session's folder).
String attachmentMention(String path) => '@$path';

/// The message sent: [text], then a line with one mention per path. Just the mentions when
/// [text] is blank; [text] unchanged without paths.
String withAttachments(String text, List<String> paths) {
  if (paths.isEmpty) return text;
  final mentions = paths.map(attachmentMention).join(' ');
  return text.trim().isEmpty ? mentions : '$text\n$mentions';
}

final _mention = RegExp('(^|\\s)@($attachmentFolder/\\S+)');

/// The inverse of [withAttachments]: the text without the attachment mentions, and their paths
/// in order. Other `@` mentions stay in the text.
({String text, List<String> paths}) splitAttachments(String message) {
  final paths = <String>[];
  final text = message.replaceAllMapped(_mention, (m) {
    paths.add(m.group(2)!);
    return m.group(1)!;
  });
  if (paths.isEmpty) return (text: message, paths: const []);
  return (text: text.trim(), paths: paths);
}

/// How many pieces a file of [size] bytes is sent in (at least one).
int attachmentPieces(int size) => size <= 0 ? 1 : (size + attachmentPieceBytes - 1) ~/ attachmentPieceBytes;

/// About how many relay messages a file of [size] bytes costs: the pieces, the host's
/// acknowledgements, start, accepted, end and done.
int attachmentRelayMessages(int size) {
  final pieces = attachmentPieces(size);
  return pieces + (pieces + attachmentAckEvery - 1) ~/ attachmentAckEvery + 4;
}
