import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'palette.dart';

import 'mosaic.dart' show G;

// Memory Glass's lit pieces: dot-matrix numerals, the "Claude is working" wave and the line
// loaders for usage.

// ---- Dot-matrix numerals ----

const _glyphs = <String, List<String>>{
  '0': ['01110', '10001', '10001', '10001', '10001', '10001', '01110'],
  '1': ['00100', '01100', '00100', '00100', '00100', '00100', '01110'],
  '2': ['01110', '10001', '00001', '00110', '01000', '10000', '11111'],
  '3': ['11110', '00001', '00001', '01110', '00001', '00001', '11110'],
  '4': ['00010', '00110', '01010', '10010', '11111', '00010', '00010'],
  '5': ['11111', '10000', '11110', '00001', '00001', '10001', '01110'],
  '6': ['00110', '01000', '10000', '11110', '10001', '10001', '01110'],
  '7': ['11111', '00001', '00010', '00100', '01000', '01000', '01000'],
  '8': ['01110', '10001', '10001', '01110', '10001', '10001', '01110'],
  '9': ['01110', '10001', '10001', '01111', '00001', '00010', '01100'],
  '%': ['11000', '11001', '00010', '00100', '01000', '10011', '00011'],
  '.': ['00000', '00000', '00000', '00000', '00000', '01100', '01100'],
  'k': ['10000', '10000', '10010', '10100', '11000', '10100', '10010'],
  ':': ['00000', '01100', '01100', '00000', '01100', '01100', '00000'],
  '+': ['00000', '00100', '00100', '11111', '00100', '00100', '00000'],
  '/': ['00001', '00010', '00010', '00100', '01000', '01000', '10000'],
  ' ': ['00000', '00000', '00000', '00000', '00000', '00000', '00000'],
};

/// Numbers drawn as LED dots [dot] pixels apart, lit cream on glass: a dark halo under each
/// dot keeps them readable over the bright mosaic, a warm glow makes them feel lit.
class DotMatrix extends StatelessWidget {
  final String text;
  final double dot;
  final Color color;

  /// The warm light around lit dots (null: none, for small sizes).
  final Color? glow;

  /// Draw the unlit dots of each cell faintly, like a real LED panel.
  final bool ghost;
  const DotMatrix(this.text, {super.key, this.dot = 8, this.color = G.text, this.glow = G.glow, this.ghost = false});

  @override
  Widget build(BuildContext context) {
    final cols = text.length * 6 - 1;
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: CustomPaint(size: Size(cols * dot, 7 * dot), painter: _DotMatrixPainter(text, dot, color, glow, ghost)),
    );
  }
}

class _DotMatrixPainter extends CustomPainter {
  final String text;
  final double dot;
  final Color color;
  final Color? glow;
  final bool ghost;
  final bool dark = G.dark;
  _DotMatrixPainter(this.text, this.dot, this.color, this.glow, this.ghost);

  @override
  void paint(Canvas canvas, Size size) {
    // Small numerals get fuller dots and no dark bed, which would wash them out.
    final small = dot < 4;
    final r = dot * (small ? 0.46 : 0.38);
    final lit = <Offset>[];
    final unlit = <Offset>[];
    for (var i = 0; i < text.length; i++) {
      final g = _glyphs[text[i]] ?? _glyphs[' ']!;
      for (var y = 0; y < 7; y++) {
        for (var x = 0; x < 5; x++) {
          final p = Offset((i * 6 + x + 0.5) * dot, (y + 0.5) * dot);
          (g[y][x] == '1' ? lit : unlit).add(p);
        }
      }
    }
    if (ghost) {
      final off = Paint()..color = const Color(0x1AFFF5FA);
      for (final p in unlit) {
        canvas.drawCircle(p, r * 0.8, off);
      }
    }
    // A soft dark bed (the text shadow of the glass screens) …
    final bed = Paint()
      ..color = G.deep.withValues(alpha: 0.5)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(1.5, dot * 0.55));
    if (!small) {
      for (final p in lit) {
        canvas.drawCircle(p, r * 1.35, bed);
      }
    }
    // … a warm glow …
    final g = glow;
    if (g != null) {
      final halo = Paint()
        ..color = g.withValues(alpha: 0.45)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, dot * 0.45);
      for (final p in lit) {
        canvas.drawCircle(p, r * 1.15, halo);
      }
    }
    // … and the lit dot itself.
    final fill = Paint()..color = color;
    for (final p in lit) {
      canvas.drawCircle(p, r, fill);
    }
  }

  @override
  bool shouldRepaint(_DotMatrixPainter old) =>
      old.text != text || old.color != color || old.dot != dot || old.glow != glow || old.ghost != ghost || old.dark != dark;
}

// ---- "Claude is working": a rolling waveform ----

/// A mirrored wave of bars rolling sideways while Claude works; its tallest bar glows
/// orange. Stands still when motion is off (reduce motion, tests).
class WorkingWave extends StatelessWidget {
  final double width;
  final double height;
  final int bars;
  const WorkingWave({super.key, this.width = 56, this.height = 20, this.bars = 10});

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Claude is working',
        child: SizedBox(
          width: width,
          height: height,
          child: GlassLoop(
            period: const Duration(milliseconds: 1400),
            builder: (context, t) => CustomPaint(painter: _WavePainter(t, bars)),
          ),
        ),
      );
}

class _WavePainter extends CustomPainter {
  final double t;
  final int n;
  _WavePainter(this.t, this.n);

  @override
  void paint(Canvas canvas, Size size) {
    final step = size.width / n;
    final w = math.max(1.6, step * 0.5);
    final mid = size.height / 2;
    final v = [for (var i = 0; i < n; i++) 0.3 + 0.7 * ((i / n + t) % 1)];
    var hot = 0;
    for (var i = 1; i < n; i++) {
      if (v[i] > v[hot]) hot = i;
    }
    final p = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < n; i++) {
      final h = math.max(w / 2, v[i] * (size.height / 2 - w / 2));
      final x = step * (i + 0.5);
      if (i == hot) {
        canvas.drawLine(
            Offset(x, mid - h),
            Offset(x, mid + h),
            Paint()
              ..strokeCap = StrokeCap.round
              ..strokeWidth = w * 2.2
              ..color = Perch.orange.withValues(alpha: 0.45)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      }
      p
        ..strokeWidth = w
        ..color = i == hot ? Perch.ember : G.text.withValues(alpha: 0.35 + 0.55 * v[i]);
      canvas.drawLine(Offset(x, mid - h), Offset(x, mid + h), p);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.t != t || old.n != n;
}

// ---- Usage meters: line loaders ----

/// A thin glowing line that loads up to [value] (0..1) when it first shows.
class UsageLine extends StatelessWidget {
  final double value;
  final double thickness;
  const UsageLine({super.key, required this.value, this.thickness = 4});

  @override
  Widget build(BuildContext context) {
    final still = !glassMotionOn(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: still ? value : 0, end: value),
      duration: still ? Duration.zero : const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => CustomPaint(size: Size(double.infinity, thickness + 8), painter: _LinePainter(v, thickness)),
    );
  }
}

class _LinePainter extends CustomPainter {
  final double v;
  final double t;
  _LinePainter(this.v, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final track = RRect.fromLTRBR(0, y - t / 2, size.width, y + t / 2, Radius.circular(t / 2));
    canvas.drawRRect(track, Paint()..color = const Color(0x24FFF5FA));
    final end = size.width * v.clamp(0, 1);
    if (end <= 0) return;
    final fill = RRect.fromLTRBR(0, y - t / 2, math.max(t, end), y + t / 2, Radius.circular(t / 2));
    canvas.drawRRect(
        fill,
        Paint()
          ..color = Perch.orange.withValues(alpha: 0.6)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawRRect(
        fill,
        Paint()
          ..shader = LinearGradient(colors: [Perch.ember.withValues(alpha: 0.85), Perch.orange])
              .createShader(Rect.fromLTRB(0, 0, math.max(t, end), size.height)));
    // A bright head where the line has loaded to.
    canvas.drawCircle(Offset(math.max(t / 2, end - t / 2), y), t * 0.62, Paint()..color = Perch.cream);
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.v != v || old.t != t;
}
