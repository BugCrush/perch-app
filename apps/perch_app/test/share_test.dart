// Share a task or a project as JSON (Task 20): copied to the clipboard ("Copied") and offered
// through the share panel; a project's JSON holds every task, Done included; the board
// page in a browser only copies.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/account_store.dart';
import 'package:perch_app/src/connection/board_file.dart';
import 'package:perch_app/src/connection/board_store.dart';
import 'package:perch_app/src/ui/board_screen.dart';
import 'package:perch_app/src/ui/share.dart';
import 'package:perch_app/src/ui/task_detail.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'glass_harness.dart';

void main() {
  late BoardStore store;
  late String? clipboard;
  final shared = <(String, String?)>[];

  setUp(() async {
    final file = BoardFile(dir: null, writer: 'phone', keyBox: MemorySecretBox());
    await file.load();
    store = BoardStore(persist: false)..attach(file);
    await store.setProjects(const ProjectList().withProject(
        const Project(id: 'p1', name: 'Perch', description: 'Phone control', gitRemote: 'github.com/o/perch'),
        atMs: 1));
    void put(String id, String title, String column) => file.edit(RecordKinds.task, id, {
          'content': taskContent(BoardTask(id: id, title: title, description: 'About $title', cwd: '', projectId: 'p1')),
          'column': {'column': column},
        });
    put('t1', 'Fix login', 'review');
    put('t2', 'Old work', 'done');
    put('t3', 'Idea', 'backlog');
    clipboard = null;
    shared.clear();
    shareText = (text, {subject}) async => shared.add((text, subject));
    shareCopiesOnly = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('share_task_copies_the_json_and_opens_the_panel', (tester) async {
    tallPhone(tester);
    await tester.pumpWidget(glassApp(TaskDetailScreen(taskId: 't1', all: const [], store: store)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('detail-share')));
    await tester.tap(find.byKey(const ValueKey('detail-share')));
    await tester.pumpAndSettle();
    final j = jsonDecode(clipboard!) as Map;
    expect(j['perch'], 'task');
    expect((j['task'] as Map)['title'], 'Fix login');
    expect((j['task'] as Map)['column'], 'review');
    expect((j['task'] as Map)['machine'], isNull);
    expect((j['project'] as Map)['name'], 'Perch');
    expect(clipboard, startsWith('{\n  "perch": "task"'));
    expect(shared.single.$1, clipboard);
    expect(shared.single.$2, 'Fix login');
    expect(find.text('Copied'), findsOneWidget);
  });

  testWidgets('share_project_contains_every_task', (tester) async {
    tallPhone(tester, height: 2400);
    await store.setProjectFilter('p1');
    await tester.pumpWidget(glassApp(BoardView(connections: const [], store: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project-share')));
    await tester.pumpAndSettle();
    final j = jsonDecode(clipboard!) as Map;
    expect(j['perch'], 'project');
    expect((j['project'] as Map)['description'], 'Phone control');
    expect([for (final t in j['tasks'] as List) (t as Map)['title']], ['Idea', 'Fix login', 'Old work'], reason: 'Done included');
    expect(shared.single.$2, 'Perch');
  });

  testWidgets('on_the_web_it_only_copies', (tester) async {
    shareCopiesOnly = true;
    tallPhone(tester);
    await tester.pumpWidget(glassApp(TaskDetailScreen(taskId: 't1', all: const [], store: store)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('detail-share')));
    await tester.tap(find.byKey(const ValueKey('detail-share')));
    await tester.pumpAndSettle();
    expect(clipboard, contains('"Fix login"'));
    expect(shared, isEmpty);
  });
}
