import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  final summary = SessionSummary(
    id: 's1',
    name: 'Fix login',
    cwd: 'D:\\projects\\x',
    origin: SessionOrigin.perch,
    state: SessionState.working,
    startedAtMs: 1,
    openPrompts: 0,
  );
  final usage = UsageSnapshot(
    fiveHour: UsageWindow(utilization: 0.87, resetsAt: 1794424800, status: 'allowed'),
  );
  final prompt = PromptRequest(
    promptId: 'p1',
    kind: PromptKind.question,
    toolName: 'AskUserQuestion',
    input: {
      'questions': [
        {'question': 'Which color?'}
      ]
    },
    suggestions: const [],
  );

  test('every client message round-trips', () {
    final msgs = <ClientMessage>[
      Hello(code: 'ABCD2345', deviceName: 'Pixel'),
      ListSessions(),
      StartSession(cwd: 'D:\\x', prompt: 'go', name: 'n', model: 'haiku'),
      StartSession(cwd: 'D:\\x', prompt: 'go'),
      Subscribe(sessionId: 's1', afterSeq: 7),
      LoadEarlier(sessionId: 's1', beforeSeq: 301),
      SendMessage(sessionId: 's1', text: 'more'),
      AnswerPrompt(sessionId: 's1', promptId: 'p1', answer: QuestionAnswer({'Which color?': 'Blue'})),
      AnswerPrompt(sessionId: 's1', promptId: 'p2', answer: PermissionAnswer(allow: true, always: true)),
      AnswerPrompt(sessionId: 's1', promptId: 'p3', answer: PlanAnswer(approve: false, feedback: 'f')),
      Interrupt(sessionId: 's1'),
      StopSession(sessionId: 's1'),
      KillAll(),
      TakeOver(sessionId: 's1', force: true),
      ListDir(path: r'D:\projects'),
      ListDir(),
      FocusSession(sessionId: 's1'),
      FocusSession(),
      SetSelfTest(enabled: true),
      SetSelfTest(enabled: false),
      RunSelfTest(),
      RenameSession(sessionId: 's1', name: 'Fix login ✓'),
      DeleteSession(sessionId: 's1'),
      ResumeSession(sessionId: 's1'),
    ];
    for (final m in msgs) {
      final frame = encodeClient(m);
      final back = decodeClient(frame);
      expect(back, isNotNull, reason: frame);
      expect(back.runtimeType, m.runtimeType);
      expect(encodeClient(back!), frame);
    }
  });

  test('every host message round-trips', () {
    final msgs = <HostMessage>[
      Welcome(machineName: 'desk', os: 'windows', hostVersion: '0.1.0', claudeVersion: '2.1.322'),
      Welcome(machineName: 'desk', os: 'windows', hostVersion: '0.1.0', hooksInstalled: false),
      Welcome(
          machineName: 'desk',
          os: 'windows',
          hostVersion: '0.1.0',
          compatibility: Compatibility(status: CompatibilityStatus.untested, claudeVersion: '2.1.324')),
      Welcome(
          machineName: 'desk',
          os: 'windows',
          hostVersion: '0.2.0',
          relayUrl: 'https://relay.example',
          lanAddresses: ['192.168.1.20:8787']),
      CompatibilityMessage(
          compatibility: Compatibility(
              status: CompatibilityStatus.drifted,
              claudeVersion: '2.1.330',
              reason: 'Claude Code shows a dialog Perch cannot recognise.',
              evidence: 'Session: x\nScreen:\n> 1. Maybe')),
      CompatibilityMessage(
          compatibility: Compatibility(
              status: CompatibilityStatus.untested,
              claudeVersion: '2.1.325',
              releaseNotes: ReleaseNotesFindings(
                  checked: true,
                  versions: ['2.1.324', '2.1.325'],
                  relevantLines: ['Fixed long options in lists and permission prompts being partly overwritten'],
                  topics: ['prompt']),
              seenWorking: [WorkingKinds.question, WorkingKinds.plan],
              selfTest: SelfTestStatus(
                  enabled: true, state: SelfTestState.failed, version: '2.1.325', reason: 'No plan', atMs: 5))),
      CompatibilityMessage(
          compatibility: Compatibility(
              status: CompatibilityStatus.untested,
              claudeVersion: '2.1.325',
              releaseNotes: ReleaseNotesFindings(checked: false, error: 'timed out'))),
      Sessions(sessions: [summary], usage: usage),
      Sessions(sessions: const []),
      SessionUpdated(session: summary),
      Events(sessionId: 's1', events: [UserMessage('hi', seq: 1, atMs: 2)], openPrompts: [prompt]),
      Events(sessionId: 's1', events: [UserMessage('hi', seq: 301, atMs: 2)], hasEarlier: true),
      EarlierEvents(sessionId: 's1', events: [UserMessage('old', seq: 300, atMs: 1)], hasEarlier: false),
      EventMessage(sessionId: 's1', event: AssistantText('yo', seq: 2, atMs: 3)),
      PromptOpened(sessionId: 's1', prompt: prompt),
      PromptClosed(sessionId: 's1', promptId: 'p1'),
      UsageMessage(usage: usage),
      ErrorMessage(code: ErrorCodes.promptAlreadyAnswered, message: 'Already answered'),
      ErrorMessage(code: ErrorCodes.cannotType, message: 'Could not type into the terminal'),
      DirListing(
        path: r'D:\projects',
        parent: r'D:\',
        entries: [DirEntry(name: 'perch', path: r'D:\projects\perch')],
        suggested: [DirEntry(name: 'Home', path: r'C:\Users\me')],
      ),
      DirListing(path: ''),
      RemoteAccessStopped(),
      MachineRenamed(machineName: 'Studio desk ✓'),
      SessionActionDone(action: SessionActions.rename, sessionId: 's1', message: 'Renamed'),
      SessionActionDone(action: SessionActions.delete, sessionId: 's1'),
    ];
    for (final m in msgs) {
      final frame = encodeHost(m);
      final back = decodeHost(frame);
      expect(back, isNotNull, reason: frame);
      expect(back.runtimeType, m.runtimeType);
      expect(encodeHost(back!), frame);
    }
  });

  test('session actions with a missing id or name decode with empty fields', () {
    expect((decodeClient('{"type":"renameSession"}') as RenameSession).name, '');
    expect((decodeClient('{"type":"deleteSession"}') as DeleteSession).sessionId, '');
    expect(decodeHost('{"type":"sessionActionDone","action":"","sessionId":"s1"}'), isNull);
  });

  test('older hosts answer an unknown message with this error', () {
    expect(isUnknownMessageError(const ErrorMessage(code: ErrorCodes.badRequest, message: unknownMessageText)), isTrue);
    expect(isUnknownMessageError(const ErrorMessage(code: ErrorCodes.badRequest, message: 'Folder does not exist')),
        isFalse);
  });

  test('unknown type and malformed JSON decode to null', () {
    expect(decodeClient('{"type":"nope"}'), isNull);
    expect(decodeClient('not json'), isNull);
    expect(decodeClient('[1,2]'), isNull);
    expect(decodeHost('{"type":"nope"}'), isNull);
    expect(decodeHost('not json'), isNull);
  });

  test('a welcome from an older host counts as hooks installed', () {
    final w = decodeHost('{"type":"welcome","machineName":"desk","os":"windows","hostVersion":"0.1.0"}') as Welcome;
    expect(w.hooksInstalled, isTrue);
    final off = decodeHost(encodeHost(const Welcome(machineName: 'd', os: 'w', hostVersion: '1', hooksInstalled: false)));
    expect((off as Welcome).hooksInstalled, isFalse);
  });

  test('compatibility decodes with safe defaults', () {
    final c = Compatibility.fromJson(const {'status': 'drifted', 'reason': 'r'});
    expect(c.status, CompatibilityStatus.drifted);
    expect(c.reason, 'r');
    expect(c.evidence, isNull);
    expect(Compatibility.fromJson(const {'status': 'something new'}).status, CompatibilityStatus.ok);
    final w = decodeHost('{"type":"welcome","machineName":"d","os":"w","hostVersion":"1"}') as Welcome;
    expect(w.compatibility, isNull);
    final m = decodeHost(encodeHost(const CompatibilityMessage(
        compatibility: Compatibility(status: CompatibilityStatus.drifted, reason: 'r', evidence: 'e'))));
    expect((m as CompatibilityMessage).compatibility.evidence, 'e');
    // From an older host: no version-check fields.
    expect(c.releaseNotes, isNull);
    expect(c.seenWorking, isEmpty);
    expect(c.selfTest, isNull);
  });

  test('version check fields decode with safe defaults', () {
    final c = Compatibility.fromJson(const {
      'status': 'untested',
      'releaseNotes': {'checked': 'yes', 'versions': ['2.1.325', 7], 'relevantLines': 'x'},
      'seenWorking': ['question', 3],
      'selfTest': {'state': 'exploded'},
    });
    expect(c.releaseNotes!.checked, isFalse);
    expect(c.releaseNotes!.versions, ['2.1.325']);
    expect(c.releaseNotes!.relevantLines, isEmpty);
    expect(c.releaseNotes!.topics, isEmpty);
    expect(c.seenWorking, ['question']);
    expect(c.selfTest!.enabled, isFalse);
    expect(c.selfTest!.state, SelfTestState.idle);
    final s = decodeClient('{"type":"setSelfTest"}') as SetSelfTest;
    expect(s.enabled, isFalse);
  });

  test('a hello frame decodes to Hello', () {
    final m = decodeClient('{"type":"hello","code":"ABCD2345","deviceName":"Pixel","extra":1}');
    expect(m, isA<Hello>());
    expect((m as Hello).code, 'ABCD2345');
  });
}
