import 'package:flutter/widgets.dart';

/// The Perch logo (Memory Glass draws it into its mosaic).
const logoAsset = 'assets/ui/perch-logo.svg';

/// The logo's colours: the bird's orange, its cream belly and eye, the warm black it sits on.
abstract final class Perch {
  static const orange = Color(0xFFF7532B);
  static const cream = Color(0xFFFCE6D1);
  static const ink = Color(0xFF161310);

  /// Orange light enough to read as text on warm black (6.4:1 on #161310).
  static const ember = Color(0xFFFF7A52);

  /// A quiet amber for the "newer Claude Code" note.
  static const amber = Color(0xFFE9A23B);

  /// LED green for "online" and "working" (an indicator, never text on its own).
  static const led = Color(0xFF3BE36B);
}

/// Font families bundled under assets/ui/fonts (variable fonts; weight set as an axis too).
abstract final class GlassFonts {
  /// Editorial serif (titles, the conversation).
  static const serif = 'PerchSerif';

  /// Readable UI sans.
  static const sans = 'PerchSans';
  static const mono = 'PerchMono';
}

/// A text style for a bundled variable font: the weight is applied as the `wght` axis as well.
TextStyle glassFont(String family, double size, FontWeight weight, Color color,
        {double height = 1.3, double spacing = 0, FontStyle? style}) =>
    TextStyle(
      fontFamily: family,
      fontSize: size,
      fontWeight: weight,
      fontStyle: style,
      fontVariations: [FontVariation('wght', weight.value.toDouble())],
      color: color,
      height: height,
      letterSpacing: spacing,
    );

/// Looping animations (the bird, the working wave, the line loaders) stop when false
/// (widget tests and screenshots).
abstract final class GlassMotion {
  static bool enabled = true;
}

/// Whether looping and decorative motion may run here: not in tests and screenshots
/// ([GlassMotion.enabled]) and not when the platform asks for reduced motion.
bool glassMotionOn(BuildContext context) =>
    GlassMotion.enabled && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

/// A looping 0→1 clock that stands still when motion is off ([glassMotionOn]).
class GlassLoop extends StatefulWidget {
  final Duration period;
  final Widget Function(BuildContext context, double t) builder;

  /// The value shown while motion is off (screenshots, tests, reduce motion).
  final double still;
  const GlassLoop({super.key, required this.period, required this.builder, this.still = 0.3});
  @override
  State<GlassLoop> createState() => _GlassLoopState();
}

class _GlassLoopState extends State<GlassLoop> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.period, value: widget.still);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (glassMotionOn(context)) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
      _c.value = widget.still;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AnimatedBuilder(animation: _c, builder: (context, _) => widget.builder(context, _c.value));
}
