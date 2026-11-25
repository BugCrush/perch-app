import 'dart:convert';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  const token = 'sk-ant-oat01-SYNTHETIC-test-token-0000000000000000000000000000000000000000';
  final created = DateTime.utc(2026, 11, 15, 12).millisecondsSinceEpoch;
  final expires = DateTime.utc(2027, 11, 15, 12).millisecondsSinceEpoch;
  final work = AccountInfo(
      id: 'acc-work', label: 'Work', email: 'someone@example.com', plan: 'Max', createdAtMs: created, expiresAtMs: expires);

  group('AccountInfo', () {
    test('round-trips and never carries a token', () {
      final j = work.toJson();
      expect(jsonEncode(j), isNot(contains('sk-ant')));
      final back = AccountInfo.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
      expect(back.id, 'acc-work');
      expect(back.label, 'Work');
      expect(back.email, 'someone@example.com');
      expect(back.plan, 'Max');
      expect(back.createdAtMs, created);
      expect(back.expiresAtMs, expires);
    });

    test('expiry: fine, soon (14 days before), expired, unknown', () {
      final exp = DateTime.fromMillisecondsSinceEpoch(expires);
      expect(work.expiry(exp.subtract(const Duration(days: 30))), AccountExpiry.ok);
      expect(work.expiry(exp.subtract(const Duration(days: 14))), AccountExpiry.soon);
      expect(work.expiry(exp.subtract(const Duration(days: 1))), AccountExpiry.soon);
      expect(work.expiry(exp), AccountExpiry.expired);
      expect(work.expiry(exp.add(const Duration(days: 3))), AccountExpiry.expired);
      expect(AccountInfo(id: 'x', label: 'X', createdAtMs: created).expiry(exp), AccountExpiry.ok);
    });

    test('a display line names label, email and plan', () {
      expect(work.describe(), 'Work · someone@example.com · Max');
      expect(AccountInfo(id: 'x', label: 'X', createdAtMs: created).describe(), 'X');
    });

    test('fromJson rejects a record without id or label', () {
      expect(AccountInfo.tryFromJson({'label': 'x'}), isNull);
      expect(AccountInfo.tryFromJson({'id': 'x'}), isNull);
      expect(AccountInfo.tryFromJson('nope'), isNull);
    });
  });

  group('wire', () {
    test('syncAccounts carries tokens app -> host', () {
      final m = decodeClient(encodeClient(SyncAccounts(accounts: [AccountWithToken(info: work, token: token)])));
      expect(m, isA<SyncAccounts>());
      final s = m as SyncAccounts;
      expect(s.accounts.single.info.label, 'Work');
      expect(s.accounts.single.token, token);
    });

    test('syncAccounts drops entries without a token', () {
      final frame = jsonEncode({
        'type': 'syncAccounts',
        'accounts': [
          {...work.toJson(), 'token': ''},
          {...work.toJson(), 'id': 'b'},
        ]
      });
      expect((decodeClient(frame) as SyncAccounts).accounts, isEmpty);
    });

    test('removeAccount, setActiveAccount, switchSessionAccount', () {
      expect((decodeClient(encodeClient(const RemoveAccount(accountId: 'a'))) as RemoveAccount).accountId, 'a');
      expect((decodeClient(encodeClient(const SetActiveAccount(accountId: machineLoginAccountId))) as SetActiveAccount).accountId,
          machineLoginAccountId);
      final sw = decodeClient(encodeClient(const SwitchSessionAccount(sessionId: 's', accountId: 'a'))) as SwitchSessionAccount;
      expect((sw.sessionId, sw.accountId), ('s', 'a'));
      expect(decodeClient(jsonEncode({'type': 'removeAccount', 'accountId': ''})), isNull);
    });

    test('accountSignIn actions', () {
      final start = decodeClient(encodeClient(
          const AccountSignIn(flowId: 'f1', action: AccountSignInActions.start, label: 'Work', email: 'a@b.c', plan: 'Pro')));
      expect(start, isA<AccountSignIn>());
      final s = start as AccountSignIn;
      expect((s.flowId, s.action, s.label, s.email, s.plan), ('f1', 'start', 'Work', 'a@b.c', 'Pro'));
      final code = decodeClient(encodeClient(const AccountSignIn(flowId: 'f1', action: AccountSignInActions.code, code: 'abc#def')))
          as AccountSignIn;
      expect(code.code, 'abc#def');
      expect(decodeClient(jsonEncode({'type': 'accountSignIn', 'flowId': 'f', 'action': 'explode'})), isNull);
    });

    test('startSession carries an optional account', () {
      final m = decodeClient(encodeClient(const StartSession(cwd: 'c', prompt: 'p', accountId: 'acc-work'))) as StartSession;
      expect(m.accountId, 'acc-work');
      expect((decodeClient(encodeClient(const StartSession(cwd: 'c', prompt: 'p'))) as StartSession).accountId, isNull);
    });

    test('usageLimitChoice switch needs an account', () {
      final m = decodeClient(
          encodeClient(const UsageLimitChoice(choice: LimitChoices.switchAccount, accountId: 'acc-work', makeDefault: true)))
          as UsageLimitChoice;
      expect((m.choice, m.accountId, m.makeDefault), ('switch', 'acc-work', true));
      expect(decodeClient(jsonEncode({'type': 'usageLimitChoice', 'choice': 'switch'})), isNull);
    });

    test('accounts message host -> app has no token', () {
      final msg = AccountsMessage(
        machineLogin: const MachineLogin(loggedIn: true, email: 'me@example.com', plan: 'Max'),
        activeAccountId: 'acc-work',
        accounts: [work],
      );
      final frame = encodeHost(msg);
      expect(frame, isNot(contains('sk-ant')));
      final back = decodeHost(frame) as AccountsMessage;
      expect(back.activeAccountId, 'acc-work');
      expect(back.machineLogin.email, 'me@example.com');
      expect(back.machineLogin.plan, 'Max');
      expect(back.accounts.single.label, 'Work');
    });

    test('accounts message: machine login active when no id', () {
      final back = decodeHost(encodeHost(const AccountsMessage(machineLogin: MachineLogin(loggedIn: false), accounts: [])))
          as AccountsMessage;
      expect(back.activeAccountId, machineLoginAccountId);
      expect(back.machineLogin.loggedIn, isFalse);
    });

    test('accountSignIn update', () {
      final back = decodeHost(encodeHost(AccountSignInUpdate(
              flowId: 'f1', state: AccountSignInStates.done, account: work, token: token)))
          as AccountSignInUpdate;
      expect(back.state, 'done');
      expect(back.account!.id, 'acc-work');
      expect(back.token, token);
      final url = decodeHost(encodeHost(const AccountSignInUpdate(
          flowId: 'f1', state: AccountSignInStates.url, url: 'https://claude.com/cai/oauth/authorize?x=1', message: 'm')))
          as AccountSignInUpdate;
      expect((url.url, url.message), ('https://claude.com/cai/oauth/authorize?x=1', 'm'));
    });

    test('session summary and usage carry the account', () {
      const s = SessionSummary(
          id: 'a', name: 'n', cwd: 'c', origin: SessionOrigin.external, state: SessionState.idle, startedAtMs: 1, accountId: 'acc-work');
      expect(SessionSummary.fromJson(s.toJson()).accountId, 'acc-work');
      expect(SessionSummary.fromJson(s.copyWith(name: 'm').toJson()).accountId, 'acc-work');
      expect(const SessionSummary(id: 'a', name: 'n', cwd: 'c', origin: SessionOrigin.external, state: SessionState.idle, startedAtMs: 1)
          .toJson()
          .containsKey('accountId'), isFalse);
      const u = UsageSnapshot(accountId: 'acc-work');
      expect(UsageSnapshot.fromJson(u.toJson()).accountId, 'acc-work');
    });
  });
}
