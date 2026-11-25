// Messages to terminal sessions Perch cannot type into (no adapter for their terminal)
// go through Claude Code's session inbox instead of failing with cannotType.
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/inbox.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const sid = '11111111-2222-4333-8444-555555555555';
final sep = Platform.pathSeparator;

void main() {
  late Directory tmp;
  late Directory work;
  late String config;
  late FakeExternalSessions external;
  late FakeConsoleTyper typer;
  late List<(String, String)> writes;
  late bool writeOk;
  late SessionManager manager;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_ibx_');
    work = Directory('${tmp.path}${sep}work')..createSync();
    config = '${tmp.path}${sep}config';
    final project = Directory('$config${sep}projects${sep}D--projects-example')..createSync(recursive: true);
    File('test${sep}fixtures${sep}transcript$sep$sid.jsonl').copySync('${project.path}$sep$sid.jsonl');
    Directory('$config${sep}sessions').createSync();
    File('$config${sep}sessions${sep}5555.json')
        .writeAsStringSync(jsonEncode({'pid': 5555, 'sessionId': sid, 'messagingSocketPath': '/tmp/cc-socks/5555.sock'}));
    external = FakeExternalSessions();
    typer = FakeConsoleTyper()..operable = false;
    writes = [];
    writeOk = true;
    manager = SessionManager(
      typer: typer,
      launcher: fakeLauncher(),
      external: external,
      claudeConfigDir: config,
      inbox: ClaudeInbox(
          configDir: config,
          available: true,
          write: (p, l) async {
            writes.add((p, l));
            return writeOk;
          }),
    );
    external.entries = [external.entry(pid: 5555, sessionId: sid, cwd: work.path, status: 'idle', name: 'example')];
  });

  tearDown(() async {
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a session no adapter can operate gets the message through its inbox', () async {
    await manager.list();
    await manager.send(sid, 'Run the tests.');
    expect(writes.single, ('/tmp/cc-socks/5555.sock', inboxLine('Run the tests.')));
    expect(typer.calls, isEmpty, reason: 'nothing typed');
    expect(external.kills, isEmpty, reason: 'nothing closed');
  });

  test('a session in a terminal Perch can type into is still typed into', () async {
    typer.operable = true;
    await manager.list();
    await manager.send(sid, 'Run the tests.');
    expect(typer.calls.single.text, 'Run the tests.');
    expect(writes, isEmpty);
  });

  test('typing that fails in a known terminal still raises cannotType (no inbox fallback)', () async {
    typer
      ..operable = true
      ..result = false;
    await manager.list();
    await expectLater(manager.send(sid, 'x'), throwsA(isA<CannotType>()));
    expect(writes, isEmpty);
  });

  test('an inbox that cannot be reached raises cannotType and closes nothing', () async {
    writeOk = false;
    await manager.list();
    await expectLater(manager.send(sid, 'x'), throwsA(isA<CannotType>()));
    expect(external.kills, isEmpty);
  });

  test('a session without an inbox raises cannotType', () async {
    File('$config${sep}sessions${sep}5555.json').deleteSync();
    await manager.list();
    await expectLater(manager.send(sid, 'x'), throwsA(isA<CannotType>()));
    expect(writes, isEmpty);
  });

  test('a new session: its first transcript lines after a send reach subscribed devices live', () async {
    final f = File('$config${sep}projects${sep}D--projects-example$sep$sid.jsonl')..deleteSync();
    await manager.list();
    expect(manager.history(sid).events, isEmpty, reason: 'no transcript yet');
    final live = <ConversationEvent>[];
    manager.events.listen((e) => live.add(e.event));
    await manager.send(sid, 'Reply with LIVE.');
    f.writeAsStringSync('${jsonEncode({
      'type': 'user',
      'isMeta': true,
      'origin': {'kind': 'peer', 'from': 'unknown', 'name': perchSenderName, 'body': 'Reply with LIVE.'},
      'message': {'role': 'user', 'content': 'Another Claude session sent a message:\n${wrapInboxText('Reply with LIVE.')}'},
    })}\n${jsonEncode({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'LIVE'}
        ]
      }
    })}\n');
    await waitUntil(() => live.whereType<AssistantText>().any((e) => e.text == 'LIVE'), timeout: const Duration(seconds: 10));
    expect(live.whereType<UserMessage>().map((e) => e.text), ['Reply with LIVE.']);
  });

  test('the sent message shows in the conversation once Claude Code writes it', () async {
    await manager.list();
    manager.history(sid);
    await manager.send(sid, 'Run the tests.');
    final f = File('$config${sep}projects${sep}D--projects-example$sep$sid.jsonl');
    f.writeAsStringSync(
        '${jsonEncode({
          'type': 'user',
          'isMeta': true,
          'origin': {'kind': 'peer', 'from': 'unknown', 'name': perchSenderName, 'body': 'Run the tests.'},
          'message': {'role': 'user', 'content': 'Another Claude session sent a message:\n${wrapInboxText('Run the tests.')}'},
        })}\n',
        mode: FileMode.append);
    await waitUntil(() => manager.history(sid).events.whereType<UserMessage>().any((e) => e.text == 'Run the tests.'),
        timeout: const Duration(seconds: 10));
  });
}
