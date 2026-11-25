// The board kept on the phone (board.json in the app's own storage, written atomically):
// edits survive a restart, the first load takes the projects and model table the older
// app kept in shared preferences, and the board key lives in secure storage, never in the
// file.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:perch_app/src/connection/account_store.dart';
import 'package:perch_app/src/connection/board_file.dart';
import 'package:perch_app/src/connection/board_store.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('perch_board_file_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('edits_survive_a_restart', () async {
    final a = BoardFile(dir: dir, writer: 'phone-1', keyBox: MemorySecretBox());
    await a.load();
    a.edit(RecordKinds.project, 'p1', {
      'content': {'name': 'Perch'}
    });
    a.edit(RecordKinds.task, 't1', {
      'content': {'title': 'An idea', 'projectId': 'p1'},
      'column': {'column': 'backlog'}
    });
    await a.flush();
    expect(File('${dir.path}${Platform.pathSeparator}board.json').existsSync(), isTrue);
    expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    final b = BoardFile(dir: dir, writer: 'phone-1', keyBox: MemorySecretBox());
    await b.load();
    expect(b.board.liveTasks.single.title, 'An idea');
    expect(b.board.projects.single.name, 'Perch');
    expect(b.clock.tick() > a.board.get(RecordKinds.task, 't1')!.newest, isTrue, reason: 'the clock goes on');
    expect(b.unsynced, isTrue, reason: 'edited here, nothing reached yet');
    b.markSynced();
    await b.flush();
    final c = BoardFile(dir: dir, writer: 'phone-1', keyBox: MemorySecretBox());
    await c.load();
    expect(c.unsynced, isFalse);
    expect(c.everSynced, isTrue);
  });

  test('local_edits_and_merges_are_told_apart', () async {
    final f = BoardFile(dir: null, writer: 'phone-1', keyBox: MemorySecretBox());
    await f.load();
    final seen = <BoardFileChange>[];
    final sub = f.changes.listen(seen.add);
    f.edit(RecordKinds.task, 't', {
      'content': {'title': 'x'}
    });
    final origin = Object();
    final changed = f.mergeAll([
      BoardRecord(RecordKinds.task, 'u', {'content': BoardGroup({'title': 'y'}, Hlc(5, 0, 'pc'))})
    ], origin: origin);
    expect(changed.single.id, 'u');
    expect(f.mergeAll([f.board.get(RecordKinds.task, 'u')!], origin: origin), isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect([for (final c in seen) (c.records.single.id, c.origin)], [('t', null), ('u', origin)]);
    await sub.cancel();
  });

  test('first_load_takes_the_projects_and_model_table_from_the_old_store', () async {
    SharedPreferences.setMockInitialValues({});
    final old = BoardStore();
    await old.load();
    await old.setProjects(const ProjectList()
        .withProject(const Project(id: 'p1', name: 'Perch', folders: {'m-win': r'D:\perch'}), atMs: 50));
    await old.setTable(ModelTable.starting.withRow(const ModelRow(id: 'chores', name: 'Chores', model: 'haiku'), atMs: 60));
    final f = BoardFile(dir: dir, writer: 'phone-1', keyBox: MemorySecretBox());
    await f.load(legacy: old);
    expect(f.board.projects.single.folders, {'m-win': r'D:\perch'});
    expect(modelTableOf(f.board)!.modelFor('chores'), 'haiku');
    // Once only: a second load reads the file, not the old store.
    await old.setProjects(const ProjectList());
    await f.flush();
    final again = BoardFile(dir: dir, writer: 'phone-1', keyBox: MemorySecretBox());
    await again.load(legacy: old);
    expect(again.board.projects.single.id, 'p1');
  });

  test('the_board_key_is_kept_in_secure_storage_not_in_the_file', () async {
    final box = MemorySecretBox();
    final f = BoardFile(dir: dir, writer: 'phone-1', keyBox: box);
    await f.load();
    expect(f.boardKey, isNull);
    final k = newBoardKey();
    final keyText = base64UrlNoPad(k.key);
    expect(await f.takeBoardKey(BoardKey(boardId: k.boardId, key: k.key, keyVersion: Hlc(10, 0, 'phone').encode())), isTrue);
    f.edit(RecordKinds.task, 't', {
      'content': {'title': 'x'}
    });
    await f.flush();
    final text = File('${dir.path}${Platform.pathSeparator}board.json').readAsStringSync();
    expect(text, isNot(contains(keyText)));
    expect(text, isNot(contains(k.boardId)));
    expect(box.values.values.join(), contains(keyText));
    // An older key never replaces it; a newer one does.
    final older = newBoardKey();
    expect(await f.takeBoardKey(BoardKey(boardId: older.boardId, key: older.key, keyVersion: Hlc(9, 0, 'pc').encode())), isFalse);
    final again = BoardFile(dir: dir, writer: 'phone-1', keyBox: box);
    await again.load();
    expect(again.boardKey!.boardId, k.boardId);
    expect(again.boardKey!.key, k.key);
  });
}
