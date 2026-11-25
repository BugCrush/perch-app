// Projects (machine-agnostic: a name and, per machine, its folder there), a task's
// acceptance criteria in the prompt Perch sends, and which of them Claude's report says are
// met.
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('projects', () {
    const p = Project(
        id: 'p1',
        name: 'Perch',
        gitRemote: 'git@github.com:o/perch.git',
        folders: {'m-win': r'D:\projects\perch', 'm-mac': '/Users/o/perch'},
        createdAtMs: 3);

    test('a project has a folder per machine, or none there', () {
      expect(p.folderOn('m-win'), r'D:\projects\perch');
      expect(p.folderOn('m-other'), isNull);
      expect(p.withFolder('m-other', '/srv/perch').folderOn('m-other'), '/srv/perch');
      expect(p.withFolder('m-win', null).folderOn('m-win'), isNull);
      final back = Project.tryFromJson(p.toJson())!;
      expect(back.toJson(), p.toJson());
      expect(Project.tryFromJson({'id': 'x'}), isNull, reason: 'a name is needed');
    });

    test('the list: add, replace, remove; newer wins is decided by updatedAtMs', () {
      final l = const ProjectList().withProject(p, atMs: 5);
      expect(l.byId('p1')!.name, 'Perch');
      expect(l.updatedAtMs, 5);
      final renamed = l.withProject(p.copyWith(name: 'Perch app'), atMs: 6);
      expect(renamed.projects.single.name, 'Perch app');
      expect(renamed.without('p1', atMs: 7).projects, isEmpty);
      expect(ProjectList.tryFromJson(renamed.toJson())!.toJson(), renamed.toJson());
    });

    test('the project a task belongs to: its id, else its folder on its machine', () {
      final l = const ProjectList().withProject(p, atMs: 1);
      BoardTask t(String cwd, {String? project}) => BoardTask(id: 't', title: 'T', cwd: cwd, projectId: project);
      expect(l.projectOf(t('x', project: 'p1'), 'm-win')?.id, 'p1');
      expect(l.projectOf(t(r'd:\Projects\Perch\'), 'm-win')?.id, 'p1', reason: 'case and a trailing slash do not matter');
      expect(l.projectOf(t('/Users/o/perch'), 'm-win'), isNull, reason: 'that folder is on the Mac');
      expect(l.projectOf(t('/Users/o/perch'), 'm-mac')?.id, 'p1');
    });

    test('auto project ids are the same on every device', () {
      expect(autoProjectId(remote: 'https://github.com/O/perch'), autoProjectId(remote: 'git@github.com:o/perch.git'));
      expect(autoProjectId(machineId: 'm', folder: r'D:\a'), autoProjectId(machineId: 'm', folder: r'd:\A\'));
      expect(autoProjectId(machineId: 'm', folder: r'D:\a'), isNot(autoProjectId(machineId: 'm', folder: r'D:\b')));
    });
  });

  group('acceptance criteria', () {
    test('the prompt lists them and asks which are met', () {
      final p = composeTaskPrompt('Add a footer', 'Small one.', acceptance: ['It shows the version', '  ', 'Tests pass']);
      expect(p, startsWith('Add a footer\n\nSmall one.\n\nAcceptance criteria:\n1. It shows the version\n2. Tests pass\n\n'));
      expect(p, endsWith(taskCriteriaRequest));
      expect(p, contains(taskReportRequest));
      expect(composeTaskPrompt('T', ''), isNot(contains('Acceptance')));
    });

    test("ticks are read from the report's checklist, by text or by order", () {
      const report = '## Report\n- Changed the footer.\n\nAcceptance criteria:\n'
          '- [x] It shows the version\n- [ ] Tests pass (one is flaky)\n';
      final c = checkCriteria(['It shows the version', 'Tests pass', 'Docs updated'], report);
      expect([for (final x in c) x.met], [true, false, null]);
      expect(c.first.text, 'It shows the version');
      // Reworded by Claude, but in the same order and as many.
      final byOrder = checkCriteria(['Footer has version', 'Green tests'], '1. [x] The footer now has the version\n2. [X] All tests green');
      expect([for (final x in byOrder) x.met], [true, true]);
      expect(checkCriteria(['A'], 'No checklist at all.').single.met, isNull);
      expect(checkCriteria(['A', 'B'], '✅ A\n❌ B').map((x) => x.met), [true, false]);
    });

    test('the report carries them; the task keeps them', () {
      final r = buildTaskReport([AssistantText('Report:\n- [x] A\n- [ ] B', seq: 1)], atMs: 2, acceptance: ['A', 'B']);
      expect([for (final x in r.criteria) x.met], [true, false]);
      final back = TaskReport.tryFromJson(r.toJson())!;
      expect([for (final x in back.criteria) (x.text, x.met)], [('A', true), ('B', false)]);
      const t = BoardTask(id: 't', title: 'T', cwd: '/p', projectId: 'p1', acceptance: ['A', 'B']);
      final tb = BoardTask.tryFromJson(t.toJson())!;
      expect(tb.projectId, 'p1');
      expect(tb.acceptance, ['A', 'B']);
      expect(t.copyWith(acceptance: ['C']).acceptance, ['C']);
      expect(t.copyWith(title: 'U').projectId, 'p1');
    });
  });

  test('wire: projects sync both ways', () {
    final list = const ProjectList().withProject(const Project(id: 'p', name: 'P', folders: {'m': '/p'}), atMs: 4);
    final c = decodeClient(encodeClient(SyncProjects(projects: list)))!;
    expect(c.toJson(), SyncProjects(projects: list).toJson());
    final h = decodeHost(encodeHost(ProjectsMessage(projects: list)))!;
    expect(h.toJson(), ProjectsMessage(projects: list).toJson());
  });
}
