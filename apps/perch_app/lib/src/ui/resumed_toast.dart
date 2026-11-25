// The toast after a session resumed from a usage limit but not the same way (PRD 7.6): it
// stays 15 seconds, counting down on a ring, with Stop (interrupts the session) and Open.
// The same words stay in the conversation as a lasting note, written by the host.
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Material, MaterialType;

import 'glass/dots.dart';
import 'glass/mosaic.dart' show Frost, G;
import 'glass/palette.dart';
import 'glass/pressable.dart';
import 'glass/widgets.dart';

/// How long the toast stays.
const resumedToastLife = Duration(seconds: 15);

OverlayEntry? _toast;

/// The app's own layer for toasts, above every screen (the navigator rearranges its own
/// overlay when routes change, which can bury an entry under the screen).
final toastLayer = GlobalKey<OverlayState>();

/// [child] (the navigator) with the toast layer over it; an empty layer lets every touch
/// through.
Widget withToastLayer(Widget child) => Stack(children: [
      Positioned.fill(child: child),
      Positioned.fill(child: Overlay(key: toastLayer)),
    ]);

/// `Docs resumed without the subagent`: the session's name and the host's note.
String resumedToastText(String sessionName, String note) {
  final name = sessionName.trim().isEmpty ? 'A session' : sessionName.trim();
  if (note.isEmpty) return '$name resumed differently';
  return '$name ${note[0].toLowerCase()}${note.substring(1)}';
}

/// Shows the toast over [overlay] (replacing one already showing).
void showResumedToast(OverlayState overlay, {required String text, VoidCallback? onStop, VoidCallback? onOpen}) {
  _toast?.remove();
  _toast = null;
  late OverlayEntry entry;
  void gone() {
    if (entry.mounted) entry.remove();
    if (_toast == entry) _toast = null;
  }

  entry = OverlayEntry(builder: (_) => ResumedToast(text: text, onStop: onStop, onOpen: onOpen, onGone: gone));
  _toast = entry;
  overlay.insert(entry);
}

class ResumedToast extends StatefulWidget {
  final String text;
  final VoidCallback? onStop;
  final VoidCallback? onOpen;
  final VoidCallback onGone;
  const ResumedToast({super.key, required this.text, required this.onGone, this.onStop, this.onOpen});

  @override
  State<ResumedToast> createState() => _ResumedToastState();
}

class _ResumedToastState extends State<ResumedToast> with TickerProviderStateMixin {
  late final AnimationController _in =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 460))..forward();
  late final AnimationController _life = AnimationController(vsync: this, duration: resumedToastLife);
  bool _stopped = false;

  @override
  void initState() {
    super.initState();
    buzz(Haptic.light);
    _life.addStatusListener((st) {
      if (st == AnimationStatus.completed) _hide();
    });
    _life.forward();
  }

  Future<void> _hide() async {
    if (!mounted) return;
    await _in.reverse();
    widget.onGone();
  }

  @override
  void dispose() {
    _in.dispose();
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Positioned(
      left: 10,
      right: 10,
      bottom: mq.padding.bottom + mq.viewInsets.bottom + 96,
      child: FadeTransition(
        opacity: _in,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.6), end: Offset.zero)
              .animate(CurvedAnimation(parent: _in, curve: Curves.easeOutBack)),
          child: Material(
            type: MaterialType.transparency,
            child: AnimatedBuilder(
              animation: _life,
              builder: (context, _) {
                final left = 1 - _life.value;
                final seconds = (resumedToastLife.inSeconds * left).ceil();
                return Frost(
                  key: const ValueKey('resumed-toast'),
                  radius: 26,
                  tint: 0.78,
                  tone: G.deep,
                  rim: true,
                  padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                  child: Row(children: [
                    SizedBox.square(
                      dimension: 40,
                      child: Stack(alignment: Alignment.center, children: [
                        CustomPaint(size: const Size.square(40), painter: _Ring(left)),
                        DotMatrix('$seconds', dot: 2.4, glow: null),
                      ]),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(_stopped ? 'Stopped. The session waits for you.' : widget.text,
                          style: gSans(13.5, FontWeight.w600)),
                    ),
                    if (!_stopped && widget.onStop != null) ...[
                      const SizedBox(width: 8),
                      GlassButton(
                        key: const ValueKey('toast-stop'),
                        label: 'Stop',
                        warm: true,
                        compact: true,
                        onTap: () {
                          buzz(Haptic.heavy);
                          setState(() => _stopped = true);
                          _life.stop();
                          widget.onStop!();
                          Future<void>.delayed(const Duration(milliseconds: 1600), _hide);
                        },
                      ),
                    ],
                    if (widget.onOpen != null) ...[
                      const SizedBox(width: 6),
                      GlassButton(
                        key: const ValueKey('toast-open'),
                        label: 'Open',
                        compact: true,
                        onTap: () {
                          _life.stop();
                          widget.onOpen!();
                          _hide();
                        },
                      ),
                    ],
                  ]),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Ring extends CustomPainter {
  final double left;
  _Ring(this.left);
  @override
  void paint(Canvas canvas, Size size) {
    final r = (Offset.zero & size).deflate(2);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, 0, 6.283, false, p..color = const Color(0x33FFFFFF));
    canvas.drawArc(r, -1.5708, 6.283 * left, false, p..color = Perch.orange);
  }

  @override
  bool shouldRepaint(_Ring old) => old.left != left;
}
