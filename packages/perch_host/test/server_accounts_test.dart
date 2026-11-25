// Accounts over the wire: the accounts message on connect, sync from the phone (to two
// hosts), the default account, removal, adding an account (link, code, token to the device
// that asked), sessions on an account, switching a session, the usage-limit switch, and
// that no token crosses the link in the clear (the relay sees only these frames).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:perch_host/src/frame_link.dart';
import 'package:perch_host/src/host_accounts.dart';
import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/setup_token.dart';
import 'package:perch_host/src/terminal_window.dart';
import 'package:perch_host/src/token_vault.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'setup_token_test.dart' show ScriptedTokenConsole, fakeUrl, token, tokenScreen;
import 'usage_limit_flow_test.dart' show fastTracker, promptScreen;

final sep = Platform.pathSeparator;
const cid = 'cccccccc-2222-4000-8000-000000000001';
const syncedToken = 'sk-ant-oat01-SYNTHETIC-synced-000000000000000000000000000000000000000000';

/// One app connection carried in memory (as the relay carries it), recording every frame
/// both ways.
class MemoryLink implements FrameLink {
  final _toHost = StreamController<Object>();
  final List<Uint8List> fromHost = [];
  final List<Uint8List> toHost = [];
  void Function(Uint8List frame)? onFromHost;
  @override
  Stream<Object> get frames => _toHost.stream;
  @override
  void send(Uint8List frame) {
    fromHost.add(frame);
    onFromHost?.call(frame);
  }

  @override
  void sendText(String text) {}
  @override
  void close() => _toHost.close();
  @override
  String get address => 'relay';
  void push(Uint8List f) {
    toHost.add(f);
    _toHost.add(f);
  }
}

class Phone {
  final MemoryLink link = MemoryLink();
  final List<HostMessage> received = [];
  late SecureSession session;
  final _ready = Completer<void>();

  Phone(PerchServer server, HostState state) {
    final id = 'phone-${identityHashCode(this)}';
    final rec = state.approveDevice(id, name: 'Phone', permission: DevicePermissions.full);
    final hs = ClientHandshake(secret: rec.keyBytes!, machineId: state.machineId, deviceId: id);
    link.onFromHost = (f) {
      if (!_ready.isCompleted) {
        session = hs.finish(f);
        _ready.complete();
        return;
      }
      final text = session.open(f);
      if (text == null) return;
      final m = decodeHost(text);
      if (m != null) received.add(m);
    };
    server.attach(link);
    link.push(hs.hello);
  }

  Future<void> hello() async {
    await _ready.future;
    send(const Hello(deviceName: 'Phone'));
    await next<Welcome>();
  }

  void send(ClientMessage m) {
    for (final f in session.seal(encodeClient(m))) {
      link.push(f);
    }
  }

  Future<T> next<T extends HostMessage>({bool Function(T)? where, int from = 0}) async {
    await waitUntil(() => received.skip(from).whereType<T>().any((m) => where == null || where(m)),
        timeout: const Duration(seconds: 15));
    return received.skip(from).whereType<T>().firstWhere((m) => where == null || where(m));
  }

  bool sawPlain(String needle) {
    final bytes = utf8.encode(needle);
    bool has(Uint8List f) {
      for (var i = 0; i + bytes.length <= f.length; i++) {
        var ok = true;
        for (var j = 0; j < bytes.length; j++) {
          if (f[i + j] != bytes[j]) {
            ok = false;
            break;
          }
        }
        if (ok) return true;
      }
      return false;
    }

    return link.fromHost.any(has) || link.toHost.any(has);
  }
}

class Host {
  late Directory dir;
  late HostState state;
  late MemoryTokenVault vault;
  late HostAccounts accounts;
  late AccountSignIns signIns;
  late SessionManager manager;
  late PerchServer server;
  late FakeExternalSessions external;
  late FakeConsoleTyper console;
  final List<TerminalLaunch> launches = [];
  final List<ScriptedTokenConsole> tokenConsoles = [];
  var nextPid = 7000;

  Future<void> start(Directory root, String name) async {
    dir = Directory('${root.path}$sep$name')..createSync();
    state = HostState.load(dir.path);
    vault = MemoryTokenVault();
    accounts = HostAccounts(
        vault: vault, store: state, launcher: fakeLauncher(env: {'FAKE_CLAUDE_AUTH_EMAIL': 'owner@example.com'}));
    signIns = AccountSignIns(
      accounts: accounts,
      console: ({required bool visible}) {
        final c = ScriptedTokenConsole(visible: visible);
        tokenConsoles.add(c);
        return c;
      },
      poll: const Duration(milliseconds: 10),
      urlTimeout: const Duration(seconds: 2),
      tokenTimeout: const Duration(seconds: 2),
    );
    external = FakeExternalSessions();
    console = FakeConsoleTyper(currentScreen: promptScreen);
    manager = SessionManager(
      launcher: fakeLauncher(),
      external: external,
      typer: console,
      accounts: accounts,
      claudeConfigDir: '${dir.path}${sep}config',
      openWindow: (l) async {
        launches.add(l);
        final r = l.args.indexOf('--resume');
        external.entries.add(external.entry(
            pid: ++nextPid,
            sessionId: r >= 0 ? l.args[r + 1] : 'dddddddd-2222-4000-8000-${'$nextPid'.padLeft(12, '0')}',
            cwd: dir.path));
      },
      terminalStartTimeout: const Duration(milliseconds: 800),
      terminalPoll: const Duration(milliseconds: 20),
      limitTracker: fastTracker,
    )..endTimeout = const Duration(milliseconds: 500);
    server = PerchServer(manager: manager, state: state, machineName: name, port: 0, signIns: signIns);
    await server.start();
  }

  void transcript(String id) {
    final d = Directory('${dir.path}${sep}config${sep}projects${sep}D--work')..createSync(recursive: true);
    File('${d.path}$sep$id.jsonl').writeAsStringSync('${jsonEncode({
          'type': 'user',
          'timestamp': DateTime.now().subtract(const Duration(minutes: 10)).toUtc().toIso8601String(),
          'message': {'role': 'user', 'content': 'Write the docs.'},
          'sessionId': id,
        })}\n');
  }

  Future<void> stop() async {
    await server.close();
    await manager.dispose();
    await accounts.dispose();
  }
}

AccountInfo work() => AccountInfo(
    id: 'acc-work',
    label: 'Work',
    email: 'work@example.com',
    plan: 'Max',
    createdAtMs: DateTime.now().millisecondsSinceEpoch,
    expiresAtMs: DateTime.now().add(const Duration(days: 365)).millisecondsSinceEpoch);

void main() {
  late Directory tmp;
  late Host a;
  late Host b;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_sacc_');
    a = Host();
    await a.start(tmp, 'Desk');
  });

  tearDown(() async {
    await a.stop();
    try {
      await b.stop();
    } catch (_) {}
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test("on connect: the machine's own login is the first account, and active", () async {
    final p = Phone(a.server, a.state);
    await p.hello();
    final m = await p.next<AccountsMessage>(where: (m) => m.machineLogin.loggedIn);
    expect(m.machineLogin.email, 'owner@example.com');
    expect(m.machineLogin.plan, 'max');
    expect(m.activeAccountId, machineLoginAccountId);
    expect(m.accounts, isEmpty);
  });

  test('sync from the phone reaches every paired machine; tokens only in the vault, never in the clear', () async {
    b = Host();
    await b.start(tmp, 'Laptop');
    for (final h in [a, b]) {
      final p = Phone(h.server, h.state);
      await p.hello();
      final from = p.received.length;
      p.send(SyncAccounts(accounts: [AccountWithToken(info: work(), token: syncedToken)]));
      final m = await p.next<AccountsMessage>(where: (m) => m.accounts.isNotEmpty, from: from);
      expect(m.accounts.single.label, 'Work');
      expect(await h.vault.get('acc-work'), syncedToken);
      final hostJson = File('${h.dir.path}${sep}host.json').readAsStringSync();
      expect(hostJson, contains('Work'));
      expect(hostJson, isNot(contains('sk-ant')));
      expect(p.sawPlain('sk-ant'), isFalse, reason: 'every frame is sealed');
      expect(p.sawPlain('Work'), isFalse);
    }
  });

  test('default account, then removal', () async {
    final p = Phone(a.server, a.state);
    await p.hello();
    p.send(SyncAccounts(accounts: [AccountWithToken(info: work(), token: syncedToken)]));
    await p.next<AccountsMessage>(where: (m) => m.accounts.isNotEmpty);
    p.send(const SetActiveAccount(accountId: 'acc-work'));
    await p.next<AccountsMessage>(where: (m) => m.activeAccountId == 'acc-work');
    p.send(const RemoveAccount(accountId: 'acc-work'));
    final m = await p.next<AccountsMessage>(where: (m) => m.accounts.isEmpty && m.activeAccountId == machineLoginAccountId);
    expect(m.accounts, isEmpty);
    expect(await a.vault.get('acc-work'), isNull);
    p.send(const SetActiveAccount(accountId: 'nope'));
    expect((await p.next<ErrorMessage>()).message, contains('does not have that account'));
  });

  test('adding an account from the phone: link to the asking device only, code, token back, every device told', () async {
    final asking = Phone(a.server, a.state);
    final other = Phone(a.server, a.state);
    await asking.hello();
    await other.hello();
    asking.send(const AccountSignIn(flowId: 'acc-new', action: AccountSignInActions.start, label: 'Side'));
    final link = await asking.next<AccountSignInUpdate>(where: (u) => u.state == AccountSignInStates.url);
    expect(link.url, fakeUrl);
    a.tokenConsoles.single.onType = (_) => a.tokenConsoles.single.screen_ = tokenScreen();
    asking.send(const AccountSignIn(flowId: 'acc-new', action: AccountSignInActions.code, code: 'abc#def'));
    final done = await asking.next<AccountSignInUpdate>(where: (u) => u.state == AccountSignInStates.done);
    expect(done.token, token);
    expect(done.account!.label, 'Side');
    await other.next<AccountsMessage>(where: (m) => m.accounts.any((x) => x.id == 'acc-new'));
    expect(other.received.whereType<AccountSignInUpdate>(), isEmpty);
    expect(asking.sawPlain('sk-ant'), isFalse);
    expect(a.tokenConsoles.single.closed, isTrue);
  });

  test('sign-in failure offers the machine; the visible console picks the token up', () async {
    final p = Phone(a.server, a.state);
    await p.hello();
    p.send(const AccountSignIn(flowId: 'acc-m', action: AccountSignInActions.atMachine, label: 'At desk'));
    await p.next<AccountSignInUpdate>(where: (u) => u.state == AccountSignInStates.atMachine);
    expect(a.tokenConsoles.single.visible, isTrue);
    a.tokenConsoles.single.screen_ = tokenScreen();
    final done = await p.next<AccountSignInUpdate>(where: (u) => u.state == AccountSignInStates.done);
    expect(done.account!.label, 'At desk');
  });

  test('a new session on the chosen account; switching it; Switch account on the usage-limit card', () async {
    final p = Phone(a.server, a.state);
    await p.hello();
    p.send(SyncAccounts(accounts: [AccountWithToken(info: work(), token: syncedToken)]));
    await p.next<AccountsMessage>(where: (m) => m.accounts.isNotEmpty);

    var from = p.received.length;
    p.send(StartSession(cwd: a.dir.path, prompt: 'Say hi', accountId: 'acc-work'));
    await waitUntil(() => a.launches.isNotEmpty);
    expect(a.launches.single.environment[oauthTokenVariable], syncedToken);

    // An owner-started session, switched to Work from the session menu.
    a.transcript(cid);
    a.external.entries.add(a.external.entry(pid: 4242, sessionId: cid, cwd: a.dir.path));
    await a.manager.list();
    from = p.received.length;
    p.send(const SwitchSessionAccount(sessionId: cid, accountId: 'acc-work'));
    final done = await p.next<SessionActionDone>(where: (d) => d.action == SessionActions.switchAccount, from: from);
    expect(done.message, contains('Work'));
    expect(a.external.kills, contains(4242));
    expect(a.launches.last.args, containsAllInOrder(['--resume', cid]));

    // Limit: Switch account moves it back to the machine's login and makes that the default.
    a.manager.limits.hit(cid, resetsAt: DateTime.now().add(const Duration(hours: 1)));
    from = p.received.length;
    p.send(const UsageLimitChoice(choice: LimitChoices.switchAccount, accountId: machineLoginAccountId, makeDefault: true));
    await p.next<UsageLimitMessage>(from: from);
    expect(a.launches.last.environment[oauthTokenVariable], Platform.environment[oauthTokenVariable]);
    expect(a.accounts.activeId, machineLoginAccountId);
    expect(p.sawPlain('sk-ant'), isFalse);
  });
}
