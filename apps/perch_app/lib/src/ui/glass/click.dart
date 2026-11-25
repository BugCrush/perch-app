import 'package:flutter/widgets.dart';

/// A [GestureDetector] that shows the hand cursor (in a browser or on a desktop) whenever
/// it takes a tap or a long press. Use it instead of a plain GestureDetector for anything
/// clickable: Flutter shows the hand only where a MouseRegion asks for it.
class ClickDetector extends StatelessWidget {
  final Widget? child;
  final HitTestBehavior? behavior;
  final GestureTapCallback? onTap;
  final GestureLongPressCallback? onLongPress;
  final GestureTapDownCallback? onTapDown;
  final GestureTapUpCallback? onTapUp;
  final GestureTapCancelCallback? onTapCancel;
  final GestureDragEndCallback? onHorizontalDragEnd;

  const ClickDetector({
    super.key,
    this.child,
    this.behavior,
    this.onTap,
    this.onLongPress,
    this.onTapDown,
    this.onTapUp,
    this.onTapCancel,
    this.onHorizontalDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final g = GestureDetector(
      behavior: behavior,
      onTap: onTap,
      onLongPress: onLongPress,
      onTapDown: onTapDown,
      onTapUp: onTapUp,
      onTapCancel: onTapCancel,
      onHorizontalDragEnd: onHorizontalDragEnd,
      child: child,
    );
    if (onTap == null && onLongPress == null) return g;
    return MouseRegion(cursor: SystemMouseCursors.click, child: g);
  }
}
