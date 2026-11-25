// The Windows setup-token console for real: a hidden console window running the fake
// `claude setup-token`, read and typed into with the console helper (no real claude).
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:perch_host/src/console_typer.dart';
import 'package:perch_host/src/host_accounts.dart';
import 'package:perch_host/src/setup_token.dart';
import 'package:perch_host/src/token_vault.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  test('hidden console: link, wrong code, new link, right code, token, window closed', () async {
    final tmp = Directory.systemTemp.createTempSync('perch_stc_');
    final envFile = File('${tmp.path}${Platform.pathSeparator}env.txt');
    final launcher = fakeLauncher(env: {'FAKE_CLAUDE_ENV_FILE': envFile.path, oauthTokenVariable: 'sk-ant-oat01-inherited'});
    final vault = MemoryTokenVault();
    final accounts = HostAccounts(vault: vault, launcher: launcher);
    final consoles = <WindowsSetupTokenConsole>[];
    final flows = AccountSignIns(
      accounts: accounts,
      console: ({required bool visible}) {
        final c = WindowsSetupTokenConsole(
            launcher: launcher, visible: visible, console: WindowsTerminalConsole(stateDir: tmp.path));
        consoles.add(c);
        return c;
      },
      urlTimeout: const Duration(seconds: 60),
      tokenTimeout: const Duration(seconds: 30),
    );
    final updates = <AccountSignInUpdate>[];
    flows.updates.listen(updates.add);
    try {
      await flows.handle(const AccountSignIn(flowId: 'acc-test', action: AccountSignInActions.start, label: 'Test'));
      expect(updates.last.state, AccountSignInStates.url, reason: updates.last.message);
      expect(updates.last.url, endsWith('state=FAKEstate1'));
      expect(envFile.readAsStringSync(), contains('BROWSER=$noBrowser'));
      expect(envFile.readAsStringSync(), contains('TOKEN=false'));

      await flows.handle(const AccountSignIn(flowId: 'acc-test', action: AccountSignInActions.code, code: 'wrong#code'));
      await waitUntil(() => updates.last.state == AccountSignInStates.url || updates.last.state == AccountSignInStates.failed,
          timeout: const Duration(seconds: 60));
      expect(updates.last.url, endsWith('state=FAKEstate2'), reason: updates.last.message);
      expect(updates.last.message, contains("wasn't accepted"));

      await flows.handle(const AccountSignIn(flowId: 'acc-test', action: AccountSignInActions.code, code: 'good#code'));
      await waitUntil(() => updates.last.state == AccountSignInStates.done || updates.last.state == AccountSignInStates.failed,
          timeout: const Duration(seconds: 60));
      expect(updates.last.state, AccountSignInStates.done, reason: updates.last.message);
      expect(updates.last.token, startsWith('sk-ant-oat01-FAKEtoken-'));
      expect(await vault.get('acc-test'), updates.last.token);
      // The console (and its token on screen) is gone.
      expect(await consoles.single.screen(), isNull);
    } finally {
      await flows.dispose();
      for (final c in consoles) {
        await c.close();
      }
      await accounts.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }, skip: Platform.isWindows ? false : 'Windows console only');
}
