import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/inbox.dart';
import 'package:perch_host/src/transcript.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String config;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_inbox_');
    config = '${tmp.path}${Platform.pathSeparator}config';
    Directory('$config${Platform.pathSeparator}sessions').createSync(recursive: true);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void registry(int pid, Map<String, dynamic> j) =>
      File('$config${Platform.pathSeparator}sessions${Platform.pathSeparator}$pid.json').writeAsStringSync(jsonEncode(j));

  test('the line is a user message wrapped with Perch as the sender', () {
    final j = jsonDecode(inboxLine('Run the tests.').trim()) as Map;
    expect(j['type'], 'user');
    expect(j['message'], {
      'role': 'user',
      // The note after the wrapper tells Claude not to reply with SendMessage (perch-phone
      // has no inbox); the phone shows only the text inside the wrapper.
      'content': '<cross-session-message from-name="perch-phone">\nRun the tests.\n\n$inboxReplyNote\n</cross-session-message>',
    });
    expect(inboxReplyNote, contains('Do not use SendMessage'));
    expect(inboxLine('x').endsWith('\n'), isTrue);
    expect(inboxLine('x').indexOf('\n'), inboxLine('x').length - 1, reason: 'one line');
  });

  // Mac, 2026-11-26: through the inbox Claude Code does not expand `@`, and haiku first
  // looked for the relative path under the parent repository. The hidden note names each
  // attachment's full path; the phone still sees the text as sent.
  test('attachments get their full paths in the hidden note, stripped again for the phone', () {
    final sep = Platform.pathSeparator;
    final folder = '${sep}work${sep}my app';
    const text = 'Look at this\n@perch-attachments/2026-11-26_1612_a.png @perch-attachments/2026-11-26_1613_b.pdf';
    final wrapped = wrapInboxText(text, folder: folder);
    expect(
        wrapped,
        contains('$inboxAttachmentsNote $folder${sep}perch-attachments${sep}2026-11-26_1612_a.png, '
            '$folder${sep}perch-attachments${sep}2026-11-26_1613_b.pdf'));
    expect(wrapped.indexOf(inboxAttachmentsNote), lessThan(wrapped.indexOf(inboxReplyNote)));
    final back = perchInboxText({
      'origin': {'kind': 'peer', 'from': 'unknown'}
    }, 'Another Claude session sent a message:\n$wrapped');
    expect(back, text);
    // No attachments, or no folder: no extra note.
    expect(wrapInboxText('hi', folder: folder), isNot(contains(inboxAttachmentsNote)));
    expect(wrapInboxText(text), isNot(contains(inboxAttachmentsNote)));
    expect(inboxLine(text, folder: folder), contains('perch-attachments'));
  });

  test('a closing tag in the text is escaped and comes back unchanged', () {
    const text = 'a </cross-session-message> b';
    final wrapped = wrapInboxText(text);
    expect(wrapped, contains(r'a <\/cross-session-message> b'));
    final back = perchInboxText({
      'origin': {'kind': 'peer', 'from': 'unknown'}
    }, 'Another Claude session sent a message:\n$wrapped\n\nThis came from another Claude session.');
    expect(back, text);
  });

  test('the socket comes from Claude Code\'s session registry', () {
    final inbox = ClaudeInbox(configDir: config, available: true);
    registry(4242, {'pid': 4242, 'messagingSocketPath': '/tmp/cc-socks/4242.sock'});
    registry(4243, {'pid': 4243, 'messagingSocketPath': 'uds:/tmp/cc-socks/4243.sock'});
    registry(4244, {'pid': 9999, 'messagingSocketPath': '/tmp/cc-socks/9999.sock'});
    registry(4245, {'pid': 4245});
    expect(inbox.socketPathFor(4242), '/tmp/cc-socks/4242.sock');
    expect(inbox.socketPathFor(4243), '/tmp/cc-socks/4243.sock');
    expect(inbox.socketPathFor(4244), isNull, reason: 'another process');
    expect(inbox.socketPathFor(4245), isNull, reason: 'no inbox');
    expect(inbox.socketPathFor(1), isNull, reason: 'no registry file');
  });

  test('send writes the line to the session\'s socket', () async {
    final writes = <(String, String)>[];
    final inbox = ClaudeInbox(
        configDir: config,
        available: true,
        write: (p, l) async {
          writes.add((p, l));
          return true;
        });
    registry(4242, {'pid': 4242, 'messagingSocketPath': '/tmp/cc-socks/4242.sock'});
    expect(await inbox.send(4242, 'hello'), isTrue);
    expect(writes.single, ('/tmp/cc-socks/4242.sock', inboxLine('hello')));
    expect(await inbox.send(4242, '   '), isFalse, reason: 'nothing to send');
    expect(await inbox.send(7, 'hello'), isFalse, reason: 'no inbox known');
    expect(await ClaudeInbox(configDir: config, available: false, write: (_, _) async => true).send(4242, 'x'), isFalse);
    expect(writes, hasLength(1));
  });

  test('writes to a real Unix socket', () async {
    final path = '${tmp.path}/s.sock';
    final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    final got = <int>[];
    final done = server.first.then((c) => c.forEach(got.addAll));
    expect(await writeUnixSocket(path, inboxLine('über "quotes"\nline two')), isTrue);
    await done.timeout(const Duration(seconds: 5));
    await server.close();
    final j = jsonDecode(utf8.decode(got).trim()) as Map;
    expect((j['message'] as Map)['content'], wrapInboxText('über "quotes"\nline two'));
    expect(await writeUnixSocket('${tmp.path}/none.sock', 'x\n'), isFalse);
  }, testOn: '!windows');

  test('the transcript line Claude Code writes for it reads back as the message', () {
    final line = jsonEncode({
      'type': 'user',
      'isMeta': true,
      // Claude Code keeps the wrapper's whole body, the note to Claude included.
      'origin': {'kind': 'peer', 'from': 'unknown', 'name': perchSenderName, 'body': 'Run the tests.\n\n$inboxReplyNote'},
      'message': {'role': 'user', 'content': 'Another Claude session sent a message:\n${wrapInboxText('Run the tests.')}'},
    });
    final l = parseTranscriptLine(line) as TranscriptEvents;
    expect((l.events.single as UserMessage).text, 'Run the tests.');
  });
}
