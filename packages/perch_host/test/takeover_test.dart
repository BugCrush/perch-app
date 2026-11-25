import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const sid = '11111111-2222-4333-8444-555555555555';
final sep = Platform.pathSeparator;

void copyDir(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final e in from.listSync()) {
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (e is File) {
      e.copySync('${to.path}$sep$name');
    } else if (e is Directory) {
      copyDir(e, Directory('${to.path}$sep$name'));
    }
  }
}

void main() {
  late Directory tmp;
  late Directory work;
  late File transcript;
  late File argsFile;
  late FakeExternalSessions external;
  late FakeConsoleTyper typer;
  late SessionManager manager;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_to_');
    work = Directory('${tmp.path}${sep}work')..createSync();
    final project = Directory('${tmp.path}${sep}config${sep}projects${sep}D--projects-example')..createSync(recursive: true);
    File('test${sep}fixtures${sep}transcript$sep$sid.jsonl').copySync('${project.path}$sep$sid.jsonl');
    copyDir(Directory('test${sep}fixtures${sep}transcript$sep$sid'), Directory('${project.path}$sep$sid'));
    transcript = File('${project.path}$sep$sid.jsonl');
    argsFile = File('${tmp.path}${sep}args.txt');
    external = FakeExternalSessions();
    typer = FakeConsoleTyper();
    manager = SessionManager(
      typer: typer,
      launcher: fakeLauncher(env: {'FAKE_CLAUDE_ARGS_FILE': argsFile.path}),
      external: external,
      claudeConfigDir: '${tmp.path}${sep}config',
    );
  });

  tearDown(() async {
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void terminalEntry({String status = 'idle', int pid = 5555, String? waitingFor}) {
    external.entries = [
      external.entry(pid: pid, sessionId: sid, cwd: work.path, status: status, waitingFor: waitingFor, name: 'example')
    ];
  }

  Future<SessionSummary> summaryOf(String id) async => (await manager.list()).firstWhere((s) => s.id == id);

  test('watching_external_session_streams_transcript', () async {
    terminalEntry();
    final s = (await manager.list()).single;
    expect(s.origin, SessionOrigin.external);
    final h = manager.history(sid);
    expect(h.events.whereType<UserMessage>().first.text, 'List the files here and count them.');
    expect(h.events.whereType<ToolCall>().map((e) => e.name), containsAll(['Bash', 'Agent']));
    final sub = h.events.whereType<SubagentStarted>().single;
    expect(sub.toolUseId, 'toolu_A2');
    expect(h.events.where((e) => e.parentToolUseId == 'toolu_A2'), isNotEmpty);
    for (var i = 1; i < h.events.length; i++) {
      expect(h.events[i].seq, h.events[i - 1].seq + 1);
    }
    expect((await summaryOf(sid)).name, 'Count project files');

    final live = <ConversationEvent>[];
    manager.events.listen((e) => live.add(e.event));
    transcript.writeAsStringSync(
        '${jsonEncode({
          'type': 'assistant',
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'A new line.'}
            ]
          }
        })}\n',
        mode: FileMode.append);
    await waitUntil(() => live.whereType<AssistantText>().any((e) => e.text == 'A new line.'));
    expect(live.last.seq, h.events.last.seq + 1);
    expect(() => manager.answer(sid, 'x', const PermissionAnswer(allow: true)), throwsA(isA<ReadOnlySession>()));
  });

  test('opening_history_does_not_rebroadcast_it_as_live_events', () async {
    terminalEntry();
    await manager.list();
    final live = <ConversationEvent>[];
    final sub = manager.events.listen((e) => live.add(e.event));
    final h = manager.history(sid);
    expect(h.events, isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(live, isEmpty, reason: 'lines already on disk are history, not live events');

    transcript.writeAsStringSync(
        '${jsonEncode({
          'type': 'assistant',
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'Only this is new.'}
            ]
          }
        })}\n',
        mode: FileMode.append);
    await waitUntil(() => live.isNotEmpty);
    expect(live.whereType<AssistantText>().single.text, 'Only this is new.');
    await sub.cancel();
  });

  test('take_over_kills_terminal_and_resumes_with_same_id', () async {
    terminalEntry();
    await manager.list();
    final before = manager.history(sid).events.length;
    final s = await manager.takeOver(sid);
    expect(external.kills, [5555]);
    expect(s.id, sid);
    expect(s.origin, SessionOrigin.perch);
    await waitUntil(() => argsFile.existsSync() && argsFile.readAsStringSync().isNotEmpty);
    final args = argsFile.readAsLinesSync();
    expect(args[args.indexOf('--resume') + 1], sid);
    expect(args[args.indexOf('--permission-mode') + 1], 'auto');
    expect(args, isNot(contains('-n')));
    final h = manager.history(sid).events;
    expect(h.length, before + 1);
    expect(h.whereType<UserMessage>().first.text, 'List the files here and count them.');
    expect((h.last as Notice).text, 'Continued on phone. To take it back, run claude --resume in the terminal.');
    final listed = await summaryOf(sid);
    expect(listed.origin, SessionOrigin.perch);
    expect((await manager.list()).where((x) => x.id == sid).length, 1);
  });

  test('take_over_then_send_goes_to_the_resumed_session', () async {
    terminalEntry();
    await manager.list();
    await manager.takeOver(sid);
    await manager.send(sid, 'hello there');
    expect(external.kills, [5555]);
    await waitUntil(() => manager.history(sid).events.whereType<AssistantText>().any((e) => e.text == 'echo: hello there'));
    final h = manager.history(sid).events;
    final notice = h.indexWhere((e) => e is Notice);
    final mine = h.lastIndexWhere((e) => e is UserMessage && e.text == 'hello there');
    expect(notice, lessThan(mine));
  });

  test('busy_session_needs_force', () async {
    terminalEntry(status: 'busy');
    await manager.list();
    await expectLater(manager.takeOver(sid), throwsA(isA<SessionBusy>()));
    expect(external.kills, isEmpty);
    final s = await manager.takeOver(sid, force: true);
    expect(s.origin, SessionOrigin.perch);
    expect(external.kills, [5555]);
  });

  test('pid_only_session_is_read_only', () async {
    external.entries = [external.entry(pid: 77, cwd: work.path)];
    await manager.list();
    await expectLater(manager.takeOver('pid:77'), throwsA(isA<ReadOnlySession>()));
    expect(external.kills, isEmpty);
  });

  test('takeover_fails_when_terminal_survives', () async {
    terminalEntry();
    external.killRemoves = false;
    await manager.list();
    await expectLater(manager.takeOver(sid), throwsA(isA<TakeoverFailed>()));
    expect((await summaryOf(sid)).origin, SessionOrigin.external);
  });

  test('terminal_resume_hands_back', () async {
    terminalEntry();
    await manager.list();
    await manager.takeOver(sid);
    await manager.send(sid, 'hello there');
    await waitUntil(() => manager.history(sid).events.whereType<AssistantText>().any((e) => e.text == 'echo: hello there'));

    // The owner runs `claude --resume` in the terminal: a new interactive entry appears.
    terminalEntry(pid: 6666);
    final listed = await summaryOf(sid);
    expect(listed.origin, SessionOrigin.external);
    final h = manager.history(sid).events;
    expect(h.whereType<Notice>().last.text, 'Continued in the terminal.');
    expect((await manager.list()).where((x) => x.id == sid).length, 1);
    await expectLater(manager.takeOver(sid), completes); // can be taken over again
    expect(external.kills, [5555, 6666]);
  });

  test('hand_back_restarts_tailer_from_end', () async {
    terminalEntry();
    await manager.list();
    await manager.takeOver(sid);
    terminalEntry(pid: 6666);
    await manager.list();
    final n = manager.history(sid).events.length;
    transcript.writeAsStringSync(
        '${jsonEncode({
          'type': 'user',
          'message': {'role': 'user', 'content': 'typed in the terminal'}
        })}\n',
        mode: FileMode.append);
    await waitUntil(() => manager.history(sid).events.length > n);
    final added = manager.history(sid, afterSeq: manager.history(sid).events[n - 1].seq).events;
    expect(added.single, isA<UserMessage>());
    expect((added.single as UserMessage).text, 'typed in the terminal');
  });

  test('send_to_terminal_session_types_and_does_not_kill', () async {
    terminalEntry(status: 'busy');
    await manager.list();
    final events = <ConversationEvent>[];
    manager.events.listen((e) => events.add(e.event));
    const text = 'Line one\nline "two"';
    await manager.send(sid, text);
    expect(typer.calls.single.pid, 5555);
    expect(typer.calls.single.text, text);
    expect(external.kills, isEmpty);
    expect((await summaryOf(sid)).origin, SessionOrigin.external);
    // send started the transcript tailer even though nobody subscribed: the history is
    // there (read in quietly, not broadcast as live events).
    expect(manager.history(sid).events, isNotEmpty);
    expect(events, isEmpty);
    // Nothing is recorded by the host itself; the transcript brings the message.
    final n = manager.history(sid).events.length;
    expect(manager.history(sid).events.whereType<UserMessage>().where((e) => e.text == text), isEmpty);
    transcript.writeAsStringSync(
        '${jsonEncode({
          'type': 'user',
          'message': {'role': 'user', 'content': text}
        })}\n',
        mode: FileMode.append);
    await waitUntil(() => manager.history(sid).events.length > n);
    expect(events.whereType<UserMessage>().last.text, text);
  });

  test('typing_failure_raises_cannot_type_and_does_not_take_over', () async {
    terminalEntry();
    typer.result = false;
    await manager.list();
    await expectLater(manager.send(sid, 'hi'), throwsA(isA<CannotType>()));
    expect(typer.calls.length, 1);
    expect(external.kills, isEmpty);
    expect((await summaryOf(sid)).origin, SessionOrigin.external);

    typer
      ..supported = false
      ..calls.clear();
    await expectLater(manager.send(sid, 'hi'), throwsA(isA<CannotType>()));
    expect(typer.calls, isEmpty);
    expect(external.kills, isEmpty);
  });

  test('pid_less_session_raises_cannot_type', () async {
    external.entries = [
      external.entry(sessionId: sid, cwd: work.path, kind: 'background', state: 'done', name: 'example')
    ];
    await manager.list();
    await expectLater(manager.send(sid, 'hi'), throwsA(isA<CannotType>()));
    expect(typer.calls, isEmpty);
    expect(external.kills, isEmpty);
  });
}
