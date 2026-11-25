// The board's bin (docs/superpowers/specs/2026-11-24-projects-first-board-design.md, section 7):
// deleted projects and tasks, newest first, for as long as they are remembered (180 days).
// Restore brings one back where it was, on every device (a project brings back the tasks
// deleted with it; a task brings back its deleted project). Delete for good keeps the
// tombstone, so it cannot come back from an old copy, and takes it off the list.
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/board_store.dart';
import 'board_logic.dart' show agoLabel;
import 'glass/mosaic.dart';
import 'glass/widgets.dart';

/// The bin's title.
const binTitle = 'Deleted';

String _titleOf(BoardRecord r) => switch (r.kind) {
      RecordKinds.project => projectOf(r)?.name ?? 'A project',
      RecordKinds.task => taskOf(r)?.title ?? 'A task',
      _ => r.id,
    };

/// Restores [r] everywhere (with what was deleted with it, or what it belongs to).
void restoreFromBin(BoardStore store, BoardRecord r) {
  final f = store.file;
  if (f == null) return;
  void bringBack(BoardRecord x) => f.edit(x.kind, x.id, {
        'life': {'deleted': false}
      });
  bringBack(r);
  if (r.kind == RecordKinds.project) {
    for (final t in f.board.records) {
      if (t.kind == RecordKinds.task && t.deleted && !t.purged && t.life?['deletedWith'] == r.id) bringBack(t);
    }
  } else if (r.kind == RecordKinds.task) {
    final pid = taskOf(r)?.projectId;
    final p = pid == null ? null : f.board.get(RecordKinds.project, pid);
    if (p != null && p.deleted) bringBack(p);
  }
}

/// Deletes [r] for good: it stays a tombstone (so an old copy cannot bring it back) and
/// leaves the bin.
void purgeFromBin(BoardStore store, BoardRecord r) {
  store.file?.edit(r.kind, r.id, {
    'life': {...?r.life, 'deleted': true, 'purged': true, 'deletedAtMs': r.deletedAtMs}
  });
}

Future<void> openBin(BuildContext context, BoardStore store) =>
    showGlassSheet<void>(context, (_) => BinSheet(store: store));

class BinSheet extends StatelessWidget {
  final BoardStore store;
  const BinSheet({super.key, required this.store});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final b = store.file?.board;
          final bin = b?.bin ?? const <BoardRecord>[];
          return GlassSheet(children: [
            ...sheetTitle(binTitle, 'Deleted projects and tasks, kept for 180 days.'),
            const SizedBox(height: 12),
            if (bin.isEmpty)
              Text('Nothing deleted.', key: const ValueKey('bin-empty'), style: gSans(14, FontWeight.w600, color: G.muted)),
            for (final r in bin) _row(context, b!, r),
          ]);
        },
      );

  Widget _row(BuildContext context, Board b, BoardRecord r) {
    final task = r.kind == RecordKinds.task ? taskOf(r) : null;
    final project = task?.projectId == null ? null : b.get(RecordKinds.project, task!.projectId!);
    final where = project == null ? null : projectOf(project)?.name;
    return Padding(
      key: ValueKey('bin-${r.id}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Frost(
        tone: G.deep,
        tint: 0.5,
        radius: 18,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(r.kind == RecordKinds.project ? Icons.folder_outlined : Icons.task_alt_rounded, size: 18, color: G.muted),
            const SizedBox(width: 8),
            Expanded(child: Text(_titleOf(r), style: gSans(15, FontWeight.w700), maxLines: 2, overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 4),
          Text(
              [
                r.kind == RecordKinds.project ? 'Project' : (where == null ? 'Task' : 'Task in $where'),
                'deleted ${agoLabel(r.deletedAtMs)}',
              ].join(' · '),
              style: gSans(12.5, FontWeight.w600, color: G.muted)),
          const SizedBox(height: 10),
          Wrap(spacing: 10, runSpacing: 8, children: [
            GlassButton(
                key: ValueKey('bin-restore-${r.id}'),
                label: 'Restore',
                icon: Icons.restore_rounded,
                compact: true,
                onTap: () => restoreFromBin(store, r)),
            DangerButton(
                key: ValueKey('bin-purge-${r.id}'),
                label: 'Delete for good',
                compact: true,
                onTap: () => purgeFromBin(store, r)),
          ]),
        ]),
      ),
    );
  }
}
