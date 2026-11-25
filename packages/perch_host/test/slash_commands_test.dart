// The composer's list of slash commands: Claude Code's own, the owner's and the project's
// commands and skills, and enabled plugins' (with the descriptions in their front matter).
// Everything is read from a scratch config folder made here, never the owner's.
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/slash_commands.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

final sep = Platform.pathSeparator;

void write(String path, String text) => File(path)
  ..parent.createSync(recursive: true)
  ..writeAsStringSync(text);

void main() {
  late Directory tmp;
  late String config;
  late String project;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_cmds_');
    config = '${tmp.path}${sep}config';
    project = '${tmp.path}${sep}work${sep}app';
    Directory(project).createSync(recursive: true);
    write('$config${sep}commands${sep}standup.md', '---\ndescription: Write my standup notes\n---\nSummarise yesterday.');
    write('$config${sep}skills${sep}tidy${sep}SKILL.md', '---\nname: tidy\ndescription: "Tidy the imports"\n---\n# Tidy');
    write('$config${sep}skills${sep}hidden${sep}SKILL.md', '---\nname: hidden\nuser-invocable: false\n---\n');
    write('$project$sep.claude${sep}commands${sep}deploy.md', '# Deploy the app to staging\nSteps…');
    write('${tmp.path}${sep}work$sep.claude${sep}skills${sep}lint${sep}SKILL.md', '---\ndescription: |\n  Lint everything\n  carefully\n---\n');
    final plugin = '${tmp.path}${sep}plug';
    write('$plugin${sep}skills${sep}brainstorming${sep}SKILL.md', '---\nname: brainstorming\ndescription: Before creative work\n---\n');
    write('${tmp.path}${sep}off${sep}commands${sep}nope.md', 'no');
    write('$config${sep}plugins${sep}installed_plugins.json', jsonEncode({
      'version': 2,
      'plugins': {
        'superpowers@market': [
          {'scope': 'user', 'installPath': plugin}
        ],
        'disabled@market': [
          {'scope': 'user', 'installPath': '${tmp.path}${sep}off'}
        ],
      }
    }));
    write('$config${sep}settings.json', jsonEncode({
      'enabledPlugins': {'superpowers@market': true, 'disabled@market': false}
    }));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('built-ins, the owner\'s, the project\'s (and its parents\'), enabled plugins\'', () {
    final list = SlashCommandCatalog(configDir: () => config).commandsFor(project);
    SlashCommandInfo of(String n) => list.firstWhere((c) => c.name == n);
    expect(of('/context').source, 'built-in');
    expect(of('/context').description, isNotEmpty);
    expect(of('/standup').description, 'Write my standup notes');
    expect(of('/standup').source, 'user');
    expect(of('/tidy').description, 'Tidy the imports');
    expect(list.where((c) => c.name == '/hidden'), isEmpty, reason: 'not user-invocable');
    expect(of('/deploy').description, 'Deploy the app to staging', reason: 'the first line when there is no front matter');
    expect(of('/deploy').source, 'project');
    expect(of('/lint').description, 'Lint everything carefully', reason: 'a parent folder of the project, a block value');
    expect(of('/superpowers:brainstorming').description, 'Before creative work');
    expect(list.where((c) => c.name.contains('nope')), isEmpty, reason: 'a disabled plugin');
    expect(list.map((c) => c.name).toSet(), hasLength(list.length), reason: 'no duplicates');
  });

  test('cached per folder for a while', () {
    final cat = SlashCommandCatalog(configDir: () => config, life: const Duration(hours: 1));
    expect(cat.commandsFor(project).any((c) => c.name == '/later'), isFalse);
    write('$config${sep}commands${sep}later.md', 'x');
    expect(cat.commandsFor(project).any((c) => c.name == '/later'), isFalse);
    expect(SlashCommandCatalog(configDir: () => config).commandsFor(project).any((c) => c.name == '/later'), isTrue);
  });

  test('front matter', () {
    expect(frontMatter('---\ndescription: x\n---\n', 'description'), 'x');
    expect(frontMatter("---\r\ndescription: 'quoted'\r\n---\r\n", 'description'), 'quoted');
    expect(frontMatter('no front matter\ndescription: x', 'description'), isNull);
  });
}
