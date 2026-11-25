// The task board's sheets: a card's menu, quick add and the editor (a task in a project, no
// machine), Run on… (a machine, its folder for the project, then a new or idle session),
// notes back, moving to a column, Duplicate and Share.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/board_store.dart';
import '../connection/host_connection.dart';
import 'board_logic.dart';
import 'folder_picker.dart';
import 'glass/dots.dart';
import 'glass/mosaic.dart';
import 'glass/palette.dart';
import 'glass/settings.dart';
import 'glass/widgets.dart';
import 'labels.dart';
import 'projects_screen.dart';
import 'share.dart';
import 'glass/click.dart';

/// Machines that can take tasks now (online, with a board).
List<HostConnection> boardMachines(Iterable<HostConnection> all) =>
    [for (final c in all) if (c.link.value == LinkState.online && c.supportsTasks) c];

/// Whether every paired machine lets this device only watch (then the board is read-only).
bool watchOnlyEverywhere(Iterable<HostConnection> all) => all.isNotEmpty && all.every((c) => !c.canControl);

/// Runs a board action and says how it went; true when it was done.
Future<bool> taskAct(BuildContext context, Future<void> Function() run, {String? done}) async {
  try {
    await run();
    if (done != null && context.mounted) say(context, done);
    return true;
  } on SessionActionFailed catch (e) {
    if (context.mounted) say(context, e.message);
    return false;
  } on StateError catch (e) {
    if (context.mounted) say(context, e.message);
    return false;
  }
}

IconData _menuIcon(TaskMenuItem i) => switch (i) {
      TaskMenuItem.open => Icons.open_in_full_rounded,
      TaskMenuItem.runOn => Icons.play_arrow_rounded,
      TaskMenuItem.notes => Icons.reply_rounded,
      TaskMenuItem.done => Icons.check_circle_outline_rounded,
      TaskMenuItem.moveColumn => Icons.view_column_rounded,
      TaskMenuItem.edit => Icons.edit_rounded,
      TaskMenuItem.share => Icons.ios_share_rounded,
      TaskMenuItem.duplicate => Icons.copy_rounded,
      TaskMenuItem.delete => Icons.delete_outline_rounded,
    };

/// A card's menu (press and hold); carries out the choice. [onOpen] opens the task.
Future<void> showTaskMenu(BuildContext context, BoardItem item,
    {required List<HostConnection> all, required BoardStore store, required VoidCallback onOpen}) async {
  final t = item.task;
  final choice = await showGlassSheet<TaskMenuItem>(
    context,
    barrier: const Color(0x66000000),
    (ctx) => GlassSheet(children: [
      menuHeader(seedOf(t.id), t.title,
          Text('${assignedLabel(t, all)} · ${columnLabel(t.column)}', style: gSans(13, FontWeight.w500, color: G.muted))),
      const SizedBox(height: 14),
      for (final i in taskMenuItems(t))
        MenuRow(
            key: ValueKey('task-menu-${i.name}'),
            label: taskMenuLabel(i),
            icon: _menuIcon(i),
            danger: i == TaskMenuItem.delete,
            onTap: () => Navigator.of(ctx).pop(i)),
    ]),
  );
  if (choice == null || !context.mounted) return;
  await runTaskMenuItem(context, choice, item, all: all, store: store, onOpen: onOpen);
}

Future<void> runTaskMenuItem(BuildContext context, TaskMenuItem i, BoardItem item,
    {required List<HostConnection> all, required BoardStore store, required VoidCallback onOpen}) async {
  final t = item.task;
  final actions = BoardActions(store, all);
  if (watchOnlyEverywhere(all) && i != TaskMenuItem.open && i != TaskMenuItem.share) {
    say(context, watchOnlyMessage);
    return;
  }
  switch (i) {
    case TaskMenuItem.open:
      onOpen();
    case TaskMenuItem.runOn:
      await showRunOnSheet(context, item, all: all, store: store);
    case TaskMenuItem.notes:
      await showNotesSheet(context, item);
    case TaskMenuItem.done:
      await taskAct(context, () => actions.move(t, TaskColumn.done), done: '${t.title} is done');
    case TaskMenuItem.moveColumn:
      final col = await showGlassSheet<TaskColumn>(
        context,
        (ctx) => GlassSheet(children: [
          ...sheetTitle('Move to a column'),
          const SizedBox(height: 10),
          for (final col in TaskColumn.values)
            if (col != t.column)
              MenuRow(label: columnLabel(col), icon: Icons.view_column_rounded, onTap: () => Navigator.of(ctx).pop(col)),
        ]),
      );
      if (col != null && context.mounted) await taskAct(context, () => actions.move(t, col));
    case TaskMenuItem.edit:
      await showTaskEditor(context, all: all, store: store, editing: item);
    case TaskMenuItem.share:
      await shareTask(context, t, store: store, all: all);
    case TaskMenuItem.duplicate:
      await taskAct(context, () async => actions.duplicate(t), done: 'Duplicated: ${t.title}');
    case TaskMenuItem.delete:
      if (await confirmDanger(context,
              title: 'Delete ${t.title}?',
              lost: 'The task, its description and its completion report go to the bin (Deleted) on every device. '
                  'Restore brings it back; after 180 days it is gone. Its session, if any, is left as it is.',
              yes: 'Delete task',
              hold: true) &&
          context.mounted) {
        await taskAct(context, () => actions.delete(t), done: 'Task deleted');
      }
  }
}

// ---------------------------------------------------------------- add and edit

/// Quick add (title and one line; the project used last) or, with [full], the editor for a
/// new task. [editing]: the task to edit. [project]: preselected (the board's project
/// filter). A new task has no machine: Run on… chooses one when it is time.
Future<void> showTaskEditor(BuildContext context,
        {required List<HostConnection> all,
        required BoardStore store,
        BoardItem? editing,
        bool full = true,
        String? project}) =>
    showGlassSheet<void>(context, (_) => TaskEditor(all: all, store: store, editing: editing, full: full, project: project));

class TaskEditor extends StatefulWidget {
  final List<HostConnection> all;
  final BoardStore store;
  final BoardItem? editing;

  /// The whole editor (description, acceptance criteria, type, priority); false: quick add.
  final bool full;

  /// The project to start on (else the one used last).
  final String? project;
  const TaskEditor({super.key, required this.all, required this.store, this.editing, this.full = true, this.project});
  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<TaskEditor> {
  late final _title = TextEditingController(text: widget.editing?.task.title ?? '');
  late final _desc = TextEditingController(text: widget.editing?.task.description ?? '');
  late final List<TextEditingController> _criteria = [
    for (final c in widget.editing?.task.acceptance ?? const <String>[]) TextEditingController(text: c)
  ];
  Project? _project;
  String? _type;
  TaskPriority _priority = TaskPriority.normal;
  late bool _full = widget.full || widget.editing != null;
  String? _titleError;
  String? _error;
  bool _saving = false;

  ProjectList get _projects => widget.store.projects;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e != null) {
      _project = e.projectIn(_projects);
      _type = e.task.taskType;
      _priority = e.task.priority;
      return;
    }
    _project = _projects.byId(widget.project) ?? _projects.byId(widget.store.lastProject) ?? _sortedProjects.firstOrNull;
  }

  List<Project> get _sortedProjects =>
      [..._projects.projects]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    for (final c in _criteria) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    setState(() {
      _titleError = BoardTask.titleError(title);
      _error = _project == null ? 'Choose a project, or make a new one' : null;
    });
    if (_titleError != null || _error != null) return;
    setState(() => _saving = true);
    final e = widget.editing;
    final acceptance = [for (final c in _criteria) if (c.text.trim().isNotEmpty) c.text.trim()];
    final task = e == null
        ? BoardTask(
            id: newTaskId(),
            title: title,
            description: _desc.text.trim(),
            cwd: '',
            projectId: _project!.id,
            acceptance: acceptance,
            taskType: _type,
            priority: _priority,
            column: TaskColumn.backlog,
            createdAtMs: DateTime.now().millisecondsSinceEpoch)
        : e.task.copyWith(
            title: title,
            description: _desc.text.trim(),
            projectId: _project!.id,
            acceptance: acceptance,
            taskType: _type,
            clearTaskType: _type == null,
            priority: _priority);
    try {
      await BoardActions(widget.store, widget.all).save(task, isNew: e == null);
      if (e == null) await widget.store.rememberProject(_project!.id);
      if (mounted) Navigator.of(context).pop();
    } on SessionActionFailed catch (x) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = x.message;
        });
      }
    }
  }

  Future<void> _newProject() async {
    final p = await editProject(context, all: widget.all, store: widget.store);
    if (p != null && mounted) setState(() => _project = p);
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.editing != null;
    final table = widget.store.table;
    final t = widget.editing?.task;
    return GlassSheet(children: [
      Text(editing ? 'Edit task' : 'New task', style: gSerif(28, w: FontWeight.w500, height: 1.15)),
      const SizedBox(height: 12),
      GlassField(
        key: const ValueKey('task-title'),
        controller: _title,
        label: 'Title',
        autofocus: !editing,
        maxLength: maxTaskTitleLength,
        error: _titleError,
      ),
      const SizedBox(height: 10),
      GlassField(
        key: const ValueKey('task-description'),
        controller: _desc,
        label: _full ? 'Description' : 'One line (optional)',
        hint: 'Sent to Claude as you write it',
        minLines: _full ? 3 : 1,
        maxLines: _full ? 10 : 2,
      ),
      const SizedBox(height: 12),
      Text('PROJECT', style: gCaps(10.5)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final p in _sortedProjects)
          GlassChip(
            key: ValueKey('task-project-${p.id}'),
            label: p.name,
            icon: p.id == _project?.id ? Icons.check_rounded : Icons.folder_outlined,
            selected: p.id == _project?.id,
            onTap: () => setState(() => _project = p),
          ),
        GlassChip(key: const ValueKey('task-project-new'), label: 'New project…', icon: Icons.add_rounded, onTap: _newProject),
      ]),
      if (t != null && t.machineId != null) ...[
        const SizedBox(height: 10),
        InfoRow(
            key: const ValueKey('task-folder'),
            label: 'Runs on ${assignedLabel(t, widget.all)} in',
            value: t.cwd.isEmpty ? 'the project\'s folder there' : t.cwd,
            mono: t.cwd.isNotEmpty),
      ],
      if (_full) ...[
        const SizedBox(height: 12),
        Text('ACCEPTANCE CRITERIA', style: gCaps(10.5)),
        const SizedBox(height: 2),
        Text('What must be true when it is done. Claude ticks them in its report.',
            style: gSans(12.5, FontWeight.w500, color: G.muted)),
        const SizedBox(height: 6),
        for (final (i, c) in _criteria.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              const Icon(Icons.check_box_outline_blank_rounded, size: 18, color: G.muted),
              const SizedBox(width: 8),
              Expanded(child: GlassField(key: ValueKey('criterion-$i'), controller: c, hint: 'Criterion ${i + 1}', maxLines: 3)),
              ClickDetector(
                key: ValueKey('criterion-remove-$i'),
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _criteria.removeAt(i).dispose()),
                child: Semantics(
                  button: true,
                  label: 'Remove criterion ${i + 1}',
                  child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.close_rounded, size: 18, color: G.muted)),
                ),
              ),
            ]),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: GlassButton(
              key: const ValueKey('criterion-add'),
              label: 'Add a criterion',
              icon: Icons.add_rounded,
              compact: true,
              onTap: () => setState(() => _criteria.add(TextEditingController()))),
        ),
        const SizedBox(height: 12),
        Text('TASK TYPE', style: gCaps(10.5)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          GlassChip(
              key: const ValueKey('task-type-none'),
              label: 'No type',
              icon: _type == null ? Icons.check_rounded : Icons.label_off_outlined,
              selected: _type == null,
              onTap: () => setState(() => _type = null)),
          for (final r in table.rows)
            GlassChip(
                key: ValueKey('task-type-${r.id}'),
                label: r.name,
                icon: _type == r.id ? Icons.check_rounded : Icons.label_outline_rounded,
                selected: _type == r.id,
                onTap: () => setState(() => _type = r.id)),
        ]),
        const SizedBox(height: 12),
        Text('PRIORITY', style: gCaps(10.5)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, children: [
          for (final p in TaskPriority.values)
            GlassChip(
                key: ValueKey('task-priority-${p.name}'),
                label: priorityLabel(p),
                icon: _priority == p ? Icons.check_rounded : Icons.flag_outlined,
                selected: _priority == p,
                onTap: () => setState(() => _priority = p)),
        ]),
      ] else
        Align(
          alignment: Alignment.centerLeft,
          child: ClickDetector(
            key: const ValueKey('task-more'),
            onTap: () => setState(() => _full = true),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('More: description, acceptance criteria, type, priority',
                  style: gSans(13, FontWeight.w700, color: Perch.orange)),
            ),
          ),
        ),
      if (_error != null)
        Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: gSans(13.5, FontWeight.w700, color: G.glow))),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        if (_saving) ...[const WorkingWave(width: 40, height: 18, bars: 8), const SizedBox(width: 14)],
        GlassButton(label: editing ? 'Save' : 'Add', warm: true, icon: Icons.check_rounded, onTap: _saving ? null : _save),
      ]),
    ]);
  }
}

// ---------------------------------------------------------------- run on, notes

/// Run on…: the machine (online ones first, then those that have a folder for the project),
/// the project's folder there (found by git remote or picked, and saved into the project),
/// then a new session or an idle one. An offline machine keeps the assignment: the task runs
/// there when the owner presses Run on… again with the machine back.
Future<void> showRunOnSheet(BuildContext context, BoardItem item,
    {required List<HostConnection> all, required BoardStore store}) async {
  final t = item.task;
  final project = item.projectIn(store.projects);
  bool online(HostConnection c) => c.link.value == LinkState.online;
  final machines = [...all]..sort((a, b) {
      final o = (online(a) ? 0 : 1).compareTo(online(b) ? 0 : 1);
      if (o != 0) return o;
      final f = (project?.folderOn(a.machine.id) != null ? 0 : 1).compareTo(project?.folderOn(b.machine.id) != null ? 0 : 1);
      return f != 0 ? f : machineTitle(a).toLowerCase().compareTo(machineTitle(b).toLowerCase());
    });
  if (machines.isEmpty) {
    say(context, 'Add a machine first: a task runs on one of your machines.');
    return;
  }
  final c = await showGlassSheet<HostConnection>(
    context,
    (ctx) => GlassSheet(children: [
      ...sheetTitle('Run on', t.title),
      const SizedBox(height: 10),
      for (final m in machines)
        MenuRow(
          key: ValueKey('run-on-${m.machine.id}'),
          label: machineTitle(m),
          icon: online(m) ? Icons.computer_rounded : Icons.cloud_off_rounded,
          note: [
            online(m) ? 'Online' : 'Offline',
            ?project?.folderOn(m.machine.id),
            if (m.machine.id == t.machineId) 'assigned now',
          ].join(' · '),
          onTap: () => Navigator.of(ctx).pop(m),
        ),
    ]),
  );
  if (c == null || !context.mounted) return;
  if (!c.canControl) {
    say(context, watchOnlyMessage);
    return;
  }
  final actions = BoardActions(store, all);
  if (!online(c)) {
    final cwd = project?.folderOn(c.machine.id) ?? (t.machineId == c.machine.id ? t.cwd : '');
    actions.assign(t, c, cwd);
    say(context, '${machineTitle(c)} is offline: run it when it is back');
    return;
  }
  String? folder;
  if (project != null) {
    folder = await projectFolderOn(context, project, c, store: store, fallbackRemote: t.gitRemote);
  } else {
    folder = await pickFolder(context, c, start: t.machineId == c.machine.id && t.cwd.isNotEmpty ? t.cwd : null,
        title: 'Folder on ${machineTitle(c)}');
  }
  if (folder == null || !context.mounted) return;
  final model = store.table.modelFor(t.taskType);
  final idle = [
    for (final s in c.sessions.value)
      if (s.live && s.state == SessionState.idle) s
  ];
  final choice = await showGlassSheet<String>(
    context,
    (ctx) => GlassSheet(children: [
      ...sheetTitle('Run ${t.title}', 'Claude gets the title and description as written, and is asked for a short report.'),
      const SizedBox(height: 12),
      MenuRow(
        key: const ValueKey('run-new'),
        label: 'New session · ${modelLabel(model)}',
        icon: Icons.add_rounded,
        onTap: () => Navigator.of(ctx).pop(''),
      ),
      if (idle.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('OR AN IDLE SESSION ON ${machineTitle(c).toUpperCase()}', style: gCaps(10.5)),
        for (final s in idle)
          MenuRow(
            key: ValueKey('run-in-${s.id}'),
            label: s.name.isEmpty ? shortFolder(s.cwd) : s.name,
            icon: Icons.forum_outlined,
            onTap: () => Navigator.of(ctx).pop(s.id),
          ),
      ],
    ]),
  );
  if (choice == null || !context.mounted) return;
  final cwd = folder;
  say(context, choice.isEmpty ? 'Starting a session for ${t.title}…' : 'Sending ${t.title}…');
  await taskAct(context, () => actions.runOn(t, c, cwd, sessionId: choice.isEmpty ? null : choice),
      done: '${t.title} is in progress');
}

Future<void> showNotesSheet(BuildContext context, BoardItem item) async {
  final c = item.connection;
  if (c == null || c.link.value != LinkState.online) {
    say(context, 'The machine this task runs on is not online.');
    return;
  }
  final text = TextEditingController();
  final notes = await showGlassSheet<String>(
    context,
    (ctx) => GlassSheet(children: [
      ...sheetTitle('Send notes back', 'Typed into ${item.task.sessionName ?? 'its session'}; the card goes back to In progress.'),
      const SizedBox(height: 12),
      GlassField(key: const ValueKey('task-notes'), controller: text, label: 'Notes', minLines: 3, maxLines: 8, autofocus: true),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: GlassButton(label: 'Cancel', onTap: () => Navigator.of(ctx).pop())),
        const SizedBox(width: 10),
        Expanded(child: GlassButton(label: 'Send', warm: true, onTap: () => Navigator.of(ctx).pop(text.text.trim()))),
      ]),
    ]),
  );
  // Not disposed here: the sheet still shows the field while it slides away.
  if (notes == null || notes.isEmpty || !context.mounted) return;
  await taskAct(context, () => c.sendTaskNotes(item.task.id, notes), done: 'Notes sent');
}
