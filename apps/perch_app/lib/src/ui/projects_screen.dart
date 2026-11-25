// Projects: machine-agnostic (a name, a description, its git remote) with, per machine, the
// folder where the project lives there (found by git remote, changeable). Projects are
// records in the board every device keeps; a project needs no folder at all (an idea).
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/board_store.dart';
import '../connection/host_connection.dart';
import '../state/providers.dart';
import 'app_theme.dart' show openGlass;
import 'board_logic.dart';
import 'folder_picker.dart';
import 'glass/mosaic.dart';
import 'glass/settings.dart';
import 'glass/widgets.dart';
import 'labels.dart';

void openProjects(BuildContext context) => openGlass<void>(context, const ProjectsScreen());

/// A new project id (made on the phone).
String newProjectId() {
  final r = Random.secure();
  return 'p-${List.generate(10, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[r.nextInt(36)]).join()}';
}

/// How many live tasks on the board belong to [p].
int tasksIn(Project p, BoardStore store) {
  final b = store.file?.board;
  if (b == null) return 0;
  return [
    for (final t in b.liveTasks)
      if (t.projectId == p.id || (t.projectId == null && t.machineId != null && store.projects.projectOf(t, t.machineId!)?.id == p.id))
        t
  ].length;
}

/// The folder on [c] with [remote] (null: none, or the machine could not say).
Future<String?> folderByRemote(HostConnection c, String? remote, {String? preferName}) async {
  if (remote == null || c.link.value != LinkState.online) return null;
  try {
    return matchGitFolder(remote, await c.gitRemotes(), preferName: preferName)?.path;
  } on SessionActionFailed {
    return null;
  }
}

/// The git remote of [folder] on [c] (null: not a git folder, or not known).
Future<String?> remoteOfFolder(HostConnection c, String folder) async {
  if (c.link.value != LinkState.online) return null;
  try {
    final key = folderKey(folder);
    return (await c.gitRemotes()).where((f) => folderKey(f.path) == key).firstOrNull?.remote;
  } on SessionActionFailed {
    return null;
  }
}

class ProjectsScreen extends ConsumerWidget {
  const ProjectsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machines = ref.watch(machinesProvider);
    final registry = ref.watch(connectionsProvider);
    return ProjectsView(connections: [for (final m in machines) registry.of(m)], store: ref.watch(boardStoreProvider));
  }
}

class ProjectsView extends StatelessWidget {
  final List<HostConnection> connections;
  final BoardStore store;
  const ProjectsView({super.key, required this.connections, required this.store});

  @override
  Widget build(BuildContext context) => GlassScaffold(
        background: MosaicBackdrop(seed: 23, fade: G.deep, fadeFrom: 0.25, pixel: 0.6),
        child: ListenableBuilder(
          listenable: Listenable.merge([store, for (final c in connections) ...[c.tasks, c.displayName, c.link]]),
          builder: (context, _) {
            final projects = [...store.projects.projects]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
            return ListView(key: const ValueKey('projects-list'), padding: screenPadding(context), children: [
              Row(children: [
                GlassOrb(icon: Icons.arrow_back_rounded, label: 'Back', onTap: () => Navigator.of(context).maybePop()),
                const SizedBox(width: 12),
                Expanded(child: Text('Projects', style: gSerif(30, w: FontWeight.w500, height: 1.1))),
                GlassButton(
                    key: const ValueKey('new-project'),
                    label: 'New project',
                    icon: Icons.add_rounded,
                    warm: true,
                    compact: true,
                    onTap: () => editProject(context, all: connections, store: store)),
              ]),
              const SizedBox(height: 10),
              Text(
                  'A project is the same on every machine; each machine has its own folder for it. '
                  'Its tasks are assigned to a machine when they run (Run on…).',
                  style: gSans(14, FontWeight.w500, color: G.muted)),
              const SizedBox(height: 16),
              if (projects.isEmpty)
                Text('No projects yet. Tasks you add on the board are grouped into projects by their folder.',
                    style: gSans(14.5, FontWeight.w600, color: G.muted))
              else
                SettingsGroup(caption: 'Your projects', children: [
                  for (final p in projects)
                    SettingRow(
                      key: ValueKey('project-row-${p.id}'),
                      label: p.name,
                      value: [
                        '${tasksIn(p, store)} ${tasksIn(p, store) == 1 ? 'task' : 'tasks'}',
                        _whereLine(p, connections),
                      ].join(' · '),
                      verb: 'Edit',
                      icon: Icons.folder_outlined,
                      onTap: () => editProject(context, all: connections, store: store, project: p),
                    ),
                ]),
            ]);
          },
        ),
      );

  static String _whereLine(Project p, List<HostConnection> all) {
    final names = [
      for (final id in p.folders.keys) all.where((c) => c.machine.id == id).firstOrNull?.displayName.value ?? 'a removed machine'
    ];
    return names.isEmpty ? 'on no machine yet' : 'on ${names.join(', ')}';
  }
}

/// Opens the editor for [project] (null: a new one, with [name] filled in); returns the
/// saved project, or null when cancelled.
Future<Project?> editProject(BuildContext context,
        {required List<HostConnection> all, required BoardStore store, Project? project, String? name, HostConnection? machine}) =>
    showGlassSheet<Project>(
        context, (_) => ProjectEditor(all: all, store: store, project: project, name: name, machine: machine));

class ProjectEditor extends StatefulWidget {
  final List<HostConnection> all;
  final BoardStore store;
  final Project? project;
  final String? name;

  /// A new project's first machine (its folder is asked for at once).
  final HostConnection? machine;
  const ProjectEditor({super.key, required this.all, required this.store, this.project, this.name, this.machine});
  @override
  State<ProjectEditor> createState() => _ProjectEditorState();
}

class _ProjectEditorState extends State<ProjectEditor> {
  late final _name = TextEditingController(text: widget.project?.name ?? widget.name ?? '');
  late final _description = TextEditingController(text: widget.project?.description ?? '');
  late final _remote = TextEditingController(text: widget.project?.gitRemote ?? '');
  late Project _p = widget.project ??
      Project(id: newProjectId(), name: widget.name ?? '', createdAtMs: DateTime.now().millisecondsSinceEpoch);
  final Set<String> _found = {};
  String? _error;

  bool get _isNew => widget.project == null;

  /// The machines shown: every paired machine.
  List<HostConnection> get _machines => widget.all;

  @override
  void initState() {
    super.initState();
    _findByRemote();
  }

  /// Machines without a folder for the project: the folder with its git remote, if any.
  Future<void> _findByRemote() async {
    final remote = _p.gitRemote;
    if (remote == null) return;
    for (final c in _machines) {
      if (_p.folderOn(c.machine.id) != null) continue;
      final f = await folderByRemote(c, remote, preferName: _p.name);
      if (f == null || !mounted || _p.folderOn(c.machine.id) != null) continue;
      setState(() {
        _p = _p.withFolder(c.machine.id, f);
        _found.add(c.machine.id);
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _remote.dispose();
    super.dispose();
  }

  Future<void> _pick(HostConnection c) async {
    final f = await pickFolder(context, c, start: _p.folderOn(c.machine.id), title: 'Folder on ${machineTitle(c)}');
    if (f == null || !mounted) return;
    setState(() {
      _p = _p.withFolder(c.machine.id, f);
      _found.remove(c.machine.id);
    });
    if (_p.gitRemote == null) {
      final r = await remoteOfFolder(c, f);
      if (r != null && mounted) {
        setState(() {
          _p = _p.copyWith(gitRemote: r);
          if (_remote.text.trim().isEmpty) _remote.text = r;
        });
        await _findByRemote();
      }
    }
  }

  Future<void> _save() async {
    final err = Project.nameError(_name.text);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final desc = _description.text.trim();
    final remote = _remote.text.trim();
    final p = _p.copyWith(
        name: _name.text.trim(),
        auto: false,
        description: desc.isEmpty ? null : desc,
        clearDescription: desc.isEmpty,
        gitRemote: remote.isEmpty ? null : remote,
        clearRemote: remote.isEmpty);
    await widget.store.setProjects(widget.store.projects.withProject(p, atMs: now));
    if (mounted) Navigator.of(context).pop(p);
  }

  Future<void> _delete() async {
    final tasks = tasksIn(_p, widget.store);
    if (!await confirmDanger(context,
            title: 'Delete the project ${_p.name}?',
            lost: tasks == 0
                ? 'It goes to the bin (Deleted) on every device; Restore brings it back. No folder or file is touched.'
                : 'It and its $tasks ${tasks == 1 ? 'task go' : 'tasks go'} to the bin (Deleted) on every device; '
                    'Restore brings them back together. No folder or file is touched.',
            yes: 'Delete project') ||
        !mounted) {
      return;
    }
    widget.store.deleteProject(_p.id);
    widget.store.onProjectsChanged?.call();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _isNew ? 0 : tasksIn(_p, widget.store);
    return GlassSheet(children: [
      Text(_isNew ? 'New project' : 'Edit project', style: gSerif(28, w: FontWeight.w500, height: 1.15)),
      const SizedBox(height: 12),
      GlassField(
        key: const ValueKey('project-name'),
        controller: _name,
        label: 'Name',
        autofocus: _isNew,
        maxLength: 60,
        error: _error,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
      ),
      const SizedBox(height: 10),
      GlassField(
        key: const ValueKey('project-description'),
        controller: _description,
        label: 'Description (optional)',
        hint: 'What it is',
        minLines: 1,
        maxLines: 4,
      ),
      const SizedBox(height: 10),
      GlassField(
        key: const ValueKey('project-remote'),
        controller: _remote,
        label: 'Git remote (optional)',
        hint: 'github.com/owner/repo: finds its folder on each machine',
      ),
      const SizedBox(height: 16),
      SettingsGroup(caption: 'Folder on each machine', children: [
        for (final c in _machines)
          SettingRow(
            key: ValueKey('project-folder-${c.machine.id}'),
            label: machineTitle(c),
            value: _p.folderOn(c.machine.id) ?? 'Not on this machine',
            mono: _p.folderOn(c.machine.id) != null,
            note: _found.contains(c.machine.id) ? 'Found by its git remote' : null,
            verb: _p.folderOn(c.machine.id) == null ? 'Set' : 'Change',
            icon: Icons.computer_rounded,
            onTap: c.link.value == LinkState.online ? () => _pick(c) : null,
          ),
        if (_machines.isEmpty) const InfoRow(label: 'Machines', value: 'None paired yet: a folder can be set later'),
      ]),
      if (!_isNew) ...[
        const SizedBox(height: 4),
        InfoRow(label: 'Tasks', value: '$tasks on the board'),
      ],
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: GlassButton(label: 'Cancel', onTap: () => Navigator.of(context).pop())),
        const SizedBox(width: 10),
        Expanded(child: GlassButton(key: const ValueKey('project-save'), label: 'Save', warm: true, onTap: _save)),
      ]),
      if (!_isNew) ...[
        const SizedBox(height: 14),
        DangerButton(key: const ValueKey('project-delete'), label: 'Delete project', compact: true, onTap: _delete),
      ],
    ]);
  }
}

/// The folder of [project] on [target], asking when it has none there: the folder with the
/// project's git remote (confirmed), else one the owner picks. The answer is saved into the
/// project. Null: cancelled.
Future<String?> projectFolderOn(BuildContext context, Project project, HostConnection target,
    {required BoardStore store, String? fallbackRemote}) async {
  final known = project.folderOn(target.machine.id);
  if (known != null) return known;
  final remote = project.gitRemote ?? fallbackRemote;
  var folder = await folderByRemote(target, remote, preferName: project.name);
  if (!context.mounted) return null;
  if (folder != null) {
    final found = folder;
    final use = await showGlassSheet<bool>(
      context,
      (ctx) => GlassSheet(children: [
        ...sheetTitle('${project.name} on ${machineTitle(target)}', 'Found by its git remote:'),
        const SizedBox(height: 8),
        CodeWell(child: Text(found, key: const ValueKey('matched-folder'), style: gMono(12.5))),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: GlassButton(label: 'Another folder…', onTap: () => Navigator.of(ctx).pop(false))),
          const SizedBox(width: 10),
          Expanded(child: GlassButton(label: 'Use this folder', warm: true, onTap: () => Navigator.of(ctx).pop(true))),
        ]),
      ]),
    );
    if (use == null || !context.mounted) return null;
    if (!use) folder = null;
  }
  folder ??= await pickFolder(context, target, title: '${project.name} has no folder on ${machineTitle(target)}: choose it');
  if (folder == null) return null;
  final p = (store.projects.byId(project.id) ?? project).withFolder(target.machine.id, folder);
  await store.setProjects(store.projects.withProject(remote != null && p.gitRemote == null ? p.copyWith(gitRemote: remote) : p,
      atMs: DateTime.now().millisecondsSinceEpoch));
  return folder;
}

/// The project for a task on [item]'s machine: its own, or one grouped from its folder.
Project? projectOfItem(BoardItem item, BoardStore store) => item.projectIn(store.projects);
