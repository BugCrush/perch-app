// The model table (PRD 7.7): task types and the model sessions of each type use. Every row
// starts on the owner's current default; the hint column shows what most people use and is
// never applied. Kept on the phone and given to every machine.
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/board_store.dart';
import 'board_logic.dart';
import 'glass/mosaic.dart';
import 'glass/palette.dart';
import 'glass/pressable.dart';
import 'glass/settings.dart';
import 'glass/widgets.dart';

class ModelTableScreen extends StatelessWidget {
  final BoardStore store;
  const ModelTableScreen({super.key, required this.store});

  Future<void> _edit(BuildContext context, ModelRow row) async {
    final choice = await chooseModel(context, title: row.name, current: row.model, extra: true);
    if (choice == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    switch (choice) {
      case _rename:
        if (!context.mounted) return;
        final name = await _askText(context, 'Rename task type', row.name);
        if (name != null) await store.setTable(store.table.withRow(row.copyWith(name: name), atMs: now));
      case _remove:
        if (!context.mounted) return;
        if (await confirmSheet(context,
            title: 'Remove ${row.name}?', body: 'Tasks of this type keep it but use your default model.', yes: 'Remove')) {
          await store.setTable(store.table.without(row.id, atMs: now));
        }
      default:
        await store.setTable(store.table
            .withRow(choice == _default ? row.copyWith(clearModel: true) : row.copyWith(model: choice), atMs: now));
    }
  }

  Future<void> _add(BuildContext context) async {
    final name = await _askText(context, 'New task type', '');
    if (name == null) return;
    final id = 'type-${DateTime.now().millisecondsSinceEpoch}';
    await store.setTable(store.table.withRow(ModelRow(id: id, name: name), atMs: DateTime.now().millisecondsSinceEpoch));
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) => ListView(padding: screenPadding(context), children: [
            Row(children: [
              GlassOrb(icon: Icons.arrow_back_rounded, label: 'Back', onTap: () => Navigator.of(context).maybePop()),
              const SizedBox(width: 12),
              Expanded(child: Text('Models', style: gSerif(30, w: FontWeight.w500, height: 1.1))),
              GlassOrb(key: const ValueKey('add-type'), icon: Icons.add_rounded, label: 'Add a task type', onTap: () => _add(context)),
            ]),
            const SizedBox(height: 14),
            // The hint bubble.
            Frost(
              key: const ValueKey('models-hint'),
              tone: G.deep,
              tint: 0.5,
              radius: 20,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.lightbulb_outline_rounded, size: 18, color: Perch.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Every row starts on your current default, and you can change any of them. Perch passes a model only '
                    'where you set one; the hint is what most people use. Sessions started from tasks use it, and the new-session '
                    'sheet can too. Your phone gives this table to all your machines.',
                    style: gSans(13.5, FontWeight.w600),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 14),
            Frost(
              tone: G.deep,
              tint: 0.5,
              rim: true,
              radius: 24,
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(flex: 5, child: Text('TASK TYPE', style: gCaps(10.5))),
                  Expanded(flex: 3, child: Text('MODEL', style: gCaps(10.5))),
                  Expanded(flex: 3, child: Text('MOST PEOPLE', style: gCaps(10.5))),
                ]),
                for (final r in store.table.rows)
                  Pressable(
                    key: ValueKey('model-row-${r.id}'),
                    onTap: () => _edit(context, r),
                    semanticLabel: '${r.name}: ${modelLabel(r.model)}',
                    builder: (context, p, child) => DecoratedBox(
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: Color.lerp(const Color(0x00FFFFFF), const Color(0x24FFFFFF), p.clamp(0, 1))),
                      child: child,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(
                          flex: 5,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(r.name, style: gSans(14.5, FontWeight.w700)),
                            if (r.covers.isNotEmpty) Text(r.covers, style: gSans(12, FontWeight.w500, color: G.muted)),
                          ]),
                        ),
                        Expanded(
                          flex: 3,
                          // The setting: its value in the accent pill, then the chevron.
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Flexible(child: ValuePill(modelLabel(r.model), key: ValueKey('model-of-${r.id}'))),
                              const Icon(Icons.chevron_right_rounded, size: 20, color: G.glow),
                            ]),
                          ),
                        ),
                        Expanded(flex: 3, child: Text(r.hint, style: gSans(12.5, FontWeight.w600, color: G.muted))),
                      ]),
                    ),
                  ),
              ]),
            ),
          ]),
        ),
      );
}

const _default = '\u0000default';
const _rename = '\u0000rename';
const _remove = '\u0000remove';
const _other = '\u0000other';

/// Asks which model: the default, opus, sonnet, haiku or another name. [extra] adds Rename
/// and Remove (the table's rows). Returns a model name, or the default/rename/remove
/// markers; null when cancelled.
Future<String?> chooseModel(BuildContext context, {required String title, String? current, bool extra = false}) async {
  final choice = await showGlassSheet<String>(
    context,
    (ctx) => GlassSheet(children: [
      ...sheetTitle(title, 'Now: ${modelLabel(current)}'),
      const SizedBox(height: 10),
      MenuRow(label: 'Default', icon: Icons.auto_awesome_rounded, selected: current == null, onTap: () => Navigator.of(ctx).pop(_default)),
      for (final m in modelChoices)
        MenuRow(label: m, icon: Icons.memory_rounded, selected: current == m, onTap: () => Navigator.of(ctx).pop(m)),
      MenuRow(label: 'Another model…', icon: Icons.edit_rounded, onTap: () => Navigator.of(ctx).pop(_other)),
      if (extra) ...[
        MenuRow(label: 'Rename…', icon: Icons.drive_file_rename_outline_rounded, onTap: () => Navigator.of(ctx).pop(_rename)),
        MenuRow(label: 'Remove…', icon: Icons.delete_outline_rounded, danger: true, onTap: () => Navigator.of(ctx).pop(_remove)),
      ],
    ]),
  );
  if (choice != _other || !context.mounted) return choice;
  final typed = await _askText(context, 'Model name', current ?? '', check: (v) => validModelName(v) ? null : 'Not a model name');
  return typed;
}

/// Whether [choice] from [chooseModel] means the default model.
bool isDefaultChoice(String choice) => choice == _default;

Future<String?> _askText(BuildContext context, String title, String initial, {String? Function(String v)? check}) =>
    showGlassSheet<String>(context, (_) => _TextSheet(title: title, initial: initial, check: check));

class _TextSheet extends StatefulWidget {
  final String title;
  final String initial;
  final String? Function(String v)? check;
  const _TextSheet({required this.title, required this.initial, this.check});
  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final _text = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _ok() {
    final v = _text.text.trim();
    final e = v.isEmpty ? 'Enter a name' : (v.length > 60 ? 'At most 60 characters' : widget.check?.call(v));
    if (e != null) {
      setState(() => _error = e);
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) => GlassSheet(children: [
        ...sheetTitle(widget.title),
        const SizedBox(height: 12),
        GlassField(controller: _text, autofocus: true, error: _error, onSubmitted: (_) => _ok()),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: GlassButton(label: 'Cancel', onTap: () => Navigator.of(context).pop())),
          const SizedBox(width: 10),
          Expanded(child: GlassButton(label: 'Save', warm: true, onTap: _ok)),
        ]),
      ]);
}
