// Turns one line of `claude -p --output-format stream-json` output into a ParsedLine.
import 'dart:convert';

import 'package:perch_protocol/perch_protocol.dart';

sealed class ParsedLine {
  const ParsedLine();
}

/// seq / atMs are left 0; the session manager stamps them.
class ParsedEvents extends ParsedLine {
  final List<ConversationEvent> events;
  const ParsedEvents(this.events);
}

class ParsedPrompt extends ParsedLine {
  final PromptRequest prompt;
  const ParsedPrompt(this.prompt);
}

class ParsedUsage extends ParsedLine {
  final UsageSnapshot usage;

  /// The event's own verdict (`allowed`, `allowed_warning`, `rejected`), the window it is
  /// about (`five_hour`, `seven_day`, …) and when that resets (Unix seconds, 0: unknown).
  final String status;
  final String? limitType;
  final int resetsAt;
  const ParsedUsage(this.usage, {this.status = '', this.limitType, this.resetsAt = 0});
}

class ParsedInit extends ParsedLine {
  final String claudeSessionId;
  final String model;
  final String claudeVersion;
  const ParsedInit({required this.claudeSessionId, required this.model, required this.claudeVersion});
}

class ParsedSkip extends ParsedLine {
  const ParsedSkip();
}

/// A line of a known kind without the fields Perch needs: a sign the format changed.
class ParsedMalformed extends ParsedLine {
  final String reason;
  const ParsedMalformed(this.reason);
}

const int maxToolResultChars = 20000;

/// Prefix used as a parent id when Claude only names the subagent by its agent id
/// (permission requests from inside a subagent carry `agent_id`, not `parent_tool_use_id`).
/// ClaudeSession resolves it to the subagent's tool_use_id once it has seen `task_started`.
const String agentParentPrefix = 'agent:';

Map<String, dynamic>? decodeJsonObject(String line) {
  if (line.trim().isEmpty) return null;
  try {
    final v = jsonDecode(line);
    return v is Map ? v.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

ParsedLine parseClaudeLine(String line) {
  final j = decodeJsonObject(line);
  if (j == null) return const ParsedSkip();
  try {
    return _parse(j);
  } catch (_) {
    // Unknown shapes are never fatal.
    return const ParsedSkip();
  }
}

ParsedLine _parse(Map<String, dynamic> j) {
  final parent = j['parent_tool_use_id'] is String ? j['parent_tool_use_id'] as String : null;
  switch (j['type']) {
    case 'system':
      switch (j['subtype']) {
        case 'init':
          return ParsedInit(
            claudeSessionId: '${j['session_id'] ?? ''}',
            model: '${j['model'] ?? ''}',
            claudeVersion: '${j['claude_code_version'] ?? ''}',
          );
        case 'task_started':
          final taskType = j['task_type'];
          // Background shell commands also report as tasks; only agent tasks are subagents.
          if (taskType != null && taskType != 'local_agent') return const ParsedSkip();
          return ParsedEvents([
            SubagentStarted(
              '${j['task_id'] ?? ''}',
              '${j['tool_use_id'] ?? ''}',
              '${j['description'] ?? ''}',
              '${j['subagent_type'] ?? 'agent'}',
              parentToolUseId: parent,
            ),
          ]);
        case 'task_notification':
          return ParsedEvents([
            SubagentFinished('${j['task_id'] ?? ''}', '${j['status'] ?? ''}', parentToolUseId: parent),
          ]);
      }
      return const ParsedSkip();
    case 'assistant':
    case 'user':
      final message = j['message'];
      if (message is! Map) return const ParsedSkip();
      final events = contentToEvents(j['type'] as String, message['content'], parent,
          includeTopLevelUserText: false);
      return events.isEmpty ? const ParsedSkip() : ParsedEvents(events);
    case 'result':
      final isError = j['is_error'] == true;
      var text = j['result'] is String ? j['result'] as String : '';
      if (text.isEmpty && j['errors'] is List) text = (j['errors'] as List).join('\n');
      if (text.isEmpty && isError) text = '${j['subtype'] ?? 'error'}';
      return ParsedEvents([TurnEnded(isError: isError, text: text)]);
    case 'rate_limit_event':
      final info = j['rate_limit_info'];
      if (info is! Map) return const ParsedSkip();
      final windows = info['unifiedWindows'];
      if (windows is! Map) return const ParsedSkip();
      final r = info['resetsAt'];
      return ParsedUsage(
        UsageSnapshot(fiveHour: _window(windows['five_hour']), sevenDay: _window(windows['seven_day'])),
        status: '${info['status'] ?? ''}',
        limitType: info['rateLimitType'] is String ? info['rateLimitType'] as String : null,
        resetsAt: r is num ? r.toInt() : 0,
      );
    case 'control_request':
      final req = j['request'];
      if (req is! Map || req['subtype'] != 'can_use_tool') return const ParsedSkip();
      final rid = j['request_id'];
      if (rid is! String || rid.isEmpty || req['tool_name'] is! String || (req['tool_name'] as String).isEmpty) {
        return const ParsedMalformed('a permission request without request_id or tool_name');
      }
      final tool = '${req['tool_name'] ?? ''}';
      final agentId = req['agent_id'];
      final reqParent = req['parent_tool_use_id'] is String
          ? req['parent_tool_use_id'] as String
          : parent ?? (agentId is String && agentId.isNotEmpty ? '$agentParentPrefix$agentId' : null);
      return ParsedPrompt(PromptRequest(
        promptId: '${j['request_id'] ?? ''}',
        kind: PromptRequest.kindForTool(tool),
        toolName: tool,
        input: req['input'] is Map ? (req['input'] as Map).cast<String, dynamic>() : <String, dynamic>{},
        suggestions: req['permission_suggestions'] is List ? List<dynamic>.from(req['permission_suggestions']) : [],
        parentToolUseId: reqParent,
      ));
  }
  return const ParsedSkip();
}

UsageWindow? _window(Object? w) {
  if (w is! Map) return null;
  final u = w['utilization'];
  final r = w['resetsAt'];
  return UsageWindow(
    utilization: u is num ? u.toDouble() : 0,
    resetsAt: r is num ? r.toInt() : 0,
    status: '${w['status'] ?? ''}',
  );
}

/// Maps a message's `content` (string or list of blocks) to events. Shared by the
/// stream parser and the transcript reader.
///
/// A plain user text (string content or `text` block) becomes a [UserMessage] only
/// when it comes from a subagent ([parent] set) or [includeTopLevelUserText] is true:
/// in structured mode the host records the user's own messages itself.
List<ConversationEvent> contentToEvents(String type, Object? content, String? parent,
    {bool includeTopLevelUserText = false}) {
  final out = <ConversationEvent>[];
  final userTextAllowed = parent != null || includeTopLevelUserText;
  if (content is String) {
    if (type == 'assistant') {
      if (content.isNotEmpty) out.add(AssistantText(content, parentToolUseId: parent));
    } else if (userTextAllowed) {
      out.add(UserMessage(content, parentToolUseId: parent));
    }
    return out;
  }
  if (content is! List) return out;
  for (final block in content) {
    if (block is! Map) continue;
    switch (block['type']) {
      case 'text':
        final text = block['text'] is String ? block['text'] as String : '';
        if (type == 'assistant') {
          if (text.isNotEmpty) out.add(AssistantText(text, parentToolUseId: parent));
        } else if (userTextAllowed) {
          out.add(UserMessage(text, parentToolUseId: parent));
        }
      case 'tool_use':
        if (type != 'assistant') break;
        out.add(ToolCall(
          '${block['id'] ?? ''}',
          '${block['name'] ?? ''}',
          block['input'] is Map ? (block['input'] as Map).cast<String, dynamic>() : <String, dynamic>{},
          parentToolUseId: parent,
        ));
      case 'tool_result':
        var text = flattenToolResult(block['content']);
        var truncated = false;
        if (text.length > maxToolResultChars) {
          text = text.substring(0, maxToolResultChars);
          truncated = true;
        }
        out.add(ToolResult('${block['tool_use_id'] ?? ''}', text,
            isError: block['is_error'] == true, truncated: truncated, parentToolUseId: parent));
      default:
        // thinking, images, and anything new: nothing.
        break;
    }
  }
  return out;
}

String flattenToolResult(Object? content) {
  if (content == null) return '';
  if (content is String) return content;
  if (content is List) {
    final parts = <String>[];
    for (final b in content) {
      if (b is Map && b['type'] == 'text') {
        parts.add('${b['text'] ?? ''}');
      } else if (b is Map && b['type'] != null) {
        parts.add('[${b['type']}]');
      } else if (b is String) {
        parts.add(b);
      }
    }
    return parts.join('\n');
  }
  return '$content';
}
