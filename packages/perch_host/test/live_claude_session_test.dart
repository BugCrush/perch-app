@Tags(['live'])
library;

import 'dart:io';

import 'package:perch_host/src/claude_session.dart';
import 'package:perch_host/src/stream_parser.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

// Calls the real `claude` with --model haiku. Run by hand: dart test -t live
void main() {
  test('live_real_claude_reply_and_interrupt', () async {
    final dir = Directory(Platform.environment['PERCH_LIVE_DIR'] ?? Directory.systemTemp.createTempSync('perch_live_').path)
      ..createSync(recursive: true);
    final s = ClaudeSession(launcher: ClaudeLauncher.fromEnvironment(), cwd: dir.path, model: 'haiku');
    final events = <ConversationEvent>[];
    final raw = <ParsedLine>[];
    s.lines.listen((l) {
      raw.add(l);
      if (l is ParsedEvents) events.addAll(l.events);
    });
    try {
      await s.start('Reply with the single word: alive');
      await waitForState(s, SessionState.idle, timeout: const Duration(seconds: 90));
      print('reply: ${events.whereType<AssistantText>().map((e) => e.text).join(' | ')}');
      expect(events.whereType<AssistantText>().any((e) => e.text.toLowerCase().contains('alive')), isTrue);

      final before = events.whereType<TurnEnded>().length;
      s.sendUser('Count slowly from 1 to 200, one number per line.');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final sentAt = DateTime.now();
      s.interrupt();
      await waitUntil(() => events.whereType<TurnEnded>().length > before, timeout: const Duration(seconds: 15));
      await waitForState(s, SessionState.idle, timeout: const Duration(seconds: 15));
      final t = events.whereType<TurnEnded>().last;
      print('second turn ended after interrupt in ${DateTime.now().difference(sentAt).inMilliseconds} ms: '
          'isError=${t.isError} text=${t.text}');
    } finally {
      await s.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
