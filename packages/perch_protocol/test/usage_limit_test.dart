import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  const limit = UsageLimit(
    resetsAtMs: 1794424800000,
    window: LimitWindows.fiveHour,
    choice: LimitChoices.wait,
    back: false,
    problem: "Couldn't stop Claude Code from continuing on Desk",
    sessions: [
      LimitedSession(id: 's1', name: 'Fix login', claudeWaiting: true),
      LimitedSession(id: 's2', name: 'Docs', claudeWaiting: null, override: LimitChoices.continueWhenAvailable),
    ],
  );

  test('a usage limit round-trips on the wire', () {
    final back = decodeHost(encodeHost(const UsageLimitMessage(limit: limit))) as UsageLimitMessage;
    final l = back.limit!;
    expect(l.resetsAtMs, 1794424800000);
    expect(l.window, LimitWindows.fiveHour);
    expect(l.choice, LimitChoices.wait);
    expect(l.back, isFalse);
    expect(l.problem, contains("Couldn't stop"));
    expect(l.sessions.map((s) => s.id), ['s1', 's2']);
    expect(l.sessions.first.claudeWaiting, isTrue);
    expect(l.sessions.last.claudeWaiting, isNull);
    expect(l.sessions.last.override, LimitChoices.continueWhenAvailable);
  });

  test('the effective choice is the session override, else the machine choice', () {
    expect(limit.choiceFor('s1'), LimitChoices.wait);
    expect(limit.choiceFor('s2'), LimitChoices.continueWhenAvailable);
    expect(limit.choiceFor('nope'), LimitChoices.wait);
    expect(limit.session('s2')?.name, 'Docs');
  });

  test('a cleared limit is null on the wire', () {
    final back = decodeHost(encodeHost(const UsageLimitMessage())) as UsageLimitMessage;
    expect(back.limit, isNull);
  });

  test('an unknown choice from a newer app falls back to continue', () {
    final l = UsageLimit.fromJson({'choice': 'switch', 'sessions': []});
    expect(l.choice, LimitChoices.continueWhenAvailable);
    expect(l.resetsAtMs, isNull);
  });

  test('the choice message round-trips, for the machine and for one session', () {
    for (final m in const [
      UsageLimitChoice(choice: LimitChoices.wait),
      UsageLimitChoice(choice: LimitChoices.continueWhenAvailable, sessionId: 's1'),
      UsageLimitChoice(choice: LimitChoices.continueNow),
    ]) {
      final back = decodeClient(encodeClient(m)) as UsageLimitChoice;
      expect(back.choice, m.choice);
      expect(back.sessionId, m.sessionId);
    }
    expect(decodeClient('{"type":"usageLimitChoice","choice":"bogus"}'), isNull);
  });

  test('a resume report round-trips', () {
    const r = ResumeReport(sessionId: 's1', sessionName: 'Fix login', changed: true, text: 'Resumed without the subagent');
    final back = decodeHost(encodeHost(r)) as ResumeReport;
    expect(back.sessionId, 's1');
    expect(back.sessionName, 'Fix login');
    expect(back.changed, isTrue);
    expect(back.text, 'Resumed without the subagent');
  });

  test('a push note can name the sessions it is about', () {
    final note = PushNote(
        machineId: 'm', sessionId: usageLimitPushId, kind: PushKinds.usageBack, sessionIds: const ['a', 'b']);
    final back = PushNote.fromJson(note.toJson())!;
    expect(back.sessionIds, ['a', 'b']);
    expect(PushNote.fromJson(PushNote(machineId: 'm', sessionId: 's', kind: PushKinds.finished).toJson())!.sessionIds,
        isEmpty);
  });
}
