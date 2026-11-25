import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_accounts.dart';
import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/token_vault.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const tokenA = 'sk-ant-oat01-SYNTHETIC-A-000000000000000000000000000000000000000000000000';
const tokenB = 'sk-ant-oat01-SYNTHETIC-B-000000000000000000000000000000000000000000000000';

AccountInfo info(String id, String label, {int? expires}) =>
    AccountInfo(id: id, label: label, email: '$id@example.com', plan: 'Max', createdAtMs: 1, expiresAtMs: expires);

void main() {
  late Directory tmp;
  late HostState state;
  late MemoryTokenVault vault;
  late HostAccounts accounts;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_acc_');
    state = HostState.load(tmp.path);
    vault = MemoryTokenVault();
    accounts = HostAccounts(vault: vault, store: state, launcher: fakeLauncher());
  });

  tearDown(() async {
    await accounts.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String hostJson() => File('${tmp.path}${Platform.pathSeparator}host.json').readAsStringSync();

  test('sync adds and updates accounts; tokens go to the vault, never to host.json', () async {
    final changes = <void>[];
    accounts.changes.listen(changes.add);
    await accounts.sync([
      AccountWithToken(info: info('a', 'Personal'), token: tokenA),
      AccountWithToken(info: info('b', 'Work'), token: tokenB),
    ]);
    expect(accounts.accounts.map((a) => a.label), ['Personal', 'Work']);
    expect(await vault.get('a'), tokenA);
    expect(hostJson(), contains('Personal'));
    expect(hostJson(), isNot(contains('sk-ant')));
    await accounts.sync([AccountWithToken(info: info('b', 'Work 2'), token: tokenB)]);
    expect(accounts.accounts.map((a) => a.label), ['Personal', 'Work 2'], reason: 'sync never removes');
    await Future<void>.delayed(Duration.zero);
    expect(changes, isNotEmpty);
  });

  test('a bad id in a sync is skipped', () async {
    await accounts.sync([AccountWithToken(info: info('../x', 'Bad'), token: tokenA)]);
    expect(accounts.accounts, isEmpty);
  });

  test('the machine login is active until the owner switches', () async {
    expect(accounts.activeId, machineLoginAccountId);
    expect(await accounts.tokenFor(machineLoginAccountId), isNull);
    await accounts.sync([AccountWithToken(info: info('a', 'Personal'), token: tokenA)]);
    expect(accounts.activeId, machineLoginAccountId, reason: 'adding an account does not switch');
    accounts.setActive('a');
    expect(accounts.activeId, 'a');
    expect(await accounts.tokenFor('a'), tokenA);
    expect(() => accounts.setActive('nope'), throwsArgumentError);
  });

  test('state survives a restart', () async {
    await accounts.sync([AccountWithToken(info: info('a', 'Personal'), token: tokenA)]);
    accounts.setActive('a');
    accounts.recordSession('11111111-0000-4000-8000-000000000001', 'a');
    final again = HostAccounts(vault: vault, store: HostState.load(tmp.path), launcher: fakeLauncher());
    expect(again.activeId, 'a');
    expect(again.accounts.single.label, 'Personal');
    expect(again.accountOf('11111111-0000-4000-8000-000000000001'), 'a');
    await again.dispose();
  });

  test('a running host keeps accounts when the CLI reloads its state', () async {
    await accounts.sync([AccountWithToken(info: info('a', 'Personal'), token: tokenA)]);
    // `perch_host name set` writes host.json from a fresh load, then the server reloads.
    HostState.load(tmp.path).setMachineName('Desk');
    expect(jsonDecode(hostJson())['accounts'], isNotNull);
  });

  test('removing an account forgets its token; the machine login takes over if it was active', () async {
    await accounts.sync([AccountWithToken(info: info('a', 'Personal'), token: tokenA)]);
    accounts.setActive('a');
    await accounts.remove('a');
    expect(accounts.accounts, isEmpty);
    expect(await vault.get('a'), isNull);
    expect(accounts.activeId, machineLoginAccountId);
  });

  test('tokenFor an unknown account, or one whose token is gone, says so', () async {
    await expectLater(accounts.tokenFor('nope'), throwsA(isA<StateError>()));
    await accounts.sync([AccountWithToken(info: info('a', 'Personal'), token: tokenA)]);
    vault.tokens.clear();
    await expectLater(accounts.tokenFor('a'), throwsA(isA<StateError>()));
  });

  test('an expired account cannot start sessions', () async {
    final past = DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    await accounts.sync([AccountWithToken(info: info('a', 'Old', expires: past), token: tokenA)]);
    await expectLater(accounts.tokenFor('a'), throwsA(isA<StateError>()));
  });

  test('sessions remember their account (capped)', () {
    for (var i = 0; i < HostAccounts.maxSessions + 5; i++) {
      accounts.recordSession('s$i', 'a');
    }
    expect(accounts.accountOf('s0'), isNull);
    expect(accounts.accountOf('s${HostAccounts.maxSessions + 4}'), 'a');
  });

  test('machine login read from claude auth status, without any token in its environment', () async {
    final args = File('${tmp.path}${Platform.pathSeparator}args.txt');
    final launcher = fakeLauncher(env: {
      'FAKE_CLAUDE_ARGS_FILE': args.path,
      'FAKE_CLAUDE_AUTH_EMAIL': 'me@example.com',
      'CLAUDE_CODE_OAUTH_TOKEN': tokenA, // as if the host itself were started with one
    });
    final a = HostAccounts(vault: vault, launcher: launcher);
    final login = await a.refreshMachineLogin();
    expect(login.loggedIn, isTrue);
    expect(login.email, 'me@example.com');
    expect(login.plan, 'max');
    expect(args.readAsStringSync().trim().split('\n'), ['auth', 'status', '--json']);
    expect(a.message.machineLogin.email, 'me@example.com');
    await a.dispose();
  });

  test('the accounts message carries no token', () async {
    await accounts.sync([AccountWithToken(info: info('a', 'Personal'), token: tokenA)]);
    expect(encodeHost(accounts.message), isNot(contains('sk-ant')));
    expect(accounts.message.accounts.single.id, 'a');
  });
}
