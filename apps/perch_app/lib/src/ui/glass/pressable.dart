import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'click.dart';

enum Haptic { none, selection, light, medium, heavy }

void buzz(Haptic h) {
  switch (h) {
    case Haptic.none:
      break;
    case Haptic.selection:
      HapticFeedback.selectionClick();
    case Haptic.light:
      HapticFeedback.lightImpact();
    case Haptic.medium:
      HapticFeedback.mediumImpact();
    case Haptic.heavy:
      HapticFeedback.heavyImpact();
  }
}

/// A press-aware wrapper: [builder] gets the press amount (0 up, 1 fully pressed; a spring
/// release overshoots below 0 for a bouncy return).
class Pressable extends StatefulWidget {
  final Widget Function(BuildContext context, double pressed, Widget? child) builder;
  final Widget? child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Haptic haptic;

  /// Release with a spring (inflated controls) instead of a plain ease.
  final bool spring;
  final Duration pressDuration;
  final String? semanticLabel;

  const Pressable({
    super.key,
    required this.builder,
    this.child,
    this.onTap,
    this.onLongPress,
    this.haptic = Haptic.light,
    this.spring = false,
    this.pressDuration = const Duration(milliseconds: 110),
    this.semanticLabel,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: 0)..addListener(() => setState(() {}));

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _down() {
    if (!_enabled) return;
    _c.animateTo(1, duration: widget.pressDuration, curve: Curves.easeOut);
  }

  void _up() {
    if (widget.spring) {
      _c.animateWith(SpringSimulation(
          const SpringDescription(mass: 1, stiffness: 520, damping: 14), _c.value, 0, _c.velocity));
    } else {
      _c.animateTo(0, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: _enabled,
      label: widget.semanticLabel,
      child: ClickDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _down(),
        onTapUp: (_) => _up(),
        onTapCancel: _up,
        onTap: widget.onTap == null
            ? null
            : () {
                buzz(widget.haptic);
                // A tap quicker than the press animation still shows a full press.
                if (_c.value < 0.6) {
                  _c.value = 1;
                  _up();
                }
                widget.onTap!();
              },
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                buzz(Haptic.medium);
                _up();
                widget.onLongPress!();
              },
        child: widget.builder(context, _c.value, widget.child),
      ),
    );
  }
}
