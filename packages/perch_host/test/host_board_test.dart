// The host's replica of the board (board.json, written atomically), its one-time migration
// from tasks.json and the project list / model table in host.json, the 180-day prune on
// load, and a broken board.json kept aside.
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_board.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

final sep = Platform.pathSeparator;
const day = 24 * 60 * 60 * 1000;

void main() {
  late Directory tmp;
  late String stateDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_host_board_');
    stateDir = '${tmp.path}${sep}state';
    Directory(stateDir).createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  HostBoard load({ProjectList? projects, ModelTable? models, int nowMs = 1000 * day, List<String>? log}) => HostBoard(
      stateDir: stateDir,
      machineId: 'm-win',
      legacyProjects: projects,
      legacyModels: models,
      remoteOf: (_) => null,
      now: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
      log: log?.add);

  test('migrates_tasks_json_into_the_board_once', () {
    final folder = '${tmp.path}${sep}proj';
    File('$stateDir${sep}tasks.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'tasks': [
        {
          'id': 't1',
          'title': 'In a project',
          'cwd': folder,
          'projectId': 'p1',
          'column': 'review',
          'createdAtMs': 5,
          'updatedAtMs': 6,
          'sessionId': 's1',
          'report': {'text': 'done', 'atMs': 7},
          'gitHead': 'abc',
          'awaiting': true,
        },
        {'id': 't2', 'title': 'Older task', 'cwd': folder, 'createdAtMs': 8, 'updatedAtMs': 9},
      ]
    }));
    const projects = ProjectList(projects: [Project(id: 'p1', name: 'Perch')], updatedAtMs: 50);
    final models = ModelTable.starting.withRow(const ModelRow(id: 'chores', name: 'Chores', model: 'haiku'), atMs: 60);
    final b = load(projects: projects, models: models);
    expect(b.myTasks.map((t) => t.id).toSet(), {'t1', 't2'});
    final t1 = b.myTasks.firstWhere((t) => t.id == 't1');
    expect(t1.machineId, 'm-win');
    expect(t1.column, TaskColumn.review);
    expect(t1.report!.text, 'done');
    expect(t1.sessionId, 's1');
    expect(b.board.get(RecordKinds.task, 't1')!.groups['run']!.value['gitHead'], 'abc');
    final t2 = b.myTasks.firstWhere((t) => t.id == 't2');
    final auto = autoProjectId(machineId: 'm-win', folder: folder);
    expect(t2.projectId, auto);
    final autoProject = projectOf(b.board.get(RecordKinds.project, auto)!)!;
    expect(autoProject.name, 'proj');
    expect(autoProject.auto, isTrue);
    expect(autoProject.folders, {'m-win': folder});
    expect(b.board.projects.map((p) => p.id).toSet(), {'p1', auto});
    expect(modelTableOf(b.board)!.modelFor('chores'), 'haiku');
    expect(File('$stateDir${sep}tasks.json').existsSync(), isFalse);
    expect(File('$stateDir${sep}tasks.json.migrated').existsSync(), isTrue);
    expect(File('$stateDir${sep}board.json').existsSync(), isTrue);

    // A second load reads board.json and does not migrate again (even with a new tasks.json).
    File('$stateDir${sep}tasks.json').writeAsStringSync(jsonEncode({
      'tasks': [
        {'id': 't3', 'title': 'Late', 'cwd': folder}
      ]
    }));
    final again = load(projects: projects, models: models);
    expect(again.myTasks.map((t) => t.id).toSet(), {'t1', 't2'});
  });

  test('a_task_in_a_known_project_folder_joins_that_project', () {
    final folder = '${tmp.path}${sep}proj';
    File('$stateDir${sep}tasks.json').writeAsStringSync(jsonEncode({
      'tasks': [
        {'id': 't', 'title': 'No project id', 'cwd': folder}
      ]
    }));
    final b = load(projects: ProjectList(projects: [Project(id: 'px', name: 'X', folders: {'m-win': folder})], updatedAtMs: 1));
    expect(b.myTasks.single.projectId, 'px');
  });

  test('edits_are_saved_atomically_and_reloaded', () async {
    final b = load();
    final changes = <BoardChange>[];
    final sub = b.changes.listen(changes.add);
    b.edit(RecordKinds.task, 'x', {
      'content': {'title': 'New', 'projectId': 'p', 'machineId': 'm-win', 'cwd': '/w'}
    });
    await Future<void>.delayed(Duration.zero);
    expect(changes.single.records.single.id, 'x');
    expect(changes.single.from, isNull);
    expect(File('$stateDir${sep}board.json.tmp').existsSync(), isFalse);
    final merged = b.mergeAll([
      BoardRecord(RecordKinds.task, 'y', {'content': BoardGroup({'title': 'From phone'}, Hlc(5 * day, 0, 'phone'))})
    ], from: 'dev1');
    expect(merged, isTrue);
    expect(b.mergeAll([b.board.get(RecordKinds.task, 'y')!], from: 'dev1'), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(changes.last.from, 'dev1');
    expect(changes.length, 2);
    await sub.cancel();
    final again = load();
    expect(again.board.get(RecordKinds.task, 'x'), isNotNull);
    expect(again.board.get(RecordKinds.task, 'y'), isNotNull);
    expect(again.myTasks.map((t) => t.id), ['x']);
    // The clock moved past what was seen.
    expect(again.clock.tick() > Hlc(5 * day, 0, 'phone'), isTrue);
  });

  test('prune_runs_on_load', () {
    final b = load(nowMs: 100 * day);
    b.edit(RecordKinds.task, 'old', {
      'life': {'deleted': true, 'deletedAtMs': 1 * day}
    });
    b.edit(RecordKinds.task, 'new', {
      'life': {'deleted': true, 'deletedAtMs': 99 * day}
    });
    final later = load(nowMs: 182 * day);
    expect(later.board.get(RecordKinds.task, 'old'), isNull);
    expect(later.board.get(RecordKinds.task, 'new'), isNotNull);
  });

  test('a_broken_board_json_is_kept_aside_not_lost', () {
    File('$stateDir${sep}board.json').writeAsStringSync('{not json');
    final log = <String>[];
    final b = load(log: log);
    expect(b.board.records, isEmpty);
    final aside = Directory(stateDir).listSync().whereType<File>().where((f) => f.path.contains('board.json.broken-'));
    expect(aside, hasLength(1));
    expect(aside.single.readAsStringSync(), '{not json');
    expect(log.single, contains('board.json'));
    expect(File('$stateDir${sep}tasks.json.migrated').existsSync(), isFalse, reason: 'no tasks.json to migrate');
  });
}
