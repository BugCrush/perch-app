// What every Memory Glass screen sits in: the Material bits it borrows (text selection,
// the keyboard, notes) themed to match, the light/dark switch, and the pixel-reveal route.
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart'
    show Brightness, ColorScheme, PageRouteBuilder, TextSelectionThemeData, ThemeData;

import 'glass/mosaic.dart';
import 'glass/palette.dart';
import 'glass/theme.dart';

/// The Material theme under Memory Glass: dark, orange accents, Manrope.
ThemeData perchTheme() => ThemeData(
      useMaterial3: true,
      fontFamily: GlassFonts.sans,
      colorScheme: ColorScheme.fromSeed(seedColor: Perch.orange, brightness: Brightness.dark)
          .copyWith(primary: Perch.orange, onPrimary: Perch.ink, surface: const Color(0xFF1B1519)),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: Perch.orange,
        selectionColor: Perch.orange.withValues(alpha: 0.4),
        selectionHandleColor: Perch.orange,
      ),
    );

/// The app's builder: Memory Glass's theme (light or dark, redrawn on change) around every
/// route, sheet and note.
Widget glassAppBuilder(BuildContext context, Widget? child) =>
    GlassThemed(child: StatusBarShade(child: child ?? const SizedBox()));

/// The app draws edge to edge: a solid band behind Android's status bar, so a screen's
/// content scrolls under it instead of showing through the clock and icons.
class StatusBarShade extends StatelessWidget {
  final Widget child;
  const StatusBarShade({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.viewPaddingOf(context).top;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Light icons on the dark band.
      value: SystemUiOverlayStyle.light.copyWith(statusBarColor: const Color(0x00000000)),
      child: Stack(children: [
        Positioned.fill(child: child),
        if (top > 0)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: top,
            child: IgnorePointer(child: ColoredBox(key: const ValueKey('status-bar-shade'), color: G.deep)),
          ),
      ]),
    );
  }
}

/// A route to a Memory Glass screen: the new screen shows through a dissolving mosaic.
Route<T> glassRoute<T>(Widget page, {RouteSettings? settings}) => PageRouteBuilder<T>(
      settings: settings,
      transitionDuration: const Duration(milliseconds: 560),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (context, a, b) => page,
      transitionsBuilder: (context, a, b, child) => AnimatedBuilder(
        animation: a,
        child: child,
        builder: (context, child) => a.status == AnimationStatus.reverse || !glassMotionOn(context)
            ? FadeTransition(opacity: a, child: child)
            : CustomPaint(foregroundPainter: PixelCover(Curves.easeOut.transform(a.value)), child: child),
      ),
    );

/// Opens [page] with [glassRoute].
Future<T?> openGlass<T>(BuildContext context, Widget page) => Navigator.of(context).push(glassRoute<T>(page));
