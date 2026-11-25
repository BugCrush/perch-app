// One session in a list: its mosaic, name, state and where it is, with its menu.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/host_connection.dart';
import '../state/providers.dart';
import '../state/session_prefs.dart';
import '../time_format.dart';
import 'accounts_screen.dart' show sessionAccountLine;
import 'app_theme.dart';
import 'glass/dots.dart';
import 'glass/mosaic.dart';
import 'glass/pressable.dart';
import 'glass/widgets.dart';
import 'labels.dart';
import 'session_menu.dart';
import 'session_screen.dart';
import 'glass/click.dart';

typedef OpenSession = void Function(BuildContext context, HostConnection connection, String sessionId);

/// Opens the conversation screen for a session.
void openSessionScreen(BuildContext context, HostConnection connection, String sessionId) =>
    openGlass<void>(context, SessionScreen(connection: connection, sessionId: sessionId));

final _fallbackPrefs = SessionPrefs(persist: false);

/// This phone's pins, hidden sessions and mutes: the app's, else an in-memory set (screens
/// shown on their own in tests).
SessionPrefs prefsOf(BuildContext context) {
  try {
    return ProviderScope.containerOf(context, listen: false).read(sessionPrefsProvider);
  } catch (_) {
    return _fallbackPrefs;
  }
}

class SessionRow extends StatelessWidget {
  final HostConnection connection;
  final SessionSummary session;
  final SessionPrefs prefs;
  final OpenSession onOpen;

  /// Name the machine on the row (the first screen's "Waiting on you").
  final bool showMachine;

  /// The current time (replaced in tests); times are shown in IST.
  final DateTime Function() clock;
  const SessionRow({
    super.key,
    required this.connection,
    required this.session,
    required this.prefs,
    this.onOpen = openSessionScreen,
    this.showMachine = false,
    this.clock = DateTime.now,
  });

  void _menu(BuildContext context) => showSessionMenu(context, connection: connection, session: session, prefs: prefs);

  @override
  Widget build(BuildContext context) {
    final s = session;
    final mid = connection.machine.id;
    final pinned = prefs.isPinned(mid, s.id);
    final muted = prefs.isMuted(mid, s.id);
    final need = wantsYou(s);
    final working = s.live && s.state == SessionState.working;
    final account = sessionAccountLine(connection, s);
    final where = [
      if (showMachine) machineTitle(connection),
      shortFolder(s.cwd),
    ].where((x) => x.isNotEmpty).join(' · ');
    return Pressable(
      key: ValueKey('session-${s.id}'),
      onTap: () => onOpen(context, connection, s.id),
      onLongPress: () => _menu(context),
      semanticLabel: s.name,
      builder: (context, p, child) => Transform.scale(scale: 1 - p.clamp(0, 1) * 0.02, child: child),
      child: Frost(
        radius: 22,
        rim: need,
        tone: G.deep,
        tint: 0.42,
        padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
        child: Row(children: [
          Opacity(opacity: s.live ? 1 : 0.6, child: MosaicThumb(seed: seedOf(s.id), size: 56, radius: 16)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.name.isEmpty ? 'Session' : s.name,
                  style: gSans(16, FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Row(children: [
                if (working) ...[const WorkingWave(width: 30, height: 14, bars: 7), const SizedBox(width: 8)],
                Flexible(
                  child: Text(stateLabel(s),
                      style: gSans(13, FontWeight.w600, color: need ? G.glow : (working ? G.text : G.muted)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
              if (where.isNotEmpty)
                Text(where, style: gSans(12, FontWeight.w500, color: G.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
              if (s.lastPromptAtMs != null)
                Text('Last message ${formatIst(s.lastPromptAtMs!, now: clock())}',
                    key: ValueKey('lastMessage-${s.id}'), style: gSans(12, FontWeight.w500, color: G.muted)),
              if (s.origin == SessionOrigin.external || pinned || muted || account != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(spacing: 10, runSpacing: 4, children: [
                    if (s.origin == SessionOrigin.external)
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.terminal_rounded, size: 14, color: G.muted),
                        const SizedBox(width: 4),
                        Text('In a terminal', style: gSans(12, FontWeight.w600, color: G.muted)),
                      ]),
                    if (account != null)
                      Row(key: ValueKey('account-${s.id}'), mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.person_rounded, size: 14, color: G.muted),
                        const SizedBox(width: 4),
                        Text(account, style: gSans(12, FontWeight.w600, color: G.muted)),
                      ]),
                    if (pinned) const Icon(Icons.push_pin_rounded, size: 14, color: G.muted, semanticLabel: 'Pinned'),
                    if (muted)
                      const Icon(Icons.notifications_off_rounded, size: 14, color: G.muted, semanticLabel: 'Muted'),
                  ]),
                ),
            ]),
          ),
          ClickDetector(
            key: ValueKey('session-menu-${s.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => _menu(context),
            child: Semantics(
              button: true,
              label: 'Session menu',
              child: const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.more_vert_rounded, size: 20, color: G.muted)),
            ),
          ),
        ]),
      ),
    );
  }
}
