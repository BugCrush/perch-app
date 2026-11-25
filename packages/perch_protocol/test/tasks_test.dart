// The task board's shared pieces: the prompt Perch sends, git remote matching, the report
// assembled from a session's events, the model table, and the wire messages.
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('prompt', () {
    test('title_then_description_then_the_report_request', () {
      final p = composeTaskPrompt(' Add a footer ', 'Use the theme colours.\nKeep it small.');
      expect(p, 'Add a footer\n\nUse the theme colours.\nKeep it small.\n\n$taskReportRequest');
      expect(composeTaskPrompt('Only a title', '  '), 'Only a title\n\n$taskReportRequest');
      expect(taskReportRequest, isNot(contains('\n')), reason: 'one line');
    });

    test('title_rules', () {
      expect(BoardTask.titleError(''), 'Enter a title');
      expect(BoardTask.titleError('x' * 101), contains('100'));
      expect(BoardTask.titleError('Fix it'), isNull);
    });
  });

  group('git remotes', () {
    test('every_spelling_of_one_remote_is_the_same', () {
      const want = 'github.com/owner/repo';
      for (final u in [
        'git@github.com:owner/repo.git',
        'git@github.com:Owner/Repo',
        'https://github.com/owner/repo.git',
        'https://github.com/owner/repo/',
        'https://user:pw@github.com/owner/repo',
        'ssh://git@github.com:22/owner/repo.git',
        'git://github.com/owner/repo',
      ]) {
        expect(normalizeGitRemote(u), want, reason: u);
      }
      expect(normalizeGitRemote('https://gitlab.com/owner/repo'), isNot(want));
      expect(normalizeGitRemote(''), '');
    });

    test('a_folder_with_the_same_remote_is_matched', () {
      final folders = [
        const GitFolder(path: '/Users/o/elsewhere', remote: 'https://github.com/o/other'),
        const GitFolder(path: '/Users/o/Desktop/work/perch', remote: 'git@github.com:O/perch.git'),
      ];
      expect(matchGitFolder('https://github.com/o/perch', folders)!.path, '/Users/o/Desktop/work/perch');
      expect(matchGitFolder('https://github.com/o/none', folders), isNull);
      expect(matchGitFolder(null, folders), isNull);
      // Two clones: the one with the same folder name wins.
      final two = [
        const GitFolder(path: '/a/copy', remote: 'https://github.com/o/perch'),
        const GitFolder(path: '/b/perch', remote: 'https://github.com/o/perch'),
      ];
      expect(matchGitFolder('https://github.com/o/perch', two, preferName: 'perch')!.path, '/b/perch');
      expect(matchGitFolder('https://github.com/o/perch', two)!.path, '/a/copy');
    });
  });

  group('report', () {
    test('report_section_is_the_last_report_heading_to_the_end', () {
      const answer = 'I looked around.\n\n## Work\nDid things.\n\n## Report\n- Changed notes.txt\n- Tested by reading it';
      expect(reportSection(answer), '## Report\n- Changed notes.txt\n- Tested by reading it');
      expect(reportSection('Done.\n\n**Report:**\nAll good.'), '**Report:**\nAll good.');
      expect(reportSection('Report:\nfine'), 'Report:\nfine');
      expect(reportSection('Done.\n\nReport: wrote a.txt'), 'Report: wrote a.txt');
      expect(reportSection('I will report back later.\nDone.'), 'I will report back later.\nDone.');
      expect(reportSection('No heading here.'), 'No heading here.');
    });

    test('todo_write_files_and_the_last_answer', () {
      var seq = 0;
      T n<T extends ConversationEvent>(T e) => e..seq = ++seq;
      final events = <ConversationEvent>[
        n(UserMessage('Create notes.txt')),
        n(ToolCall('t1', 'TodoWrite', {
          'todos': [
            {'content': 'Create notes.txt', 'status': 'in_progress', 'activeForm': 'Creating'},
            {'content': 'Check it', 'status': 'pending', 'activeForm': 'Checking'},
          ]
        })),
        n(AssistantText('Working on it.')),
        n(ToolCall('t2', 'Write', {'file_path': 'D:\\x\\notes.txt', 'content': 'hello'})),
        n(ToolCall('t3', 'Edit', {'file_path': 'D:\\x\\notes.txt', 'old_string': 'a', 'new_string': 'b'})),
        n(ToolCall('t4', 'Edit', {'file_path': 'D:\\x\\b.txt'}, parentToolUseId: 'agent')),
        n(ToolCall('t5', 'TodoWrite', {
          'todos': [
            {'content': 'Create notes.txt', 'status': 'completed'},
            {'content': 'Check it', 'status': 'pending'},
          ]
        })),
        n(AssistantText('A subagent says hi', parentToolUseId: 'agent')),
        n(AssistantText('Done.\n\n## Report\nCreated notes.txt.')),
        n(TurnEnded(isError: false, text: 'Done.')),
      ];
      final r = buildTaskReport(events, atMs: 5, changes: const [' notes.txt | 1 +']);
      expect(r.text, '## Report\nCreated notes.txt.');
      expect(r.todos, const [TodoItem('Create notes.txt', done: true), TodoItem('Check it')]);
      expect(r.files, ['D:\\x\\notes.txt', 'D:\\x\\b.txt']);
      expect(r.changes, [' notes.txt | 1 +']);
      final back = TaskReport.tryFromJson(r.toJson())!;
      expect(back.todos, r.todos);
      expect(back.files, r.files);
      expect(back.atMs, 5);
    });

    test('task_create_and_update_tick_items_by_their_id', () {
      var seq = 0;
      T n<T extends ConversationEvent>(T e) => e..seq = ++seq;
      final r = buildTaskReport([
        n(ToolCall('a', 'TaskCreate', {'subject': 'First', 'description': 'd'})),
        n(ToolResult('a', 'Task #4 created successfully: First')),
        n(ToolCall('b', 'TaskCreate', {'subject': 'Second'})),
        n(ToolResult('b', 'Task #5 created successfully: Second')),
        n(ToolCall('c', 'TaskCreate', {'subject': 'Dropped'})),
        n(ToolCall('d', 'TaskUpdate', {'taskId': '5', 'status': 'completed'})),
        n(ToolCall('e', 'TaskUpdate', {'taskId': '3', 'status': 'deleted'})),
        n(AssistantText('Finished.')),
      ], atMs: 1);
      expect(r.todos, const [TodoItem('First'), TodoItem('Second', done: true)]);
      expect(r.text, 'Finished.');
    });
  });

  group('model table', () {
    test('starting_rows_are_on_the_default_with_hints', () {
      final t = ModelTable.starting;
      expect(t.rows, hasLength(7));
      expect(t.rows.every((r) => r.model == null), isTrue);
      expect(t.row('planning')!.hint, 'Strongest model');
      expect(t.row('chores')!.hint, 'Fastest model');
      expect(t.modelFor('feature'), isNull);
      expect(t.nameOf(null), 'No type');
      expect(t.nameOf('gone'), 'Removed type');
    });

    test('a_set_model_is_used_and_survives_json', () {
      final t = ModelTable.starting.withRow(ModelTable.starting.row('chores')!.copyWith(model: 'haiku'), atMs: 9);
      expect(t.modelFor('chores'), 'haiku');
      expect(t.updatedAtMs, 9);
      final back = ModelTable.tryFromJson(t.toJson())!;
      expect(back.modelFor('chores'), 'haiku');
      expect(back.rows.map((r) => r.id), t.rows.map((r) => r.id));
      expect(t.without('chores', atMs: 10).row('chores'), isNull);
    });

    test('model_names', () {
      for (final m in ['opus', 'sonnet[1m]', 'claude-opus-4-1', 'haiku']) {
        expect(validModelName(m), isTrue, reason: m);
      }
      for (final m in ['', 'two words', 'x;rm -rf', '/model']) {
        expect(validModelName(m), isFalse, reason: m);
      }
      // A bad name in a table is dropped (the row uses the default).
      expect(ModelRow.tryFromJson({'id': 'a', 'name': 'A', 'model': 'x y'})!.model, isNull);
    });
  });

  group('wire', () {
    final task = BoardTask(
      id: 't1',
      title: 'Add footer',
      description: 'Small one',
      cwd: 'D:\\p',
      taskType: 'feature',
      priority: TaskPriority.high,
      column: TaskColumn.review,
      createdAtMs: 1,
      updatedAtMs: 2,
      sessionId: 's1',
      sessionName: 'Add footer',
      sentAtMs: 3,
      report: const TaskReport(text: 'r', todos: [TodoItem('a', done: true)], files: ['f'], atMs: 4),
      gitRemote: 'https://github.com/o/r',
    );

    test('client_messages_round_trip', () {
      final msgs = <ClientMessage>[
        const ListTasks(),
        SaveTask(task: task),
        const MoveTask(taskId: 't1', column: TaskColumn.done),
        const DeleteTask(taskId: 't1'),
        const RunTask(taskId: 't1'),
        const RunTask(taskId: 't1', sessionId: 's9'),
        const TaskNotes(taskId: 't1', notes: 'Also update the README'),
        const ListGitRemotes(),
        SyncModelTable(table: ModelTable.starting),
        const SetSessionModel(sessionId: 's1', model: 'haiku'),
        const SetSessionModel(sessionId: 's1'),
      ];
      for (final m in msgs) {
        final back = decodeClient(encodeClient(m));
        expect(back, isNotNull, reason: m.type);
        expect(back!.toJson(), m.toJson(), reason: m.type);
      }
      expect(decodeClient('{"type":"moveTask","taskId":"t1","column":"sideways"}'), isNull);
      expect(decodeClient('{"type":"runTask"}'), isNull);
    });

    test('host_messages_round_trip', () {
      final msgs = <HostMessage>[
        TasksMessage(tasks: [task]),
        const GitRemotesMessage(folders: [GitFolder(path: '/p', remote: 'git@github.com:o/r.git')]),
        ModelTableMessage(table: ModelTable.starting),
        const SessionActionDone(action: SessionActions.model, sessionId: 's1', message: 'Model: haiku'),
      ];
      for (final m in msgs) {
        final back = decodeHost(encodeHost(m));
        expect(back, isNotNull, reason: m.type);
        expect(back!.toJson(), m.toJson(), reason: m.type);
      }
    });
  });
}
