import 'dart:convert';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

const project = Project(
    id: 'p1',
    name: 'Perch',
    description: 'Phone control for Claude Code',
    gitRemote: 'github.com/o/perch',
    folders: {'m-win': r'D:\projects\perch', 'm-mac': '/Users/o/perch'},
    createdAtMs: 86400000);

const task = BoardTask(
  id: 't1',
  title: 'Fix login',
  description: 'The login page loops.',
  cwd: r'D:\projects\perch',
  projectId: 'p1',
  machineId: 'm-win',
  acceptance: ['Login works'],
  taskType: 'bugfix',
  priority: TaskPriority.high,
  column: TaskColumn.review,
  createdAtMs: 1000,
  updatedAtMs: 2000,
  sessionId: 's1',
  sessionName: 'Fix login',
  sentAtMs: 1500,
  report: TaskReport(
    text: 'Report: fixed',
    criteria: [CriterionCheck('Login works', met: true)],
    todos: [TodoItem('Find it', done: true), TodoItem('Fix it')],
    files: ['lib/login.dart'],
    changes: [' lib/login.dart | 3 ++-'],
    atMs: 3000,
    sessionEnded: true,
  ),
  gitRemote: 'github.com/o/perch',
);

final models = ModelTable.starting.withRow(const ModelRow(id: 'bugfix', name: 'Bug fixes', model: 'sonnet'), atMs: 1);

void main() {
  test('task_share_has_every_field', () {
    final j = jsonDecode(taskShareJson(task, project: project, machineName: 'Desktop', models: models)) as Map;
    expect(j['perch'], 'task');
    expect(j['version'], 1);
    expect(j.keys.toList(), ['perch', 'version', 'project', 'task']);
    final p = j['project'] as Map;
    expect(p['name'], 'Perch');
    expect(p['description'], 'Phone control for Claude Code');
    expect(p['gitRemote'], 'github.com/o/perch');
    final t = j['task'] as Map;
    expect(t.keys.toList(), [
      'id', 'title', 'description', 'acceptance', 'type', 'priority', 'column', 'machine', 'folder', 'createdAt', //
      'updatedAt', 'session', 'report', 'gitRemote'
    ]);
    expect(t['id'], 't1');
    expect(t['title'], 'Fix login');
    expect(t['description'], 'The login page loops.');
    expect(t['acceptance'], ['Login works']);
    expect(t['type'], {'id': 'bugfix', 'name': 'Bug fixes', 'model': 'sonnet'});
    expect(t['priority'], 'high');
    expect(t['column'], 'review');
    expect(t['machine'], {'id': 'm-win', 'name': 'Desktop'});
    expect(t['folder'], r'D:\projects\perch');
    expect(t['createdAt'], '1970-01-01T00:00:01.000Z');
    expect(t['updatedAt'], '1970-01-01T00:00:02.000Z');
    expect(t['session'], {'id': 's1', 'name': 'Fix login', 'sentAt': '1970-01-01T00:00:01.500Z'});
    expect(t['report'], {
      'text': 'Report: fixed',
      'todos': [
        {'text': 'Find it', 'done': true},
        {'text': 'Fix it', 'done': false}
      ],
      'files': ['lib/login.dart'],
      'changes': [' lib/login.dart | 3 ++-'],
      'criteria': [
        {'text': 'Login works', 'met': true}
      ],
      'at': '1970-01-01T00:00:03.000Z',
      'sessionEnded': true,
    });
    expect(t['gitRemote'], 'github.com/o/perch');
  });

  test('an_unassigned_idea_shares_nulls', () {
    const idea = BoardTask(id: 'i', title: 'An idea', cwd: '', projectId: 'p1');
    final t = (jsonDecode(taskShareJson(idea)) as Map)['task'] as Map;
    expect(t['machine'], isNull);
    expect(t['folder'], isNull);
    expect(t['session'], isNull);
    expect(t['report'], isNull);
    expect(t['type'], isNull);
    expect((jsonDecode(taskShareJson(idea)) as Map)['project'], isNull);
  });

  test('project_share_has_all_tasks_including_done', () {
    final tasks = [
      task.copyWith(column: TaskColumn.done),
      const BoardTask(id: 'a', title: 'Low ready', cwd: '', priority: TaskPriority.low, column: TaskColumn.ready),
      const BoardTask(id: 'b', title: 'High ready', cwd: '', priority: TaskPriority.high, column: TaskColumn.ready),
      const BoardTask(id: 'c', title: 'Backlog', cwd: ''),
    ];
    final j = jsonDecode(projectShareJson(project, tasks, machineNames: {'m-win': 'Desktop', 'm-mac': 'Laptop'}, models: models))
        as Map;
    expect(j['perch'], 'project');
    expect(j['version'], 1);
    final p = j['project'] as Map;
    expect(p.keys.toList(), ['id', 'name', 'description', 'gitRemote', 'folders', 'createdAt']);
    expect(p['folders'], [
      {'machine': {'id': 'm-win', 'name': 'Desktop'}, 'path': r'D:\projects\perch'},
      {'machine': {'id': 'm-mac', 'name': 'Laptop'}, 'path': '/Users/o/perch'},
    ]);
    expect(p['createdAt'], '1970-01-02T00:00:00.000Z');
    expect([for (final t in j['tasks'] as List) (t as Map)['id']], ['c', 'b', 'a', 't1']);
    expect(((j['tasks'] as List).last as Map)['machine'], {'id': 'm-win', 'name': 'Desktop'});
  });

  test('no_secret_ever_appears', () {
    final text = projectShareJson(project, [task], machineNames: {'m-win': 'Desktop'}, models: models) +
        taskShareJson(task, project: project, machineName: 'Desktop', models: models);
    void walk(Object? v) {
      if (v is Map) {
        for (final e in v.entries) {
          final k = (e.key as String).toLowerCase();
          expect(k.contains('key') || k.contains('secret') || k.contains('token'), isFalse, reason: k);
          walk(e.value);
        }
      } else if (v is List) {
        v.forEach(walk);
      }
    }

    walk(jsonDecode(projectShareJson(project, [task])));
    walk(jsonDecode(taskShareJson(task, project: project)));
    expect(text, isNot(contains('"key"')));
  });

  test('share_is_pretty_printed_with_two_spaces', () {
    final s = taskShareJson(task);
    expect(s.startsWith('{\n  "perch": "task",\n  "version": 1,'), isTrue, reason: s.substring(0, 40));
    expect(projectShareJson(project, const []).contains('\n  "tasks": []'), isTrue);
  });
}
