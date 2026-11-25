// A session's menu (its dots, press and hold, or the conversation's menu orb): only what
// applies to the session's state now. Rename, Resume and Delete act through the host.
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/host_connection.dart';
import '../state/session_prefs.dart';
import 'accounts_screen.dart' show machineAccountName, showAccountPicker;
import 'glass/dots.dart';
import 'glass/mosaic.dart';
import 'glass/widgets.dart';
import 'labels.dart';
import 'model_table_screen.dart' show chooseModel, isDefaultChoice;
import 'new_session_sheet.dart';

IconData sessionMenuIcon(SessionMenuItem i) => switch (i) {
      SessionMenuItem.limitContinue => Icons.update_rounded,
      SessionMenuItem.limitWait => Icons.pause_circle_outline_rounded,
      SessionMenuItem.interrupt => Icons.pan_tool_rounded,
      SessionMenuItem.mute => Icons.notifications_off_rounded,
      SessionMenuItem.unmute => Icons.notifications_rounded,
      SessionMenuItem.rename => Icons.edit_rounded,
      SessionMenuItem.model => Icons.memory_rounded,
      SessionMenuItem.pin => Icons.push_pin_rounded,
      SessionMenuItem.unpin => Icons.push_pin_outlined,
      SessionMenuItem.newHere => Icons.add_rounded,
      SessionMenuItem.switchAccount => Icons.switch_account_rounded,
      SessionMenuItem.resume => Icons.play_arrow_rounded,
      SessionMenuItem.hide => Icons.visibility_off_rounded,
      SessionMenuItem.end => Icons.power_settings_new_rounded,
      SessionMenuItem.delete => Icons.delete_outline_rounded,
    };

/// Opens [session]'s menu over [context] (a screen) and carries out the choice there.
/// [onDeleted] runs after the host deleted it (the conversation screen closes).
Future<void> showSessionMenu(BuildContext context,
    {required HostConnection connection,
    required SessionSummary session,
    required SessionPrefs prefs,
    VoidCallback? onDeleted}) async {
  final mid = connection.machine.id;
  final pinned = prefs.isPinned(mid, session.id);
  final muted = prefs.isMuted(mid, session.id);
  final working = session.live && session.state == SessionState.working;
  final limit = connection.usageLimit.value;
  final choice = await showGlassSheet<SessionMenuItem>(
    context,
    barrier: const Color(0x66000000),
    (ctx) => GlassSheet(children: [
      menuHeader(
        seedOf(session.id),
        session.name.isEmpty ? 'Session' : session.name,
        Row(children: [
          if (working) ...[const WorkingWave(width: 26, height: 12, bars: 6), const SizedBox(width: 7)],
          Flexible(
            child: Text('${machineTitle(connection)} · ${stateLabel(session)}',
                style: gSans(13, FontWeight.w500, color: G.muted)),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      if (limit?.session(session.id) != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('AT THE USAGE LIMIT (THIS SESSION)', style: gCaps(10.5)),
        ),
      for (final i in sessionMenuItems(session,
          pinned: pinned,
          muted: muted,
          limit: limit,
          accounts: connection.accounts.value?.accounts.isNotEmpty ?? false,
          control: connection.canControl))
        MenuRow(
          label: sessionMenuLabel(i),
          icon: sessionMenuIcon(i),
          danger: i == SessionMenuItem.delete || i == SessionMenuItem.end,
          selected: sessionMenuChosen(i, session.id, limit),
          onTap: () => Navigator.of(ctx).pop(i),
        ),
    ]),
  );
  if (choice == null || !context.mounted) return;
  await runSessionMenuItem(context, choice, connection: connection, session: session, prefs: prefs, onDeleted: onDeleted);
}

/// Carries out one menu item for [session].
Future<void> runSessionMenuItem(BuildContext context, SessionMenuItem i,
    {required HostConnection connection,
    required SessionSummary session,
    required SessionPrefs prefs,
    VoidCallback? onDeleted}) async {
  final s = session;
  final mid = connection.machine.id;
  final where = machineTitle(connection);

  /// Runs a host action and says how it went; true when it was done.
  Future<bool> act(Future<String> Function() run) async {
    try {
      final line = await run();
      if (context.mounted) say(context, line.isEmpty ? 'Done' : line);
      return true;
    } on SessionActionFailed catch (e) {
      if (context.mounted) say(context, e.message);
      return false;
    }
  }

  switch (i) {
    case SessionMenuItem.limitContinue:
    case SessionMenuItem.limitWait:
      final wait = i == SessionMenuItem.limitWait;
      try {
        await connection.chooseLimit(wait ? LimitChoices.wait : LimitChoices.continueWhenAvailable, sessionId: s.id);
        if (context.mounted) {
          say(context, wait ? '${s.name} waits for you at the usage limit' : '${s.name} continues when usage is back');
        }
      } on SessionActionFailed catch (e) {
        if (context.mounted) say(context, e.message);
      }
    case SessionMenuItem.interrupt:
      connection.interrupt(s.id);
      say(context, 'Interrupting ${s.name}');
    case SessionMenuItem.mute:
      await prefs.mute(mid, s.id);
      if (context.mounted) say(context, 'No notifications for ${s.name} on this phone');
    case SessionMenuItem.unmute:
      await prefs.unmute(mid, s.id);
      if (context.mounted) say(context, 'Notifications for ${s.name} are on again');
    case SessionMenuItem.rename:
      final name = await showSessionRenameSheet(context, current: s.name);
      if (name == null || !context.mounted) return;
      await act(() => connection.renameSession(s.id, name));
    case SessionMenuItem.model:
      final m = await chooseModel(context, title: "${s.name.isEmpty ? 'This session' : s.name}'s model", current: s.model);
      if (m == null || !context.mounted) return;
      await act(() => connection.setSessionModel(s.id, isDefaultChoice(m) ? null : m));
    case SessionMenuItem.pin:
      try {
        await prefs.pin(mid, s.id);
      } on TooManyPins catch (e) {
        if (context.mounted) say(context, '$e');
      }
    case SessionMenuItem.unpin:
      await prefs.unpin(mid, s.id);
    case SessionMenuItem.newHere:
      await showNewSessionSheet(context, connection, folder: s.cwd);
    case SessionMenuItem.switchAccount:
      final accounts = connection.accounts.value;
      final to = await showAccountPicker(context, connection,
          title: "Switch ${s.name.isEmpty ? 'this session' : s.name}'s account",
          body: 'Only this session moves; the machine keeps its account for new sessions.',
          current: s.accountId,
          exclude: {?s.accountId});
      if (to == null || !context.mounted || accounts == null) return;
      final name = machineAccountName(accounts, to);
      if (!await confirmSheet(context,
          title: 'Restart on $name?',
          body: 'Claude Code cannot change the account of a running session. Perch ends it in its terminal on $where '
              'and resumes the same conversation in a new terminal window on $name. Anything Claude is doing now stops.',
          yes: 'Restart on $name')) {
        return;
      }
      if (!context.mounted) return;
      say(context, 'Restarting ${s.name} on $name…');
      await act(() => connection.switchSessionAccount(s.id, to));
    case SessionMenuItem.resume:
      say(context, 'Opening a terminal window on $where…');
      await act(() => connection.resumeSession(s.id));
    case SessionMenuItem.hide:
      await prefs.hide(mid, s.id);
      await prefs.unpin(mid, s.id);
      if (context.mounted) {
        say(context, 'Hidden until it runs again', action: 'Undo', onAction: () => prefs.unhide(mid, s.id));
      }
    case SessionMenuItem.end:
      if (await confirmDanger(context,
          title: 'End ${s.name.isEmpty ? 'this session' : s.name}?',
          lost: 'Claude Code quits in its terminal on $where; anything Claude is doing now is cut off. '
              'The conversation is kept: Resume brings it back.',
          yes: 'End session')) {
        connection.stopSession(s.id);
      }
    case SessionMenuItem.delete:
      if (!await confirmDanger(context,
          title: 'Delete ${s.name.isEmpty ? 'this session' : s.name}?',
          lost: '${s.live ? 'It is ended first. ' : ''}Its whole conversation is deleted from $where for Claude Code too: '
              'claude --resume will not list it. This cannot be undone.',
          yes: 'Delete',
          hold: true)) {
        return;
      }
      if (!context.mounted) return;
      if (await act(() => connection.deleteSession(s.id))) {
        await prefs.forgetSession(mid, s.id);
        onDeleted?.call();
      }
  }
}

/// Asks for a session's new name (1 to 100 characters, spaces collapsed); null when
/// cancelled.
Future<String?> showSessionRenameSheet(BuildContext context, {required String current}) =>
    showGlassSheet<String>(context, (_) => _SessionRenameSheet(current: current));

class _SessionRenameSheet extends StatefulWidget {
  final String current;
  const _SessionRenameSheet({required this.current});
  @override
  State<_SessionRenameSheet> createState() => _SessionRenameSheetState();
}

class _SessionRenameSheetState extends State<_SessionRenameSheet> {
  late final _text = TextEditingController(text: widget.current);
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final t = _text.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final error = t.isEmpty ? 'Enter a name' : (t.length > 100 ? 'At most 100 characters' : null);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(t);
  }

  @override
  Widget build(BuildContext context) => GlassSheet(children: [
        ...sheetTitle('Rename session', 'Claude Code uses this name too.'),
        const SizedBox(height: 14),
        GlassField(
          controller: _text,
          label: 'Name',
          autofocus: true,
          error: _error,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: GlassButton(label: 'Cancel', onTap: () => Navigator.of(context).pop())),
          const SizedBox(width: 10),
          Expanded(child: GlassButton(label: 'Save', warm: true, onTap: _save)),
        ]),
      ]);
}
