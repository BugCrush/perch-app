// Attachments from the phone: each picked file uploads at once, in pieces of 512 KB over the
// encrypted channel, with at most four unacknowledged; the host writes it into the session's
// folder under `perch-attachments/` and the message mentions it with `@`.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'host_connection.dart';

enum AttachmentState { uploading, done, failed }

const _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif'};

/// What the phone shows when an attachment fails without a word from the host.
abstract final class AttachmentErrors {
  static const tooBig = 'Files up to 20 MB';
  static const connectionLost = 'Connection lost; tap Retry';
  static const notConnected = 'Not connected; tap Retry';
  static const watchOnly = 'This device can only watch';
  static const empty = 'Empty file';

  /// Reasons Retry cannot help with (the chip offers only Remove).
  static const noRetry = {tooBig, empty};
}

/// One picked file and how its upload goes.
class Attachment extends ChangeNotifier {
  final String name;
  final int size;
  final String? mime;

  /// The picked image itself (shown small); null for other files.
  final Uint8List? thumbnailBytes;
  final Uint8List _bytes;
  final String? sessionId;
  final String? cwd;

  AttachmentState state = AttachmentState.uploading;

  /// Bytes the host has acknowledged.
  int sent = 0;

  /// Where the file is, relative to the session's folder (`perch-attachments/<name>`).
  String? path;
  String? error;

  String _uploadId = '';
  bool _accepted = false;
  int _nextPiece = 0;
  late final String _sha = sha256.convert(_bytes).toString();

  Attachment._(this.name, this._bytes, this.mime, this.sessionId, this.cwd, {int? size})
      : size = size ?? _bytes.length,
        thumbnailBytes = _isImage(name, mime) ? _bytes : null;

  /// The picked bytes (kept for Retry, and for the conversation's thumbnail once sent).
  Uint8List get bytes => _bytes;

  bool get isImage => _isImage(name, mime);

  static bool _isImage(String name, String? mime) {
    if (mime != null && mime.startsWith('image/')) return true;
    final dot = name.lastIndexOf('.');
    return dot >= 0 && _imageExtensions.contains(name.substring(dot + 1).toLowerCase());
  }

  void _set({AttachmentState? state, int? sent, String? path, String? error}) {
    if (state != null) this.state = state;
    if (sent != null) this.sent = sent;
    if (path != null) this.path = path;
    this.error = error ?? (state == AttachmentState.failed ? this.error : null);
    notifyListeners();
  }
}

/// Uploads the attachments of one composer (a conversation's, or the New session sheet's).
class AttachmentUploader extends ChangeNotifier {
  final HostConnection conn;
  final List<Attachment> _items = [];
  final Map<String, Attachment> _byId = {};
  late final StreamSubscription<HostMessage> _events;
  late final StreamSubscription<Welcome> _welcomes;
  bool _disposed = false;

  AttachmentUploader(this.conn) {
    _events = conn.attachmentEvents.listen(_onEvent);
    _welcomes = conn.welcomes.listen((_) => _failUploading(conn.canControl ? AttachmentErrors.connectionLost : AttachmentErrors.watchOnly));
    conn.link.addListener(_onLink);
  }

  List<Attachment> get items => List.unmodifiable(_items);

  /// Some attachment is still uploading.
  bool get uploading => _items.any((a) => a.state == AttachmentState.uploading);

  /// Some attachment failed (Send waits until it is retried or removed).
  bool get hasFailed => _items.any((a) => a.state == AttachmentState.failed);

  /// The paths of the finished attachments, in the order they were picked.
  List<String> get donePaths => [
        for (final a in _items)
          if (a.state == AttachmentState.done && a.path != null) a.path!
      ];

  /// Starts uploading [bytes] into [sessionId]'s folder, or [cwd] for a new session. [size]:
  /// the file's size when its bytes were not read (a file over the limit).
  Attachment add(
      {required String name, required Uint8List bytes, String? mime, String? sessionId, String? cwd, int? size}) {
    final a = Attachment._(name, bytes, mime, sessionId, cwd, size: size);
    _items.add(a);
    if (a.size == 0) {
      a._set(state: AttachmentState.failed, error: AttachmentErrors.empty);
    } else if (a.size > maxAttachmentBytes || a.size != bytes.length) {
      a._set(state: AttachmentState.failed, error: AttachmentErrors.tooBig);
    } else {
      _start(a);
    }
    notifyListeners();
    return a;
  }

  /// Uploads a failed attachment again, as a new upload.
  void retry(Attachment a) {
    if (a.state != AttachmentState.failed || AttachmentErrors.noRetry.contains(a.error) || !_items.contains(a)) return;
    _start(a);
    notifyListeners();
  }

  /// Drops [a] from the list; an upload in progress is cancelled (a finished file stays on the
  /// machine, unused).
  void remove(Attachment a) {
    if (!_items.remove(a)) return;
    _cancel(a);
    notifyListeners();
  }

  /// Drops every attachment (after Send, or when the folder changes).
  void clear() {
    for (final a in _items) {
      _cancel(a);
    }
    _items.clear();
    notifyListeners();
  }

  void _cancel(Attachment a) {
    _byId.remove(a._uploadId);
    if (a.state == AttachmentState.uploading) conn.sendAttach(AttachCancel(uploadId: a._uploadId));
  }

  static final _random = Random.secure();

  void _start(Attachment a) {
    _byId.remove(a._uploadId);
    a._uploadId = base64UrlNoPad(Uint8List.fromList([for (var i = 0; i < 16; i++) _random.nextInt(256)]));
    a._accepted = false;
    a._nextPiece = 0;
    a.path = null;
    a._set(state: AttachmentState.uploading, sent: 0);
    _byId[a._uploadId] = a;
    final ok = conn.sendAttach(AttachStart(
        uploadId: a._uploadId,
        sessionId: a.sessionId,
        cwd: a.sessionId == null ? a.cwd : null,
        name: a.name,
        size: a.size,
        mime: a.mime ?? ''));
    if (!ok) _fail(a, AttachmentErrors.notConnected);
  }

  void _fail(Attachment a, String reason) {
    _byId.remove(a._uploadId);
    a._set(state: AttachmentState.failed, error: reason);
    notifyListeners();
  }

  /// Sends pieces while fewer than [attachmentWindow] are unacknowledged; the end after the last.
  void _pump(Attachment a) {
    final pieces = attachmentPieces(a.size);
    final acked = a.sent >= a.size ? pieces : a.sent ~/ attachmentPieceBytes;
    while (a._nextPiece < pieces && a._nextPiece - acked < attachmentWindow) {
      final i = a._nextPiece++;
      final end = min((i + 1) * attachmentPieceBytes, a.size);
      final data = base64Encode(Uint8List.sublistView(a._bytes, i * attachmentPieceBytes, end));
      if (!conn.sendAttach(AttachChunk(uploadId: a._uploadId, index: i, data: data))) {
        _fail(a, AttachmentErrors.connectionLost);
        return;
      }
      if (a._nextPiece == pieces) conn.sendAttach(AttachEnd(uploadId: a._uploadId, sha256: a._sha));
    }
  }

  void _onEvent(HostMessage m) {
    switch (m) {
      case AttachAccepted(:final uploadId, :final path):
        final a = _byId[uploadId];
        if (a == null || a._accepted) return;
        a._accepted = true;
        a.path = path;
        _pump(a);
      case AttachProgress(:final uploadId, :final received):
        final a = _byId[uploadId];
        if (a == null) return;
        a._set(sent: received);
        _pump(a);
      case AttachDone(:final uploadId, :final path):
        final a = _byId.remove(uploadId);
        if (a == null) return;
        a._set(state: AttachmentState.done, sent: a.size, path: path);
        notifyListeners();
      case AttachFailed(:final uploadId, :final reason):
        final a = _byId[uploadId];
        if (a == null) return;
        _fail(a, reason);
      default:
        break;
    }
  }

  void _onLink() {
    if (conn.link.value == LinkState.online) return;
    _failUploading(AttachmentErrors.connectionLost);
  }

  /// The host's side of these uploads is gone (the connection went or was replaced).
  void _failUploading(String reason) {
    for (final a in _items) {
      if (a.state == AttachmentState.uploading) _fail(a, reason);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _events.cancel();
    _welcomes.cancel();
    conn.link.removeListener(_onLink);
    for (final a in _items) {
      if (a.state == AttachmentState.uploading) conn.sendAttach(AttachCancel(uploadId: a._uploadId));
    }
    super.dispose();
  }
}
