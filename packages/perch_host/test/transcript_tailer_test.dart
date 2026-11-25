import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/transcript.dart';
import 'package:perch_host/src/transcript_tailer.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

String userLine(String text) => jsonEncode({
      'type': 'user',
      'message': {'role': 'user', 'content': text},
    });

String assistantLine(String text) => jsonEncode({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': text}
        ]
      },
    });

void main() {
  late Directory tmp;
  late File file;
  TranscriptTailer? tailer;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_tail_');
    file = File('${tmp.path}${Platform.pathSeparator}abc.jsonl');
  });
  tearDown(() async {
    await tailer?.close();
    tailer = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  List<String> texts(List<TranscriptLine> got) => [
        for (final l in got)
          if (l is TranscriptEvents)
            for (final e in l.events)
              if (e is UserMessage) e.text else if (e is AssistantText) e.text
      ];

  const fast = Duration(milliseconds: 20);

  test('emits_existing_then_appended_lines', () async {
    file.writeAsStringSync('${userLine('one')}\n${assistantLine('two')}\n');
    tailer = TranscriptTailer(file, poll: fast);
    final got = <TranscriptLine>[];
    tailer!.lines.listen(got.add);
    await waitUntil(() => texts(got).length == 2);
    file.writeAsStringSync('${userLine('three')}\n', mode: FileMode.append);
    await waitUntil(() => texts(got).length == 3);
    expect(texts(got), ['one', 'two', 'three']);
  });

  test('partial_line_waits_for_newline', () async {
    file.writeAsStringSync('');
    tailer = TranscriptTailer(file, poll: fast);
    final got = <TranscriptLine>[];
    tailer!.lines.listen(got.add);
    final line = userLine('héllo wörld');
    final bytes = utf8.encode(line);
    final half = bytes.length ~/ 2 + 1; // may split a multi-byte character
    file.writeAsBytesSync(bytes.sublist(0, half), mode: FileMode.append);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(got, isEmpty);
    file.writeAsBytesSync([...bytes.sublist(half), 10], mode: FileMode.append);
    await waitUntil(() => got.isNotEmpty);
    expect(texts(got), ['héllo wörld']);
  });

  test('new_subagent_file_emits_started_and_tagged_events', () async {
    file.writeAsStringSync('${userLine('main')}\n');
    tailer = TranscriptTailer(file, poll: fast);
    final got = <TranscriptLine>[];
    tailer!.lines.listen(got.add);
    await waitUntil(() => texts(got).length == 1);
    final sub = Directory('${tmp.path}${Platform.pathSeparator}abc${Platform.pathSeparator}subagents')
      ..createSync(recursive: true);
    File('${sub.path}${Platform.pathSeparator}agent-x1.meta.json').writeAsStringSync(
        jsonEncode({'agentType': 'general-purpose', 'description': 'Count files', 'toolUseId': 'toolu_P'}));
    File('${sub.path}${Platform.pathSeparator}agent-x1.jsonl').writeAsStringSync('${userLine('sub task')}\n');
    await waitUntil(() => texts(got).length == 2);
    final events = [for (final l in got) if (l is TranscriptEvents) ...l.events];
    final started = events.whereType<SubagentStarted>().single;
    expect(started.taskId, 'x1');
    expect(started.toolUseId, 'toolu_P');
    expect(started.description, 'Count files');
    expect(started.subagentType, 'general-purpose');
    final subMsg = events.whereType<UserMessage>().last;
    expect(subMsg.text, 'sub task');
    expect(subMsg.parentToolUseId, 'toolu_P');
    expect(events.indexOf(started), lessThan(events.indexOf(subMsg)));

    // Without a meta file the defaults apply.
    File('${sub.path}${Platform.pathSeparator}agent-y2.jsonl').writeAsStringSync('${userLine('other')}\n');
    await waitUntil(() => texts(got).length == 3);
    final s2 = [for (final l in got) if (l is TranscriptEvents) ...l.events].whereType<SubagentStarted>().last;
    expect(s2.toolUseId, 'agent:y2');
    expect(s2.description, 'Subagent');
    expect(s2.subagentType, 'agent');
  });

  test('survives_file_not_yet_created', () async {
    tailer = TranscriptTailer(file, poll: fast);
    final got = <TranscriptLine>[];
    tailer!.lines.listen(got.add);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(got, isEmpty);
    file.writeAsStringSync('${userLine('late')}\n');
    await waitUntil(() => texts(got).length == 1);
  });

  test('remembers_last_permission_mode_and_titles', () async {
    file.writeAsStringSync('{"type":"permission-mode","permissionMode":"plan"}\n'
        '{"type":"ai-title","aiTitle":"T"}\n{"type":"permission-mode","permissionMode":"auto"}\n');
    tailer = TranscriptTailer(file, poll: fast);
    final got = <TranscriptLine>[];
    tailer!.lines.listen(got.add);
    await waitUntil(() => got.whereType<TranscriptPermissionMode>().length == 2);
    expect(tailer!.lastPermissionMode, 'auto');
    expect(got.whereType<TranscriptTitle>().single.title, 'T');
  });

  group('chronological backlog', () {
    final sep = Platform.pathSeparator;
    String at(int s) => DateTime.utc(2026, 11, 12, 10, 0, s).toIso8601String();
    int ms(int s) => DateTime.utc(2026, 11, 12, 10, 0, s).millisecondsSinceEpoch;
    String user(String text, int s) => jsonEncode({
          'type': 'user',
          'timestamp': at(s),
          'message': {'role': 'user', 'content': text},
        });
    String assistant(String text, int s) => jsonEncode({
          'type': 'assistant',
          'timestamp': at(s),
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': text}
            ]
          },
        });
    String agentCall(String id, int s) => jsonEncode({
          'type': 'assistant',
          'timestamp': at(s),
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'tool_use', 'id': id, 'name': 'Agent', 'input': {'description': 'Task $id'}}
            ]
          },
        });
    String result(String id, int s) => jsonEncode({
          'type': 'user',
          'timestamp': at(s),
          'message': {
            'role': 'user',
            'content': [
              {'type': 'tool_result', 'tool_use_id': id, 'content': 'done $id'}
            ]
          },
        });

    void subagent(String agentId, String toolUseId, List<String> lines) {
      final dir = Directory('${tmp.path}${sep}abc${sep}subagents')..createSync(recursive: true);
      File('${dir.path}${sep}agent-$agentId.meta.json')
          .writeAsStringSync(jsonEncode({'agentType': 'general-purpose', 'description': 'D $agentId', 'toolUseId': toolUseId}));
      File('${dir.path}${sep}agent-$agentId.jsonl').writeAsStringSync('${lines.join('\n')}\n');
    }

    /// Runs the tailer's first read and returns every event it emitted, numbered in order.
    List<ConversationEvent> backlog() {
      tailer = TranscriptTailer(file, poll: const Duration(hours: 1));
      final got = <ConversationEvent>[];
      tailer!.lines.listen((l) {
        if (l is TranscriptEvents) got.addAll(l.events);
      });
      tailer!.pollNow();
      return got;
    }

    String label(ConversationEvent e) => switch (e) {
          UserMessage(:final text) => text,
          AssistantText(:final text) => text,
          ToolCall(:final toolUseId) => 'call $toolUseId',
          ToolResult(:final toolUseId) => 'result $toolUseId',
          SubagentStarted(:final taskId) => 'started $taskId',
          SubagentFinished(:final taskId) => 'finished $taskId',
          _ => '$e',
        };

    test('backlog_is_merged_by_timestamp_across_main_and_subagent_files', () {
      file.writeAsStringSync([
        user('start', 0),
        agentCall('toolu_A', 1),
        agentCall('toolu_B', 3),
        result('toolu_A', 10),
        result('toolu_B', 20),
        user('latest', 30),
        '',
      ].join('\n'));
      // Sorted by name, b9 would come before z1 if files were simply concatenated.
      subagent('z1', 'toolu_A', [user('A task', 2), assistant('A done', 7)]);
      subagent('b9', 'toolu_B', [user('B task', 4), assistant('B mid', 6), assistant('B done', 8)]);
      final events = backlog();
      expect(events.map(label).toList(), [
        'start',
        'call toolu_A',
        'started z1',
        'A task',
        'call toolu_B',
        'started b9',
        'B task',
        'B mid',
        'A done',
        'B done',
        'result toolu_A',
        'result toolu_B',
        'latest',
      ]);
      expect(events.last, isA<UserMessage>());
      expect((events.last as UserMessage).text, 'latest');
      expect(events.last.atMs, ms(30));
      for (var i = 1; i < events.length; i++) {
        expect(events[i].atMs, greaterThanOrEqualTo(events[i - 1].atMs), reason: label(events[i]));
      }
    });

    test('subagent_header_sits_where_it_started', () {
      file.writeAsStringSync([user('start', 0), agentCall('toolu_A', 5), user('after', 9), ''].join('\n'));
      // The subagent's first line is written a little after the Agent call.
      subagent('a1', 'toolu_A', [user('sub first', 6), assistant('sub last', 8)]);
      final events = backlog();
      final labels = events.map(label).toList();
      expect(labels, ['start', 'call toolu_A', 'started a1', 'sub first', 'sub last', 'after']);
      final started = events.whereType<SubagentStarted>().single;
      expect(started.atMs, ms(5)); // the Agent call's time, which is earlier than its file's first line
      expect(started.toolUseId, 'toolu_A');

      // Without a known parent call, the header takes the file's first line time.
      tailer?.close();
      file.writeAsStringSync([user('start', 0), user('after', 9), ''].join('\n'));
      final dir = Directory('${tmp.path}${sep}abc${sep}subagents');
      dir.deleteSync(recursive: true);
      subagent('a2', 'toolu_X', [user('orphan', 4)]);
      final again = backlog();
      expect(again.map(label).toList(), ['start', 'started a2', 'orphan', 'after']);
      expect(again.whereType<SubagentStarted>().single.atMs, ms(4));
    });

    test('missing_timestamp_falls_back_to_previous_time', () {
      file.writeAsStringSync([user('one', 3), userLine('two'), assistant('three', 7), ''].join('\n'));
      final events = backlog();
      expect(events.map(label).toList(), ['one', 'two', 'three']);
      expect(events.map((e) => e.atMs).toList(), [ms(3), ms(3), ms(7)]);
    });

    test('later_subagent_file_is_appended_not_reordered', () async {
      file.writeAsStringSync([user('start', 0), agentCall('toolu_A', 1), user('now', 20), ''].join('\n'));
      final events = backlog();
      expect(events.map(label).last, 'now');
      subagent('late', 'toolu_A', [user('old sub line', 2)]);
      tailer!.pollNow();
      expect(events.map(label).skip(3).toList(), ['started late', 'old sub line']);
    });
  });

  test('from_end_skips_existing_content', () async {
    file.writeAsStringSync('${userLine('old')}\n');
    tailer = TranscriptTailer(file, poll: fast, fromEnd: true);
    final got = <TranscriptLine>[];
    tailer!.lines.listen(got.add);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    file.writeAsStringSync('${userLine('new')}\n', mode: FileMode.append);
    await waitUntil(() => texts(got).isNotEmpty);
    expect(texts(got), ['new']);
  });
}
