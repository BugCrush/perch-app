// Adding an account: reading `claude setup-token`'s screen, and the sign-in flow (phone
// and at-the-machine) against a scripted console. Screens are SYNTHETIC, shaped like the
// ones captured on Windows with Claude Code 2.1.325 (2026-11-15; no real values).
import 'dart:async';

import 'package:perch_host/src/host_accounts.dart';
import 'package:perch_host/src/setup_token.dart';
import 'package:perch_host/src/token_vault.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const fakeUrl = 'https://claude.com/cai/oauth/authorize?code=true&client_id=00000000-0000-4000-8000-000000000000&resp'
    'onse_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3'
    'Ainference&code_challenge=SYNTHETICchallengeSYNTHETICchallenge0000000&code_challenge_method=S256&sta'
    'te=SYNTHETICstateSYNTHETICstate000000000000000';

const token = 'sk-ant-oat01-SYNTHETICtokenSYNTHETICtokenSYNTHETICtokenSYNTHETICtokenSYNTHETICtokenSYNTHETIC0000AA';

/// The URL as the console shows it: wrapped into rows of [width].
String wrapped(String s, int width) {
  final rows = <String>[];
  for (var i = 0; i < s.length; i += width) {
    rows.add(s.substring(i, i + width > s.length ? s.length : i + width));
  }
  return rows.join('\n');
}

const banner = '''Welcome to Claude Code v2.1.325
..........................................................
       █████████                                        *
.......█ █   █ █..........................................
 This will guide you through long-lived (1-year) auth token setup for your Claude account. Claude
 subscription required.''';

String urlScreen([String url = fakeUrl]) => '''$banner
 Browser didn't open? Use the url below to sign in (c to copy)
${wrapped(url, 100)}
 Paste code here if prompted >''';

const rejectedScreen = '''$banner
 OAuth error: That code wasn't accepted. It may be incomplete, expired, already used, or from an
 earlier sign-in attempt. Sign in again to get a new code.
 Press Enter to retry.''';

String tokenScreen({String t = token, String validity = '1 year', int width = 100}) => '''$banner
 ✓ Long-lived authentication token created successfully!
 Your OAuth token (valid for $validity):
${wrapped(' $t', width).split('\n').map((r) => r.startsWith(' ') ? r : ' $r').join('\n')}
 Store this token securely. You won't be able to see it again.
 Use this token by setting: export CLAUDE_CODE_OAUTH_TOKEN=<token>
C:\\work>''';

void main() {
  group('reading the screen', () {
    test('sign-in link joined from its rows', () {
      expect(signInUrlFrom(urlScreen()), fakeUrl);
      expect(signInUrlFrom(banner), isNull);
    });

    test('the shorter claude.ai link of 2.1.331 (one row, then the prompt)', () {
      const short = 'https://claude.ai/oauth/authorize?c=SYNTHETICshortcode0123456789abcdefABCDEF';
      const screen = ' This will guide you through long-lived (1-year) auth token setup for your Claude account.\n'
          ' Browser didn\'t open? Use the URL below to sign in (c to copy)\n'
          '$short\n'
          ' Paste code here if prompted\n'
          ' ╭──────╮\n'
          ' │      │\n'
          ' ╰──────╯';
      expect(signInUrlFrom(screen), short);
      expect(waitingForCode(screen), isTrue);
    });

    test('the link on one row (a wide pty)', () {
      expect(signInUrlFrom('x\n$fakeUrl\n Paste code here if prompted >'), fakeUrl);
    });

    test('the newest link wins (a retry shows a new one)', () {
      const second = 'https://claude.com/cai/oauth/authorize?code=true&state=second';
      expect(signInUrlFrom('${urlScreen()}\n$rejectedScreen\n Browser didn\'t open?\n$second\n Paste code here'), second);
    });

    test('waiting for the code', () {
      expect(waitingForCode(urlScreen()), isTrue);
      expect(waitingForCode(banner), isFalse);
    });

    test('token joined from its rows, with indent', () {
      expect(tokenFrom(tokenScreen()), token);
      expect(tokenFrom(tokenScreen(width: 40)), token);
      expect(tokenFrom(urlScreen()), isNull);
    });

    test('a token that does not look like one is not taken', () {
      expect(tokenFrom(tokenScreen(t: 'not a token at all')), isNull);
    });

    test('validity', () {
      expect(tokenValidityFrom(tokenScreen()), const Duration(days: 365));
      expect(tokenValidityFrom(tokenScreen(validity: '30 days')), const Duration(days: 30));
      expect(tokenValidityFrom(tokenScreen(validity: '12 hours')), const Duration(hours: 12));
      expect(tokenValidityFrom(tokenScreen(validity: 'a while')), isNull);
    });

    test('a rejected code', () {
      expect(codeRejected(rejectedScreen), isTrue);
      expect(signInError(rejectedScreen), startsWith("That code wasn't accepted."));
      expect(codeRejected(urlScreen()), isFalse);
    });

    test('ANSI output from a pty is made plain', () {
      const raw = '\x1B[2K\x1B[1A\x1B[2K\x1B[G\x1B[38;5;214mYour OAuth token (valid for 1 year):\x1B[39m\r\n'
          '\x1B]8;;\x07sk-ant-oat01-abcDEF_123-xyz00000000000000000\x1B[0m\r\nStore this token';
      final plain = plainTerminalText(raw);
      expect(plain, contains('Your OAuth token (valid for 1 year):'));
      expect(tokenFrom(plain), 'sk-ant-oat01-abcDEF_123-xyz00000000000000000');
    });

    test('cursor moves between words become spaces (BSD script on the Mac)', () {
      // Claude Code 2.1.326 redraws a retry's link page with "go to column" and "forward"
      // moves instead of spaces (captured from `script` on the Mac, 2026-11-17).
      const raw = '\r\r\n\x1B[2GPaste\x1B[8Gcode\x1B[13Ghere\x1B[18Gif\x1B[21Gprompted\r\r\n'
          'Use\x1B[1Cthe\x1B[2Curl';
      final plain = plainTerminalText(raw);
      expect(plain, contains(' Paste code here if prompted'));
      expect(waitingForCode(plain), isTrue);
      expect(plain, contains('Use the  url'));
    });
  });

  group('sign-in flow', () {
    late HostAccounts accounts;
    late MemoryTokenVault vault;
    late List<ScriptedTokenConsole> consoles;
    late AccountSignIns flows;
    late List<AccountSignInUpdate> updates;
    late List<String> logs;

    /// What the next console shows when it starts (null: the sign-in link).
    String? firstScreen;

    setUp(() {
      firstScreen = null;
      vault = MemoryTokenVault();
      accounts = HostAccounts(vault: vault, launcher: fakeLauncher(), clock: () => DateTime.utc(2026, 11, 15, 12));
      consoles = [];
      updates = [];
      logs = [];
      flows = AccountSignIns(
        accounts: accounts,
        console: ({required bool visible}) {
          final c = ScriptedTokenConsole(visible: visible)..screen_ = firstScreen;
          consoles.add(c);
          return c;
        },
        poll: const Duration(milliseconds: 10),
        urlTimeout: const Duration(milliseconds: 400),
        tokenTimeout: const Duration(milliseconds: 400),
        clock: () => DateTime.utc(2026, 11, 15, 12),
        log: logs.add,
      );
      flows.updates.listen(updates.add);
    });

    tearDown(() async {
      await flows.dispose();
      await accounts.dispose();
    });

    Future<void> settle() => waitUntil(() => consoles.every((c) => !c.busy), timeout: const Duration(seconds: 5));

    test('phone: link, code, token stored, account reported, console closed', () async {
      await flows.handle(const AccountSignIn(flowId: 'acc-work', action: AccountSignInActions.start, label: 'Work', email: 'w@example.com'));
      expect(consoles.single.visible, isFalse);
      expect(updates.last.state, AccountSignInStates.url);
      expect(updates.last.url, fakeUrl);

      consoles.single.onType = (text) {
        expect(text, 'abc#def');
        consoles.single.screen_ = tokenScreen();
      };
      await flows.handle(const AccountSignIn(flowId: 'acc-work', action: AccountSignInActions.code, code: '  abc#def \n'));
      await waitUntil(() => updates.last.state == AccountSignInStates.done);
      final done = updates.last;
      expect(done.token, token);
      expect(done.account!.id, 'acc-work');
      expect(done.account!.label, 'Work');
      expect(done.account!.email, 'w@example.com');
      expect(done.account!.createdAtMs, DateTime.utc(2026, 11, 15, 12).millisecondsSinceEpoch);
      expect(done.account!.expiresAtMs, DateTime.utc(2027, 11, 15, 12).millisecondsSinceEpoch);
      expect(updates.map((u) => u.state), containsAllInOrder([AccountSignInStates.url, AccountSignInStates.checking, AccountSignInStates.done]));
      expect(await vault.get('acc-work'), token);
      expect(accounts.accounts.single.label, 'Work');
      expect(consoles.single.closed, isTrue);
      // Nothing the host logs holds the token or the link's secrets.
      for (final l in logs) {
        expect(l, isNot(contains('sk-ant')));
        expect(l, isNot(contains('SYNTHETIC')));
      }
      // Only the finished update carries a token.
      expect(updates.where((u) => u.token != null), hasLength(1));
    });

    test('a rejected code: Enter for a new link, the owner is told', () async {
      await flows.handle(const AccountSignIn(flowId: 'f1', action: AccountSignInActions.start, label: 'Work'));
      const second = 'https://claude.com/cai/oauth/authorize?code=true&state=second';
      final c = consoles.single;
      c.onType = (_) => c.screen_ = rejectedScreen;
      c.onEnter = () => c.screen_ = urlScreen(second);
      await flows.handle(const AccountSignIn(flowId: 'f1', action: AccountSignInActions.code, code: 'wrong#code'));
      await waitUntil(() => updates.last.state == AccountSignInStates.url && updates.last.url == second);
      expect(updates.last.message, contains("wasn't accepted"));
      expect(c.closed, isFalse);
      expect(accounts.accounts, isEmpty);
    });

    test('a code that is not all of it: same link, Claude Code says why, the next code works', () async {
      // Claude Code 2.1.326 checks the code's shape at once: the box is emptied and the same
      // link stays (seen on the Mac through BSD script, where the log loses the spaces).
      await flows.handle(const AccountSignIn(flowId: 'f4', action: AccountSignInActions.start, label: 'Work'));
      final c = consoles.single;
      var enters = 0;
      c.onEnter = () => enters++;
      final short = '${urlScreen()}\n ✘Thatdoesn\'tlooklikethefullcode.Copyallofit,includingthe#inthemiddle.';
      c.onType = (_) => c.screen_ = short;
      await flows.handle(const AccountSignIn(flowId: 'f4', action: AccountSignInActions.code, code: 'abc123'));
      await waitUntil(() => updates.last.state == AccountSignInStates.url);
      expect(updates.last.url, fakeUrl);
      expect(updates.last.message, "That doesn't look like the full code. Copy all of it, including the # in the middle.");
      expect(enters, 0);
      expect(c.closed, isFalse);
      // The old line stays on screen while the right code is checked.
      c.onType = (_) => Timer(const Duration(milliseconds: 60), () => c.screen_ = '$short\n${tokenScreen()}');
      await flows.handle(const AccountSignIn(flowId: 'f4', action: AccountSignInActions.code, code: 'abc#def'));
      await waitUntil(() => updates.last.state == AccountSignInStates.done);
      expect(await vault.get('f4'), token);
    });

    test('no link appears: failed, console closed', () async {
      firstScreen = banner;
      await flows.handle(const AccountSignIn(flowId: 'f2', action: AccountSignInActions.start, label: 'Work'));
      expect(updates.last.state, AccountSignInStates.failed);
      expect(updates.last.message, contains('Sign in at the machine'));
      expect(consoles.single.closed, isTrue);
    });

    test('code for an unknown flow is refused', () async {
      await expectLater(flows.handle(const AccountSignIn(flowId: 'nope', action: AccountSignInActions.code, code: 'x#y')),
          throwsA(isA<StateError>()));
    });

    test('cancel closes the console', () async {
      await flows.handle(const AccountSignIn(flowId: 'f1', action: AccountSignInActions.start, label: 'Work'));
      await flows.handle(const AccountSignIn(flowId: 'f1', action: AccountSignInActions.cancel));
      expect(consoles.single.closed, isTrue);
      expect(updates.last.state, AccountSignInStates.cancelled);
    });

    test('at the machine: a visible console, the token picked up from its screen', () async {
      await flows.handle(const AccountSignIn(flowId: 'f1', action: AccountSignInActions.start, label: 'Work'));
      await flows.handle(const AccountSignIn(flowId: 'f1', action: AccountSignInActions.atMachine, label: 'Work'));
      expect(consoles.first.closed, isTrue); // the hidden one
      final visible = consoles.last;
      expect(visible.visible, isTrue);
      expect(updates.last.state, AccountSignInStates.atMachine);
      visible.screen_ = tokenScreen(validity: '365 days');
      await waitUntil(() => updates.last.state == AccountSignInStates.done);
      expect(updates.last.token, token);
      expect(visible.closed, isTrue);
      expect(await vault.get('f1'), token);
      await settle();
    });

    test('a bad label is refused before anything runs', () async {
      await expectLater(flows.handle(const AccountSignIn(flowId: 'f1', action: AccountSignInActions.start, label: '  ')),
          throwsA(isA<ArgumentError>()));
      await expectLater(flows.handle(const AccountSignIn(flowId: '../x', action: AccountSignInActions.start, label: 'W')),
          throwsA(isA<ArgumentError>()));
      expect(consoles, isEmpty);
    });
  });
}

/// A setup-token console whose screen the test controls. It shows the sign-in link as
/// soon as it starts.
class ScriptedTokenConsole implements SetupTokenConsole {
  final bool visible;
  ScriptedTokenConsole({required this.visible});

  String? screen_;
  bool closed = false;
  bool started = false;
  bool busy = false;
  void Function(String text)? onType;
  void Function()? onEnter;

  @override
  Future<void> start() async {
    started = true;
    screen_ ??= visible ? banner : urlScreen();
  }

  @override
  Future<String?> screen() async => closed ? null : screen_;

  @override
  Future<bool> type(String text) async {
    onType?.call(text);
    return true;
  }

  @override
  Future<bool> enter() async {
    onEnter?.call();
    return true;
  }

  @override
  Future<void> close() async => closed = true;
}
