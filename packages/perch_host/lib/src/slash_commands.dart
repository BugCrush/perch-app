// The slash commands a session can run, for the composer's list on the phone: Claude Code's
// own (a list kept here for the installed version: Claude Code has no way to print them
// without starting a model turn) and the owner's, the project's and installed plugins'
// commands and skills, read from their files with the descriptions in their front matter.
import 'dart:convert';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

import 'transcript.dart' show claudeConfigDir;

/// Claude Code's own commands (2.1.331: /claude-approvals, /passes, /privacy-settings, /send-to-project, /ship,
/// /steward and /web-setup added, /clear, /design-sync, /tasks and /teleport reworded, read on Windows on 2026-11-25;
/// 2.1.328: /deep-research and /ultrareview added and /code-review reworded, read on
/// Windows on 2026-11-19 the same way; 2.1.327 had the same set as 2.1.326; names and descriptions as its `/` list shows them,
/// read on the Mac on 2026-11-18 by scrolling that list in a test session; Claude Code's
/// bundled skills included, the owner's skills and plugins found separately below).
const builtinCommands = <SlashCommandInfo>[
  SlashCommandInfo(name: '/add-dir', description: 'Add a working directory', argumentHint: '<path>'),
  SlashCommandInfo(name: '/advisor', description: 'Let Claude consult a stronger model at key moments'),
  SlashCommandInfo(name: '/artifact-capabilities', description: 'Runtime capabilities for published Artifacts'),
  SlashCommandInfo(name: '/artifact-diagramming', description: 'Diagramming guidance for Artifacts'),
  SlashCommandInfo(name: '/artifacts', description: 'Browse your published and shared artifacts'),
  SlashCommandInfo(name: '/auto-mode-setup', description: 'Teach auto mode about your environment'),
  SlashCommandInfo(name: '/autocompact', description: 'Set how full the context gets before auto-summarizing'),
  SlashCommandInfo(name: '/autofix-pr', description: 'Monitor and autofix any issues with the current PR'),
  SlashCommandInfo(name: '/background', description: 'Send this session to the background and free the terminal'),
  SlashCommandInfo(name: '/batch', description: 'Plan a large change; background agents each open a PR'),
  SlashCommandInfo(name: '/branch', description: 'Create a branch of the current conversation at this point', argumentHint: '[name]'),
  SlashCommandInfo(name: '/btw', description: 'Ask a side question without interrupting Claude', argumentHint: '[question]'),
  SlashCommandInfo(name: '/bug', description: 'Report a bug or share your session'),
  SlashCommandInfo(name: '/cd', description: 'Move this session to a new working directory'),
  SlashCommandInfo(name: '/chrome', description: 'Open Claude in Chrome settings'),
  SlashCommandInfo(name: '/claude-api', description: 'Build and debug apps that use the Claude API'),
  SlashCommandInfo(name: '/claude-approvals', description: 'Edit, explain, or tune a Claude Approvals policy file or classifier'),
  SlashCommandInfo(name: '/claude-in-chrome', description: 'Let Claude browse and interact with pages in your Chrome'),
  SlashCommandInfo(name: '/clear', description: 'Start a new session with empty context; loops carry over, and the old one stays in /resume'),
  SlashCommandInfo(name: '/code-review', description: 'Review the current diff or a PR for bugs'),
  SlashCommandInfo(name: '/color', description: 'Set the prompt bar color for this session'),
  SlashCommandInfo(name: '/compact', description: 'Free up context by summarizing the conversation so far', argumentHint: '<optional custom summarization instructions>'),
  SlashCommandInfo(name: '/config', description: 'Open settings'),
  SlashCommandInfo(name: '/context', description: 'Show what fills the context', argumentHint: '[all]'),
  SlashCommandInfo(name: '/copy', description: 'Copy the last response to clipboard (/copy 2 for the one before)'),
  SlashCommandInfo(name: '/dataviz', description: 'Chart and dashboard design guidance'),
  SlashCommandInfo(name: '/debug', description: 'Turn on debug logging and investigate problems'),
  SlashCommandInfo(name: '/deep-research', description: 'Deep research harness: fan-out web searches, fetch sources'),
  SlashCommandInfo(name: '/design', description: 'Make a new Design artifact from a brief'),
  SlashCommandInfo(name: '/design-login', description: 'Authorize design-system access for /design-sync with your claude.ai account'),
  SlashCommandInfo(name: '/design-sync', description: 'Sync your design system to Claude Design'),
  SlashCommandInfo(name: '/desktop', description: 'Continue the current session in Claude Desktop'),
  SlashCommandInfo(name: '/diff', description: 'Toggle the diff panel showing uncommitted changes'),
  SlashCommandInfo(name: '/doctor', description: 'Health-check your setup and fix issues: installation, unused extensions, duplicated or bloated memory files, slow hooks, updates, permissions'),
  SlashCommandInfo(name: '/effort', description: 'Set the model\'s effort level'),
  SlashCommandInfo(name: '/exit', description: 'Exit the CLI'),
  SlashCommandInfo(name: '/export', description: 'Export this session to a file or clipboard'),
  SlashCommandInfo(name: '/fast', description: 'Toggle fast mode (Opus 5.5)'),
  SlashCommandInfo(name: '/feedback', description: 'Send feedback to Anthropic or report a bug'),
  SlashCommandInfo(name: '/fewer-permission-prompts', description: 'Pre-approve safe read-only commands based on your usage'),
  SlashCommandInfo(name: '/focus', description: 'Toggle focus view: just your prompt, summary, and response'),
  SlashCommandInfo(name: '/fork', description: 'Copy this conversation into a new background session and keep working here'),
  SlashCommandInfo(name: '/goal', description: 'Set a goal Claude checks before stopping', argumentHint: '[<condition> | clear]'),
  SlashCommandInfo(name: '/help', description: 'Show help and available commands'),
  SlashCommandInfo(name: '/hooks', description: 'View hook configurations for tool events'),
  SlashCommandInfo(name: '/ide', description: 'Manage IDE integrations and show status'),
  SlashCommandInfo(name: '/import', description: 'Import config from another AI coding agent'),
  SlashCommandInfo(name: '/init', description: 'Initialize a new CLAUDE.md file with codebase documentation'),
  SlashCommandInfo(name: '/insights', description: 'Generate a report analyzing your Claude Code sessions'),
  SlashCommandInfo(name: '/install-github-app', description: 'Set up Claude GitHub Actions for a repository'),
  SlashCommandInfo(name: '/install-slack-app', description: 'Install the Claude Slack app'),
  SlashCommandInfo(name: '/keybindings', description: 'Open your keyboard shortcuts file'),
  SlashCommandInfo(name: '/list-agents', description: 'List subagents, teammates, and other Claude sessions you can message'),
  SlashCommandInfo(name: '/login', description: 'Sign in with your Anthropic account'),
  SlashCommandInfo(name: '/logout', description: 'Sign out from your Anthropic account'),
  SlashCommandInfo(name: '/loop', description: 'Repeat a prompt or command on an interval (e.g. /loop 5m /foo)'),
  SlashCommandInfo(name: '/mcp', description: 'Manage MCP servers'),
  SlashCommandInfo(name: '/memory', description: 'Edit CLAUDE.md files and memory settings'),
  SlashCommandInfo(name: '/mobile', description: 'Show QR code to download the Claude mobile app'),
  SlashCommandInfo(name: '/model', description: 'Switch model', argumentHint: '[model]'),
  SlashCommandInfo(name: '/output-style', description: 'List output styles or switch to one'),
  SlashCommandInfo(name: '/passes', description: 'Share a free week of Claude Code with friends and earn usage credits'),
  SlashCommandInfo(name: '/permissions', description: 'Manage allow and deny tool permission rules'),
  SlashCommandInfo(name: '/plan', description: 'Turn on plan mode or view the plan'),
  SlashCommandInfo(name: '/plugin', description: 'Manage Claude Code plugins'),
  SlashCommandInfo(name: '/plugin-authoring', description: 'Write a mod: a live pane, view or behaviour change in Claude Code'),
  SlashCommandInfo(name: '/powerup', description: 'Learn Claude Code features in short lessons'),
  SlashCommandInfo(name: '/privacy-settings', description: 'View and update your privacy settings'),
  SlashCommandInfo(name: '/radio', description: 'Listen to Claude FM lo-fi radio'),
  SlashCommandInfo(name: '/rate-limit-options', description: 'Manage usage limits and upgrade options'),
  SlashCommandInfo(name: '/recap', description: 'Generate a one-line session recap now'),
  SlashCommandInfo(name: '/release-notes', description: 'View release notes'),
  SlashCommandInfo(name: '/reload-plugins', description: 'Activate pending plugin changes in the current session'),
  SlashCommandInfo(name: '/reload-skills', description: 'Pick up skills added or changed on disk during this session'),
  SlashCommandInfo(name: '/remote-control', description: 'Control this session from your phone or claude.ai/code'),
  SlashCommandInfo(name: '/remote-env', description: 'Choose the default environment for cloud agents'),
  SlashCommandInfo(name: '/rename', description: 'Rename the current conversation', argumentHint: '[name]'),
  SlashCommandInfo(name: '/resume', description: 'Resume a previous session'),
  SlashCommandInfo(name: '/rewind', description: 'Restore earlier code, conversation, or both'),
  SlashCommandInfo(name: '/run', description: 'Launch this project’s app to see your change working'),
  SlashCommandInfo(name: '/run-skill-generator', description: 'Create a skill that knows how to run this project’s app'),
  SlashCommandInfo(name: '/sandbox', description: '◯ sandbox disabled (⏎ to configure)'),
  SlashCommandInfo(name: '/schedule', description: 'Create and manage routines: cloud agents on a schedule'),
  SlashCommandInfo(name: '/security-review', description: 'Complete a security review of the pending changes on the current branch'),
  SlashCommandInfo(name: '/send-to-project', description: "Send this session's work to a Claude Project"),
  SlashCommandInfo(name: '/ship', description: 'Open a pull request if there is none, review it here, then watch it'),
  SlashCommandInfo(name: '/simplify', description: 'Clean up the changed code without changing behavior'),
  SlashCommandInfo(name: '/skill-doctor', description: 'Show which loaded skills are unused and costing context'),
  SlashCommandInfo(name: '/skills', description: 'List available skills'),
  SlashCommandInfo(name: '/slides', description: 'Make a new Slides deck artifact from a brief'),
  SlashCommandInfo(name: '/status', description: 'Show version, account, model, MCP servers, and setup warnings'),
  SlashCommandInfo(name: '/statusline', description: 'Set up the status line'),
  SlashCommandInfo(name: '/steward', description: 'Watch your open pull request in this session and fix what comes up'),
  SlashCommandInfo(name: '/stickers', description: 'Check Claude Code sticker availability'),
  SlashCommandInfo(name: '/subtask', description: 'Send a subagent off with your full context; its result comes back here'),
  SlashCommandInfo(name: '/tasks', description: "View and manage this session's background work"),
  SlashCommandInfo(name: '/team-onboarding', description: 'Help teammates ramp on Claude Code with a guide from your usage'),
  SlashCommandInfo(name: '/teleport', description: 'Resume a cloud session here'),
  SlashCommandInfo(name: '/terminal-setup', description: 'Set up Shift+Enter for newlines'),
  SlashCommandInfo(name: '/theme', description: 'Change the theme'),
  SlashCommandInfo(name: '/tui', description: 'Set the terminal UI renderer (classic | fullscreen)'),
  SlashCommandInfo(name: '/ultrareview', description: 'Start a cloud agent that finds and verifies bugs in your branch'),
  SlashCommandInfo(name: '/update-config', description: 'Change settings: hooks, permissions, environment variables'),
  SlashCommandInfo(name: '/upgrade', description: 'Upgrade your plan for higher rate limits and more Opus'),
  SlashCommandInfo(name: '/usage', description: 'Show session cost, plan usage, and activity stats'),
  SlashCommandInfo(name: '/usage-credits', description: 'Configure usage credits or request them from your admin when you hit a limit'),
  SlashCommandInfo(name: '/verify', description: 'Try your change and report if it works'),
  SlashCommandInfo(name: '/voice', description: 'Toggle voice mode'),
  SlashCommandInfo(name: '/web-setup', description: 'Set up cloud sessions with your GitHub account'),
  SlashCommandInfo(name: '/whiteboard', description: 'Make a new Whiteboard artifact from a brief'),
  SlashCommandInfo(name: '/workflow-authoring', description: 'Load the reference for writing Workflow tool scripts'),
  SlashCommandInfo(name: '/workflows', description: 'Browse running and completed workflows'),
];

/// Perch's own command: in a terminal (`perch_host commands install`) it opens the Perch
/// menu; picked in the app it opens the app's board for the session's project instead.
const perchCommand = SlashCommandInfo(
    name: '/perch', description: "Perch task board for this session's project", source: 'perch');

/// The value of [key] in [md]'s front matter (`---` … `---`), unquoted; null when absent.
String? frontMatter(String md, String key) {
  final lines = const LineSplitter().convert(md.replaceAll('\r', ''));
  if (lines.isEmpty || lines.first.trim() != '---') return null;
  for (var i = 1; i < lines.length; i++) {
    final l = lines[i];
    if (l.trim() == '---') return null;
    final m = RegExp('^${RegExp.escape(key)}\\s*:\\s*(.*)\$').firstMatch(l);
    if (m == null) continue;
    var v = m.group(1)!.trim();
    if (v.length >= 2 && (v[0] == '"' || v[0] == "'") && v[v.length - 1] == v[0]) v = v.substring(1, v.length - 1);
    if (v == '|' || v == '>' || v == '>-' || v == '|-') {
      // A block: the indented lines under it.
      final block = <String>[];
      for (var j = i + 1; j < lines.length && (lines[j].startsWith(' ') || lines[j].startsWith('\t')); j++) {
        block.add(lines[j].trim());
      }
      v = block.join(' ');
    }
    return v.isEmpty ? null : v;
  }
  return null;
}

/// The first line of [md]'s body (after its front matter), headings unmarked.
String _firstLine(String md) {
  var lines = const LineSplitter().convert(md.replaceAll('\r', ''));
  if (lines.isNotEmpty && lines.first.trim() == '---') {
    final end = lines.indexWhere((l) => l.trim() == '---', 1);
    lines = end < 0 ? const [] : lines.sublist(end + 1);
  }
  for (final l in lines) {
    final t = l.trim().replaceFirst(RegExp(r'^#+\s*'), '');
    if (t.isNotEmpty) return t.length > 160 ? '${t.substring(0, 159)}…' : t;
  }
  return '';
}

String _short(String s) => s.length > 200 ? '${s.substring(0, 199)}…' : s;

/// The commands in a `commands` folder: `name.md` (in subfolders too) is `/name`;
/// [prefix] (a plugin's name) makes it `/prefix:name`.
List<SlashCommandInfo> commandsIn(Directory dir, {required String source, String? prefix}) {
  final out = <SlashCommandInfo>[];
  if (!dir.existsSync()) return out;
  try {
    for (final f in dir.listSync(recursive: true, followLinks: false)) {
      if (f is! File || !f.path.toLowerCase().endsWith('.md')) continue;
      final base = f.uri.pathSegments.last;
      final name = base.substring(0, base.length - 3);
      if (name.isEmpty) continue;
      String md;
      try {
        md = f.readAsStringSync();
      } catch (_) {
        continue;
      }
      out.add(SlashCommandInfo(
        name: '/${prefix == null ? '' : '$prefix:'}$name',
        description: _short(frontMatter(md, 'description') ?? _firstLine(md)),
        argumentHint: frontMatter(md, 'argument-hint') ?? '',
        source: source,
      ));
    }
  } catch (_) {}
  return out;
}

/// The skills in a `skills` folder: `<name>/SKILL.md` is `/name` (its front matter's name
/// when it has one); [prefix] as for [commandsIn].
List<SlashCommandInfo> skillsIn(Directory dir, {required String source, String? prefix}) {
  final out = <SlashCommandInfo>[];
  if (!dir.existsSync()) return out;
  try {
    for (final d in dir.listSync(followLinks: false)) {
      if (d is! Directory) continue;
      final f = File('${d.path}${Platform.pathSeparator}SKILL.md');
      if (!f.existsSync()) continue;
      String md;
      try {
        md = f.readAsStringSync();
      } catch (_) {
        continue;
      }
      if (frontMatter(md, 'user-invocable') == 'false') continue;
      final name = frontMatter(md, 'name') ?? d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      out.add(SlashCommandInfo(
        name: '/${prefix == null ? '' : '$prefix:'}$name',
        description: _short(frontMatter(md, 'description') ?? _firstLine(md)),
        argumentHint: frontMatter(md, 'argument-hint') ?? '',
        source: source,
      ));
    }
  } catch (_) {}
  return out;
}

/// Reads and caches (per folder, for [life]) the commands a session in a folder can run.
class SlashCommandCatalog {
  final String Function() configDir;
  final Duration life;
  SlashCommandCatalog({String Function()? configDir, this.life = const Duration(minutes: 1)})
      : configDir = configDir ?? claudeConfigDir;

  final Map<String, ({DateTime at, List<SlashCommandInfo> commands})> _cache = {};

  List<SlashCommandInfo> commandsFor(String cwd) {
    final key = cwd.toLowerCase();
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.at) < life) return hit.commands;
    final commands = _read(cwd);
    _cache[key] = (at: DateTime.now(), commands: commands);
    return commands;
  }

  List<SlashCommandInfo> _read(String cwd) {
    final sep = Platform.pathSeparator;
    final config = configDir();
    final found = <SlashCommandInfo>[];
    // The project's own, from the folder up (the nearest wins).
    if (cwd.isNotEmpty) {
      var dir = Directory(cwd);
      for (var i = 0; i < 12; i++) {
        final dotClaude = '${dir.path}$sep.claude';
        if (Directory(dotClaude).existsSync() && dotClaude.toLowerCase() != config.toLowerCase()) {
          found
            ..addAll(commandsIn(Directory('$dotClaude${sep}commands'), source: 'project'))
            ..addAll(skillsIn(Directory('$dotClaude${sep}skills'), source: 'project'));
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    // The owner's.
    found
      ..addAll(commandsIn(Directory('$config${sep}commands'), source: 'user'))
      ..addAll(skillsIn(Directory('$config${sep}skills'), source: 'user'));
    // Skills synced from claude.ai (anthropic-skills:…).
    try {
      final synced = Directory('$config${sep}skills${sep}synced');
      if (synced.existsSync()) {
        for (final d in synced.listSync(followLinks: false)) {
          if (d is Directory && !d.uri.pathSegments.where((s) => s.isNotEmpty).last.startsWith('.')) {
            found.addAll(skillsIn(d, source: 'claude.ai', prefix: 'anthropic-skills'));
          }
        }
      }
    } catch (_) {}
    // Installed, enabled plugins.
    found.addAll(_plugins(config));
    final byName = <String, SlashCommandInfo>{};
    for (final c in [perchCommand, ...found, ...builtinCommands]) {
      byName.putIfAbsent(c.name.toLowerCase(), () => c);
    }
    return byName.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  List<SlashCommandInfo> _plugins(String config) {
    final sep = Platform.pathSeparator;
    final out = <SlashCommandInfo>[];
    try {
      final installed = jsonDecode(File('$config${sep}plugins${sep}installed_plugins.json').readAsStringSync());
      Map<dynamic, dynamic> enabled = const {};
      try {
        final s = jsonDecode(File('$config${sep}settings.json').readAsStringSync());
        if (s is Map && s['enabledPlugins'] is Map) enabled = s['enabledPlugins'] as Map;
      } catch (_) {}
      final plugins = installed is Map ? installed['plugins'] : null;
      if (plugins is! Map) return out;
      for (final e in plugins.entries) {
        final id = '${e.key}';
        if (enabled[id] != true) continue;
        final entries = e.value is List ? e.value as List : [e.value];
        final path = entries.whereType<Map>().map((m) => m['installPath']).whereType<String>().firstOrNull;
        if (path == null) continue;
        final name = id.split('@').first;
        out
          ..addAll(commandsIn(Directory('$path${sep}commands'), source: name, prefix: name))
          ..addAll(skillsIn(Directory('$path${sep}skills'), source: name, prefix: name));
      }
    } catch (_) {}
    return out;
  }
}
