// Attachments in a composer: the paperclip, its Photo / File sheet, and a row of chips (a small
// picture or the file's name, progress, and Retry / Remove when an upload failed).
import 'package:file_picker/file_picker.dart' show FilePicker;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart' show ImagePicker, ImageSource;
import 'package:material_ui/material_ui.dart' show CircularProgressIndicator, Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/attachment_upload.dart';
import 'glass/click.dart';
import 'glass/mosaic.dart';
import 'glass/palette.dart';
import 'glass/widgets.dart';

/// A file the owner picked: its name, its bytes as they are (never shrunk), and its type.
class PickedFile {
  final String name;
  final Uint8List bytes;
  final String? mime;

  /// The file's size when its bytes were not read (over the limit); else the bytes' length.
  final int size;
  PickedFile({required this.name, required this.bytes, this.mime, int? size}) : size = size ?? bytes.length;
}

/// Where attachments come from (the phone's pickers; a fake in tests).
abstract class AttachmentPicker {
  /// A photo from the phone's photo picker (null: none chosen).
  Future<PickedFile?> photo();

  /// Any file from the system's file picker (null: none chosen).
  Future<PickedFile?> file();
}

/// The phone's photo picker and system file picker. Files over the limit are not read.
class SystemAttachmentPicker implements AttachmentPicker {
  const SystemAttachmentPicker();

  @override
  Future<PickedFile?> photo() async {
    // No size or quality options: the original is sent as it is.
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, requestFullMetadata: false);
    if (x == null) return null;
    final size = await x.length();
    if (size > maxAttachmentBytes) return PickedFile(name: x.name, bytes: Uint8List(0), mime: x.mimeType, size: size);
    return PickedFile(name: x.name, bytes: await x.readAsBytes(), mime: x.mimeType ?? _mimeOf(x.name));
  }

  @override
  Future<PickedFile?> file() async {
    final f = await FilePicker.pickFile();
    if (f == null) return null;
    final size = f.lengthSync() ?? await f.length() ?? 0;
    if (size > maxAttachmentBytes) return PickedFile(name: f.name, bytes: Uint8List(0), size: size);
    return PickedFile(name: f.name, bytes: await f.readAsBytes(), mime: _mimeOf(f.name));
  }

  static String? _mimeOf(String name) {
    final ext = name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : '';
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'pdf' => 'application/pdf',
      _ => null,
    };
  }
}

/// Asks Photo or File and picks one (null: nothing chosen).
Future<PickedFile?> pickAttachment(BuildContext context, AttachmentPicker picker) async {
  final which = await showGlassSheet<String>(
    context,
    (ctx) => GlassSheet(children: [
      ...sheetTitle('Attach', 'Sent as it is, up to 20 MB. It is saved in the session\'s folder, in perch-attachments.'),
      const SizedBox(height: 10),
      MenuRow(label: 'Photo', icon: Icons.photo_outlined, onTap: () => Navigator.of(ctx).pop('photo')),
      MenuRow(label: 'File', icon: Icons.insert_drive_file_outlined, onTap: () => Navigator.of(ctx).pop('file')),
    ]),
  );
  if (which == null) return null;
  try {
    return which == 'photo' ? await picker.photo() : await picker.file();
  } catch (_) {
    return null;
  }
}

/// The paperclip beside a composer's field.
class AttachButton extends StatelessWidget {
  final VoidCallback onTap;
  const AttachButton({super.key, required this.onTap});
  @override
  Widget build(BuildContext context) => GlassOrb(icon: Icons.attach_file_rounded, size: 44, label: 'Attach', onTap: onTap);
}

String _sizeText(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// One chip per attachment, in a row that scrolls sideways.
class AttachmentChips extends StatelessWidget {
  final List<Attachment> items;

  /// The machine is reached through the relay: each chip says roughly what the file costs.
  final bool viaRelay;
  final void Function(Attachment) onRetry;
  final void Function(Attachment) onRemove;
  const AttachmentChips(
      {super.key, required this.items, required this.viaRelay, required this.onRetry, required this.onRemove});

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          for (final a in items)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ListenableBuilder(
                listenable: a,
                builder: (context, _) => _Chip(a, viaRelay: viaRelay, onRetry: onRetry, onRemove: onRemove),
              ),
            ),
        ]),
      );
}

class _Chip extends StatelessWidget {
  final Attachment a;
  final bool viaRelay;
  final void Function(Attachment) onRetry;
  final void Function(Attachment) onRemove;
  const _Chip(this.a, {required this.viaRelay, required this.onRetry, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final failed = a.state == AttachmentState.failed;
    final thumb = a.thumbnailBytes;
    final note = failed
        ? a.error ?? 'Failed'
        : [
            _sizeText(a.size),
            if (viaRelay && a.state == AttachmentState.uploading) 'about ${attachmentRelayMessages(a.size)} relay messages',
          ].join(' · ');
    return Container(
      key: const ValueKey('attachment-chip'),
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: G.deep.withValues(alpha: 0.82),
        border: Border.all(color: failed ? Danger.edge : const Color(0x33FFFFFF)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox.square(
          dimension: 40,
          child: Stack(fit: StackFit.expand, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: thumb != null && thumb.isNotEmpty
                  ? Image.memory(thumb,
                      fit: BoxFit.cover,
                      cacheWidth: 120,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const _FileIcon())
                  : const _FileIcon(),
            ),
            if (a.state == AttachmentState.uploading)
              Center(
                child: SizedBox.square(
                  dimension: 26,
                  child: CircularProgressIndicator(
                    key: const ValueKey('attachment-progress'),
                    strokeWidth: 3,
                    value: a.size == 0 ? null : (a.sent / a.size).clamp(0.02, 1.0),
                    color: Perch.orange,
                    backgroundColor: const Color(0x55000000),
                  ),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(a.name, style: gSans(12.5, FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(note,
                style: gSans(11.5, FontWeight.w500, color: failed ? Danger.text : G.muted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            if (failed)
              Row(mainAxisSize: MainAxisSize.min, children: [
                if (!AttachmentErrors.noRetry.contains(a.error))
                  _Link(key: const ValueKey('attachment-retry'), label: 'Retry', onTap: () => onRetry(a)),
                _Link(key: const ValueKey('attachment-remove'), label: 'Remove', onTap: () => onRemove(a)),
              ]),
          ]),
        ),
        if (!failed)
          ClickDetector(
            key: const ValueKey('attachment-remove'),
            behavior: HitTestBehavior.opaque,
            onTap: () => onRemove(a),
            child: const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.close_rounded, size: 18, color: G.muted),
            ),
          ),
      ]),
    );
  }
}

class _FileIcon extends StatelessWidget {
  const _FileIcon();
  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0x1FFFFFFF),
        child: const Icon(Icons.insert_drive_file_outlined, size: 20, color: G.text),
      );
}

class _Link extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _Link({super.key, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => ClickDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(top: 4, right: 14),
          child: Text(label, style: gSans(12.5, FontWeight.w800, color: Perch.orange)),
        ),
      );
}
