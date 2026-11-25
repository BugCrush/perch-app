// One task, in sections: where it runs (project, machine or "Not assigned", folder:
// information), its Description as written, its Acceptance criteria (ticked from Claude's
// report after a run) and the Completion report (the linked session, Claude's report, its
// to-do list with ticks, the files it touched and the git changes); Run on…, Send notes
// back, Done, Edit and Share.
import 'package:flutter/widgets.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:material_ui/material_ui.dart' show Icons, SelectionArea;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/board_store.dart';
import '../connection/host_connection.dart';
import 'board_logic.dart';
import 'conversation.dart' show glassMarkdown;
import 'glass/dots.dart';
import 'glass/mosaic.dart';
import 'glass/palette.dart';
import 'glass/settings.dart';
import 'glass/widgets.dart';
import 'labels.dart';
import 'session_row.dart' show openSessionScreen;
import 'share.dart';
import 'task_sheets.dart';
import 'glass/click.dart';

class TaskDetailScreen extends StatelessWidget {
  final String taskId;
  final List<HostConnection> all;
  final BoardStore store;
  const TaskDetailScreen({super.key, required this.taskId, required this.all, required this.store});

  @override
  Widget build(BuildContext context) => GlassScaffold(
        child: ListenableBuilder(
          listenable: Listenable.merge([store, for (final c in all) ...[c.tasks, c.sessions, c.displayName]]),
          builder: (context, _) {
            final item = boardItems(store, all).where((x) => x.task.id == taskId).firstOrNull;
            return ListView(padding: screenPadding(context), children: [
              Row(children: [
                GlassOrb(icon: Icons.arrow_back_rounded, label: 'Back', onTap: () => Navigator.of(context).maybePop()),
                const Spacer(),
                if (item != null)
                  GlassOrb(
                    key: const ValueKey('task-menu'),
                    icon: Icons.more_horiz_rounded,
                    label: 'Task menu',
                    onTap: () => showTaskMenu(context, item, all: all, store: store, onOpen: () {}),
                  ),
              ]),
              const SizedBox(height: 14),
              if (item == null)
                Text('This task is no longer on the board (it may be in Deleted).', style: gSans(15, FontWeight.w600, color: G.muted))
              else
                ..._body(context, item),
            ]);
          },
        ),
      );

  List<Widget> _body(BuildContext context, BoardItem item) {
    final t = item.task;
    final connection = item.connection;
    final session = t.sessionId == null ? null : connection?.sessions.value.where((s) => s.id == t.sessionId).firstOrNull;
    final r = t.report;
    final project = item.projectIn(store.projects);
    final muted = gSans(13.5, FontWeight.w600, color: G.muted);
    final checks = r?.criteria ?? const <CriterionCheck>[];
    return [
      Text(t.title, key: const ValueKey('detail-title'), style: gSerif(28, w: FontWeight.w500, height: 1.2)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        GlassTag(columnLabel(t.column)),
        GlassTag(store.table.nameOf(t.taskType)),
        GlassTag(priorityLabel(t.priority)),
      ]),
      const SizedBox(height: 8),
      // Where it runs: information, not settings (Edit… in the menu changes them).
      InfoRow(key: const ValueKey('detail-project'), label: 'Project', value: project?.name ?? lastFolder(t.cwd)),
      InfoRow(key: const ValueKey('detail-machine'), label: 'Machine', value: assignedLabel(t, all)),
      if (t.cwd.isNotEmpty) InfoRow(label: 'Folder', value: t.cwd, mono: true),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (t.column != TaskColumn.inProgress)
          GlassButton(
              key: const ValueKey('detail-run'),
              label: t.sessionId == null ? 'Run on…' : 'Run again…',
              icon: Icons.play_arrow_rounded,
              warm: t.column != TaskColumn.review,
              compact: true,
              onTap: () => showRunOnSheet(context, item, all: all, store: store)),
        if (t.column == TaskColumn.review && t.sessionId != null) ...[
          GlassButton(
              key: const ValueKey('detail-notes'),
              label: 'Send notes back',
              icon: Icons.reply_rounded,
              compact: true,
              onTap: () => showNotesSheet(context, item)),
        ],
        if (t.column == TaskColumn.review) ...[
          GlassButton(
              key: const ValueKey('detail-done'),
              label: 'Done',
              icon: Icons.check_rounded,
              warm: true,
              compact: true,
              onTap: () => taskAct(context, () => BoardActions(store, all).move(t, TaskColumn.done), done: '${t.title} is done')),
        ],
        GlassButton(
            key: const ValueKey('detail-edit'),
            label: 'Edit',
            icon: Icons.edit_rounded,
            compact: true,
            onTap: () => showTaskEditor(context, all: all, store: store, editing: item)),
        GlassButton(
            key: const ValueKey('detail-share'),
            label: 'Share',
            icon: Icons.ios_share_rounded,
            compact: true,
            onTap: () => shareTask(context, t, store: store, all: all)),
      ]),
      const SizedBox(height: 16),
      GlassPanel(caption: 'DESCRIPTION', children: [
        Text(t.description.isEmpty ? 'No description: Claude gets the title only.' : t.description,
            key: const ValueKey('detail-description'), style: gSerif(16.5, height: 1.5)),
      ]),
      const SizedBox(height: 12),
      GlassPanel(
        key: const ValueKey('detail-criteria'),
        caption: 'ACCEPTANCE CRITERIA',
        trailing: checks.isEmpty
            ? null
            : Text('${checks.where((c) => c.met == true).length}/${checks.length} met',
                style: gSans(12.5, FontWeight.w800, color: G.glow)),
        children: [
          if (t.acceptance.isEmpty)
            Text('None written. Edit the task to add what must be true when it is done.', style: muted)
          else
            for (final (i, c) in t.acceptance.indexed)
              _criterion(i, c, checks.length > i && checks[i].text == c ? checks[i].met : _metOf(checks, c), ran: r != null),
        ],
      ),
      const SizedBox(height: 12),
      GlassPanel(key: const ValueKey('detail-completion'), caption: 'COMPLETION REPORT', children: [
        if (t.sessionId != null)
          ClickDetector(
            key: const ValueKey('detail-session'),
            behavior: HitTestBehavior.opaque,
            onTap: session == null || connection == null ? null : () => openSessionScreen(context, connection, session.id),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                if (session != null && session.live && session.state == SessionState.working) ...[
                  const WorkingWave(width: 26, height: 12, bars: 6),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    '${session?.name ?? t.sessionName ?? 'Session'} · ${session == null ? 'not listed now' : stateLabel(session)}',
                    style: gSans(15, FontWeight.w700),
                  ),
                ),
                if (session != null) const ValuePillOpen(),
              ]),
            ),
          ),
        if (t.activity != null && t.column == TaskColumn.inProgress)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('${t.activity}${t.activityAtMs == null ? '' : ' · ${agoLabel(t.activityAtMs!)}'}', style: muted),
          ),
        if (r == null)
          Text(
              t.column == TaskColumn.inProgress
                  ? 'Claude is on it: the report shows here when its turn ends.'
                  : 'Not run yet. When Claude finishes, its report, to-do list, files and git changes show here.',
              style: muted)
        else ...[
          if (r.sessionEnded)
            Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('The session ended.', style: muted)),
          Text("CLAUDE'S REPORT", style: gCaps(10)),
          const SizedBox(height: 4),
          SelectionArea(
            child: MarkdownBody(
              key: const ValueKey('detail-report'),
              data: r.text.isEmpty ? '_Claude gave no answer._' : r.text,
              styleSheet: glassMarkdown(body: gSerif(16, height: 1.5)),
            ),
          ),
          if (r.todos.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('TO-DO LIST', style: gCaps(10)),
            const SizedBox(height: 4),
            for (final (i, todo) in r.todos.indexed)
              Padding(
                key: ValueKey('todo-$i'),
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(todo.done ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                      size: 19, color: todo.done ? Perch.led : G.muted),
                  const SizedBox(width: 8),
                  Expanded(child: Text(todo.text, style: gSans(14.5, FontWeight.w600))),
                ]),
              ),
          ],
          if (r.files.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('FILES IT TOUCHED', style: gCaps(10)),
            const SizedBox(height: 4),
            for (final f in r.files) Text(f, style: gMono(12.5)),
          ],
          if (r.changes.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('CHANGES SINCE THE TASK STARTED (GIT)', style: gCaps(10)),
            const SizedBox(height: 4),
            CodeWell(child: Text(r.changes.join('\n'), key: const ValueKey('detail-changes'), style: gMono(12))),
          ],
        ],
      ]),
    ];
  }

  static bool? _metOf(List<CriterionCheck> checks, String text) => checks.where((c) => c.text == text).firstOrNull?.met;

  /// One criterion: an empty box before a run; after it, a tick (met), a cross (not met) or
  /// a question mark (the report did not say).
  Widget _criterion(int i, String text, bool? met, {required bool ran}) {
    final (IconData icon, Color color, String state) = !ran
        ? (Icons.check_box_outline_blank_rounded, G.muted, 'not run yet')
        : met == true
            ? (Icons.check_circle_rounded, Perch.led, 'met')
            : met == false
                ? (Icons.cancel_rounded, Perch.ember, 'not met')
                : (Icons.help_outline_rounded, G.muted, 'not reported');
    return Semantics(
      label: '$text, $state',
      excludeSemantics: true,
      child: Padding(
        key: ValueKey('criterion-$i-$state'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: gSans(14.5, FontWeight.w600))),
        ]),
      ),
    );
  }
}

/// The "Open" pill on a row that opens something (the linked session).
class ValuePillOpen extends StatelessWidget {
  const ValuePillOpen({super.key});
  @override
  Widget build(BuildContext context) => const Row(mainAxisSize: MainAxisSize.min, children: [
        ValuePill('Open'),
        Icon(Icons.chevron_right_rounded, color: G.glow, size: 22),
      ]);
}
