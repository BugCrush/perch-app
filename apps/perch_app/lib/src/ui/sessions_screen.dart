// One machine's sessions: its name, how many need you, usage, then the sessions grouped by
// what they need (Pinned, Needs you, Working, Idle and finished, Not running).
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/host_connection.dart';
import '../state/providers.dart';
import '../state/session_prefs.dart';
import 'accounts_screen.dart' show machineAccountLine, switchMachineAccount;
import 'compatibility.dart';
import 'glass/dots.dart';
import 'glass/mosaic.dart';
import 'glass/pressable.dart';
import 'glass/settings.dart';
import 'glass/widgets.dart';
import 'labels.dart';
import 'machine_menu.dart';
import 'new_session_sheet.dart';
import 'session_row.dart';
import 'usage_limit_card.dart';
import 'glass/click.dart';

class SessionsScreen extends StatefulWidget {
  final HostConnection connection;
  final OpenSession onOpenSession;

  /// This phone's pins, hidden sessions and mutes; null: the app's (from the provider),
  /// else kept in memory only.
  final SessionPrefs? prefs;

  /// The current time (replaced in tests); times are shown in IST.
  final DateTime Function() clock;

  const SessionsScreen(
      {super.key,
      required this.connection,
      this.onOpenSession = openSessionScreen,
      this.prefs,
      this.clock = DateTime.now});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  SessionPrefs? _prefs;
  bool _notRunningOpen = false;

  HostConnection get connection => widget.connection;
  String get machineId => connection.machine.id;
  SessionPrefs get prefs => _prefs!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _prefs ??= widget.prefs ?? prefsOf(context);
  }

  /// Hidden sessions that run again are shown again (and no longer hidden).
  void _unhideRunning(List<SessionSummary> sessions) {
    final back = [for (final s in sessions) if (s.live && prefs.isHidden(machineId, s.id)) s.id];
    if (back.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final id in back) {
        prefs.unhide(machineId, id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        connection.sessions,
        connection.usage,
        connection.link,
        connection.route,
        connection.displayName,
        connection.compatibility,
        connection.usageLimit,
        connection.accounts,
        prefs
      ]),
      builder: (context, _) {
        final all = [...connection.sessions.value]..sort((a, b) => b.startedAtMs.compareTo(a.startedAtMs));
        _unhideRunning(all);
        final sessions = [for (final s in all) if (s.live || !prefs.isHidden(machineId, s.id)) s];
        final byId = {for (final s in sessions) s.id: s};
        final pinned = [for (final id in prefs.pins(machineId)) if (byId[id] != null) byId[id]!];
        final pinnedIds = {for (final s in pinned) s.id};
        final rest = [for (final s in sessions) if (!pinnedIds.contains(s.id)) s];
        final running = rest.where((s) => s.live).toList();
        final need = running.where(needsYou).toList();
        final working = running.where((s) => s.state == SessionState.working).toList();
        final others = running.where((s) => !needsYou(s) && s.state != SessionState.working).toList();
        final notRunning = rest.where((s) => !s.live).toList();
        final link = connection.link.value;
        final online = link == LinkState.online;
        final route = connection.route.value;
        final workingNow = all.where((s) => s.live && s.state == SessionState.working).length;
        final needCount = sessionsNeedingYou(all);
        final version = connection.compatibility.value?.claudeVersion;
        final usage = connection.usage.value;
        final limit = online ? connection.usageLimit.value : null;
        return GlassScaffold(
          background: MosaicBackdrop(seed: seedOf(machineId), fade: G.deep, fadeFrom: 0.3, pixel: 0.6, flap: true),
          child: ListView(
            key: const ValueKey('sessions-list'),
            padding: screenPadding(context),
            children: [
              Row(children: [
                GlassOrb(
                    key: const ValueKey('back'),
                    icon: Icons.arrow_back_rounded,
                    label: 'Back',
                    onTap: () => Navigator.of(context).maybePop()),
                Expanded(
                  child: Text((online && route != null ? routeLabel(route) : linkLabel(link)).toUpperCase(),
                      textAlign: TextAlign.center, style: gCaps(11, color: G.text).copyWith(shadows: lift)),
                ),
                GlassOrb(
                  key: const ValueKey('new-session'),
                  icon: Icons.add_rounded,
                  label: 'New session',
                  onTap: () => showNewSessionSheet(context, connection),
                ),
              ]),
              const SizedBox(height: 56),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ClickDetector(
                      key: const ValueKey('machine-title'),
                      onLongPress: () => showMachineMenu(context, connection),
                      child: Text(machineTitle(connection),
                          style: gSerif(38, w: FontWeight.w500, height: 1.05).copyWith(shadows: lift)),
                    ),
                    const SizedBox(height: 6),
                    if (!online)
                      Row(children: [
                        LedDot(linkColor(link)),
                        const SizedBox(width: 7),
                        Flexible(child: Text(linkLabel(link), style: gSans(13, FontWeight.w600).copyWith(shadows: lift))),
                      ])
                    else if (version != null)
                      Text('Claude Code $version', style: gSans(13, FontWeight.w600).copyWith(shadows: lift)),
                    if (connection.accounts.value case final acc? when online)
                      ClickDetector(
                        key: const ValueKey('machine-account'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => switchMachineAccount(context, connection),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(text: machineAccountLine(acc, acc.activeAccountId)),
                              const TextSpan(text: '  '),
                              const WidgetSpan(alignment: PlaceholderAlignment.middle, child: ValuePill('Switch')),
                            ]),
                            style: gSans(13, FontWeight.w600).copyWith(shadows: lift),
                          ),
                        ),
                      ),
                    if (workingNow > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(children: [
                          const WorkingWave(width: 30, height: 14, bars: 7),
                          const SizedBox(width: 8),
                          Text('$workingNow working now', style: gSans(13, FontWeight.w600).copyWith(shadows: lift)),
                        ]),
                      ),
                  ]),
                ),
                SizedBox.square(
                  dimension: 104,
                  child: Frost(
                    radius: 52,
                    rim: true,
                    tone: G.deep,
                    tint: 0.4,
                    padding: EdgeInsets.zero,
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      DotMatrix('$needCount', dot: 5.5),
                      const SizedBox(height: 7),
                      Text(needCount == 1 ? 'needs you' : 'need you', style: gSans(12, FontWeight.w600)),
                    ]),
                  ),
                ),
              ]),
              const SizedBox(height: 18),
              if (limit != null) ...[
                UsageLimitCard(connection: connection, limit: limit, onOpenSession: widget.onOpenSession, clock: widget.clock),
                const SizedBox(height: 14),
              ],
              CompatibilityNotice(connection: connection),
              if (usage != null && (usage.fiveHour != null || usage.sevenDay != null))
                Frost(
                  key: const ValueKey('usage'),
                  tone: G.deep,
                  tint: 0.42,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (usage.accountId != null && connection.accounts.value != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('USAGE · ${machineAccountLine(connection.accounts.value!, usage.accountId!).toUpperCase()}',
                          key: const ValueKey('usage-account'), style: gCaps(10.5)),
                    ),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (usage.fiveHour case final w?)
                      Expanded(
                          child: UsageMeter(
                              label: '5-HOUR', window: w, note: w.resetsAt > 0 ? 'resets ${resetClock(w.resetsAt)}' : '')),
                    if (usage.fiveHour != null && usage.sevenDay != null) const SizedBox(width: 18),
                    if (usage.sevenDay case final w?)
                      Expanded(
                          child: UsageMeter(
                              label: 'WEEKLY',
                              window: w,
                              note: w.resetsAt > 0 ? 'resets ${resetClock(w.resetsAt, withDay: true)}' : '')),
                  ]),
                  ]),
                ),
              if (sessions.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text('No sessions on this machine yet.', style: gSans(15, FontWeight.w600).copyWith(shadows: lift)),
                ),
              ..._section('Pinned', pinned),
              ..._section('Needs you', need),
              ..._section('Working', working),
              ..._section('Idle and finished', others),
              if (notRunning.isNotEmpty) ...[
                const SizedBox(height: 14),
                Pressable(
                  key: const ValueKey('not-running'),
                  haptic: Haptic.selection,
                  semanticLabel: 'Not running',
                  onTap: () => setState(() => _notRunningOpen = !_notRunningOpen),
                  builder: (context, p, child) => Opacity(opacity: 1 - p.clamp(0, 1) * 0.3, child: child),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      Text('Not running'.toUpperCase(), style: gCaps(11)),
                      const SizedBox(width: 6),
                      Text('${notRunning.length}', style: gSans(11, FontWeight.w800, color: G.muted)),
                      const Spacer(),
                      Icon(_notRunningOpen ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: G.muted),
                    ]),
                  ),
                ),
                if (_notRunningOpen)
                  for (final s in notRunning) _row(s),
              ],
              const SizedBox(height: 22),
              Center(child: StopAllButton(connections: [connection])),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _section(String title, List<SessionSummary> items) {
    if (items.isEmpty) return const [];
    return [
      const SizedBox(height: 22),
      Text(title.toUpperCase(), style: gCaps(11)),
      const SizedBox(height: 10),
      for (final s in items) _row(s),
    ];
  }

  Widget _row(SessionSummary s) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: SessionRow(
            connection: connection, session: s, prefs: prefs, onOpen: widget.onOpenSession, clock: widget.clock),
      );
}

/// A usage window on a machine's page: the share in LED dots over a glowing line, and when
/// it resets.
class UsageMeter extends StatelessWidget {
  final String label;
  final UsageWindow window;
  final String note;
  const UsageMeter({super.key, required this.label, required this.window, required this.note});
  @override
  Widget build(BuildContext context) => Semantics(
        label: '$label usage ${percent(window)} percent${note.isEmpty ? '' : ', $note'}',
        excludeSemantics: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(child: Text(label, style: gCaps(10.5, color: G.text))),
            DotMatrix('${percent(window)}%', dot: 3.2, glow: null),
          ]),
          const SizedBox(height: 4),
          UsageLine(value: window.utilization.clamp(0, 1).toDouble()),
          if (note.isNotEmpty) Text(note, style: gSans(12, FontWeight.w500, color: G.muted)),
        ]),
      );
}
