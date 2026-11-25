// The task board, projects first (docs/superpowers/specs/2026-11-24-projects-first-board-design.md):
// the device's own copy of the board (every project and task, assigned to a machine or to
// none), a project picker, a machine filter, and Backlog, Ready, In progress, Review and
// Done. It works with every machine offline. On the phone one column at a time (the chips
// on top with their counts in dots; swipe or tap a chip) with full-width cards; on a wide
// screen (the board page in a browser on the machine) all five side by side, cards dragged
// between them.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/board_store.dart';
import '../connection/host_connection.dart';
import '../state/providers.dart';
import 'app_theme.dart' show openGlass;
import 'board_bin.dart';
import 'board_logic.dart';
import 'glass/dots.dart';
import 'glass/mosaic.dart';
import 'glass/palette.dart';
import 'glass/pressable.dart';
import 'glass/widgets.dart';
import 'labels.dart';
import 'projects_screen.dart' show editProject;
import 'share.dart';
import 'task_detail.dart';
import 'task_sheets.dart';

/// Wider than this, the five columns sit side by side.
const wideBoard = 900.0;

void openBoard(BuildContext context) => openGlass<void>(context, const BoardScreen());

/// `/perch` in a session's composer: the board, showing that session's project.
Future<void> openSessionBoard(BuildContext context, HostConnection connection, String cwd) async {
  final store = ProviderScope.containerOf(context, listen: false).read(boardStoreProvider);
  final p = await focusBoardOn(store, machineId: connection.machine.id, cwd: cwd);
  if (!context.mounted) return;
  openBoard(context);
  if (p != null) say(context, 'Board: ${p.name}');
}

/// The board for the app's machines (from the providers).
class BoardScreen extends ConsumerWidget {
  const BoardScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machines = ref.watch(machinesProvider);
    final registry = ref.watch(connectionsProvider);
    return BoardView(connections: [for (final m in machines) registry.of(m)], store: ref.watch(boardStoreProvider));
  }
}

class BoardView extends StatefulWidget {
  final List<HostConnection> connections;
  final BoardStore store;

  /// Shown as the first screen (the board page): no back button.
  final bool root;

  /// The machine's other screens (the board page's way to the rest of the app).
  final VoidCallback? onHome;
  const BoardView({super.key, required this.connections, required this.store, this.root = false, this.onHome});
  @override
  State<BoardView> createState() => _BoardViewState();
}

class _BoardViewState extends State<BoardView> {
  final _pages = PageController();
  final _chipKeys = [for (final _ in TaskColumn.values) GlobalKey()];
  int _column = 0;
  Timer? _recheck;

  @override
  void dispose() {
    _recheck?.cancel();
    _pages.dispose();
    super.dispose();
  }

  List<HostConnection> get _all => widget.connections;

  bool _grouping = false;

  /// Tasks from older hosts made before projects are grouped into projects (once their
  /// machines said which projects they have).
  void _groupOlderTasks(List<BoardItem> items) {
    if (_grouping) return;
    final tasks = [
      for (final i in items)
        if (i.task.projectId == null && i.connection != null && projectsSettled(i.connection!)) (i.task.machineId!, i.task)
    ];
    if (tasks.isEmpty) return;
    final next = groupIntoProjects(widget.store.projects, tasks, atMs: DateTime.now().millisecondsSinceEpoch);
    if (next == null) return;
    _grouping = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.store.setProjects(next);
      _grouping = false;
    });
  }

  void _open(BoardItem item) => openGlass<void>(context, TaskDetailScreen(taskId: item.task.id, all: _all, store: widget.store));

  void _menu(BoardItem item) =>
      showTaskMenu(context, item, all: _all, store: widget.store, onOpen: () => _open(item));

  bool get _readOnly => watchOnlyEverywhere(_all);

  Future<void> _add() async {
    if (_readOnly) {
      say(context, watchOnlyMessage);
      return;
    }
    if (widget.store.projects.projects.isEmpty) {
      // A task belongs to a project: the first one is made right here.
      final p = await editProject(context, all: _all, store: widget.store);
      if (p == null || !mounted) return;
    }
    if (!mounted) return;
    await showTaskEditor(context, all: _all, store: widget.store, full: false, project: widget.store.projectFilter);
  }

  Future<void> _newProject() async {
    if (_readOnly) {
      say(context, watchOnlyMessage);
      return;
    }
    final p = await editProject(context, all: _all, store: widget.store);
    if (p != null) await widget.store.setProjectFilter(p.id);
  }

  Future<void> _drop(BoardItem item, TaskColumn to) async {
    if (item.task.column == to) return;
    if (_readOnly) {
      say(context, watchOnlyMessage);
      return;
    }
    if (to == TaskColumn.inProgress && item.task.column != TaskColumn.review) {
      // Moving into In progress means running it.
      await showRunOnSheet(context, item, all: _all, store: widget.store);
      return;
    }
    await taskAct(context, () => BoardActions(widget.store, _all).move(item.task, to));
  }

  /// The column a chip tap is sliding to (the pages passed on the way are not shown).
  int? _sliding;

  Future<void> _goTo(int i) async {
    _show(i);
    if (!_pages.hasClients) return;
    _sliding = i;
    await _pages.animateToPage(i, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    if (_sliding == i) _sliding = null;
  }

  /// Marks column [i] as shown and slides the chip row so its chip is wholly on screen.
  void _show(int i) {
    setState(() => _column = i);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _chipKeys[i].currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(ctx,
          alignment: 0.5, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
    });
  }

  Widget _header(BuildContext context, {required bool wide}) {
    final filter = widget.store.machineFilter;
    final machines = _all;
    final projects = [...widget.store.projects.projects]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final pf = widget.store.projectFilter;
    final shown = widget.store.projects.byId(pf);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (!widget.root) ...[
            GlassOrb(icon: Icons.arrow_back_rounded, label: 'Back', onTap: () => Navigator.of(context).maybePop()),
            const SizedBox(width: 12),
          ],
          Expanded(child: Text('Board', style: gSerif(30, w: FontWeight.w500, height: 1.1))),
          if (widget.onHome != null) ...[
            GlassOrb(key: const ValueKey('board-home'), icon: Icons.home_rounded, label: 'Machines and sessions', onTap: widget.onHome),
            const SizedBox(width: 8),
          ],
          if (wide) ...[
            const SizedBox(width: 8),
            GlassButton(key: const ValueKey('board-add-wide'), label: 'New task', icon: Icons.add_rounded, warm: true, onTap: _add),
          ],
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: SingleChildScrollView(
            key: const ValueKey('project-row'),
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              GlassChip(
                  key: const ValueKey('project-all'),
                  label: 'All projects',
                  icon: pf == null ? Icons.check_rounded : Icons.folder_copy_outlined,
                  selected: pf == null,
                  onTap: () => widget.store.setProjectFilter(null)),
              for (final p in projects) ...[
                const SizedBox(width: 6),
                GlassChip(
                    key: ValueKey('project-${p.id}'),
                    label: p.name,
                    icon: pf == p.id ? Icons.check_rounded : Icons.folder_outlined,
                    selected: pf == p.id,
                    onTap: () => widget.store.setProjectFilter(p.id)),
              ],
              const SizedBox(width: 6),
              GlassChip(key: const ValueKey('project-new'), label: 'New project', icon: Icons.add_rounded, onTap: _newProject),
            ]),
          ),
        ),
        if (shown != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Expanded(
                child: Text(shown.description ?? '',
                    key: const ValueKey('board-project-description'),
                    style: gSans(13, FontWeight.w500, color: G.muted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
              GlassButton(
                  key: const ValueKey('project-share'),
                  label: 'Share project',
                  icon: Icons.ios_share_rounded,
                  compact: true,
                  onTap: () => shareProject(context, shown, store: widget.store, all: _all)),
            ]),
          ),
        if (machines.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                GlassChip(
                    key: const ValueKey('filter-all'),
                    label: 'All machines',
                    icon: filter == null ? Icons.check_rounded : Icons.devices_rounded,
                    selected: filter == null,
                    onTap: () => widget.store.setFilter(null)),
                for (final c in machines) ...[
                  const SizedBox(width: 6),
                  GlassChip(
                      key: ValueKey('filter-${c.machine.id}'),
                      label: machineTitle(c),
                      icon: filter == c.machine.id ? Icons.check_rounded : Icons.computer_rounded,
                      selected: filter == c.machine.id,
                      onTap: () => widget.store.setFilter(c.machine.id)),
                ],
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _empty() {
    final online = _all.where((c) => c.link.value == LinkState.online).toList();
    final String text;
    if (online.isNotEmpty && !online.any((c) => c.supportsTasks || c.boardSync)) {
      if (!online.every((c) => c.boardMissing)) {
        // Their tasks may still be on the way: look again in a moment.
        _recheck ??= Timer(online.first.boardGrace, () {
          _recheck = null;
          if (mounted) setState(() {});
        });
        return const SizedBox.shrink();
      }
      text = olderHostTasksMessage;
    } else {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Text(text, key: const ValueKey('board-note'), style: gSans(14, FontWeight.w600, color: G.muted)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      background: MosaicBackdrop(seed: 11, fade: G.deep, fadeFrom: 0.2, pixel: 0.75),
      child: ListenableBuilder(
        listenable: Listenable.merge([
          widget.store,
          for (final c in _all) ...[c.tasks, c.link, c.sessions, c.displayName, c.hostProjects],
        ]),
        builder: (context, _) {
          final wide = MediaQuery.sizeOf(context).width >= wideBoard;
          final filter = widget.store.machineFilter;
          final items = boardItems(widget.store, _all);
          _groupOlderTasks(items);
          final columns = {
            for (final col in TaskColumn.values)
              col: boardColumn(items, col,
                  machineFilter: filter, projectFilter: widget.store.projectFilter, projects: widget.store.projects),
          };
          return Stack(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _header(context, wide: wide),
              _empty(),
              if (widget.store.file?.unsynced == true)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                  child: Text(savedOnPhoneNote,
                      key: const ValueKey('board-offline-note'), style: gSans(12.5, FontWeight.w600, color: G.muted)),
                ),
              Expanded(child: wide ? _wide(columns) : _phone(columns)),
            ]),
            if (!wide)
              Positioned(
                right: 18,
                bottom: 22 + systemBottom(context),
                child: GlassOrb(key: const ValueKey('board-add'), icon: Icons.add_rounded, label: 'New task', size: 60, warm: true, onTap: _add),
              ),
            // The bin: deleted projects and tasks (Restore, Delete for good).
            Positioned(
              right: wide ? 22 : 26,
              bottom: (wide ? 22 : 22 + 60 + 14) + systemBottom(context),
              child: GlassOrb(
                  key: const ValueKey('board-bin'),
                  icon: Icons.delete_outline_rounded,
                  label: binTitle,
                  size: 44,
                  onTap: () => openBin(context, widget.store)),
            ),
          ]);
        },
      ),
    );
  }

  Widget _phone(Map<TaskColumn, List<BoardItem>> columns) => Column(children: [
        SizedBox(
          height: 58,
          // Every chip is built (not lazily): the row slides to one that is off screen.
          child: SingleChildScrollView(
            key: const ValueKey('chip-row'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              for (final (i, col) in TaskColumn.values.indexed)
                Padding(
                  key: _chipKeys[i],
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ColumnChip(
                      key: ValueKey('chip-${col.name}'),
                      label: columnLabel(col),
                      count: columns[col]!.length,
                      selected: i == _column,
                      onTap: () => _goTo(i)),
                ),
            ]),
          ),
        ),
        Expanded(
          child: PageView(
            key: const ValueKey('board-pages'),
            controller: _pages,
            onPageChanged: (i) {
              if (_sliding == null && i != _column) _show(i);
            },
            children: [
              for (final col in TaskColumn.values)
                ListView(
                  key: ValueKey('column-${col.name}'),
                  padding: screenPadding(context, left: 14, top: 8, right: 14, bottom: 170),
                  children: [
                    if (columns[col]!.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 30),
                        child: Center(child: Text('Nothing in ${columnLabel(col)}', style: gSans(14, FontWeight.w600, color: G.muted))),
                      ),
                    for (final item in columns[col]!)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: TaskCard(
                          key: ValueKey('card-${item.task.id}'),
                          item: item,
                          project: item.projectIn(widget.store.projects)?.name,
                          machine: assignedLabel(item.task, _all),
                          onTap: () => _open(item),
                          onLongPress: () => _menu(item),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ]);

  Widget _wide(Map<TaskColumn, List<BoardItem>> columns) => Padding(
        padding: EdgeInsets.fromLTRB(10, 0, 10, 10 + systemBottom(context)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final col in TaskColumn.values)
            Expanded(
              child: DragTarget<BoardItem>(
                key: ValueKey('drop-${col.name}'),
                onWillAcceptWithDetails: (d) => d.data.task.column != col,
                onAcceptWithDetails: (d) => _drop(d.data, col),
                builder: (context, candidates, _) => Container(
                  margin: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: candidates.isNotEmpty ? Perch.orange : const Color(0x26FFFFFF), width: 1.5),
                  ),
                  child: Frost(
                    tone: G.deep,
                    tint: 0.42,
                    radius: 26,
                    padding: const EdgeInsets.fromLTRB(14, 16, 14, 6),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      // Clear of the frame's rounded corners.
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(children: [
                          Expanded(child: Text(columnLabel(col).toUpperCase(), style: gCaps(11, color: G.text))),
                          DotMatrix('${columns[col]!.length}', dot: 3, glow: null),
                        ]),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView(key: ValueKey('column-${col.name}'), children: [
                          for (final item in columns[col]!)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Draggable<BoardItem>(
                                key: ValueKey('drag-${item.task.id}'),
                                data: item,
                                feedback: SizedBox(
                                  width: 260,
                                  child: Opacity(
                                      opacity: 0.9,
                                      child: TaskCard(
                                          item: item,
                                          project: item.projectIn(widget.store.projects)?.name,
                                          machine: assignedLabel(item.task, _all),
                                          compact: true)),
                                ),
                                childWhenDragging: Opacity(
                                    opacity: 0.35,
                                    child: TaskCard(
                                        item: item,
                                        project: item.projectIn(widget.store.projects)?.name,
                                        machine: assignedLabel(item.task, _all),
                                        compact: true)),
                                child: TaskCard(
                                  key: ValueKey('card-${item.task.id}'),
                                  item: item,
                                  project: item.projectIn(widget.store.projects)?.name,
                                  compact: true,
                                  machine: assignedLabel(item.task, _all),
                                  onTap: () => _open(item),
                                  onLongPress: () => _menu(item),
                                ),
                              ),
                            ),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      );
}

/// A column's chip: its name and its count in dots; orange when it is the one shown.
class ColumnChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  const ColumnChip({super.key, required this.label, required this.count, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        haptic: Haptic.selection,
        semanticLabel: '$label, $count',
        builder: (context, p, child) => Opacity(opacity: 1 - p.clamp(0, 1) * 0.3, child: child),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: selected ? Perch.orange : const Color(0x1FFFFFFF),
            border: Border.all(color: selected ? Perch.orange : const Color(0x33FFFFFF)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: gSans(14, FontWeight.w700, color: selected ? Perch.ink : G.text, height: 1)),
            const SizedBox(width: 8),
            DotMatrix('$count', dot: 3, color: selected ? Perch.ink : G.text, glow: null),
          ]),
        ),
      );
}

/// A task's card: its title, project, machine ("Not assigned" until Run on… chooses one),
/// type and priority; while in progress the working wave and what its session did last.
class TaskCard extends StatelessWidget {
  final BoardItem item;

  /// The name of its project (null: none known yet; then its folder shows).
  final String? project;

  /// The machine it is assigned to, or "Not assigned".
  final String machine;
  final bool compact;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  const TaskCard(
      {super.key,
      required this.item,
      this.project,
      this.machine = notAssignedLabel,
      this.compact = false,
      this.onTap,
      this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final t = item.task;
    final table = _tableOf(context);
    final session = t.sessionId == null ? null : item.connection?.sessions.value.where((s) => s.id == t.sessionId).firstOrNull;
    final working = t.column == TaskColumn.inProgress && session != null && session.live && session.state == SessionState.working;
    final muted = gSans(12.5, FontWeight.w600, color: G.muted);
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: t.title,
      builder: (context, p, child) => Transform.scale(scale: 1 - p.clamp(0, 1) * 0.02, child: child),
      child: Frost(
        tone: G.deep,
        tint: 0.55,
        rim: true,
        radius: compact ? 18 : 22,
        padding: EdgeInsets.fromLTRB(compact ? 12 : 16, compact ? 10 : 14, compact ? 12 : 16, compact ? 10 : 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (t.priority != TaskPriority.normal)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 8),
                child: LedDot(t.priority == TaskPriority.high ? Perch.orange : G.muted, size: 8),
              ),
            Expanded(
              child: Text(t.title,
                  style: gSans(compact ? 14.5 : 16, FontWeight.w700), maxLines: compact ? 3 : 2, overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.folder_outlined, size: 14, color: G.muted),
              const SizedBox(width: 4),
              Text(project ?? (t.cwd.isEmpty ? 'No project' : lastFolder(t.cwd)), key: ValueKey('card-project-${t.id}'), style: muted),
            ]),
            Text('·', style: muted),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(t.machineId == null ? Icons.lightbulb_outline_rounded : Icons.computer_rounded, size: 14, color: G.muted),
              const SizedBox(width: 4),
              Text(machine, key: ValueKey('card-machine-${t.id}'), style: muted),
            ]),
            if (t.taskType != null) GlassTag(table?.nameOf(t.taskType) ?? t.taskType!),
            if (t.priority != TaskPriority.normal) GlassTag(priorityLabel(t.priority)),
          ]),
          if (t.column == TaskColumn.inProgress)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                if (working) ...[const WorkingWave(width: 26, height: 12, bars: 6), const SizedBox(width: 7)],
                Expanded(
                  child: Text(
                    [
                      ?t.activity,
                      if (t.activityAtMs != null) agoLabel(t.activityAtMs!),
                    ].join(' · '),
                    key: ValueKey('activity-${t.id}'),
                    style: gSans(12.5, FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ),
          if (t.column == TaskColumn.review && t.report != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                [
                  if (t.report!.criteria.isNotEmpty)
                    '${t.report!.criteria.where((x) => x.met == true).length}/${t.report!.criteria.length} criteria met',
                  '${t.report!.todos.where((x) => x.done).length}/${t.report!.todos.length} to-dos',
                  '${t.report!.files.length} ${t.report!.files.length == 1 ? 'file' : 'files'}',
                ].join(' · '),
                style: gSans(12.5, FontWeight.w600, color: G.glow),
              ),
            ),
        ]),
      ),
    );
  }

  static ModelTable? _tableOf(BuildContext context) {
    try {
      return ProviderScope.containerOf(context, listen: false).read(boardStoreProvider).table;
    } catch (_) {
      return ModelTable.starting;
    }
  }
}

