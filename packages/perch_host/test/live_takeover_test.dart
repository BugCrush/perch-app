@Tags(['live'])
library;

import 'dart:io';

import 'package:perch_host/src/claude_session.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

// Live check for Task 4b (Windows). Before running, open a terminal in PERCH_LIVE_CWD with
//   claude --model haiku "Remember the word pineapple."
// and let it answer. Then: dart test -P live -t live test/live_takeover_test.dart
// The test takes the session over, asks for the word, then opens a new terminal window running
// `claude --resume <id> --model haiku` and expects the host to hand the session back.
void main() {
  test('live_take_over_and_hand_back', () async {
    final cwd = Platform.environment['PERCH_LIVE_CWD'];
    if (cwd == null) fail('Set PERCH_LIVE_CWD to the terminal session folder');
    final m = SessionManager(launcher: ClaudeLauncher.fromEnvironment());
    try {
      final all = await m.list();
      final norm = cwd.toLowerCase().replaceAll('/', '\\');
      final target = all.firstWhere(
          (s) => s.origin == SessionOrigin.external && s.cwd.toLowerCase().replaceAll('/', '\\') == norm,
          orElse: () => throw StateError('No terminal session in $cwd: ${all.map((s) => '${s.id} ${s.cwd}').toList()}'));
      print('found ${target.id} state=${target.state} name=${target.name}');
      final before = m.history(target.id).events;
      print('transcript events before take-over: ${before.length}');

      await m.takeOver(target.id);
      await m.send(target.id, 'Which word did I ask you to remember? Reply with one word.');
      await waitUntil(() => m.history(target.id).events.whereType<TurnEnded>().length >
              before.whereType<TurnEnded>().length,
          timeout: const Duration(seconds: 120));
      final replies = m.history(target.id).events.whereType<AssistantText>().map((e) => e.text).toList();
      print('reply: ${replies.last}');
      expect(replies.last.toLowerCase(), contains('pineapple'));

      // Hand back: resume in a new terminal window.
      final claudeId = m.claudeSessionIdOf(target.id)!;
      await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "foreach (\$n in '${ClaudeLauncher.inheritedSessionMarkers.join("','")}') { Remove-Item \"Env:\$n\" -ErrorAction SilentlyContinue }; "
            "Start-Process cmd.exe -WorkingDirectory '$cwd' -ArgumentList '/k','claude --resume $claudeId --model haiku'"
      ]);
      final t0 = DateTime.now();
      await waitUntil(() async {
        final s = (await m.list()).firstWhere((s) => s.id == target.id);
        return s.origin == SessionOrigin.external;
      }, timeout: const Duration(seconds: 60));
      print('handed back after ${DateTime.now().difference(t0).inSeconds} s');
      expect(m.history(target.id).events.whereType<Notice>().last.text, 'Continued in the terminal.');
    } finally {
      await m.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
