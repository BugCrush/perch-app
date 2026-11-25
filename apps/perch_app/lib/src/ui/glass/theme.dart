import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mosaic.dart';

/// Memory Glass's theme: follow the phone, or always light or dark.
enum GlassMode { system, light, dark }

/// The owner's choice, remembered on this phone.
abstract final class GlassTheme {
  static const prefsKey = 'theme';

  /// Where the Memory Glass prototype kept the choice (read once, if [prefsKey] is unset).
  static const legacyKey = 'lab.glass.theme';
  static final mode = ValueNotifier(GlassMode.system);
  static Future<void>? _loading;

  /// Reads the remembered choice once.
  static Future<void> load() => _loading ??= () async {
        try {
          final prefs = await SharedPreferences.getInstance();
          final saved = prefs.getString(prefsKey) ?? prefs.getString(legacyKey);
          mode.value = GlassMode.values.firstWhere((m) => m.name == saved, orElse: () => GlassMode.system);
        } catch (_) {
          // Keep following the phone.
        }
      }();

  /// Shows and remembers [m].
  static Future<void> choose(GlassMode m) async {
    mode.value = m;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, m.name);
    } catch (_) {
      // Shown, just not remembered.
    }
  }

  /// Whether [m] shows dark with the phone in [platform] brightness.
  static bool isDark(GlassMode m, Brightness platform) =>
      m == GlassMode.dark || (m == GlassMode.system && platform == Brightness.dark);

  /// Forgets the choice (tests).
  @visibleForTesting
  static void reset() {
    _loading = null;
    mode.value = GlassMode.system;
    G.dark = false;
  }
}

/// Sets [G.dark] for the Memory Glass screen below it and redraws that screen when the
/// theme changes (the owner's choice, or the phone's setting while following it), keeping
/// every widget's state.
class GlassThemed extends StatefulWidget {
  final Widget child;
  const GlassThemed({super.key, required this.child});
  @override
  State<GlassThemed> createState() => _GlassThemedState();
}

class _GlassThemedState extends State<GlassThemed> {
  bool? _shown;

  @override
  void initState() {
    super.initState();
    GlassTheme.mode.addListener(_changed);
  }

  @override
  void dispose() {
    GlassTheme.mode.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final dark = GlassTheme.isDark(GlassTheme.mode.value, MediaQuery.platformBrightnessOf(context));
    G.dark = dark;
    if (_shown != null && _shown != dark) {
      // The screens read the theme from G, not from an inherited widget: rebuild them all.
      void rebuild(Element e) {
        e.markNeedsBuild();
        e.visitChildren(rebuild);
      }

      (context as Element).visitChildren(rebuild);
    }
    _shown = dark;
    return widget.child;
  }
}

/// Scrolling on Memory Glass: no Android stretch. The stretch draws the scrolled content
/// through an image filter while the list is pulled past its end, and glass inside that
/// filter can only blur the (empty) filter layer, not the mosaic behind it: the glass turned
/// clear. Pulling past the end bounces instead, which keeps the glass frosted.
class GlassScrollBehavior extends ScrollBehavior {
  const GlassScrollBehavior();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}
