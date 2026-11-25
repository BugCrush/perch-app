import 'dart:convert';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

HlcClock clockAt(String writer, int ms) => HlcClock(writer, now: () => DateTime.fromMillisecondsSinceEpoch(ms));

const fullTask = BoardTask(
  id: 't1',
  title: 'Fix login',
  description: 'The login page loops.',
  cwd: r'D:\projects\app',
  projectId: 'p1',
  machineId: 'm-win',
  acceptance: ['Login works', 'A test covers it'],
  taskType: 'bugfix',
  priority: TaskPriority.high,
  column: TaskColumn.review,
  createdAtMs: 1000,
  sessionId: 's1',
  sessionName: 'Fix login',
  sentAtMs: 2000,
  report: TaskReport(
    text: 'Report: fixed',
    criteria: [CriterionCheck('Login works', met: true), CriterionCheck('A test covers it')],
    todos: [TodoItem('Find it', done: true), TodoItem('Fix it')],
    files: ['lib/login.dart'],
    changes: [' lib/login.dart | 3 ++-'],
    atMs: 3000,
    sessionEnded: true,
  ),
  gitRemote: 'github.com/o/app',
);

void main() {
  test('task_roundtrips_through_its_record', () {
    final b = Board();
    b.put(RecordKinds.task, fullTask.id, taskGroupValues(fullTask), clockAt('phone', 5000));
    final back = taskOf(b.get(RecordKinds.task, 't1')!)!;
    final want = fullTask.toJson()..remove('updatedAtMs');
    final got = back.toJson()..remove('updatedAtMs');
    expect(jsonEncode(got), jsonEncode(want));
    expect(back.updatedAtMs, 5000);
    expect(taskGroupValues(fullTask).keys.toSet(), {'content', 'column', 'run'});
    expect(taskGroupValues(fullTask, life: {'deleted': true}).keys, contains('life'));
    expect(taskGroupValues(fullTask)['content']!['machineId'], 'm-win');
  });

  test('activity_is_not_stored', () {
    final t = fullTask.copyWith(activity: 'Running tests', activityAtMs: 9);
    final g = taskGroupValues(t);
    expect(jsonEncode(g), isNot(contains('Running tests')));
  });

  test('a_task_without_machine_is_not_assigned', () {
    final b = Board();
    b.put(RecordKinds.task, 'idea', {
      'content': {'title': 'An idea', 'projectId': 'p1'}
    }, clockAt('phone', 1));
    final t = taskOf(b.get(RecordKinds.task, 'idea')!)!;
    expect(t.machineId, isNull);
    expect(t.cwd, '');
    expect(t.column, TaskColumn.backlog);
    expect(taskOf(BoardRecord(RecordKinds.project, 'p', {'content': BoardGroup({'name': 'x'}, Hlc(1, 0, 'a'))})), isNull);
    expect(taskOf(BoardRecord(RecordKinds.task, 'x', {'column': BoardGroup({'column': 'ready'}, Hlc(1, 0, 'a'))})), isNull,
        reason: 'no title: broken');
  });

  test('project_folders_merge_from_two_machines', () {
    final phone = Board();
    const p = Project(id: 'p1', name: 'Perch', description: 'The app', gitRemote: 'github.com/o/perch', createdAtMs: 7);
    phone.put(RecordKinds.project, 'p1', projectGroupValues(p), clockAt('phone', 100));
    final win = Board(), mac = Board();
    for (final r in phone.records) {
      win.merge(r);
      mac.merge(r);
    }
    win.put(RecordKinds.project, 'p1', {'folder:m-win': {'path': r'D:\projects\perch'}}, clockAt('win', 200));
    mac.put(RecordKinds.project, 'p1', {'folder:m-mac': {'path': '/Users/o/perch'}}, clockAt('mac', 300));
    for (final r in win.records) {
      phone.merge(r);
    }
    for (final r in mac.records) {
      phone.merge(r);
    }
    final got = projectOf(phone.get(RecordKinds.project, 'p1')!)!;
    expect(got.folders, {'m-win': r'D:\projects\perch', 'm-mac': '/Users/o/perch'});
    expect(got.description, 'The app');
    expect(got.gitRemote, 'github.com/o/perch');
    expect(got.createdAtMs, 7);
    // A cleared folder ({path: ''}) is gone.
    phone.put(RecordKinds.project, 'p1', {'folder:m-mac': {'path': ''}}, clockAt('phone', 400));
    expect(projectOf(phone.get(RecordKinds.project, 'p1')!)!.folders.keys, ['m-win']);
    expect(projectGroupValues(got).keys.toSet(), {'content', 'folder:m-win', 'folder:m-mac'});
  });

  test('bin_lists_deleted_newest_first_and_hides_purged', () {
    final b = Board();
    final c = clockAt('a', 1000);
    for (final id in ['alive', 'd1', 'd2', 'gone']) {
      b.put(RecordKinds.task, id, {'content': {'title': id, 'projectId': 'p'}}, c);
    }
    b.put(RecordKinds.task, 'd1', {'life': {'deleted': true, 'deletedAtMs': 1}}, c);
    b.put(RecordKinds.task, 'd2', {'life': {'deleted': true, 'deletedAtMs': 2}}, c);
    b.put(RecordKinds.task, 'gone', {'life': {'deleted': true, 'purged': true, 'deletedAtMs': 3}}, c);
    b.put(RecordKinds.project, 'p', {'content': {'name': 'Zed'}}, c);
    b.put(RecordKinds.project, 'q', {'content': {'name': 'Alpha'}}, c);
    b.put(RecordKinds.project, 'q', {'life': {'deleted': true, 'deletedAtMs': 4}}, c);
    b.put(RecordKinds.project, 'r', {'content': {'name': 'beta'}}, c);
    expect([for (final r in b.bin) r.id], ['q', 'd2', 'd1']);
    expect([for (final t in b.liveTasks) t.id], ['alive']);
    expect([for (final t in b.tasksOf('p')) t.id], ['alive']);
    expect([for (final p in b.projects) p.name], ['beta', 'Zed']);
  });

  test('model_table_roundtrip', () {
    final b = Board();
    expect(modelTableOf(b), isNull);
    final t = ModelTable.starting.withRow(const ModelRow(id: 'chores', name: 'Chores', model: 'haiku'), atMs: 50);
    b.put(RecordKinds.modelTable, modelTableRecordId, modelTableGroups(t), clockAt('phone', 60));
    final back = modelTableOf(b)!;
    expect(jsonEncode(back.rows.map((r) => r.toJson()).toList()), jsonEncode(t.rows.map((r) => r.toJson()).toList()));
    expect(back.updatedAtMs, 60);
  });

  test('new_fields_survive_json', () {
    expect(BoardTask.tryFromJson(fullTask.toJson())!.machineId, 'm-win');
    expect(fullTask.copyWith(clearMachine: true).machineId, isNull);
    const p = Project(id: 'p', name: 'n', description: 'd');
    expect(Project.tryFromJson(p.toJson())!.description, 'd');
    expect(p.withFolder('m', '/x').description, 'd');
    expect(p.copyWith(clearDescription: true).description, isNull);
  });
}
