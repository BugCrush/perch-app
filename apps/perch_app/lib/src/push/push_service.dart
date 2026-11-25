// Push notifications on Android: Firebase Cloud Messaging brings the host's sealed
// message (data only), this app opens it with the machine's pairing secret and shows a
// local notification; tapping it opens that session. Elsewhere (desktop, web) there is no
// push and every call does nothing.
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:ui' show DartPluginRegistrant;

import '../connection/machine_store.dart';
import 'push_notes.dart';
import 'push_registrar.dart';
import '../ui/glass/widgets.dart' show confirmSheet;

abstract class PushService {
  /// The last notification tapped (also the one that started the app), until consumed.
  ValueListenable<PushTap?> get taps;
  void consumeTap();

  /// Sets up push; never throws (without Firebase the app works as before).
  Future<void> start(String deviceId);

  /// The paired machines now: each machine with a relay learns this device's push token.
  void syncMachines(List<Machine> machines);

  /// A machine was removed: its relay forgets this device's token.
  Future<void> forget(Machine m);

  /// Just paired with [m]: asks once for permission to notify (Android 13+), with a line
  /// saying why, and registers the token.
  Future<void> afterPairing(BuildContext context, Machine m);

  /// Asks for permission to notify unless it was asked before (also at start, for
  /// machines paired before this version).
  Future<void> askOnce(BuildContext context);
}

/// Desktop, web and tests.
class NoPushService implements PushService {
  final ValueNotifier<PushTap?> _taps = ValueNotifier(null);
  @override
  ValueListenable<PushTap?> get taps => _taps;
  @override
  void consumeTap() => _taps.value = null;
  @override
  Future<void> start(String deviceId) async {}
  @override
  void syncMachines(List<Machine> machines) {}
  @override
  Future<void> forget(Machine m) async {}
  @override
  Future<void> afterPairing(BuildContext context, Machine m) async {}
  @override
  Future<void> askOnce(BuildContext context) async {}
}

bool get pushSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

PushService createPushService() => pushSupported ? AndroidPushService() : NoPushService();

const _initSettings = InitializationSettings(android: AndroidInitializationSettings('ic_stat_perch'));

NotificationDetails _details([List<PushButton> buttons = const []]) => NotificationDetails(
      android: AndroidNotificationDetails(
        perchChannelId,
        perchChannelName,
        channelDescription: perchChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
        icon: 'ic_stat_perch',
        category: AndroidNotificationCategory.message,
        actions: [
          for (final b in buttons) AndroidNotificationAction(b.id, b.label, showsUserInterface: b.opensApp, cancelNotification: true)
        ],
      ),
    );

class _TraySink implements NotificationSink {
  final FlutterLocalNotificationsPlugin plugin;
  _TraySink(this.plugin);
  @override
  Future<void> show(
          {required int id,
          required String title,
          required String body,
          required String payload,
          List<PushButton> buttons = const []}) =>
      plugin.show(id: id, title: title, body: body, notificationDetails: _details(buttons), payload: payload);
  @override
  Future<void> cancel(int id) => plugin.cancel(id: id);
}

/// A notification button that acts without opening the app (Continue, Stop). Runs in a
/// background isolate: it connects to the machine itself and sends the action. When the
/// machine cannot be reached, a notification says so; tapping it opens the app, which
/// sends the action once connected.
@pragma('vm:entry-point')
Future<void> perchNotificationAction(NotificationResponse r) async {
  final tap = PushTap.decode(r.payload);
  final action = r.actionId;
  if (tap == null || action == null || action == PushActions.open) return;
  try {
    DartPluginRegistrant.ensureInitialized();
    final machines = await MachineStore().load(fresh: true);
    final want = tap.withAction(action);
    if (await sendPushAction(want, machines, await loadDeviceId())) return;
    final machine = machines.where((m) => m.id == tap.machineId).firstOrNull;
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(settings: _initSettings);
    await _TraySink(plugin).show(
      id: notificationIdFor(tap.machineId, tap.sessionId),
      title: machine?.alias ?? machine?.label ?? 'Perch',
      body: action == PushActions.stop
          ? "Couldn't reach the machine to stop the session. Tap to open Perch and stop it."
          : "Couldn't reach the machine to continue. Tap to open Perch and continue.",
      payload: want.encode(),
    );
  } catch (_) {
    // Nothing more can be done from here.
  }
}

/// Runs in a background isolate when a message arrives with the app in the background or
/// closed.
@pragma('vm:entry-point')
Future<void> perchBackgroundMessage(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(settings: _initSettings);
    await showPushFromStore(message.data, _TraySink(plugin));
  } catch (_) {
    // A message that cannot be shown is dropped.
  }
}

class AndroidPushService implements PushService {
  final _plugin = FlutterLocalNotificationsPlugin();
  final ValueNotifier<PushTap?> _taps = ValueNotifier(null);
  PushRegistrar? _registrar;
  String? _token;
  List<Machine> _machines = const [];
  bool _ready = false;

  @override
  ValueListenable<PushTap?> get taps => _taps;

  @override
  void consumeTap() => _taps.value = null;

  void _tapped(String? payload) {
    final t = PushTap.decode(payload);
    if (t != null) _taps.value = t;
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  @override
  Future<void> start(String deviceId) async {
    _registrar = PushRegistrar(deviceId: deviceId);
    try {
      await _plugin.initialize(
        settings: _initSettings,
        onDidReceiveNotificationResponse: (r) => _tapped(r.payload),
        onDidReceiveBackgroundNotificationResponse: perchNotificationAction,
      );
      await _android?.createNotificationChannel(const AndroidNotificationChannel(
        perchChannelId,
        perchChannelName,
        description: perchChannelDescription,
        importance: Importance.high,
      ));
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) _tapped(launch?.notificationResponse?.payload);
    } catch (_) {}
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(perchBackgroundMessage);
      FirebaseMessaging.onMessage.listen((m) async {
        try {
          // The app is in front: a resumed-differently toast says it already.
          await showPushFromStore(m.data, _TraySink(_plugin), foreground: true);
        } catch (_) {}
      });
      _ready = true;
    } catch (_) {
      return; // no google-services.json in this build: no push
    }
    unawaited(() async {
      // The registration token (what FCM HTTP v1 sends to). firebase_messaging 17 marks it
      // deprecated in favour of installation ids, which the relay does not address.
      try {
        // ignore: deprecated_member_use
        FirebaseMessaging.instance.onTokenRefresh.listen((t) {
          _token = t;
          unawaited(_registrar?.sync(_machines, t));
        });
        // ignore: deprecated_member_use
        _token = await FirebaseMessaging.instance.getToken();
        await _registrar?.sync(_machines, _token);
      } catch (_) {}
    }());
  }

  @override
  void syncMachines(List<Machine> machines) {
    _machines = List.of(machines);
    if (_ready) unawaited(_registrar?.sync(_machines, _token));
  }

  @override
  Future<void> forget(Machine m) async {
    if (_ready) await _registrar?.unregister(m);
  }

  @override
  Future<void> afterPairing(BuildContext context, Machine m) async {
    await askOnce(context);
    final token = _token;
    if (_ready && token != null) await _registrar?.register(m, token);
  }

  @override
  Future<void> askOnce(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('notificationsAsked') != true) {
        await prefs.setBool('notificationsAsked', true);
        final enabled = await _android?.areNotificationsEnabled();
        if (enabled != true && context.mounted) {
          final allow = await confirmSheet(
            context,
            title: 'Notifications',
            body: 'Perch can tell you when a session asks you something, is blocked, '
                'or finishes a turn while you are away from the machine.',
            yes: 'Allow',
            no: 'Not now',
          );
          if (allow) await _android?.requestNotificationsPermission();
        }
      }
    } catch (_) {}
  }
}
