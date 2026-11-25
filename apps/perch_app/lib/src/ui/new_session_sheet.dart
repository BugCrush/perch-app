// Starting a session from the phone: choose a folder on the machine by browsing it, give
// the first instruction (and optionally a name and model), Start.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/host_connection.dart';
import '../state/providers.dart';
import 'accounts_screen.dart' show machineAccountIds, machineAccountName;
import 'glass/dots.dart';
import 'glass/mosaic.dart';
import 'glass/palette.dart';
import 'glass/pressable.dart';
import 'glass/widgets.dart';
import 'labels.dart';

/// [folder]: start with that folder chosen (New session here…).
Future<void> showNewSessionSheet(BuildContext context, HostConnection connection, {String? folder}) async {
  if (!connection.canControl) {
    say(context, watchOnlyMessage);
    return;
  }
  await showGlassSheet<void>(context, (_) => NewSessionSheet(connection: connection, folder: folder));
}

class NewSessionSheet extends StatefulWidget {
  final HostConnection connection;

  /// The folder chosen to start with; null: none (browsing starts at the latest session's).
  final String? folder;

  /// "Choose account per session" is on: the sheet asks which account (null: read from
  /// the app's accounts).
  final bool? perSession;
  const NewSessionSheet({super.key, required this.connection, this.folder, this.perSession});
  @override
  State<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<NewSessionSheet> {
  final _prompt = TextEditingController();
  final _name = TextEditingController();
  final _model = TextEditingController();

  /// The folder chosen with "Use this folder".
  String? _folder;
  String? _folderError;
  String? _promptError;
  String? _hostError;
  bool _waiting = false;
  Set<String> _known = {};
  StreamSubscription<ErrorMessage>? _errors;

  /// The folder being shown, and whether a listing is on its way.
  DirListing? _listing;
  bool _browsing = false;
  String? _browseError;

  /// The first listing asked for the roots only to learn the home folder.
  bool _wantHome = false;

  /// The first listing was the most recent session's folder (fall back to home if it fails).
  bool _initial = false;

  HostConnection get conn => widget.connection;

  /// The account picked for this session (per-session setting); null: the machine's.
  String? _account;
  bool? _perSession;

  bool get _asksAccount => (_perSession ?? false) && conn.accounts.value != null;

  /// The model table's rows (the app's; none outside the app).
  List<ModelRow> get _types {
    try {
      return ProviderScope.containerOf(context, listen: false).read(boardStoreProvider).table.rows;
    } catch (_) {
      return const [];
    }
  }

  bool _appPerSession() {
    try {
      return ProviderScope.containerOf(context, listen: false).read(phoneAccountsProvider).perSession;
    } catch (_) {
      return false; // outside the app (a test of the sheet alone)
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _perSession ??= widget.perSession ?? _appPerSession();
    _account ??= conn.accounts.value?.activeAccountId;
  }

  @override
  void initState() {
    super.initState();
    conn.sessions.addListener(_onSessions);
    conn.dirListing.addListener(_onListing);
    _errors = conn.errors.listen(_onError);
    final given = widget.folder;
    if (given != null && given.isNotEmpty) _folder = given;
    final recent = (given != null && given.isNotEmpty) ? given : mostRecentFolder(conn.sessions.value);
    if (recent != null) {
      _initial = true;
      _request(recent);
    } else {
      _wantHome = true;
      _request(null);
    }
  }

  void _request(String? path) {
    _browsing = true;
    _browseError = null;
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
    if (!mounted) return;
    if (_waiting) {
      setState(() {
        _hostError = e.message;
        _waiting = false;
      });
      return;
    }
    if (!_browsing) return;
    if (_initial) {
      // The last session's folder is gone: start at the home folder instead.
      _initial = false;
      _wantHome = true;
      _browse(null);
      return;
    }
    setState(() {
      _browsing = false;
      _browseError = e.message;
    });
  }

  void _onSessions() {
    if (!_waiting || !mounted) return;
    final now = conn.sessions.value;
    // A terminal session waiting for its folder to be trusted counts as started: its card is in the session.
    if (now.any((s) => !_known.contains(s.id) && (s.state != SessionState.blocked || s.origin == SessionOrigin.external))) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    conn.sessions.removeListener(_onSessions);
    conn.dirListing.removeListener(_onListing);
    _errors?.cancel();
    _prompt.dispose();
    _name.dispose();
    _model.dispose();
    super.dispose();
  }

  void _start() {
    final folder = _folder;
    final prompt = _prompt.text.trim();
    setState(() {
      _folderError = folder == null ? 'Enter a folder' : null;
      _promptError = prompt.isEmpty ? 'Enter an instruction' : null;
      _hostError = null;
    });
    if (folder == null || prompt.isEmpty) return;
    _known = {for (final s in conn.sessions.value) s.id};
    setState(() => _waiting = true);
    conn.startSession(
        cwd: folder, prompt: prompt, name: _name.text, model: _model.text, accountId: _asksAccount ? _account : null);
  }

  Widget _browser(BuildContext context) {
    final l = _listing;
    final shown = l == null ? '' : (l.path.isEmpty ? 'This computer' : l.path);
    final Widget body;
    if (_browsing || l == null) {
      body = Center(child: Text('Loading folders…', style: gSans(14, FontWeight.w500, color: G.muted)));
    } else if (l.entries.isEmpty) {
      body = Center(child: Text('No folders here', style: gSans(14, FontWeight.w500, color: G.muted)));
    } else {
      body = ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: l.entries.length,
        itemBuilder: (context, i) {
          final e = l.entries[i];
          return Pressable(
            key: ValueKey('dir-${e.path}'),
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
    final canUse = l != null && l.path.isNotEmpty && !_browsing;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: const Color(0x401B1519),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0x26FFFFFF)),
      ),
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          GlassOrb(
            key: const ValueKey('folder-up'),
            icon: Icons.arrow_upward_rounded,
            label: 'Up',
            size: 38,
            onTap: canUse ? () => _browse(l.parent) : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(shown,
                key: const ValueKey('shownFolder'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: gMono(12.5)),
          ),
        ]),
        if (l != null && l.suggested.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final s in l.suggested)
                GlassChip(
                  key: ValueKey('chip-${s.name}'),
                  label: s.name,
                  icon: s.name == 'Home' ? Icons.home_rounded : Icons.history_rounded,
                  onTap: () => _browse(s.path),
                ),
            ]),
          ),
        if (_browseError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Text(_browseError!, style: gSans(13, FontWeight.w700, color: G.glow)),
          ),
        SizedBox(height: 200, child: body),
        Align(
          alignment: Alignment.centerRight,
          child: GlassButton(
            label: 'Use this folder',
            icon: Icons.check_rounded,
            compact: true,
            onTap: canUse
                ? () => setState(() {
                      _folder = l.path;
                      _folderError = null;
                    })
                : null,
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassSheet(children: [
      Text('New session', style: gSerif(28, w: FontWeight.w500, height: 1.15)),
      Text('on ${machineTitle(conn)}', style: gSans(14, FontWeight.w500, color: G.muted)),
      const SizedBox(height: 14),
      Row(children: [
        Icon(_folder == null ? Icons.folder_off_rounded : Icons.check_circle_rounded,
            size: 18, color: _folderError != null ? G.glow : (_folder == null ? G.muted : Perch.led)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(_folder == null ? 'Folder: none chosen yet' : 'Folder: $_folder',
              key: const ValueKey('chosenFolder'), style: gSans(14, FontWeight.w600)),
        ),
      ]),
      if (_folderError != null)
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 26),
          child: Text(_folderError!, style: gSans(12.5, FontWeight.w700, color: G.glow)),
        ),
      _browser(context),
      const SizedBox(height: 14),
      GlassField(controller: _prompt, label: 'First instruction', minLines: 2, maxLines: 6, error: _promptError),
      const SizedBox(height: 12),
      GlassField(controller: _name, label: 'Name (optional)'),
      const SizedBox(height: 12),
      GlassField(controller: _model, label: 'Model (optional)', hint: 'Default'),
      if (_types.any((r) => r.model != null)) ...[
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 5),
          child: Text('Model from a task type', style: gSans(12.5, FontWeight.w700, color: G.muted)),
        ),
        Wrap(spacing: 6, runSpacing: 6, children: [
          GlassChip(
              key: const ValueKey('new-session-type-default'),
              label: 'Default',
              icon: _model.text.isEmpty ? Icons.check_rounded : Icons.auto_awesome_rounded,
              onTap: () => setState(() => _model.text = '')),
          for (final r in _types)
            if (r.model != null)
              GlassChip(
                  key: ValueKey('new-session-type-${r.id}'),
                  label: '${r.name} · ${r.model}',
                  icon: _model.text == r.model ? Icons.check_rounded : Icons.label_outline_rounded,
                  onTap: () => setState(() => _model.text = r.model!)),
        ]),
      ],
      if (_asksAccount) ...[
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 5),
          child: Text('Account', style: gSans(12.5, FontWeight.w700, color: G.muted)),
        ),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final id in machineAccountIds(conn.accounts.value!))
            GlassChip(
              key: ValueKey('new-session-account-$id'),
              label: machineAccountName(conn.accounts.value!, id),
              icon: id == _account ? Icons.check_rounded : Icons.person_outline_rounded,
              onTap: () => setState(() => _account = id),
            ),
        ]),
      ],
      if (_hostError != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_hostError!, style: gSans(14, FontWeight.w700, color: G.glow)),
        ),
      const SizedBox(height: 18),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        if (_waiting) ...[const WorkingWave(width: 40, height: 18, bars: 8), const SizedBox(width: 14)],
        GlassButton(label: 'Start', warm: true, icon: Icons.play_arrow_rounded, onTap: _waiting ? null : _start),
      ]),
    ]);
  }
}
