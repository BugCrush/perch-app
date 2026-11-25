// Accounts on the phone: the keystore-backed store, giving them to every machine as it
// connects, adding an account (phone sign-in and the machine fallback), the machine's
// Switch, the per-session picker, switching a running session, the usage-limit card's
// Switch account, expiry warnings and removal. SYNTHETIC tokens and emails.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/account_store.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/connection/machine_store.dart';
import 'package:perch_app/src/state/providers.dart';
import 'package:perch_app/src/state/session_prefs.dart';
import 'package:perch_app/src/ui/accounts_screen.dart';
import 'package:perch_app/src/ui/glass/widgets.dart';
import 'package:perch_app/src/ui/home_screen.dart';
import 'package:perch_app/src/ui/labels.dart';
import 'package:perch_app/src/ui/new_session_sheet.dart';
import 'package:perch_app/src/ui/session_menu.dart';
import 'package:perch_app/src/ui/session_row.dart';
import 'package:perch_app/src/ui/usage_limit_card.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'glass_harness.dart';

const tokenWork = 'sk-ant-oat01-SYNTHETIC-work-000000000000000000000000000000000000000000';
const tokenNew = 'sk-ant-oat01-SYNTHETIC-new-0000000000000000000000000000000000000000000';

final yearOn = DateTime.now().add(const Duration(days: 365)).millisecondsSinceEpoch;

AccountInfo work({int? expiresAtMs}) => AccountInfo(
    id: 'acc-work', label: 'Work', email: 'work@example.com', plan: 'Max', createdAtMs: 1, expiresAtMs: expiresAtMs ?? yearOn);

AccountsMessage hostAccounts({String active = machineLoginAccountId, List<AccountInfo>? accounts}) => AccountsMessage(
    machineLogin: const MachineLogin(loggedIn: true, email: 'me@example.com', plan: 'max'),
    activeAccountId: active,
    accounts: accounts ?? [work()]);

void main() {
  late FakeChannels channels;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    channels = FakeChannels();
  });

  List<ClientMessage> sent(FakeHostSide h) => h.messages.skip(1).toList();

  group('the phone store', () {
    test('keeps accounts, tokens, removals and the setting in the secret box only', () async {
      final box = MemorySecretBox();
      final a = PhoneAccounts(box: box);
      await a.load();
      await a.put(work(), tokenWork);
      await a.setPerSession(true);
      expect(box.values.keys, [PhoneAccounts.key]);
      final again = PhoneAccounts(box: box);
      await again.load();
      expect(again.accounts.single.label, 'Work');
      expect(again.withTokens.single.token, tokenWork);
      expect(again.perSession, isTrue);
      await again.remove('acc-work');
      expect(again.accounts, isEmpty);
      expect(again.removed, {'acc-work'});
      final prefs = await SharedPreferences.getInstance();
      expect(jsonEncode({for (final k in prefs.getKeys()) k: prefs.get(k)}), isNot(contains('sk-ant')));
    });

    test('an unreadable store starts empty', () async {
      final box = MemorySecretBox()..values[PhoneAccounts.key] = 'not json';
      final a = PhoneAccounts(box: box);
      await a.load();
      expect(a.accounts, isEmpty);
      expect(a.loaded, isTrue);
    });

    test('new ids are safe for the host (letters, digits, dash)', () {
      for (var i = 0; i < 50; i++) {
        expect(RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(newAccountId()), isTrue);
      }
    });

    test('expiry lines', () {
      final now = DateTime(2026, 11, 15, 12);
      expect(expiryLine(work(expiresAtMs: DateTime(2027, 11, 15).millisecondsSinceEpoch), now), 'Valid until 15 Nov 2027');
      expect(expiryLine(work(expiresAtMs: DateTime(2026, 11, 25, 13).millisecondsSinceEpoch), now), 'Sign-in expires in 10 days');
      expect(expiryLine(work(expiresAtMs: DateTime(2026, 11, 15, 8).millisecondsSinceEpoch), now), 'Sign-in expired');
    });
  });

  group('the connection', () {
    late PhoneAccounts phone;
    late HostConnection c;
    late FakeHostSide host;

    Future<void> connect() async {
      c = HostConnection(testMachine(), channelFactory: channels.factory, accountSource: phone);
      c.connect();
      host = channels.last;
      host.send(welcome);
      await eventually(() => c.link.value == LinkState.online);
    }

    setUp(() async {
      phone = PhoneAccounts(box: MemorySecretBox());
      await phone.load();
    });
    tearDown(() => c.dispose());

    test("a machine with accounts is given the phone's (sealed in the channel)", () async {
      await phone.put(work(), tokenWork);
      await connect();
      host.send(hostAccounts(accounts: []));
      await eventually(() => sent(host).whereType<SyncAccounts>().isNotEmpty);
      final s = sent(host).whereType<SyncAccounts>().single;
      expect(s.accounts.single.token, tokenWork);
      for (final f in host.raw.whereType<List<int>>()) {
        expect(utf8.decode(f, allowMalformed: true), isNot(contains('sk-ant')));
      }
    });

    test('an older host (no accounts message) is sent nothing', () async {
      await phone.put(work(), tokenWork);
      await connect();
      host.send(const Sessions(sessions: []));
      await pump(50);
      expect(sent(host).whereType<SyncAccounts>(), isEmpty);
      expect(c.supportsAccounts, isFalse);
      await expectLater(c.setActiveAccount('acc-work'), throwsA(isA<SessionActionFailed>()));
    });

    test('an account removed while the machine was away is forgotten when it connects', () async {
      await phone.put(work(), tokenWork);
      await phone.remove('acc-work');
      await connect();
      host.send(hostAccounts());
      await eventually(() => sent(host).whereType<RemoveAccount>().isNotEmpty);
      expect(sent(host).whereType<RemoveAccount>().single.accountId, 'acc-work');
    });

    test('set the active account; switch a session; the limit switch', () async {
      await connect();
      host.send(hostAccounts());
      await eventually(() => c.supportsAccounts);
      final done = c.setActiveAccount('acc-work');
      await eventually(() => sent(host).whereType<SetActiveAccount>().isNotEmpty);
      host.send(hostAccounts(active: 'acc-work'));
      await done;
      expect(c.accounts.value!.activeAccountId, 'acc-work');

      final sw = c.switchSessionAccount('s1', 'acc-work');
      await eventually(() => sent(host).whereType<SwitchSessionAccount>().isNotEmpty);
      host.send(const SessionActionDone(action: SessionActions.switchAccount, sessionId: 's1', message: 'Restarted on Work'));
      expect(await sw, 'Restarted on Work');

      final lim = c.chooseLimit(LimitChoices.switchAccount, accountId: 'acc-work', makeDefault: true);
      await eventually(() => sent(host).whereType<UsageLimitChoice>().isNotEmpty);
      final m = sent(host).whereType<UsageLimitChoice>().single;
      expect((m.choice, m.accountId, m.makeDefault), (LimitChoices.switchAccount, 'acc-work', true));
      host.send(const UsageLimitMessage());
      await lim;
    });

    test('a refused switch says why', () async {
      await connect();
      host.send(hostAccounts());
      await eventually(() => c.supportsAccounts);
      final done = c.setActiveAccount('nope');
      await eventually(() => sent(host).whereType<SetActiveAccount>().isNotEmpty);
      host.send(const ErrorMessage(code: ErrorCodes.badRequest, message: 'This machine does not have that account.'));
      await expectLater(done, throwsA(isA<SessionActionFailed>().having((e) => e.message, 'message', contains('does not have'))));
    });
  });

  group('screens', () {
    late PhoneAccounts phone;
    late List<Uri> opened;

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
    }

    Future<FakeHostSide> home(WidgetTester tester, {AccountsMessage? accounts, List<SessionSummary> sessions = const []}) async {
      SharedPreferences.setMockInitialValues({MachineStore.key: jsonEncode([testMachine(label: 'Desk').toJson()])});
      tallPhone(tester);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          channelFactoryProvider.overrideWithValue(channels.factory),
          phoneAccountsProvider.overrideWithValue(phone),
          urlOpenerProvider.overrideWithValue((u) async {
            opened.add(u);
            return true;
          }),
        ],
        child: glassApp(const HomeScreen()),
      ));
      await settle(tester);
      final host = channels.last;
      host.send(welcome);
      host.send(Sessions(sessions: sessions));
      host.send(accounts ?? hostAccounts(accounts: []));
      await settle(tester);
      return host;
    }

    setUp(() async {
      phone = PhoneAccounts(box: MemorySecretBox());
      await phone.load();
      opened = [];
    });

    testWidgets("the machine card shows its account (first: the machine's own login) and switches", (tester) async {
      final host = await home(tester, accounts: hostAccounts());
      expect(find.text("This machine's login · me@example.com · Max"), findsOneWidget);
      await tapKey(tester, 'switch-account-m1');
      expect(find.text('Account for devbox'), findsOneWidget);
      await tapKey(tester, 'pick-account-acc-work');
      await tester.runAsync(() => eventually(() => sent(host).whereType<SetActiveAccount>().isNotEmpty));
      expect(sent(host).whereType<SetActiveAccount>().single.accountId, 'acc-work');
      host.send(hostAccounts(active: 'acc-work'));
      await settle(tester);
      expect(find.text('Work · work@example.com · Max'), findsOneWidget);
    });

    testWidgets('add an account from the phone: link opens in the browser, code sent, token kept, every machine given it',
        (tester) async {
      final host = await home(tester);
      await tapKey(tester, 'open-menu');
      await tapKey(tester, 'open-accounts');
      expect(find.text('Accounts'), findsWidgets);
      await tapKey(tester, 'add-account');
      await tester.enterText(field('Name'), 'Side');
      await tester.enterText(field('Email (optional)'), 'side@example.com');
      await tapKey(tester, 'start-sign-in');
      await tester.runAsync(() => eventually(() => sent(host).whereType<AccountSignIn>().isNotEmpty));
      final start = sent(host).whereType<AccountSignIn>().single;
      expect((start.action, start.label, start.email), (AccountSignInActions.start, 'Side', 'side@example.com'));
      const url = 'https://claude.com/cai/oauth/authorize?code=true&state=SYNTHETIC';
      host.send(AccountSignInUpdate(flowId: start.flowId, state: AccountSignInStates.url, url: url));
      await settle(tester);
      await tapKey(tester, 'open-sign-in');
      expect(opened.single.toString(), url);
      await tester.enterText(field('Code'), ' abc#def ');
      await tapKey(tester, 'send-code');
      await tester.runAsync(() => eventually(() => sent(host).whereType<AccountSignIn>().length == 2));
      expect(sent(host).whereType<AccountSignIn>().last.code, 'abc#def');
      final info = AccountInfo(id: start.flowId, label: 'Side', email: 'side@example.com', createdAtMs: 1, expiresAtMs: yearOn);
      host.send(AccountSignInUpdate(flowId: start.flowId, state: AccountSignInStates.done, account: info, token: tokenNew));
      await settle(tester);
      expect(phone.withTokens.single.token, tokenNew);
      await tester.runAsync(() => eventually(() => sent(host).whereType<SyncAccounts>().isNotEmpty));
      expect(sent(host).whereType<SyncAccounts>().last.accounts.single.info.label, 'Side');
      expect(find.textContaining('is ready on every paired machine'), findsOneWidget);
      await tapKey(tester, 'sign-in-done');
      expect(find.text('Side'), findsOneWidget);
    });

    testWidgets('a failed sign-in offers the machine instead', (tester) async {
      final host = await home(tester);
      await tapKey(tester, 'open-menu');
      await tapKey(tester, 'open-accounts');
      await tapKey(tester, 'add-account');
      await tester.enterText(field('Name'), 'Side');
      await tapKey(tester, 'start-sign-in');
      await tester.runAsync(() => eventually(() => sent(host).whereType<AccountSignIn>().isNotEmpty));
      final flow = sent(host).whereType<AccountSignIn>().single.flowId;
      host.send(AccountSignInUpdate(flowId: flow, state: AccountSignInStates.failed, message: 'Claude Code did not show a sign-in link.'));
      await settle(tester);
      expect(find.textContaining('did not show a sign-in link'), findsOneWidget);
      await tapKey(tester, 'sign-in-at-machine');
      await tester.runAsync(() => eventually(() => sent(host).whereType<AccountSignIn>().length == 2));
      expect(sent(host).whereType<AccountSignIn>().last.action, AccountSignInActions.atMachine);
      host.send(AccountSignInUpdate(flowId: flow, state: AccountSignInStates.atMachine, message: 'Sign in in the terminal window'));
      await settle(tester);
      expect(find.text('Sign in in the terminal window'), findsOneWidget);
      // The owner closes the sheet and finishes at the machine: the account still reaches the phone.
      await tapButton(tester, 'Close');
      final before = sent(host).length;
      final info = AccountInfo(id: flow, label: 'Side', createdAtMs: 1, expiresAtMs: yearOn);
      host.send(AccountSignInUpdate(flowId: flow, state: AccountSignInStates.done, account: info, token: tokenNew));
      await settle(tester);
      expect(phone.withTokens.single.token, tokenNew);
      expect(sent(host).skip(before).whereType<AccountSignIn>(), isEmpty, reason: 'closing did not cancel it');
      await tester.runAsync(() => eventually(() => sent(host).whereType<SyncAccounts>().isNotEmpty));
    });

    testWidgets('a name is required before anything runs', (tester) async {
      final host = await home(tester);
      await tapKey(tester, 'open-menu');
      await tapKey(tester, 'open-accounts');
      await tapKey(tester, 'add-account');
      await tapKey(tester, 'start-sign-in');
      expect(find.textContaining('Give it a name'), findsOneWidget);
      expect(sent(host).whereType<AccountSignIn>(), isEmpty);
    });

    testWidgets('expiry: a warning on the first screen two weeks before, Sign in again in Accounts', (tester) async {
      await phone.put(work(expiresAtMs: DateTime.now().add(const Duration(days: 9, hours: 2)).millisecondsSinceEpoch), tokenWork);
      await home(tester);
      expect(find.byKey(const ValueKey('accounts-notice')), findsOneWidget);
      expect(find.textContaining('Work: Sign-in expires in 9 days'), findsOneWidget);
      await tapKey(tester, 'accounts-notice');
      expect(find.byKey(const ValueKey('sign-in-again-acc-work')), findsOneWidget);
      await tapKey(tester, 'sign-in-again-acc-work');
      expect(find.text('Sign in again: Work'), findsOneWidget);
    });

    testWidgets('no warning for an account a year away', (tester) async {
      await phone.put(work(), tokenWork);
      await home(tester);
      expect(find.byKey(const ValueKey('accounts-notice')), findsNothing);
    });

    testWidgets('removing an account tells every connected machine', (tester) async {
      await phone.put(work(), tokenWork);
      final host = await home(tester, accounts: hostAccounts());
      await tapKey(tester, 'open-menu');
      await tapKey(tester, 'open-accounts');
      await tapKey(tester, 'account-menu-acc-work');
      await tapKey(tester, 'menu-Remove…');
      await tapButton(tester, 'Remove');
      await tester.runAsync(() => eventually(() => sent(host).whereType<RemoveAccount>().isNotEmpty));
      expect(phone.accounts, isEmpty);
    });

    testWidgets('the per-session setting', (tester) async {
      await home(tester);
      await tapKey(tester, 'open-menu');
      await tapKey(tester, 'open-accounts');
      await tapKey(tester, 'per-session');
      expect(phone.perSession, isTrue);
    });
  });

  group('sessions and the usage-limit card', () {
    late HostConnection c;
    late FakeHostSide host;

    Future<void> online(WidgetTester tester, {List<SessionSummary>? sessions, AccountsMessage? accounts}) async {
      c = HostConnection(testMachine(id: 'm1', label: 'Desk'), channelFactory: channels.factory);
      c.connect();
      host = channels.last;
      host.send(welcome);
      host.send(Sessions(sessions: sessions ?? [summary('s1', name: 'Docs', origin: SessionOrigin.external)]));
      host.send(accounts ?? hostAccounts());
      await tester.runAsync(() => eventually(() => c.supportsAccounts && c.sessions.value.isNotEmpty));
    }

    tearDown(() => c.dispose());

    testWidgets('a session shows its account; the machine-login one says nothing when it is the only account', (tester) async {
      await online(tester, sessions: [
        const SessionSummary(
            id: 's1', name: 'Docs', cwd: 'D:\\w', origin: SessionOrigin.external, state: SessionState.idle, startedAtMs: 1, accountId: 'acc-work'),
      ]);
      tallPhone(tester);
      await tester.pumpWidget(glassApp(GlassScaffold(child: SessionRow(connection: c, session: c.sessions.value.single, prefs: SessionPrefs(persist: false)))));
      expect(find.text('on Work'), findsOneWidget);
      expect(sessionAccountLine(c, summary('x')), isNull, reason: 'unknown account: nothing');
    });

    testWidgets('per-session picker on the new-session sheet', (tester) async {
      await online(tester);
      tallPhone(tester);
      await tester.pumpWidget(glassApp(GlassScaffold(child: NewSessionSheet(connection: c, folder: r'D:\work', perSession: true))));
      host.send(const DirListing(path: r'D:\work'));
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('new-session-account-machine')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('new-session-account-acc-work')));
      await tester.pump();
      await tester.enterText(field('First instruction'), 'Say hi');
      await tester.tap(button('Start'));
      await tester.pump();
      await tester.runAsync(() => eventually(() => sent(host).whereType<StartSession>().isNotEmpty));
      expect(sent(host).whereType<StartSession>().single.accountId, 'acc-work');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without the setting the sheet asks nothing and the machine decides', (tester) async {
      await online(tester);
      tallPhone(tester);
      await tester.pumpWidget(glassApp(GlassScaffold(child: NewSessionSheet(connection: c, folder: r'D:\work', perSession: false))));
      await tester.pump();
      expect(find.byKey(const ValueKey('new-session-account-machine')), findsNothing);
      await tester.enterText(field('First instruction'), 'Say hi');
      await tester.tap(button('Start'));
      await tester.pump();
      await tester.runAsync(() => eventually(() => sent(host).whereType<StartSession>().isNotEmpty));
      expect(sent(host).whereType<StartSession>().single.accountId, isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("session menu: Switch this session's account, with a confirmation that it restarts", (tester) async {
      await online(tester);
      final s = c.sessions.value.single;
      expect(sessionMenuItems(s, pinned: false, muted: false, accounts: true), contains(SessionMenuItem.switchAccount));
      expect(sessionMenuItems(s, pinned: false, muted: false), isNot(contains(SessionMenuItem.switchAccount)));
      tallPhone(tester);
      await tester.pumpWidget(glassApp(Builder(
          builder: (context) => GlassScaffold(
              child: Center(
                  child: GestureDetector(
                      onTap: () => showSessionMenu(context, connection: c, session: s, prefs: SessionPrefs(persist: false)),
                      child: const Text('menu')))))));
      await tester.tap(find.text('menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Switch this session's account…"));
      await tester.pumpAndSettle();
      await tapKey(tester, 'pick-account-acc-work');
      expect(find.text('Restart on Work?'), findsOneWidget);
      expect(find.textContaining('cannot change the account of a running session'), findsOneWidget);
      await tapButton(tester, 'Restart on Work');
      await tester.runAsync(() => eventually(() => sent(host).whereType<SwitchSessionAccount>().isNotEmpty));
      final m = sent(host).whereType<SwitchSessionAccount>().single;
      expect((m.sessionId, m.accountId), ('s1', 'acc-work'));
      host.send(const SessionActionDone(action: SessionActions.switchAccount, sessionId: 's1', message: 'Restarted on Work'));
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('usage-limit card: Switch account picks another account and moves the paused sessions', (tester) async {
      await online(tester, sessions: [
        const SessionSummary(
            id: 's1', name: 'Docs', cwd: 'D:\\w', origin: SessionOrigin.external, state: SessionState.blocked, startedAtMs: 1, accountId: machineLoginAccountId),
      ]);
      tallPhone(tester);
      const limit = UsageLimit(sessions: [LimitedSession(id: 's1', name: 'Docs', claudeWaiting: true)]);
      await tester.pumpWidget(glassApp(GlassScaffold(child: SingleChildScrollView(child: UsageLimitCard(connection: c, limit: limit, perSession: false)))));
      expect(find.text('Not available yet'), findsNothing);
      expect(find.text('Restart the paused sessions on another account and continue them'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('limit-switch-account')));
      await tester.pumpAndSettle();
      // The account the limit hit is not offered.
      expect(find.byKey(const ValueKey('pick-account-machine')), findsNothing);
      expect(find.textContaining('New sessions on devbox start on it too'), findsOneWidget);
      await tapKey(tester, 'pick-account-acc-work');
      await tester.runAsync(() => eventually(() => sent(host).whereType<UsageLimitChoice>().isNotEmpty));
      final m = sent(host).whereType<UsageLimitChoice>().single;
      expect((m.choice, m.accountId, m.makeDefault), (LimitChoices.switchAccount, 'acc-work', true));
      host.send(const UsageLimitMessage());
      await tester.runAsync(() => pump(50));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('usage-limit card with no other account sends the owner to Accounts', (tester) async {
      await online(tester, accounts: hostAccounts(accounts: []));
      tallPhone(tester);
      const limit = UsageLimit(sessions: [LimitedSession(id: 's1', name: 'Docs')]);
      await tester.pumpWidget(glassApp(GlassScaffold(child: SingleChildScrollView(child: UsageLimitCard(connection: c, limit: limit, perSession: false)))));
      expect(find.text('Add another account first'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
