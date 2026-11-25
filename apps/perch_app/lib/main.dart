import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/connection/account_store.dart';
import 'src/connection/board_file.dart';
import 'src/connection/board_store.dart';
import 'src/connection/machine_store.dart';
import 'src/push/push_notes.dart';
import 'src/push/push_service.dart';
import 'src/state/providers.dart';
import 'src/state/session_prefs.dart';
import 'src/connection/pair_links.dart';
import 'src/ui/add_machine_screen.dart';
import 'src/ui/app_lock.dart';
import 'src/ui/drafts.dart';
import 'src/ui/app_menu.dart' show appVersion;
import 'src/ui/app_theme.dart';
import 'src/ui/board_screen.dart';
import 'src/ui/glass/theme.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/intro.dart';
import 'src/ui/resumed_toast.dart';
import 'src/ui/session_screen.dart';
import 'src/ui/sessions_screen.dart';
import 'src/update_check.dart';
import 'src/web_board.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) return webMain();
  // Android's splash (plain warm black) covers the app until the first frame: the stores
  // load side by side to keep that short; the intro's clock starts only after it.
  final push = createPushService();
  final sessionPrefs = SessionPrefs();
  final accounts = PhoneAccounts();
  final board = BoardStore();
  final auth = DeviceAuthenticator();
  late final String deviceId;
  await Future.wait([
    () async {
      deviceId = await loadDeviceId();
      await push.start(deviceId);
    }(),
    sessionPrefs.load(),
    accounts.load(),
    board.load(),
    GlassTheme.load(),
    AppLock.load(),
    Drafts.load(),
    auth.refresh(),
  ]);
  // The board (board.json in the app's own storage; its key in secure storage): read before
  // the first frame so it opens at once, with or without a connection. The first time it
  // takes the projects and model table the older app kept.
  final boardFile = BoardFile(dir: await getApplicationSupportDirectory(), writer: deviceId, keyBox: KeystoreSecretBox());
  await boardFile.load(legacy: board);
  board.attach(boardFile);
  final updates = await createUpdateChecker();
  runApp(ProviderScope(overrides: [
    deviceIdProvider.overrideWithValue(deviceId),
    boardFileProvider.overrideWithValue(boardFile),
    boardRelayProvider.overrideWith((ref) => appBoardRelayFor(ref, boardFile)),
    authenticatorProvider.overrideWithValue(auth),
    sessionPrefsProvider.overrideWithValue(sessionPrefs),
    pushServiceProvider.overrideWithValue(push),
    phoneAccountsProvider.overrideWithValue(accounts),
    boardStoreProvider.overrideWithValue(board),
    updateCheckerProvider.overrideWithValue(updates),
  ], child: const PerchApp()));
  // A few seconds after start: the first screen comes first.
  unawaited(Future<void>.delayed(const Duration(seconds: 5), updates.check));
}

/// "Update available" for this Android app: the version put off with Later is kept on the
/// phone. Off in builds made with `--dart-define=PERCH_UPDATE_CHECK=false` (a store build).
Future<UpdateChecker> createUpdateChecker() async {
  const key = 'perch.update.dismissed';
  try {
    final prefs = await SharedPreferences.getInstance();
    return UpdateChecker(
      current: appVersion,
      enabled: updateCheckOn,
      dismissed: prefs.getString(key),
      saveDismissed: (v) => prefs.setString(key, v),
    );
  } catch (_) {
    return UpdateChecker(current: appVersion, enabled: updateCheckOn);
  }
}

/// The board page in a browser on the machine (served by its host): that machine only, no
/// push, no camera, no account tokens; it opens on the board.
Future<void> webMain() async {
  await GlassTheme.load();
  final Machine machine;
  try {
    machine = await fetchLocalMachine(Uri.base);
  } catch (e) {
    runApp(Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF161310),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text('$e', style: const TextStyle(color: Color(0xFFFCE6D1), fontSize: 18)),
          ),
        ),
      ),
    ));
    return;
  }
  final sessionPrefs = SessionPrefs();
  await sessionPrefs.load();
  final board = BoardStore();
  await board.load();
  // The board page keeps the board in memory only: the machine has it.
  final boardFile = BoardFile(dir: null, writer: 'board-page', keyBox: MemorySecretBox());
  await boardFile.load(legacy: board);
  board.attach(boardFile);
  runApp(ProviderScope(overrides: [
    deviceIdProvider.overrideWithValue('board-page'),
    boardFileProvider.overrideWithValue(boardFile),
    deviceNameProvider.overrideWithValue('Board page on this machine'),
    machineStoreProvider.overrideWithValue(LocalMachineStore(machine)),
    sessionPrefsProvider.overrideWithValue(sessionPrefs),
    phoneAccountsProvider.overrideWithValue(PhoneAccounts(box: MemorySecretBox())),
    boardStoreProvider.overrideWithValue(board),
  ], child: const PerchApp(home: WebBoardHome())));
}

/// The board page's first screen: the board, with the rest of the app a tap away.
class WebBoardHome extends ConsumerWidget {
  const WebBoardHome({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machines = ref.watch(machinesProvider);
    final registry = ref.watch(connectionsProvider);
    return BoardView(
      connections: [for (final m in machines) registry.of(m)],
      store: ref.watch(boardStoreProvider),
      root: true,
      onHome: () => openGlass<void>(context, const HomeScreen()),
    );
  }
}

class PerchApp extends ConsumerStatefulWidget {
  /// The first screen (the board on the board page; default the home screen).
  final Widget home;
  const PerchApp({super.key, this.home = const HomeScreen()});

  @override
  ConsumerState<PerchApp> createState() => _PerchAppState();
}

class _PerchAppState extends ConsumerState<PerchApp> {
  final _navigator = GlobalKey<NavigatorState>();
  late final AppLifecycleListener _lifecycle;
  late final PushService _push;
  StreamSubscription<dynamic>? _reports;
  final _pairLinks = PairLinks();

  @override
  void initState() {
    super.initState();
    GlassTheme.load();
    _push = ref.read(pushServiceProvider);
    _push.taps.addListener(_openTapped);
    // A tap that arrived while the app was locked is opened once it is unlocked.
    AppLock.locked.addListener(_openTapped);
    // A pairing QR code scanned by the phone's camera opens Add machine with its link.
    if (!kIsWeb) {
      _pairLinks.pending.addListener(_openPairLink);
      AppLock.locked.addListener(_openPairLink);
      unawaited(_pairLinks.start());
    }
    // The host sends no notification for the session in front of the owner, and none is
    // in front of them while the app is in the background.
    _lifecycle = AppLifecycleListener(onStateChange: (s) {
      final registry = ref.read(connectionsProvider);
      final relay = ref.read(boardRelayProvider);
      if (s == AppLifecycleState.resumed) {
        registry.appInForeground = true;
        relay?.foreground = true;
      }
      if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden || s == AppLifecycleState.detached) {
        registry.appInForeground = false;
        relay?.foreground = false;
      }
    });
    // The board's encrypted copy in the relay: so an idea written with every machine off
    // still reaches them.
    ref.read(boardRelayProvider)?.start();
    // Each machine's relay learns this device's push token; a tap waiting for the saved
    // machines (cold start) is opened when they arrive.
    ref.listenManual(machinesProvider, (_, machines) {
      _push.syncMachines(machines);
      _openTapped();
      _askOnce(machines);
    }, fireImmediately: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openTapped());
    // A link that started the app arrives before the first screen: opened after it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPairLink());
    // A session that resumed after a usage limit but not the same way: a 15-second toast.
    _reports = ref.read(connectionsProvider).resumeReports.listen((r) {
      if (!r.report.changed) return;
      final overlay = toastLayer.currentState;
      if (overlay == null) return;
      showResumedToast(
        overlay,
        text: resumedToastText(r.report.sessionName, r.report.text),
        onStop: () => r.connection.interrupt(r.report.sessionId),
        onOpen: () => _navigator.currentState
            ?.push(glassRoute<void>(SessionScreen(connection: r.connection, sessionId: r.report.sessionId))),
      );
    });
  }

  @override
  void dispose() {
    _push.taps.removeListener(_openTapped);
    AppLock.locked.removeListener(_openTapped);
    _pairLinks.pending.removeListener(_openPairLink);
    AppLock.locked.removeListener(_openPairLink);
    _reports?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  bool _asked = false;

  /// A machine paired before notifications existed: ask once at start.
  void _askOnce(List<Machine> machines) {
    if (_asked || machines.isEmpty) return;
    _asked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _navigator.currentContext;
      if (ctx != null) _push.askOnce(ctx);
    });
  }

  /// Opens Add machine with a pairing link the camera opened (after the app lock).
  void _openPairLink() {
    final nav = _navigator.currentState;
    if (nav == null || AppLock.locked.value || _pairLinks.pending.value == null) return;
    final link = _pairLinks.take()!;
    nav.push(glassRoute<void>(AddMachineScreen(initialLink: link)));
  }

  /// Opens the session of a tapped notification (also from a cold start, once the saved
  /// machines are loaded): the machine's sessions below it, so Back goes there.
  void _openTapped() {
    final PushTap? tap = _push.taps.value;
    final nav = _navigator.currentState;
    if (tap == null || nav == null || AppLock.locked.value) return;
    final machine = ref.read(machinesProvider).where((m) => m.id == tap.machineId).firstOrNull;
    if (machine == null) return; // not loaded yet: tried again when the machines arrive
    _push.consumeTap();
    final conn = ref.read(connectionsProvider).of(machine);
    // A button whose background send could not reach the machine: sent now, once online.
    final action = pushActionMessage(tap);
    if (action != null) unawaited(conn.sendWhenOnline(action));
    nav.popUntil((r) => r.isFirst);
    nav.push(glassRoute<void>(SessionsScreen(connection: conn)));
    // The machine's usage-limit notification opens the machine (its card is on top).
    if (!tap.forMachine) nav.push(glassRoute<void>(SessionScreen(connection: conn, sessionId: tap.sessionId)));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Perch',
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      theme: perchTheme(),
      // On a cold start the intro plays over the first screen (not on the board page).
      builder: (context, child) => glassAppBuilder(
          context,
          withToastLayer(kIsWeb
              ? (child ?? const SizedBox())
              : IntroGate(child: LockGate(child: child ?? const SizedBox())))),
      home: widget.home,
    );
  }
}
