// The board's bin (Task 21): deleted projects and tasks newest first; Restore brings one back
// everywhere (a project with the tasks deleted with it); Delete for good hides it but keeps
// the tombstone; an edit from an offline device to a deleted task keeps it in the bin, with
// the new text.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/account_store.dart';
import 'package:perch_app/src/connection/board_file.dart';
import 'package:perch_app/src/connection/board_store.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/ui/board_bin.dart';
import 'package:perch_app/src/ui/board_screen.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'fakes.dart';
import 'glass_harness.dart';

void main() {
  late BoardStore store;
  late BoardFile file;
  late FakeChannels channels;
  final conns = <HostConnection>[];

  setUp(() async {
    channels = FakeChannels();
    file = BoardFile(dir: null, writer: 'phone', keyBox: MemorySecretBox());
    await file.load();
    store = BoardStore(persist: false)..attach(file);
    await store.setProjects(const ProjectList()
        .withProject(const Project(id: 'p1', name: 'Perch'), atMs: 1)
        .withProject(const Project(id: 'p2', name: 'Garden'), atMs: 1));
    void put(String id, String title, String project) => file.edit(RecordKinds.task, id, {
          'content': taskContent(BoardTask(id: id, title: title, cwd: '', projectId: project)),
          'column': {'column': 'backlog'},
        });
    put('t1', 'First gone', 'p1');
    put('t2', 'Second gone', 'p1');
    put('t3', 'Still here', 'p1');
    put('g1', 'Dig', 'p2');
  });
  tearDown(() {
    for (final c in conns) {
      c.dispose();
    }
    conns.clear();
  });

  void delete(String id) => file.edit(RecordKinds.task, id, {
        'life': {'deleted': true, 'deletedAtMs': DateTime.now().millisecondsSinceEpoch}
      });

  Future<void> openTheBin(WidgetTester tester, {List<HostConnection> conns = const []}) async {
    tallPhone(tester, height: 2400);
    await tester.pumpWidget(glassApp(BoardView(connections: conns, store: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('board-bin')));
    await tester.pumpAndSettle();
    expect(find.text(binTitle), findsWidgets);
  }

  testWidgets('the_bin_lists_deleted_items_newest_first', (tester) async {
    delete('t1');
    delete('t2');
    await openTheBin(tester);
    expect(find.byKey(const ValueKey('bin-t3')), findsNothing);
    expect(tester.getTopLeft(find.byKey(const ValueKey('bin-t2'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('bin-t1'))).dy), reason: 'newest first');
    expect(find.textContaining('Task in Perch · deleted just now'), findsNWidgets(2));
  });

  testWidgets('restore_brings_it_back_everywhere', (tester) async {
    final c = HostConnection(testMachine(id: 'm1', label: 'Desk'), channelFactory: channels.factory, boardFile: file);
    conns.add(c);
    c.connect();
    final host = channels.last;
    host.send(boardWelcome);
    host.send(const BoardSummaryFromHost(summary: {}));
    await tester.runAsync(() => eventually(() => c.link.value == LinkState.online));
    delete('t1');
    await openTheBin(tester, conns: [c]);
    await tester.tap(find.byKey(const ValueKey('bin-restore-t1')));
    await tester.pumpAndSettle();
    expect(file.board.get(RecordKinds.task, 't1')!.deleted, isFalse);
    expect(find.byKey(const ValueKey('bin-t1')), findsNothing);
    await tester.runAsync(() => eventually(() => host.messages
        .whereType<BoardRecordsFromApp>()
        .any((m) => m.records.any((r) => r.id == 't1' && r.groups['life']?.value['deleted'] == false))));
  });

  testWidgets('deleting_a_project_bins_its_tasks_and_restoring_it_restores_them', (tester) async {
    delete('t1'); // deleted on its own earlier: not brought back with the project
    store.deleteProject('p1');
    expect(file.board.get(RecordKinds.task, 't2')!.deleted, isTrue);
    expect(file.board.get(RecordKinds.task, 't3')!.life!['deletedWith'], 'p1');
    expect(file.board.get(RecordKinds.task, 'g1')!.deleted, isFalse);
    await openTheBin(tester);
    expect(find.byKey(const ValueKey('bin-p1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bin-restore-p1')));
    await tester.pumpAndSettle();
    expect(file.board.get(RecordKinds.project, 'p1')!.deleted, isFalse);
    expect(file.board.get(RecordKinds.task, 't2')!.deleted, isFalse);
    expect(file.board.get(RecordKinds.task, 't3')!.deleted, isFalse);
    expect(file.board.get(RecordKinds.task, 't1')!.deleted, isTrue, reason: 'it was deleted on its own');
  });

  testWidgets('delete_for_good_hides_it_but_keeps_the_tombstone', (tester) async {
    delete('t1');
    final at = file.board.get(RecordKinds.task, 't1')!.deletedAtMs;
    await openTheBin(tester);
    await tester.tap(find.byKey(const ValueKey('bin-purge-t1')));
    await tester.pumpAndSettle();
    final r = file.board.get(RecordKinds.task, 't1')!;
    expect(r.deleted, isTrue);
    expect(r.purged, isTrue);
    expect(r.deletedAtMs, at, reason: 'still dropped 180 days after it was deleted');
    expect(find.byKey(const ValueKey('bin-t1')), findsNothing);
    expect(find.byKey(const ValueKey('bin-empty')), findsOneWidget);
    // An old copy that still has the task alive does not bring it back.
    final stale = BoardRecord(RecordKinds.task, 't1', {
      'life': BoardGroup({'deleted': false}, Hlc(1, 0, 'old_device'))
    });
    file.mergeAll([stale], origin: 'old');
    expect(file.board.get(RecordKinds.task, 't1')!.purged, isTrue);
  });

  testWidgets('an_edit_from_an_offline_device_to_a_deleted_task_keeps_it_in_the_bin_with_the_new_text', (tester) async {
    delete('t1');
    final content = file.board.get(RecordKinds.task, 't1')!.groups['content']!;
    // The Mac edited the title while offline, after the phone deleted the task.
    file.mergeAll([
      BoardRecord(RecordKinds.task, 't1', {
        'content': BoardGroup({...content.value, 'title': 'Renamed on the Mac'}, Hlc(content.version.ms + 3600000, 0, 'mac'))
      })
    ], origin: 'mac');
    await openTheBin(tester);
    expect(find.text('Renamed on the Mac'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bin-restore-t1')));
    await tester.pumpAndSettle();
    expect(taskOf(file.board.get(RecordKinds.task, 't1')!)!.title, 'Renamed on the Mac');
    expect(file.board.liveTasks.any((t) => t.title == 'Renamed on the Mac'), isTrue);
    expect(find.byIcon(Icons.restore_rounded), findsNothing);
  });
}
