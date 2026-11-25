// The first screen: how many sessions need you, the machines, what waits on you, and the
// kill switch, over the bird.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/host_connection.dart';
import '../state/providers.dart';
import 'accounts_screen.dart';
import 'app_menu.dart';
import 'add_machine_screen.dart';
import 'app_theme.dart';
import 'board_screen.dart';
import 'compatibility.dart';
import 'glass/dots.dart';
import 'glass/mosaic.dart';
import 'glass/palette.dart';
import 'glass/pressable.dart';
import 'glass/settings.dart';
import 'glass/theme.dart';
import 'glass/widgets.dart';
import 'labels.dart';
import 'machine_menu.dart';
import 'search_screen.dart';
import 'session_row.dart';
import 'sessions_screen.dart';
import 'update_notice.dart';
import 'usage_limit_card.dart' show limitSummary;
import 'glass/click.dart';

/// Opens a machine's sessions.
typedef OpenMachine = void Function(BuildContext context, HostConnection connection);

void openMachine(BuildContext context, HostConnection connection) =>
    openGlass<void>(context, SessionsScreen(connection: connection));

/// Every session that wants the owner across the connected machines (the attention list).
List<(HostConnection, SessionSummary)> waitingOnYou(List<HostConnection> connections) => [
      for (final c in connections)
        if (c.link.value == LinkState.online)
          for (final s in c.sessions.value)
            if (wantsYou(s)) (c, s)
    ];

class HomeScreen extends ConsumerWidget {
  final OpenMachine onOpen;
  final OpenSession onOpenSession;
  final void Function(BuildContext context) onOpenBoard;
  const HomeScreen(
      {super.key, this.onOpen = openMachine, this.onOpenSession = openSessionScreen, this.onOpenBoard = openBoard});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machines = ref.watch(machinesProvider);
    final registry = ref.watch(connectionsProvider);
    final connections = [for (final m in machines) registry.of(m)];
    final prefs = ref.watch(sessionPrefsProvider);
    final h = MediaQuery.sizeOf(context).height;
    return GlassScaffold(
      background: MosaicBackdrop(seed: 7, fade: G.deep, fadeFrom: 0.42, pixel: 0.75, flap: true),
      child: ListenableBuilder(
        listenable: Listenable.merge([
          prefs,
          for (final c in connections) ...[c.sessions, c.link, c.displayName, c.tasks],
        ]),
        builder: (context, _) {
          final waiting = waitingOnYou(connections);
          return ListView(
            key: const ValueKey('home-list'),
            padding: screenPadding(context),
            children: [
              Row(children: [
                GlassOrb(
                  key: const ValueKey('open-menu'),
                  icon: Icons.menu_rounded,
                  label: 'Menu: models, accounts, projects, appearance, checks',
                  onTap: () => showAppMenu(context),
                ),
                const Spacer(),
                GlassOrb(
                  key: const ValueKey('open-search'),
                  icon: Icons.search_rounded,
                  label: 'Search every conversation',
                  onTap: () => openGlass<void>(context, SearchScreen(connections: connections)),
                ),
              ]),
              const SizedBox(height: 14),
              const UpdateNotice(),
              const AccountsNotice(),
              for (final c in connections) CompatibilityNotice(connection: c, untested: false),
              SizedBox(height: h * 0.06),
              Center(child: NeedYouHero(count: waiting.length)),
              const SizedBox(height: 18),
              Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                HomeAction(
                  orbKey: const ValueKey('add-machine'),
                  icon: Icons.center_focus_strong_rounded,
                  label: 'Add machine',
                  onTap: () => openAddMachine(context),
                ),
                const SizedBox(width: 28),
                HomeAction(
                  orbKey: const ValueKey('open-board'),
                  icon: Icons.view_kanban_rounded,
                  label: 'Board',
                  note: boardReviewNote(connections),
                  onTap: () => onOpenBoard(context),
                ),
              ]),
              const SizedBox(height: 28),
              // Dark glass: it stays readable wherever it scrolls over the bird.
              Frost(
                rim: true,
                tone: G.deep,
                tint: 0.5,
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('MACHINES', style: gCaps(11)),
                  const SizedBox(height: 6),
                  for (final c in connections) MachineRow(key: ValueKey('machine-${c.machine.id}'), connection: c, onOpen: onOpen),
                  if (machines.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text('No machines yet. Start the Perch host on a computer and add it with its QR code.',
                          style: gSans(14, FontWeight.w500, color: G.muted)),
                    ),
                ]),
              ),
              if (waiting.isNotEmpty) ...[
                const SizedBox(height: 22),
                Text('WAITING ON YOU', style: gCaps(11)),
                const SizedBox(height: 10),
                for (final (c, s) in waiting)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SessionRow(
                        key: ValueKey('waiting-${c.machine.id}-${s.id}'),
                        connection: c,
                        session: s,
                        prefs: prefs,
                        onOpen: onOpenSession,
                        showMachine: true),
                  ),
              ],
              const SizedBox(height: 18),
              Center(child: StopAllButton(connections: connections)),
            ],
          );
        },
      ),
    );
  }
}

/// The Board entry's note under it: `2 to review` when tasks wait in Review (null: none).
String? boardReviewNote(List<HostConnection> connections) {
  final l = boardEntryLabel(connections);
  return l == 'Board' ? null : l.substring('Board · '.length);
}

/// One of the first screen's two big round actions (Add machine, Board): the orb, its
/// label under it and an optional orange note.
class HomeAction extends StatelessWidget {
  final Key orbKey;
  final IconData icon;
  final String label;
  final String? note;
  final VoidCallback onTap;
  const HomeAction({super.key, required this.orbKey, required this.icon, required this.label, required this.onTap, this.note});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 104,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          GlassOrb(key: orbKey, icon: icon, size: 64, label: note == null ? label : '$label, $note', onTap: onTap),
          const SizedBox(height: 6),
          Text(label, textAlign: TextAlign.center, style: gSans(13, FontWeight.w700).copyWith(shadows: lift)),
          if (note != null)
            Text(note!, textAlign: TextAlign.center, style: gSans(12, FontWeight.w800, color: G.glow).copyWith(shadows: lift)),
        ]),
      );
}

/// The Board entry: `Board`, or `Board · 2 to review` when tasks wait in Review.
String boardEntryLabel(List<HostConnection> connections) {
  final review = [
    for (final c in connections)
      if (c.link.value == LinkState.online)
        for (final t in c.tasks.value ?? const <BoardTask>[])
          if (t.column == TaskColumn.review) t
  ].length;
  return review == 0 ? 'Board' : 'Board · $review to review';
}

/// One machine in the Machines panel: its picture, name, connection, sessions and usage.
class MachineRow extends ConsumerWidget {
  final HostConnection connection;
  final OpenMachine onOpen;
  const MachineRow({super.key, required this.connection, this.onOpen = openMachine});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = connection;
    return ListenableBuilder(
      listenable: Listenable.merge([
        c.link,
        c.route,
        c.lastError,
        c.sessions,
        c.usage,
        c.machineName,
        c.displayName,
        c.hooksInstalled,
        c.hooksNoteDismissed,
        c.compatibility,
        c.usageLimit,
        c.accounts,
        c.permission,
      ]),
      builder: (context, _) {
        final m = c.machine;
        final accounts = c.link.value == LinkState.online ? c.accounts.value : null;
        final sessions = c.sessions.value;
        final link = c.link.value;
        final online = link == LinkState.online;
        final need = sessionsNeedingYou(sessions);
        final working = sessions.where((s) => s.live && s.state == SessionState.working).length;
        final title = c.displayName.value;
        final own = c.ownName;
        final usage = c.usage.value;
        final hooksNote = online && !c.hooksInstalled.value && !c.hooksNoteDismissed.value;
        final limit = online ? c.usageLimit.value : null;
        final muted = gSans(13, FontWeight.w500, color: G.muted);
        return Pressable(
          onTap: () => onOpen(context, c),
          onLongPress: () => showMachineMenu(context, c),
          semanticLabel: title,
          builder: (context, p, child) => Opacity(opacity: 1 - p.clamp(0, 1) * 0.3, child: child),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 4), child: MosaicThumb(seed: seedOf(m.id))),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: gSans(17, FontWeight.w700)),
                  if (title != own) Text('Machine name: $own', style: gSans(12, FontWeight.w500, color: G.muted)),
                  if (m.address.isNotEmpty) Text(m.address, style: muted),
                  const SizedBox(height: 3),
                  Row(children: [
                    LedDot(linkColor(link)),
                    const SizedBox(width: 7),
                    Flexible(
                        child: Text(linkLabel(link),
                            style: gSans(13, FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    if (online && c.route.value != null) ...[
                      Text(' · ', style: muted),
                      Flexible(child: Text(routeLabel(c.route.value!), style: muted)),
                    ],
                    if (online && !c.canControl) ...[
                      const SizedBox(width: 8),
                      ValuePill('Watch only', key: ValueKey('watch-only-${m.id}')),
                    ],
                  ]),
                  if ((link == LinkState.refused ||
                          link == LinkState.awaitingApproval ||
                          link == LinkState.denied ||
                          link == LinkState.removed) &&
                      c.lastError.value != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(c.lastError.value!, style: gSans(12.5, FontWeight.w600, color: G.glow)),
                    ),
                  if (online)
                    Text('${sessions.length} ${sessions.length == 1 ? 'session' : 'sessions'}'
                        '${need > 0 ? ' · $need need${need == 1 ? 's' : ''} you' : ''}', style: muted),
                  if (accounts != null)
                    Padding(
                      key: ValueKey('machine-account-${m.id}'),
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(children: [
                        const Icon(Icons.person_rounded, size: 15, color: G.muted),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(machineAccountLine(accounts, accounts.activeAccountId),
                              style: gSans(12.5, FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 6),
                        ClickDetector(
                          key: ValueKey('switch-account-${m.id}'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => switchMachineAccount(context, c),
                          child: Semantics(
                            button: true,
                            label: 'Switch account',
                            excludeSemantics: true,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                              child: ValuePill('Switch'),
                            ),
                          ),
                        ),
                      ]),
                    ),
                  if (limit != null)
                    Padding(
                      key: ValueKey('limit-summary-${m.id}'),
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(children: [
                        Icon(limit.back ? Icons.play_circle_outline_rounded : Icons.hourglass_bottom_rounded,
                            size: 15, color: G.glow),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(limitSummary(limit, DateTime.now()),
                              style: gSans(12.5, FontWeight.w700, color: G.glow)),
                        ),
                      ]),
                    ),
                  if (online && working > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(children: [
                        const WorkingWave(width: 26, height: 12, bars: 6),
                        const SizedBox(width: 7),
                        Text('$working working', style: gSans(12.5, FontWeight.w600)),
                      ]),
                    ),
                  if (link == LinkState.denied)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: GlassButton(
                        key: ValueKey('ask-again-${m.id}'),
                        label: 'Ask again',
                        icon: Icons.refresh_rounded,
                        compact: true,
                        onTap: c.connect,
                      ),
                    ),
                  if (link == LinkState.removed)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: GlassButton(
                        key: ValueKey('ask-to-pair-again-${m.id}'),
                        label: 'Ask to pair again',
                        icon: Icons.refresh_rounded,
                        compact: true,
                        onTap: c.askToPairAgain,
                      ),
                    ),
                  if (link == LinkState.needsPairing)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: GlassButton(
                        key: ValueKey('pair-again-${m.id}'),
                        label: 'Pair again',
                        icon: Icons.qr_code_scanner_rounded,
                        compact: true,
                        onTap: () => openAddMachine(context, replacing: m.id),
                      ),
                    ),
                  if (usage != null && (usage.fiveHour != null || usage.sevenDay != null) && accounts != null && usage.accountId != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('Usage · ${machineAccountName(accounts, usage.accountId!)}',
                          key: ValueKey('usage-account-${m.id}'), style: gSans(11.5, FontWeight.w600, color: G.muted)),
                    ),
                  if (usage != null && (usage.fiveHour != null || usage.sevenDay != null))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(children: [
                        if (usage.fiveHour != null) Expanded(child: MiniMeter(label: '5-hour', window: usage.fiveHour!)),
                        if (usage.fiveHour != null && usage.sevenDay != null) const SizedBox(width: 14),
                        if (usage.sevenDay != null) Expanded(child: MiniMeter(label: 'Week', window: usage.sevenDay!)),
                      ]),
                    ),
                  if (hooksNote)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(children: [
                        const Icon(Icons.info_outline_rounded, size: 16, color: G.muted),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text('Instant updates are off on this machine',
                              style: gSans(12.5, FontWeight.w500, color: G.muted)),
                        ),
                        ClickDetector(
                          key: ValueKey('dismiss-hooks-${m.id}'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => c.hooksNoteDismissed.value = true,
                          child: Semantics(
                            button: true,
                            label: 'Dismiss',
                            child: const Padding(
                                padding: EdgeInsets.all(6), child: Icon(Icons.close_rounded, size: 16, color: G.muted)),
                          ),
                        ),
                      ]),
                    ),
                  CompatibilityNotice(connection: c, drift: false, bare: true),
                ]),
              ),
              if (online && need > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: Perch.orange, borderRadius: BorderRadius.circular(99)),
                    child: Text('$need', style: gSans(13, FontWeight.w800, color: Perch.ink)),
                  ),
                ),
              ClickDetector(
                key: ValueKey('machine-menu-${m.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => showMachineMenu(context, c),
                child: Semantics(
                  button: true,
                  label: 'Machine menu',
                  child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.more_vert_rounded, size: 20, color: G.muted)),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}

/// A usage window, small, in a machine's row: its label, its share and a line.
class MiniMeter extends StatelessWidget {
  final String label;
  final UsageWindow window;
  const MiniMeter({super.key, required this.label, required this.window});
  @override
  Widget build(BuildContext context) => Semantics(
        label: '$label usage ${percent(window)} percent',
        excludeSemantics: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(label, style: gSans(11.5, FontWeight.w600, color: G.muted, height: 1.1))),
            Text('${percent(window)}%', style: gSans(11.5, FontWeight.w800, height: 1.1)),
          ]),
          UsageLine(value: window.utilization.clamp(0, 1).toDouble(), thickness: 3),
        ]),
      );
}

/// The number of sessions that need the owner, in LED dots on a disc of dark glass with its
/// label: the glass blurs the bird behind it, so the dots never blend into the mosaic.
class NeedYouHero extends StatelessWidget {
  final int count;
  const NeedYouHero({super.key, required this.count});
  @override
  Widget build(BuildContext context) => SizedBox.square(
        key: const ValueKey('hero'),
        dimension: 204,
        child: Frost(
          radius: 102,
          tone: G.deep,
          tint: G.dark ? 0.5 : 0.46,
          rim: true,
          padding: const EdgeInsets.fromLTRB(28, 30, 28, 26),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: DotMatrix('$count', dot: 16))),
            const SizedBox(height: 10),
            Text(count == 1 ? 'session needs you' : 'sessions need you', style: gSans(14.5, FontWeight.w700, height: 1.1)),
          ]),
        ),
      );
}

/// System, light or dark: one tap switches the theme, and the phone remembers it.
class ThemeSwitch extends StatelessWidget {
  const ThemeSwitch({super.key});
  static const _options = [
    (GlassMode.system, Icons.brightness_auto_rounded, 'Theme follows the phone'),
    (GlassMode.light, Icons.light_mode_rounded, 'Light theme'),
    (GlassMode.dark, Icons.dark_mode_rounded, 'Dark theme'),
  ];

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: GlassTheme.mode,
        builder: (context, mode, _) => Frost(
          radius: 23,
          tint: 0.16,
          padding: const EdgeInsets.all(3),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final (m, icon, label) in _options)
              Pressable(
                key: ValueKey('theme-${m.name}'),
                haptic: Haptic.selection,
                semanticLabel: label,
                onTap: () => GlassTheme.choose(m),
                builder: (context, p, child) => AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: m == mode ? Perch.orange : const Color(0x00000000),
                    boxShadow: m == mode ? [BoxShadow(color: Perch.orange.withValues(alpha: 0.4), blurRadius: 12)] : null,
                  ),
                  child: Icon(icon, size: 19, color: m == mode ? Perch.ink : G.text),
                ),
              ),
          ]),
        ),
      );
}
