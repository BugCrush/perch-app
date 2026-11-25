import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/stream_parser.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('fixture_driver_yields_expected_sequence', () {
    final parsed = File('test/fixtures/out_driver.jsonl').readAsLinesSync().map(parseClaudeLine).toList();

    // A flat list of interesting items, in order.
    final items = <Object>[];
    for (final p in parsed) {
      switch (p) {
        case ParsedEvents(:final events):
          items.addAll(events);
        case ParsedPrompt(:final prompt):
          items.add(prompt);
        default:
          break;
      }
    }

    int indexWhere(bool Function(Object) f, [int start = 0]) {
      for (var i = start; i < items.length; i++) {
        if (f(items[i])) return i;
      }
      return -1;
    }

    final q = indexWhere((o) => o is PromptRequest && o.kind == PromptKind.question);
    expect(q, greaterThanOrEqualTo(0));
    final question = items[q] as PromptRequest;
    expect(question.toolName, 'AskUserQuestion');
    expect((question.input['questions'] as List).length, 2);

    final agent = indexWhere((o) => o is ToolCall && o.name == 'Agent', q);
    expect(agent, greaterThan(q));
    final started = indexWhere((o) => o is SubagentStarted && o.subagentType == 'general-purpose', agent);
    expect(started, greaterThan(agent));
    final perm = indexWhere((o) => o is PromptRequest && o.kind == PromptKind.permission, started);
    expect(perm, greaterThan(started));
    final permission = items[perm] as PromptRequest;
    expect(permission.toolName, 'PowerShell');
    expect(permission.parentToolUseId, isNotNull);
    expect(permission.suggestions, isNotEmpty);

    expect(items.whereType<SubagentFinished>().length, 1);
    final turns = items.whereType<TurnEnded>().toList();
    expect(turns.length, 2);
    expect(turns.every((t) => !t.isError), isTrue);

    expect(parsed.whereType<ParsedInit>().first.claudeSessionId, 'e991a194-6875-4c7d-aa85-5499898f6fd1');
    // Subagent messages carry their parent.
    expect(items.whereType<UserMessage>().single.parentToolUseId, 'toolu_01E5q34rShPwXhHyhHFJQBmK');
  });

  test('usage_event_is_parsed', () {
    final line = jsonEncode({
      'type': 'rate_limit_event',
      'rate_limit_info': {
        'status': 'allowed',
        'unifiedWindows': {
          'five_hour': {'utilization': 0.87, 'resetsAt': 1794424800, 'status': 'allowed'},
          'seven_day': {'utilization': 0.1, 'resetsAt': 1794906000, 'status': 'allowed'},
        },
      },
    });
    final p = parseClaudeLine(line);
    expect(p, isA<ParsedUsage>());
    final u = (p as ParsedUsage).usage;
    expect(u.fiveHour!.utilization, 0.87);
    expect(u.fiveHour!.resetsAt, 1794424800);
    expect(u.sevenDay!.utilization, 0.1);
  });

  test('unknown_and_malformed_lines_are_skipped', () {
    for (final l in ['{"type":"brand_new"}', '{', '', '{"type":"assistant"}', '[1]', '{"type":"user","message":5}']) {
      expect(parseClaudeLine(l), isA<ParsedSkip>(), reason: l);
    }
  });

  test('long_tool_result_is_truncated', () {
    final line = jsonEncode({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': 't1', 'content': 'x' * 30000}
        ]
      },
      'parent_tool_use_id': null,
    });
    final p = parseClaudeLine(line) as ParsedEvents;
    final r = p.events.single as ToolResult;
    expect(r.text.length, 20000);
    expect(r.truncated, isTrue);
  });

  test('exit_plan_mode_is_a_plan_prompt', () {
    final line = jsonEncode({
      'type': 'control_request',
      'request_id': 'r9',
      'request': {
        'subtype': 'can_use_tool',
        'tool_name': 'ExitPlanMode',
        'input': {'plan': '# Plan\n1. do it'},
        'tool_use_id': 'toolu_x',
      },
    });
    final p = parseClaudeLine(line) as ParsedPrompt;
    expect(p.prompt.kind, PromptKind.plan);
    expect(p.prompt.promptId, 'r9');
    expect(p.prompt.suggestions, isEmpty);
  });
}
