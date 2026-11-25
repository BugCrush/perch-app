import 'dart:async';
import 'dart:io';

import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late Directory tmp;
  late SessionManager manager;
  late FakeExternalSessions external;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_sm_');
    external = FakeExternalSessions();
    manager = SessionManager(launcher: fakeLauncher(), external: external);
  });
  tearDown(() async {
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<SessionState> stateOf(String id) async => (await manager.list()).firstWhere((s) => s.id == id).state;

  test('start_lists_and_streams', () async {
    final got = <ConversationEvent>[];
    manager.events.listen((e) => got.add(e.event));
    final s = await manager.start(cwd: tmp.path, prompt: 'echo hello');
    final listed = (await manager.list()).firstWhere((x) => x.id == s.id);
    expect(listed.origin, SessionOrigin.perch);
    expect(listed.name, 'echo hello');
    await waitUntil(() => got.any((e) => e is TurnEnded));
    expect(got.first, isA<UserMessage>());
    expect(got.first.seq, 1);
    expect(got.indexWhere((e) => e is AssistantText), greaterThan(0));
    expect(got.indexWhere((e) => e is TurnEnded), greaterThan(got.indexWhere((e) => e is AssistantText)));
    for (var i = 1; i < got.length; i++) {
      expect(got[i].seq, greaterThan(got[i - 1].seq));
    }
    expect(got.every((e) => e.atMs > 0), isTrue);
  });

  test('perch_session_is_live_while_its_process_runs', () async {
    final s = await manager.start(cwd: tmp.path, prompt: 'slow');
    expect((await manager.list()).firstWhere((x) => x.id == s.id).live, isTrue);
    await manager.stop(s.id);
    final after = (await manager.list()).firstWhere((x) => x.id == s.id);
    expect(after.state, SessionState.stopped);
    expect(after.live, isFalse);
  });

  test('name_defaults_to_first_40_characters', () async {
    final prompt = 'echo ${'x' * 60}';
    final s = await manager.start(cwd: tmp.path, prompt: prompt);
    expect(s.name, prompt.substring(0, 40));
    final named = await manager.start(cwd: tmp.path, prompt: 'echo', name: 'Fix login');
    expect(named.name, 'Fix login');
  });

  test('history_after_seq', () async {
    final s = await manager.start(cwd: tmp.path, prompt: 'echo one');
    await waitUntil(() async => (await stateOf(s.id)) == SessionState.idle);
    await manager.send(s.id, 'two'); // 1 user, 2 text, 3 turn, 4 user, 5 text, 6 turn
    await waitUntil(() => manager.history(s.id).events.length >= 6);
    expect(manager.history(s.id, afterSeq: 3).events.map((e) => e.seq).take(2).toList(), [4, 5]);
    expect(manager.history(s.id, afterSeq: 4).events.first, isA<AssistantText>());
  });

  test('event_buffer_is_capped', () async {
    // 1 UserMessage + 5198 AssistantText + 1 TurnEnded = 5200 events.
    final s = await manager.start(cwd: tmp.path, prompt: 'flood 5198');
    await waitUntil(() => manager.history(s.id).events.lastOrNull is TurnEnded, timeout: const Duration(seconds: 60));
    final h = manager.history(s.id).events;
    expect(h.length, maxEventsPerSession);
    expect(h.first.seq, 201);
    expect(h.last.seq, 5200);
  });

  test('read_only_and_missing', () async {
    external.entries = [external.entry(pid: 4242, cwd: tmp.path)];
    final list = await manager.list();
    final ext = list.firstWhere((s) => s.origin == SessionOrigin.external);
    expect(ext.id, 'pid:4242');
    expect(() => manager.send(ext.id, 'hi'), throwsA(isA<CannotType>())); // no typer in this test
    expect(() => manager.send('nope', 'hi'), throwsA(isA<NoSuchSession>()));
    expect(() => manager.interrupt('nope'), throwsA(isA<NoSuchSession>()));
    expect(() => manager.history('nope'), throwsA(isA<NoSuchSession>()));
  });

  test('kill_all_stops_everything', () async {
    external.entries = [external.entry(pid: 4242, cwd: tmp.path)];
    final a = await manager.start(cwd: tmp.path, prompt: 'slow');
    final b = await manager.start(cwd: tmp.path, prompt: 'slow');
    await waitUntil(() async => (await stateOf(a.id)) == SessionState.working);
    final n = await manager.killAll();
    expect(n, 3);
    expect(await stateOf(a.id), SessionState.stopped);
    expect(await stateOf(b.id), SessionState.stopped);
    expect(external.kills, [4242]);
  });

  test('missing_cwd_is_rejected', () async {
    expect(() => manager.start(cwd: 'Z:/nope', prompt: 'echo'), throwsArgumentError);
  });

  test('prompts_open_and_close_and_usage_arrives', () async {
    final opened = <String>[];
    final closed = <String>[];
    manager.promptsOpened.listen((p) => opened.add(p.prompt.promptId));
    manager.promptsClosed.listen((p) => closed.add(p.promptId));
    final s = await manager.start(cwd: tmp.path, prompt: 'question');
    await waitUntil(() => opened.isNotEmpty);
    expect(manager.history(s.id).openPrompts.single.promptId, opened.single);
    expect((await manager.list()).firstWhere((x) => x.id == s.id).openPrompts, 1);
    manager.answer(s.id, opened.single, const QuestionAnswer({'Which color?': 'Blue'}));
    await waitUntil(() => closed.isNotEmpty);
    expect(closed.single, opened.single);
    expect(() => manager.answer(s.id, opened.single, const QuestionAnswer({})),
        throwsA(isA<Object>().having((e) => e.runtimeType.toString(), 'type', 'PromptAlreadyAnswered')));
    expect(manager.usage, isNotNull);
  });

  test('perch_session_claude_id_hides_its_external_entry', () async {
    final s = await manager.start(cwd: tmp.path, prompt: 'echo');
    await waitUntil(() async => (await stateOf(s.id)) == SessionState.idle);
    final claudeId = manager.claudeSessionIdOf(s.id)!;
    external.entries = [external.entry(sessionId: claudeId, cwd: tmp.path, kind: 'background', state: 'working')];
    final list = await manager.list();
    expect(list.where((x) => x.origin == SessionOrigin.external), isEmpty);
  });
}
