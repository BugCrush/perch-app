// Riverpod providers: saved machines and one live connection per machine.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:url_launcher/url_launcher.dart';

import '../connection/account_store.dart';
import '../connection/board_file.dart';
import '../connection/board_relay_app.dart';
import '../connection/board_store.dart';
import '../connection/host_connection.dart';
import '../connection/machine_store.dart';
import '../push/push_service.dart';
import '../update_check.dart';
import 'session_prefs.dart';

/// How WebSockets are opened (overridden in tests).
final channelFactoryProvider = Provider<ChannelFactory>((ref) => defaultChannelFactory);

/// The name this device gives itself when pairing.
final deviceNameProvider = Provider<String>((ref) => 'Android');

/// This app's device id (loaded in main() with loadDeviceId; fixed in tests).
final deviceIdProvider = Provider<String>((ref) => 'test-device');

final machineStoreProvider = Provider<MachineStore>((ref) => MachineStore());

/// This phone's pins, hidden sessions and mutes (loaded in main(); in memory in tests).
final sessionPrefsProvider = Provider<SessionPrefs>((ref) => SessionPrefs(persist: false));

/// Push notifications (Android; a no-op elsewhere and in tests). Set in main().
final pushServiceProvider = Provider<PushService>((ref) => NoPushService());

/// The owner's Claude Code accounts on this phone (loaded in main() from the keystore; in
/// memory in tests).
final phoneAccountsProvider = Provider<PhoneAccounts>((ref) => PhoneAccounts(box: MemorySecretBox()));

/// "Update available": asks GitHub for the newest release (main() turns it on for the
/// Android app; tests and the board page never ask).
final updateCheckerProvider = Provider<UpdateChecker>((ref) => UpdateChecker.disabled());

/// Opens the update's download in the phone's browser (overridden in tests).
final updateOpenerProvider =
    Provider<Future<bool> Function(Uri url)>((ref) => (url) => launchUrl(url, mode: LaunchMode.externalApplication));

/// The model table and the board's quick-add defaults (loaded in main(); in memory in tests).
/// The board kept on this device (memory only unless main gives the real one).
final boardFileProvider = Provider<BoardFile>((ref) {
  final f = BoardFile(dir: null, writer: ref.watch(deviceIdProvider), keyBox: MemorySecretBox());
  ref.onDispose(f.dispose);
  return f;
});

final boardStoreProvider = Provider<BoardStore>((ref) => BoardStore(persist: false)..attach(ref.watch(boardFileProvider)));

/// The board's sync with its encrypted copy in the relay (null: none, as in tests and on
/// the board page). Uses the relay of any paired machine.
final boardRelayProvider = Provider<AppBoardRelay?>((ref) => null);

/// The relay sync for [file] in the app (main overrides [boardRelayProvider] with this).
AppBoardRelay appBoardRelayFor(Ref ref, BoardFile file) {
  final r = AppBoardRelay(
      file: file,
      relayUrl: () => ref.read(machinesProvider).map((m) => m.relayUrl).whereType<String>().firstOrNull);
  ref.onDispose(r.dispose);
  return r;
}

class MachinesNotifier extends Notifier<List<Machine>> {
  bool _loaded = false;

  @override
  List<Machine> build() {
    unawaited(_load());
    return const [];
  }

  Future<void> _load() async {
    final saved = await ref.read(machineStoreProvider).load();
    if (_loaded) return;
    _loaded = true;
    // Keep machines added while loading.
    final ids = {for (final m in saved) m.id};
    state = [...saved, ...state.where((m) => !ids.contains(m.id))];
  }

  Future<void> add(Machine m) async {
    final i = state.indexWhere((x) => x.id == m.id);
    state = i >= 0 ? [...state.sublist(0, i), m, ...state.sublist(i + 1)] : [...state, m];
    await ref.read(machineStoreProvider).save(m);
  }

  /// Saves a machine from a pairing link. [replacing] is the card whose "Pair again" led
  /// here (a phase 1 machine, or one whose host forgot its devices); it is removed when
  /// the link is for another machine id.
  Future<Machine> pair(PairingLink link, {String? replacing}) async {
    var m = Machine.fromLink(link);
    // This device's name for the machine stays (the same machine id, or the card being
    // paired again).
    final before = state.where((x) => x.id == m.id).firstOrNull ?? state.where((x) => x.id == replacing).firstOrNull;
    if (before?.alias != null) m = m.copyWith(alias: before!.alias);
    if (replacing != null && replacing != m.id) await remove(replacing);
    ref.read(connectionsProvider).drop(m.id); // a new secret: start over
    await add(m);
    return m;
  }

  /// Sets this device's name for a machine ([alias] null: its own name again). The alias
  /// is trimmed; a blank one or one longer than [maxAliasLength] is refused
  /// ([ArgumentError]). An alias equal to the machine's own name is no alias.
  Future<void> rename(String id, String? alias) async {
    final i = state.indexWhere((x) => x.id == id);
    if (i < 0) return;
    final old = state[i];
    String? a;
    if (alias != null) {
      final error = aliasError(alias);
      if (error != null) throw ArgumentError(error);
      a = alias.trim();
      final own = ref.read(connectionsProvider).byId(id)?.ownName ?? old.label;
      if (a == own) a = null;
    }
    final m = a == null ? old.copyWith(clearAlias: true) : old.copyWith(alias: a);
    final c = ref.read(connectionsProvider).byId(id);
    if (c != null) c.machine = c.machine.copyWith(alias: a, clearAlias: a == null);
    await add(m);
  }

  /// The host reported a change (its name, relay URL or LAN addresses): saved, keeping
  /// this device's alias. A machine removed meanwhile stays removed.
  Future<void> updateFromHost(Machine m) async {
    final i = state.indexWhere((x) => x.id == m.id);
    if (i < 0) return;
    final alias = state[i].alias;
    await add(alias == null ? m.copyWith(clearAlias: true) : m.copyWith(alias: alias));
  }

  Future<void> remove(String id) async {
    for (final m in state.where((m) => m.id == id)) {
      unawaited(ref.read(pushServiceProvider).forget(m));
    }
    ref.read(connectionsProvider).drop(id);
    unawaited(ref.read(sessionPrefsProvider).forgetMachine(id));
    state = state.where((m) => m.id != id).toList();
    await ref.read(machineStoreProvider).remove(id);
  }
}

final machinesProvider = NotifierProvider<MachinesNotifier, List<Machine>>(MachinesNotifier.new);

/// One HostConnection per machine, created and connected on first use.
class ConnectionRegistry {
  final ChannelFactory channelFactory;
  final String deviceName;
  final String deviceId;

  /// Saves a machine whose relay URL or LAN addresses the host reported changed.
  final void Function(Machine m)? onMachineUpdated;

  /// The owner's accounts, given to every machine as it connects.
  final AccountSource? accounts;

  /// The owner's model table, synced with every machine.
  final ModelTableSource? models;

  /// The board this device keeps, synced with every machine that keeps it too.
  final BoardFile? boardFile;

  /// A sign-in finished on a machine (with its token): the phone keeps the account, whether
  /// or not the sheet that started it is still open.
  final Future<void> Function(AccountInfo account, String token)? onSignedIn;
  ConnectionRegistry(
      {required this.channelFactory,
      required this.deviceName,
      this.deviceId = 'device',
      this.onMachineUpdated,
      this.accounts,
      this.models,
      this.boardFile,
      this.onSignedIn});

  /// Every connected machine gets the model table (the owner changed it).
  void syncModelTable() {
    for (final c in _byId.values) {
      c.syncModelTable();
    }
  }

  /// Every connected machine gets the phone's project list.
  void syncProjects() {
    for (final c in _byId.values) {
      c.syncProjects();
    }
  }

  /// Every connected machine gets the accounts again (one was added or signed in afresh).
  void syncAccounts() {
    for (final c in _byId.values) {
      c.syncAccounts();
    }
  }

  /// Every connected machine forgets [accountId] (the others when they next connect).
  void removeAccount(String accountId) {
    for (final c in _byId.values) {
      c.removeAccount(accountId);
    }
  }

  final Map<String, HostConnection> _byId = {};
  bool _foreground = true;
  final _reports = StreamController<({HostConnection connection, ResumeReport report})>.broadcast();

  /// Every machine's resume reports (the app shows a toast for those that changed).
  Stream<({HostConnection connection, ResumeReport report})> get resumeReports => _reports.stream;

  /// Whether the app is in front of the owner; every connection tells its host.
  bool get appInForeground => _foreground;
  set appInForeground(bool value) {
    _foreground = value;
    for (final c in _byId.values) {
      c.appInForeground = value;
    }
  }

  HostConnection of(Machine m) {
    final existing = _byId[m.id];
    if (existing != null &&
        existing.machine.secret == m.secret &&
        (m.deviceKey == null || m.deviceKey == existing.machine.deviceKey)) {
      // Same pairing: keep the connection; take new addresses for the next connect. A copy
      // saved before the connection got its device key keeps the key the connection has.
      final key = existing.machine.deviceKey;
      existing.machine = m.deviceKey == null && key != null ? m.copyWith(deviceKey: key) : m;
      return existing;
    }
    existing?.dispose();
    final c = HostConnection(m,
        channelFactory: channelFactory,
        deviceName: deviceName,
        deviceId: deviceId,
        onMachineUpdated: onMachineUpdated,
        accountSource: accounts,
        modelSource: models,
        boardFile: boardFile)
      ..appInForeground = _foreground;
    _byId[m.id] = c;
    c.resumeReports.listen((r) {
      if (!_reports.isClosed) _reports.add((connection: c, report: r));
    });
    c.signIns.listen((u) async {
      final a = u.account, t = u.token;
      if (u.state != AccountSignInStates.done || a == null || t == null) return;
      await onSignedIn?.call(a, t);
      syncAccounts();
    });
    c.connect();
    return c;
  }

  HostConnection? byId(String id) => _byId[id];
  Iterable<HostConnection> get all => _byId.values;

  void drop(String id) => _byId.remove(id)?.dispose();

  void dispose() {
    for (final c in _byId.values) {
      c.dispose();
    }
    _byId.clear();
    _reports.close();
  }
}

final connectionsProvider = Provider<ConnectionRegistry>((ref) {
  final r = ConnectionRegistry(
      channelFactory: ref.watch(channelFactoryProvider),
      deviceName: ref.watch(deviceNameProvider),
      deviceId: ref.watch(deviceIdProvider),
      accounts: ref.watch(phoneAccountsProvider),
      models: ref.watch(boardStoreProvider),
      boardFile: ref.watch(boardFileProvider),
      onSignedIn: (a, t) => ref.read(phoneAccountsProvider).put(a, t),
      onMachineUpdated: (m) => Timer.run(() => ref.read(machinesProvider.notifier).updateFromHost(m)));
  ref.watch(boardStoreProvider)
    ..onTableChanged = r.syncModelTable
    ..onProjectsChanged = r.syncProjects;
  ref.onDispose(r.dispose);
  return r;
});

/// States that need the owner.
bool needsAttention(SessionState s) =>
    s == SessionState.waitingQuestion ||
    s == SessionState.waitingPermission ||
    s == SessionState.waitingPlan ||
    s == SessionState.blocked;

/// A running session that needs the owner. Sessions whose process is gone never do.
bool needsYou(SessionSummary s) => s.live && needsAttention(s.state);

/// How many sessions need the owner.
int sessionsNeedingYou(Iterable<SessionSummary> sessions) => sessions.where(needsYou).length;

/// States in which a session is still running.
bool isActive(SessionState s) => s != SessionState.finished && s != SessionState.stopped;
