import 'dart:convert';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

String _j(Object? o) => jsonEncode(o);

void main() {
  final events = <ConversationEvent>[
    UserMessage('hi', seq: 1, atMs: 10),
    AssistantText('hello **there**', seq: 2, atMs: 11, parentToolUseId: 'toolu_1'),
    ToolCall('toolu_2', 'PowerShell', {'command': 'ls', 'n': 3}, seq: 3, atMs: 12),
    ToolResult('toolu_2', 'out', isError: true, truncated: true, seq: 4, atMs: 13),
    SubagentStarted('task1', 'toolu_3', 'Count files', 'general-purpose', seq: 5, atMs: 14),
    SubagentFinished('task1', 'completed', seq: 6, atMs: 15),
    TurnEnded(isError: false, text: 'done', seq: 7, atMs: 16),
    Notice('Continued on phone.', seq: 8, atMs: 17),
  ];

  test('every ConversationEvent subtype round-trips', () {
    for (final e in events) {
      final back = ConversationEvent.fromJson(jsonDecode(_j(e.toJson())) as Map<String, dynamic>);
      expect(back.runtimeType, e.runtimeType);
      expect(_j(back.toJson()), _j(e.toJson()));
    }
  });

  test('event json carries kind in lowerCamelCase', () {
    expect(events.map((e) => e.toJson()['kind']).toList(), [
      'userMessage',
      'assistantText',
      'toolCall',
      'toolResult',
      'subagentStarted',
      'subagentFinished',
      'turnEnded',
      'notice',
    ]);
  });

  test('PromptRequest round-trips', () {
    final p = PromptRequest(
      promptId: 'r1',
      kind: PromptKind.permission,
      toolName: 'PowerShell',
      input: {'command': 'ls'},
      suggestions: [
        {'type': 'addRules', 'behavior': 'allow'}
      ],
      parentToolUseId: 'toolu_9',
    );
    final back = PromptRequest.fromJson(jsonDecode(_j(p.toJson())) as Map<String, dynamic>);
    expect(_j(back.toJson()), _j(p.toJson()));
    expect(back.kind, PromptKind.permission);
  });

  test('each PromptAnswer round-trips', () {
    final answers = <PromptAnswer>[
      QuestionAnswer({'Which color?': 'Blue', 'Which size?': 'Large'}),
      PermissionAnswer(allow: true, always: true, message: null),
      PermissionAnswer(allow: false, always: false, message: 'no'),
      PlanAnswer(approve: false, feedback: 'more tests'),
    ];
    for (final a in answers) {
      final back = PromptAnswer.fromJson(jsonDecode(_j(a.toJson())) as Map<String, dynamic>);
      expect(back.runtimeType, a.runtimeType);
      expect(_j(back.toJson()), _j(a.toJson()));
    }
  });

  test('the last message time is optional and round-trips', () {
    const s = SessionSummary(
        id: 'a', name: 'n', cwd: '/w', origin: SessionOrigin.external, state: SessionState.idle, startedAtMs: 1,
        lastPromptAtMs: 1794680859171);
    expect(SessionSummary.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>).lastPromptAtMs,
        1794680859171);
    const none = SessionSummary(
        id: 'a', name: 'n', cwd: '/w', origin: SessionOrigin.external, state: SessionState.idle, startedAtMs: 1);
    expect(none.toJson().containsKey('lastPromptAtMs'), isFalse, reason: 'older apps see nothing new');
    expect(SessionSummary.fromJson(none.toJson()).lastPromptAtMs, isNull, reason: 'older hosts: unknown');
    expect(SessionSummary.fromJson({...none.toJson(), 'lastPromptAtMs': 'x'}).lastPromptAtMs, isNull);
    expect(none.copyWith(lastPromptAtMs: 5).lastPromptAtMs, 5);
  });

  test('SessionSummary and UsageSnapshot round-trip', () {
    final s = SessionSummary(
      id: 's1',
      name: 'n',
      cwd: 'D:\\x',
      origin: SessionOrigin.external,
      state: SessionState.waitingPermission,
      model: 'haiku',
      startedAtMs: 5,
      reason: 'r',
      openPrompts: 2,
    );
    expect(_j(SessionSummary.fromJson(jsonDecode(_j(s.toJson()))).toJson()), _j(s.toJson()));
    final u = UsageSnapshot(
      fiveHour: UsageWindow(utilization: 0.87, resetsAt: 1794424800, status: 'allowed'),
      sevenDay: UsageWindow(utilization: 0.1, resetsAt: 1794906000, status: 'allowed'),
    );
    expect(_j(UsageSnapshot.fromJson(jsonDecode(_j(u.toJson()))).toJson()), _j(u.toJson()));
  });

  test('fromJson ignores an extra unknown key', () {
    final m = UserMessage('hi', seq: 1, atMs: 2).toJson()..['brandNew'] = 42;
    expect((ConversationEvent.fromJson(m) as UserMessage).text, 'hi');
    final p = PromptRequest(
      promptId: 'r',
      kind: PromptKind.question,
      toolName: 'AskUserQuestion',
      input: const {},
      suggestions: const [],
    ).toJson()
      ..['extra'] = true;
    expect(PromptRequest.fromJson(p).promptId, 'r');
    final a = PermissionAnswer(allow: true).toJson()..['zzz'] = 1;
    expect((PromptAnswer.fromJson(a) as PermissionAnswer).allow, true);
    final s = SessionSummary(
      id: 'a',
      name: 'b',
      cwd: 'c',
      origin: SessionOrigin.perch,
      state: SessionState.idle,
      startedAtMs: 0,
    ).toJson()
      ..['what'] = 'ever';
    expect(SessionSummary.fromJson(s).id, 'a');
  });

  test('session_summary_live_round_trips_and_defaults_to_true', () {
    const s = SessionSummary(
        id: 'x', name: 'n', cwd: 'c', origin: SessionOrigin.external, state: SessionState.idle, startedAtMs: 1, live: false);
    final back = SessionSummary.fromJson(jsonDecode(_j(s.toJson())) as Map<String, dynamic>);
    expect(back.live, isFalse);
    expect(s.copyWith(live: true).live, isTrue);
    expect(s.copyWith(name: 'm').live, isFalse);
    final old = SessionSummary.fromJson({'id': 'y', 'name': 'n', 'cwd': 'c', 'state': 'blocked'});
    expect(old.live, isTrue);
  });

  test('the_amber_line_says_what_the_release_notes_say', () {
    Compatibility c(ReleaseNotesFindings? f) =>
        Compatibility(status: CompatibilityStatus.untested, claudeVersion: '2.1.325', releaseNotes: f);
    expect(untestedLine(c(null)), "Claude Code 2.1.325 hasn't been checked yet");
    expect(untestedLine(c(const ReleaseNotesFindings(checked: true, versions: ['2.1.325']))),
        "Claude Code 2.1.325 hasn't been checked yet · release notes: nothing affecting Perch");
    expect(
        untestedLine(c(const ReleaseNotesFindings(checked: true, relevantLines: ['x'], topics: ['prompt']))),
        "Claude Code 2.1.325 hasn't been checked yet · release notes mention prompt changes");
    expect(releaseNotesPhrase(const ReleaseNotesFindings(checked: true, relevantLines: ['x'], topics: ['prompt', 'hook', 'transcript'])),
        'release notes mention prompt, hook and transcript changes');
    expect(untestedLine(c(const ReleaseNotesFindings(checked: false, error: 'offline'))),
        "Claude Code 2.1.325 hasn't been checked yet · release notes could not be read");
  });

  test('the_progress_line_marks_what_was_seen_working', () {
    const c = Compatibility(
        status: CompatibilityStatus.untested, claudeVersion: '2.1.325', seenWorking: ['question', 'permission']);
    expect(seenWorkingLine(c), 'Seen working on 2.1.325: questions ✓, permissions ✓, plans —');
  });
}
