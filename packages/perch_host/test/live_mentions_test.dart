@Tags(['live'])
library;

import 'dart:io';

import 'package:perch_host/src/claude_session.dart';
import 'package:perch_host/src/console_typer.dart';
import 'package:perch_host/src/file_index.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/stream_parser.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

// Live check of `@` mentions. PERCH_LIVE_CWD holds notes.txt ("The code word is MARIGOLD.")
// and sub/inner.txt ("The second code word is OBSIDIAN."); before running, open a terminal
// there (session markers cleared) with
//   claude --model haiku --permission-mode plan --setting-sources project,local
// and leave it idle with no turn yet (a later run counts the earlier reply). Then: dart test -P live -t live test/live_mentions_test.dart
// The test lists the folder as the phone's @ list does, has Perch type a message naming both
// files with @, and expects Claude Code to attach them: the reply has both words and Claude
// read no file with a tool.
void main() {
  test('live_at_mentions_are_resolved_by_claude_code', () async {
    final cwd = Platform.environment['PERCH_LIVE_CWD'];
    if (cwd == null) fail('Set PERCH_LIVE_CWD to the terminal session folder');
    final list = await FileIndex().search(cwd, 'no');
    print('@no lists: ${list.files.map((f) => f.mention).toList()}');
    expect(list.files.first.mention, '@notes.txt');
    final inner = await FileIndex().search(cwd, 'sub/');
    expect(inner.files.map((f) => f.mention), contains('@sub/inner.txt'));

    final m = SessionManager(launcher: ClaudeLauncher.fromEnvironment(), typer: defaultTerminalConsole());
    try {
      final norm = cwd.toLowerCase().replaceAll('/', '\\');
      SessionSummary? target;
      await waitUntil(() async {
        final all = await m.list();
        target = all.where((s) => s.origin == SessionOrigin.external && s.cwd.toLowerCase().replaceAll('/', '\\') == norm).firstOrNull;
        return target != null;
      }, timeout: const Duration(seconds: 30));
      final id = target!.id;
      print('found $id state=${target!.state}');
      final before = m.history(id).events.whereType<AssistantText>().length;
      await m.send(id, 'Reply with the two code words from @notes.txt and @sub/inner.txt only, nothing else.');
      await waitUntil(() => m.history(id).events.whereType<AssistantText>().length > before,
          timeout: const Duration(seconds: 120));
      final events = m.history(id).events;
      print('user: ${events.whereType<UserMessage>().map((e) => e.text).last}');
      final reply = events.whereType<AssistantText>().map((e) => e.text).last;
      print('reply: $reply');
      print('tool calls: ${events.whereType<ToolCall>().map((t) => '${t.name} ${t.input}').toList()}');
      expect(reply.toUpperCase(), allOf(contains('MARIGOLD'), contains('OBSIDIAN')));
      expect(events.whereType<ToolCall>().where((t) => t.name == 'Read'), isEmpty,
          reason: 'Claude Code attached the files itself');
    } finally {
      await m.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  // A session Perch runs itself (started from the phone): the message goes in as stream-json.
  test('live_at_mentions_in_a_perch_run_session', () async {
    final cwd = Platform.environment['PERCH_LIVE_CWD'];
    if (cwd == null) fail('Set PERCH_LIVE_CWD to the folder with notes.txt');
    final s = ClaudeSession(launcher: ClaudeLauncher.fromEnvironment(), cwd: cwd, model: 'haiku', permissionMode: 'plan');
    final events = <ConversationEvent>[];
    s.lines.listen((l) {
      if (l is ParsedEvents) events.addAll(l.events);
    });
    try {
      await s.start('Reply with the code word from @notes.txt only, nothing else.');
      await waitForState(s, SessionState.idle, timeout: const Duration(seconds: 120));
      final reply = events.whereType<AssistantText>().map((e) => e.text).join(' ');
      print('reply: $reply; tool calls: ${events.whereType<ToolCall>().map((t) => t.name).toList()}');
      expect(reply.toUpperCase(), contains('MARIGOLD'));
      expect(events.whereType<ToolCall>().where((t) => t.name == 'Read'), isEmpty);
    } finally {
      await s.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
