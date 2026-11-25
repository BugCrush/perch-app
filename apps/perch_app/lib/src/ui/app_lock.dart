// App lock: the phone's fingerprint, face or PIN when Perch opens, and when it comes back
// after a while in the background. Nothing extra before risky actions (the owner's choice),
// and the notification buttons that act in the background (Continue, Stop) are not locked.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:shared_preferences/shared_preferences.dart';

import 'glass/mosaic.dart';
import 'glass/widgets.dart';

/// How long Perch may stay in the background before it locks again.
enum LockAfter {
  immediately(Duration.zero, 'Immediately'),
  oneMinute(Duration(minutes: 1), 'After 1 minute'),
  fiveMinutes(Duration(minutes: 5), 'After 5 minutes'),
  fifteenMinutes(Duration(minutes: 15), 'After 15 minutes');

  final Duration duration;
  final String label;
  const LockAfter(this.duration, this.label);
}

/// The lock's settings (shared preferences) and whether it is locked now.
abstract final class AppLock {
  static const enabledKey = 'appLock.enabled';
  static const afterKey = 'appLock.after';

  /// On by default.
  static final enabled = ValueNotifier(true);
  static final after = ValueNotifier(LockAfter.fiveMinutes);

  /// True while the lock covers the app (a notification tap waits for it to open).
  static final locked = ValueNotifier(false);

  /// The clock the lock measures time in the background with (tests replace it).
  static DateTime Function() clock = DateTime.now;
  static Future<void>? _loading;

  static Future<void> load() => _loading ??= () async {
        try {
          final prefs = await SharedPreferences.getInstance();
          enabled.value = prefs.getBool(enabledKey) ?? true;
          final a = prefs.getString(afterKey);
          after.value = LockAfter.values.firstWhere((v) => v.name == a, orElse: () => LockAfter.fiveMinutes);
        } catch (_) {
          // The defaults.
        }
      }();

  static Future<void> setEnabled(bool on) async {
    enabled.value = on;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(enabledKey, on);
    } catch (_) {}
  }

  static Future<void> setAfter(LockAfter a) async {
    after.value = a;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(afterKey, a.name);
    } catch (_) {}
  }

  @visibleForTesting
  static void reset() {
    _loading = null;
    enabled.value = true;
    after.value = LockAfter.fiveMinutes;
    locked.value = false;
    clock = DateTime.now;
  }
}

/// The phone's own check (fingerprint, face, or its PIN / pattern / password).
abstract interface class Authenticator {
  /// Whether the phone has a screen lock Perch can ask for (false: Perch never locks).
  bool get available;

  /// Reads [available] again (the owner may have set a screen lock meanwhile).
  Future<void> refresh();

  /// Asks the owner; true when they passed.
  Future<bool> authenticate();
}

/// No check at all (tests, the board page).
class NoAuthenticator implements Authenticator {
  const NoAuthenticator();
  @override
  bool get available => false;
  @override
  Future<void> refresh() async {}
  @override
  Future<bool> authenticate() async => true;
}

/// The real check through local_auth: biometrics with the phone's PIN as the fallback.
class DeviceAuthenticator implements Authenticator {
  final LocalAuthentication _auth = LocalAuthentication();
  bool _available = false;

  @override
  bool get available => _available;

  @override
  Future<void> refresh() async {
    try {
      _available = await _auth.isDeviceSupported();
    } catch (_) {
      _available = false;
    }
  }

  @override
  Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(localizedReason: 'Unlock Perch', persistAcrossBackgrounding: true);
    } on LocalAuthException catch (e) {
      if (e.code == LocalAuthExceptionCode.noCredentialsSet) {
        // No screen lock after all: never lock.
        _available = false;
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}

/// The check the app uses (set in main(); none in tests and on the board page).
final authenticatorProvider = Provider<Authenticator>((ref) => const NoAuthenticator());

/// Covers the app while it is locked; asks for the phone's check when it shows.
class LockGate extends ConsumerStatefulWidget {
  final Widget child;
  const LockGate({super.key, required this.child});

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> {
  late final AppLifecycleListener _lifecycle;
  late final Authenticator _auth = ref.read(authenticatorProvider);
  DateTime? _backgroundAt;
  bool _asking = false;

  bool get _wanted => AppLock.enabled.value && _auth.available;

  @override
  void initState() {
    super.initState();
    AppLock.locked.value = _wanted; // a cold start
    AppLock.enabled.addListener(_settingChanged);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    if (AppLock.locked.value) WidgetsBinding.instance.addPostFrameCallback((_) => _ask());
  }

  @override
  void dispose() {
    AppLock.enabled.removeListener(_settingChanged);
    _lifecycle.dispose();
    super.dispose();
  }

  void _settingChanged() {
    if (!AppLock.enabled.value && AppLock.locked.value) _open();
  }

  Future<void> _onLifecycle(AppLifecycleState s) async {
    if (_asking) return; // the check's own dialog moves the app through these states
    if (s == AppLifecycleState.hidden || s == AppLifecycleState.paused) {
      _backgroundAt ??= AppLock.clock();
      return;
    }
    if (s != AppLifecycleState.resumed) return;
    final since = _backgroundAt;
    _backgroundAt = null;
    if (since == null || AppLock.locked.value) return;
    await _auth.refresh();
    if (!mounted || !_wanted) return;
    if (AppLock.clock().difference(since) >= AppLock.after.value.duration) {
      setState(() => AppLock.locked.value = true);
      unawaited(_ask());
    }
  }

  void _open() {
    if (!mounted) return;
    setState(() => AppLock.locked.value = false);
  }

  Future<void> _ask() async {
    if (_asking || !AppLock.locked.value) return;
    _asking = true;
    try {
      final ok = await _auth.authenticate();
      if (ok || !_auth.available) _open();
    } finally {
      _asking = false;
      _backgroundAt = null;
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: AppLock.locked,
        builder: (context, locked, child) => Stack(children: [
          // Kept (with its state) under the lock, but not reachable.
          Positioned.fill(child: ExcludeSemantics(excluding: locked, child: IgnorePointer(ignoring: locked, child: child))),
          if (locked) Positioned.fill(child: LockedView(onUnlock: _ask)),
        ]),
        child: widget.child,
      );
}

/// The lock's screen: the bird on glass, "Perch is locked", and Unlock.
class LockedView extends StatelessWidget {
  final VoidCallback onUnlock;
  const LockedView({super.key, required this.onUnlock});

  @override
  Widget build(BuildContext context) => DefaultTextStyle(
        // Above the Navigator there is no Material: no default underline.
        style: const TextStyle(decoration: TextDecoration.none),
        child: ColoredBox(
          key: const ValueKey('app-locked'),
          color: G.deep,
          child: Stack(children: [
            Positioned.fill(child: MosaicBackdrop(seed: 7, fade: G.deep, fadeFrom: 0.42, pixel: 0.75, flap: true)),
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                  child: Frost(
                    tone: G.deep,
                    tint: 0.6,
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const Icon(Icons.lock_rounded, size: 28, color: G.text),
                      const SizedBox(height: 10),
                      Text('Perch is locked', textAlign: TextAlign.center, style: gSerif(28, w: FontWeight.w500)),
                      const SizedBox(height: 6),
                      Text('Use your fingerprint, face or the phone\'s PIN.',
                          textAlign: TextAlign.center, style: gSans(14, FontWeight.w500, color: G.muted)),
                      const SizedBox(height: 16),
                      GlassButton(
                          key: const ValueKey('unlock'),
                          label: 'Unlock',
                          warm: true,
                          icon: Icons.fingerprint_rounded,
                          onTap: onUnlock),
                    ]),
                  ),
                ),
              ),
            ),
          ]),
        ),
      );
}
