// Slash commands in the conversation and the composer's list of them.
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('command events round trip', () {
    for (final e in <ConversationEvent>[
      SlashCommand('/model', 'haiku', seq: 3, atMs: 4),
      CommandOutput('| a | b |', seq: 5),
      CommandOutput('Unknown command', isError: true, seq: 6),
    ]) {
      final back = ConversationEvent.tryFromJson(e.toJson())!;
      expect(back.toJson(), e.toJson());
    }
    expect(SlashCommand('/model', ' haiku ').line, '/model haiku');
    expect(SlashCommand('/context', '').line, '/context');
  });

  test('the list matches by name first, then by description', () {
    const all = [
      SlashCommandInfo(name: '/context', description: 'Show current context usage'),
      SlashCommandInfo(name: '/compact', description: 'Free up context by summarizing'),
      SlashCommandInfo(name: '/config', description: 'Open settings'),
      SlashCommandInfo(name: '/superpowers:brainstorming', description: 'Before creative work', source: 'superpowers'),
      SlashCommandInfo(name: '/clear', description: 'Start a new session'),
    ];
    expect(matchCommands(all, '/co').map((c) => c.name), ['/compact', '/config', '/context']);
    expect(matchCommands(all, '/cont').first.name, '/context');
    expect(matchCommands(all, '/brain').single.name, '/superpowers:brainstorming');
    expect(matchCommands(all, '/settings').single.name, '/config', reason: 'by description');
    expect(matchCommands(all, '/'), hasLength(5));
    expect(matchCommands(all, 'co'), isEmpty);
  });

  test('wire', () {
    final c = decodeClient(encodeClient(const ListCommands(sessionId: 's1')))!;
    expect(c.toJson(), const ListCommands(sessionId: 's1').toJson());
    const m = CommandsMessage(sessionId: 's1', commands: [
      SlashCommandInfo(name: '/context', description: 'Show current context usage', argumentHint: '[all]'),
      SlashCommandInfo(name: '/deploy', description: 'Ship it', source: 'project'),
    ]);
    expect(decodeHost(encodeHost(m))!.toJson(), m.toJson());
  });
}
