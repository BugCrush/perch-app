// Sessions on accounts: new sessions start on the machine's active account (or the one
// picked for the session), running sessions keep theirs, switching a session ends it and
// resumes its conversation under the other account's token, and the usage-limit card's
// Switch account moves the paused sessions and continues them. Fake claude, fake console,
// SYNTHETIC tokens.
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_accounts.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/terminal_window.dart';
import 'package:perch_host/src/token_vault.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'usage_limit_flow_test.dart' show fastTracker, promptScreen;

final sep = Platform.pathSeparator;
const cid = 'aaaaaaaa-1111-4000-8000-000000000001';
const tokenWork = 'sk-ant-oat01-SYNTHETIC-work-00000000000000000000000000000000000000000000';
const tokenHome = 'sk-ant-oat01-SYNTHETIC-home-00000000000000000000000000000000000000000000';

AccountInfo acc(String id, String label, {int? expiresAtMs}) =>
    AccountInfo(id: id, label: label, createdAtMs: 1, expiresAtMs: expiresAtMs);

void main() {
  late Directory tmp;
  late Directory work;
  late String config;
  late FakeExternalSessions external;
  late FakeConsoleTyper console;
  late List<TerminalLaunch> launches;
  late MemoryTokenVault vault;
  late HostAccounts accounts;
  late SessionManager manager;
  var nextPid = 9000;

  /// What a new window does: Claude Code lists a session for it.
  late void Function(TerminalLaunch) onLaunch;

  void transcript(String id) {
    final dir = Directory('$config${sep}projects${sep}D--work')..createSync(recursive: true);
    File('${dir.path}$sep$id.jsonl').writeAsStringSync('${jsonEncode({
          'type': 'user',
          'timestamp': DateTime.now().subtract(const Duration(minutes: 10)).toUtc().toIso8601String(),
          'message': {'role': 'user', 'content': 'Write the docs.'},
          'sessionId': id,
        })}\n');
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_accs_');
    work = Directory('${tmp.path}${sep}work')..createSync();
    config = '${tmp.path}${sep}config';
    external = FakeExternalSessions();
    console = FakeConsoleTyper(currentScreen: promptScreen);
    launches = [];
    nextPid = 9000;
    onLaunch = (l) {
      final resume = l.args.indexOf('--resume');
      external.entries.add(external.entry(
          pid: ++nextPid,
          sessionId: resume >= 0 ? l.args[resume + 1] : 'bbbbbbbb-1111-4000-8000-${'$nextPid'.padLeft(12, '0')}',
          cwd: work.path));
    };
    vault = MemoryTokenVault();
    accounts = HostAccounts(vault: vault, launcher: fakeLauncher());
    await accounts.sync([
      AccountWithToken(info: acc('work', 'Work'), token: tokenWork),
      AccountWithToken(info: acc('home', 'Home'), token: tokenHome),
    ]);
    manager = SessionManager(
      launcher: fakeLauncher(),
      external: external,
      typer: console,
      accounts: accounts,
      claudeConfigDir: config,
      openWindow: (l) async {
        launches.add(l);
        onLaunch(l);
      },
      terminalStartTimeout: const Duration(milliseconds: 800),
      terminalPoll: const Duration(milliseconds: 20),
      limitTracker: fastTracker,
    )..endTimeout = const Duration(milliseconds: 500);
  });

  tearDown(() async {
    await manager.dispose();
    await accounts.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('new sessions', () {
    test("start on the machine's own login until the owner switches: no token added", () async {
      final s = await manager.start(cwd: work.path, prompt: 'Say hi');
      expect(launches.single.environment[oauthTokenVariable], Platform.environment[oauthTokenVariable]);
      expect(s.accountId, machineLoginAccountId);
    });

    test("start on the machine's active account: its token in the new terminal's environment", () async {
      accounts.setActive('work');
      final s = await manager.start(cwd: work.path, prompt: 'Say hi');
      expect(launches.single.environment[oauthTokenVariable], tokenWork);
      expect(launches.single.args, isNot(contains(tokenWork)), reason: 'never on the command line');
      expect(s.accountId, 'work');
      expect(accounts.accountOf(s.id), 'work', reason: 'remembered by Claude Code session id');
      expect((await manager.list()).single.accountId, 'work');
    });

    test('a session picked for another account (per-session setting)', () async {
      accounts.setActive('work');
      final s = await manager.start(cwd: work.path, prompt: 'Say hi', accountId: 'home');
      expect(launches.single.environment[oauthTokenVariable], tokenHome);
      expect(s.accountId, 'home');
      expect(accounts.activeId, 'work', reason: 'the machine default is unchanged');
    });

    test('an unknown or expired account opens nothing', () async {
      await expectLater(manager.start(cwd: work.path, prompt: 'x', accountId: 'nope'), throwsA(isA<StateError>()));
      await accounts.sync([
        AccountWithToken(
            info: acc('old', 'Old', expiresAtMs: DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch),
            token: tokenWork)
      ]);
      await expectLater(manager.start(cwd: work.path, prompt: 'x', accountId: 'old'),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('expired'))));
      expect(launches, isEmpty);
    });

    test('a session Perch runs itself (no terminal) gets the token too', () async {
      console.supported = false;
      final envFile = File('${tmp.path}${sep}env.txt');
      final m = SessionManager(
          launcher: fakeLauncher(env: {'FAKE_CLAUDE_ENV_FILE': envFile.path}), external: FakeExternalSessions(), typer: console, accounts: accounts);
      try {
        accounts.setActive('home');
        final s = await m.start(cwd: work.path, prompt: 'echo hi');
        expect(s.accountId, 'home');
        await waitUntil(() => envFile.existsSync() && envFile.readAsStringSync().contains('TOKEN='));
        expect(envFile.readAsStringSync().trim(), 'TOKEN=$tokenHome');
      } finally {
        await m.dispose();
      }
    });

    test("sessions the owner started by typing claude show the machine's login", () async {
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      expect((await manager.list()).single.accountId, machineLoginAccountId);
    });

    test('running sessions keep their account when the machine switches', () async {
      accounts.setActive('work');
      final s = await manager.start(cwd: work.path, prompt: 'Say hi');
      accounts.setActive('home');
      expect((await manager.list()).firstWhere((x) => x.id == s.id).accountId, 'work');
      expect(launches, hasLength(1), reason: 'nothing restarted');
    });
  });

  group('switching a session', () {
    test('a running session is ended and its conversation resumed under the other token', () async {
      transcript(cid);
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      await manager.list();
      final s = await manager.switchAccount(cid, 'home');
      expect(external.kills, [4242]);
      final l = launches.single;
      expect(l.args.skip(l.args.length - 2), ['--resume', cid]);
      expect(l.environment[oauthTokenVariable], tokenHome);
      expect(s.id, cid);
      expect(s.live, isTrue);
      expect(s.accountId, 'home');
      expect((await manager.list()).single.accountId, 'home');
    });

    test("to the machine's own login: no token", () async {
      transcript(cid);
      accounts.setActive('work');
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      await manager.list();
      final s = await manager.switchAccount(cid, machineLoginAccountId);
      expect(launches.single.environment[oauthTokenVariable], Platform.environment[oauthTokenVariable]);
      expect(s.accountId, machineLoginAccountId);
    });

    test('an expired account: nothing is ended', () async {
      transcript(cid);
      await accounts.sync([
        AccountWithToken(
            info: acc('old', 'Old', expiresAtMs: DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch),
            token: tokenWork)
      ]);
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      await manager.list();
      await expectLater(manager.switchAccount(cid, 'old'), throwsA(isA<StateError>()));
      expect(external.kills, isEmpty);
      expect(launches, isEmpty);
    });

    test('a session without a saved conversation cannot move', () async {
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      await manager.list();
      await expectLater(manager.switchAccount(cid, 'home'), throwsA(isA<StateError>()));
      expect(external.kills, isEmpty);
    });

    test('resume keeps the account it ran on', () async {
      transcript(cid);
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      await manager.list();
      await manager.switchAccount(cid, 'home');
      // It ends; the owner resumes it from the menu later; the machine default is Work.
      accounts.setActive('work');
      external.entries.clear();
      await manager.list();
      await manager.resume(cid);
      expect(launches.last.environment[oauthTokenVariable], tokenHome);
    });
  });

  group('macOS Terminal.app window', () {
    test('the token is read from an owner-only file the shell deletes, never typed on its command line', () async {
      final l = TerminalLaunch(
          cwd: '/Users/someone/work', executable: 'claude', args: const ['-n', 'Docs'], environment: const {oauthTokenVariable: tokenWork});
      final cmd = terminalAppCommand(l, sourceFile: '/Users/someone/.perch/run/account-1.sh');
      expect(cmd, "cd '/Users/someone/work' && . '/Users/someone/.perch/run/account-1.sh' && 'claude' '-n' 'Docs'");
      expect(cmd, isNot(contains('sk-ant')));
      if (!Platform.isWindows) {
        final path = await writeTokenSourceFile(tokenWork, '${tmp.path}/run');
        final r = await Process.run('/bin/sh', ['-c', '. "\$0" && printf %s "\$CLAUDE_CODE_OAUTH_TOKEN"', path]);
        expect(r.stdout, tokenWork);
        expect(File(path).existsSync(), isFalse, reason: 'it deletes itself');
      }
    });
  });

  group('usage-limit card: Switch account', () {
    test('paused sessions move to the account and get please continue at their prompt', () async {
      transcript(cid);
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      await manager.list();
      manager.limits.hit(cid, resetsAt: DateTime.now().add(const Duration(hours: 2)), claudeWaiting: true);
      expect(manager.limits.current!.sessions.single.id, cid);

      await manager.switchLimitedTo('work', makeDefault: true);
      expect(external.kills, [4242]);
      expect(launches.single.environment[oauthTokenVariable], tokenWork);
      expect(accounts.activeId, 'work');
      await waitUntil(() => console.calls.any((c) => c.text == 'please continue'));
      expect(console.calls.where((c) => c.text == 'please continue').single.pid, nextPid);
      await waitUntil(() => manager.limits.current == null);
    });

    test('without makeDefault the machine keeps its account', () async {
      transcript(cid);
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      await manager.list();
      manager.limits.hit(cid, resetsAt: DateTime.now().add(const Duration(hours: 2)));
      await manager.switchLimitedTo('home');
      expect(accounts.activeId, machineLoginAccountId);
    });

    test('the owner typed something since the limit: nothing is sent for them', () async {
      transcript(cid);
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      await manager.list();
      manager.limits.hit(cid, at: DateTime.now().subtract(const Duration(minutes: 20)));
      // (the transcript's last owner message is 10 minutes old: newer than the limit)
      await manager.switchLimitedTo('home');
      await waitUntil(() => manager.limits.current == null);
      expect(console.calls.where((c) => c.text == 'please continue'), isEmpty);
    });

    test('no limit: refused', () async {
      await expectLater(manager.switchLimitedTo('home'), throwsA(isA<StateError>()));
    });
  });
}
