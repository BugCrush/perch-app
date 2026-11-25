// Choosing a folder on a machine by browsing it (tasks, Copy to… / Move to…): the same
// browser as the new-session sheet, in a sheet of its own that returns the chosen path.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/host_connection.dart';
import 'glass/mosaic.dart';
import 'glass/pressable.dart';
import 'glass/widgets.dart';
import 'labels.dart';

/// The chosen folder, or null when cancelled. Browsing starts at [start] (else the
/// machine's most recent session folder, else home).
Future<String?> pickFolder(BuildContext context, HostConnection connection, {String? start, String? title}) =>
    showGlassSheet<String>(context, (_) => FolderPicker(connection: connection, start: start, title: title));

class FolderPicker extends StatefulWidget {
  final HostConnection connection;
  final String? start;
  final String? title;
  const FolderPicker({super.key, required this.connection, this.start, this.title});
  @override
  State<FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<FolderPicker> {
  DirListing? _listing;
  bool _browsing = false;
  String? _error;
  bool _wantHome = false;
  bool _initial = false;
  StreamSubscription<ErrorMessage>? _errors;
  HostConnection get conn => widget.connection;

  @override
  void initState() {
    super.initState();
    conn.dirListing.addListener(_onListing);
    _errors = conn.errors.listen(_onError);
    final first = (widget.start != null && widget.start!.isNotEmpty) ? widget.start : mostRecentFolder(conn.sessions.value);
    if (first != null) {
      _initial = true;
      _request(first);
    } else {
      _wantHome = true;
      _request(null);
    }
  }

  @override
  void dispose() {
    conn.dirListing.removeListener(_onListing);
    _errors?.cancel();
    super.dispose();
  }

  void _request(String? path) {
    _browsing = true;
    _error = null;
    conn.listDir(path);
  }

  void _browse(String? path) => setState(() => _request(path));

  void _onListing() {
    final l = conn.dirListing.value;
    if (l == null || !mounted || !_browsing) return;
    _initial = false;
    if (_wantHome) {
      _wantHome = false;
      if (l.suggested.isNotEmpty) {
        _browse(l.suggested.last.path);
        return;
      }
    }
    setState(() {
      _browsing = false;
      _listing = l;
    });
  }

  void _onError(ErrorMessage e) {
    if (!mounted || !_browsing) return;
    if (_initial) {
      _initial = false;
      _wantHome = true;
      _browse(null);
      return;
    }
    setState(() {
      _browsing = false;
      _error = e.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = _listing;
    final canUse = l != null && l.path.isNotEmpty && !_browsing;
    final Widget body;
    if (_browsing || l == null) {
      body = Center(child: Text('Loading folders…', style: gSans(14, FontWeight.w500, color: G.muted)));
    } else if (l.entries.isEmpty) {
      body = Center(child: Text('No folders here', style: gSans(14, FontWeight.w500, color: G.muted)));
    } else {
      body = ListView.builder(
        itemCount: l.entries.length,
        itemBuilder: (context, i) {
          final e = l.entries[i];
          return Pressable(
            key: ValueKey('pick-${e.path}'),
            onTap: () => _browse(e.path),
            haptic: Haptic.selection,
            semanticLabel: e.name,
            builder: (context, p, child) => Opacity(opacity: 1 - p.clamp(0, 1) * 0.35, child: child),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(children: [
                const Icon(Icons.folder_rounded, size: 18, color: G.glow),
                const SizedBox(width: 10),
                Expanded(child: Text(e.name, style: gSans(14.5, FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
                const Icon(Icons.chevron_right_rounded, size: 18, color: G.muted),
              ]),
            ),
          );
        },
      );
    }
    return GlassSheet(children: [
      ...sheetTitle(widget.title ?? 'Choose a folder', 'on ${machineTitle(conn)}'),
      const SizedBox(height: 12),
      Row(children: [
        GlassOrb(
            key: const ValueKey('pick-up'),
            icon: Icons.arrow_upward_rounded,
            label: 'Up',
            size: 38,
            onTap: canUse ? () => _browse(l.parent) : null),
        const SizedBox(width: 10),
        Expanded(
          child: Text(l == null ? '' : (l.path.isEmpty ? 'This computer' : l.path),
              key: const ValueKey('pick-shown'), maxLines: 2, overflow: TextOverflow.ellipsis, style: gMono(12.5)),
        ),
      ]),
      if (l != null && l.suggested.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final s in l.suggested)
              GlassChip(
                  label: s.name,
                  icon: s.name == 'Home' ? Icons.home_rounded : Icons.history_rounded,
                  onTap: () => _browse(s.path)),
          ]),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_error!, style: gSans(13, FontWeight.w700, color: G.glow)),
        ),
      Container(
        height: 240,
        margin: const EdgeInsets.only(top: 10),
        decoration: BoxDecoration(
          color: const Color(0x401B1519),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0x26FFFFFF)),
        ),
        child: body,
      ),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: GlassButton(label: 'Cancel', onTap: () => Navigator.of(context).pop())),
        const SizedBox(width: 10),
        Expanded(
          child: GlassButton(
              label: 'Use this folder', warm: true, onTap: canUse ? () => Navigator.of(context).pop(l.path) : null),
        ),
      ]),
    ]);
  }
}
