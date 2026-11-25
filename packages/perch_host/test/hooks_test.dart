import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/hooks.dart';
import 'package:test/test.dart';

final sep = Platform.pathSeparator;

/// A settings file that already has the owner's own hooks and other keys.
const existing = '''
{
  "model": "opus",
  "permissions": {"allow": ["Bash(git status)"], "defaultMode": "auto"},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "echo mine"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "say done", "timeout": 3}]}
    ]
  },
  "statusLine": {"type": "command", "command": "status.sh"}
}
''';

void main() {
  late Directory config;
  late HookInstaller installer;
  File settings() => File('${config.path}${sep}settings.json');
  Map<String, dynamic> read() => jsonDecode(settings().readAsStringSync()) as Map<String, dynamic>;

  setUp(() {
    config = Directory.systemTemp.createTempSync('perch_hooks_');
    installer = HookInstaller(configDir: config.path);
  });

  tearDown(() {
    try {
      config.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the_command_posts_stdin_quietly_and_always_succeeds', () {
    final c = perchHookCommand(8787);
    expect(c, contains('curl -s -m 2 -o /dev/null -X POST'));
    expect(c, contains('--data-binary @-'));
    expect(c, contains('http://127.0.0.1:8787/hook'));
    expect(c, contains('>/dev/null 2>&1; exit 0'));
    expect(c, contains(perchHookTag));
    expect(hookPortOf(c), 8787);
    expect(hookPortOf('echo mine'), isNull);
  });

  test('entries_cover_every_event_async_with_a_short_timeout', () {
    final e = perchHookEntries(9000, stopChecks: false);
    expect(e.keys.toSet(), {
      'PreToolUse',
      'PermissionRequest',
      'PostToolUse',
      'Notification',
      'Stop',
      'UserPromptSubmit',
      'SubagentStart',
      'SubagentStop',
      'SessionStart',
      'SessionEnd',
      'StopFailure',
    });
    expect(e['PreToolUse']!['matcher'], 'AskUserQuestion|ExitPlanMode');
    expect(e['Stop']!.containsKey('matcher'), isFalse);
    final h = (e['Stop']!['hooks'] as List).single as Map;
    expect(h['type'], 'command');
    expect(h['async'], isTrue);
    expect(h['timeout'], lessThanOrEqualTo(5));
  });

  test('the_permission_request_hook_waits_for_the_phone_and_prints_its_answer', () {
    final c = perchWaitingHookCommand(8787);
    expect(c, contains('curl -sf -m ${perchHookHold.inSeconds + 30} -X POST'));
    expect(c, contains('--data-binary @-'));
    expect(c, contains('"http://127.0.0.1:8787/hook?wait=1"'));
    expect(c, isNot(contains('-o /dev/null')), reason: "the host's answer goes to Claude Code on stdout");
    expect(c, contains('2>/dev/null; exit 0'));
    expect(c, contains(perchHookTag));
    expect(hookPortOf(c), 8787);

    final h = (perchHookEntries(8787)['PermissionRequest']!['hooks'] as List).single as Map;
    expect(h['command'], c);
    expect(h.containsKey('async'), isFalse, reason: 'Claude Code reads its answer');
    expect(h['timeout'], greaterThan(perchHookHold.inSeconds + 30));
    expect(perchHookEntries(8787)['PermissionRequest']!.containsKey('matcher'), isFalse);
  });

  test('an_older_install_with_an_async_permission_hook_still_counts_but_says_to_reinstall', () {
    installer.install(port: 8787);
    expect(installer.status().waits, isTrue);
    final j = read();
    (j['hooks']['PermissionRequest'] as List).first['hooks'] = [
      {'type': 'command', 'command': perchHookCommand(8787), 'async': true, 'timeout': 5}
    ];
    settings().writeAsStringSync(jsonEncode(j));
    final st = installer.status();
    expect(st.state, HookState.installed);
    expect(st.waits, isFalse);
    expect(st.describe(), contains('hooks install'));
  });

  test('an_install_from_before_the_stop_failure_hook_still_counts_but_says_to_reinstall', () {
    installer.install(port: 8787);
    expect(installer.status().current, isTrue);
    final j = read();
    (j['hooks'] as Map).remove('StopFailure');
    settings().writeAsStringSync(jsonEncode(j));
    final st = installer.status();
    expect(st.state, HookState.installed, reason: 'the app must not say instant updates are off');
    expect(st.limits, isFalse);
    expect(st.current, isFalse);
    expect(st.describe(), contains('usage limits'));
  });

  test('stop_checks_ask_the_host_at_once_before_and_after_tools', () {
    final c = perchStopCheckCommand(8787);
    expect(c, contains('curl -sf --connect-timeout 1 -m 2 -X POST'));
    expect(c, contains('"http://127.0.0.1:8787/hook?check=1"'));
    expect(c, isNot(contains('-o /dev/null')), reason: "the host's answer goes to Claude Code on stdout");
    expect(c, contains('2>/dev/null; exit 0'));
    expect(hookPortOf(c), 8787);

    final e = perchHookEntries(8787, stopChecks: true);
    expect(e.keys.toSet(), {...perchHookEvents.keys, 'PostToolBatch'});
    for (final event in ['PreToolUse', 'PostToolBatch']) {
      expect(e[event]!.containsKey('matcher'), isFalse, reason: '$event: every tool');
      final h = (e[event]!['hooks'] as List).single as Map;
      expect(h['command'], c);
      expect(h.containsKey('async'), isFalse);
      expect(h['timeout'], lessThanOrEqualTo(5));
    }
    // Windows keeps the async question/plan hook and no stop checks.
    final w = perchHookEntries(8787, stopChecks: false);
    expect(w.containsKey('PostToolBatch'), isFalse);
    expect(w['PreToolUse']!['matcher'], 'AskUserQuestion|ExitPlanMode');
  });

  test('an_install_without_stop_checks_counts_but_says_to_reinstall_where_they_are_used', () {
    HookInstaller(configDir: config.path, stopChecks: false).install(port: 8787);
    final withChecks = HookInstaller(configDir: config.path, stopChecks: true);
    final st = withChecks.status();
    expect(st.state, HookState.installed);
    expect(st.waits, isTrue);
    expect(st.stops, isFalse);
    expect(st.current, isFalse);
    expect(st.describe(), contains('hooks install'));
    expect(HookInstaller(configDir: config.path, stopChecks: false).status().current, isTrue);
    withChecks.install(port: 8787);
    expect(withChecks.status().current, isTrue);
    withChecks.uninstall();
    expect(read(), <String, dynamic>{});
  });

  test('install_merges_keeps_everything_else_and_writes_a_backup', () {
    settings().writeAsStringSync(existing);
    expect(installer.status().state, HookState.notInstalled);
    installer.install(port: 8787);

    final backup = File('${config.path}${sep}settings.json.perch-backup');
    expect(backup.readAsStringSync(), existing);
    final j = read();
    expect(j['model'], 'opus');
    expect(j['permissions'], jsonDecode(existing)['permissions']);
    expect(j['statusLine'], jsonDecode(existing)['statusLine']);
    final pre = j['hooks']['PreToolUse'] as List;
    expect(pre.first, {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'echo mine'}]});
    expect(pre, hasLength(2));
    expect((j['hooks']['Stop'] as List).first, jsonDecode(existing)['hooks']['Stop'][0]);
    expect((j['hooks'] as Map).keys, containsAll(perchHookEntries(8787).keys));
    // 2-space indent.
    expect(settings().readAsStringSync(), contains('\n  "model": "opus"'));

    final st = installer.status();
    expect(st.state, HookState.installed);
    expect(st.port, 8787);
    expect(installer.status(port: 9999).state, HookState.otherPort);

    // Installing again (another port) replaces Perch's entries, never duplicates them.
    installer.install(port: 9999);
    final again = read();
    expect((again['hooks']['PreToolUse'] as List), hasLength(2));
    expect(installer.status(port: 9999).state, HookState.installed);
  });

  test('uninstall_removes_exactly_perch_entries', () {
    settings().writeAsStringSync(existing);
    installer.install(port: 8787);
    installer.uninstall();
    expect(read(), jsonDecode(existing));
    expect(installer.status().state, HookState.notInstalled);
  });

  test('install_without_a_settings_file_creates_one_and_uninstall_leaves_it_valid', () {
    installer.install(port: 8787);
    expect(installer.status().state, HookState.installed);
    expect(File('${config.path}${sep}settings.json.perch-backup').existsSync(), isFalse);
    installer.uninstall();
    expect(read(), <String, dynamic>{});
  });

  test('a_settings_file_that_is_not_json_is_left_alone', () {
    settings().writeAsStringSync('{ not json');
    expect(() => installer.install(port: 8787), throwsA(isA<HookSettingsError>()));
    expect(settings().readAsStringSync(), '{ not json');
    expect(installer.status().state, HookState.unreadable);
  });

  test('a_partly_installed_set_is_reported_as_not_installed', () {
    installer.install(port: 8787);
    final j = read();
    (j['hooks'] as Map).remove('Stop');
    settings().writeAsStringSync(jsonEncode(j));
    expect(installer.status().state, HookState.notInstalled);
  });

  test('config_dir_follows_claude_config_dir', () {
    expect(HookInstaller.fromEnvironment({'CLAUDE_CONFIG_DIR': r'X:\cfg'}).configDir, r'X:\cfg');
    expect(HookInstaller.fromEnvironment({'USERPROFILE': r'C:\Users\me', 'HOME': '/home/me'}).configDir,
        Platform.isWindows ? r'C:\Users\me\.claude' : '/home/me/.claude');
  });
}
