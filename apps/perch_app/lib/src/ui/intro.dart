// The intro on a cold start (about 1.7 s), on the same warm black as Android's splash so
// nothing flashes. The first frame is empty: the bird of the icon (only the bird, without the
// terminal and twig it stands on in the icon) is still beyond the bottom-left corner. It flies
// in beating its wing while a branch, drawn from the icon's own line, grows above where the
// name will be; it lands on the branch, folds its wing, and the name Perch shows under it.
// Then it takes off with quick wing beats to beyond the top-right corner while the name and
// the branch fade and the first screen shows through. A tap skips it; it never plays with
// reduced motion (the platform's setting, or GlassMotion off in tests), and only once per
// launch of the app.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/widgets.dart';

import 'glass/mosaic.dart' show MosaicScene;
import 'glass/palette.dart';
import 'glass/widgets.dart' show gSerif;

/// How long the whole intro takes (on time frames).
const introDuration = Duration(milliseconds: 1700);

/// How long the intro holds its first frame after the app is on screen (Android's splash
/// fades out over it), at least.
const introStartGuard = Duration(milliseconds: 150);

/// The longest the intro waits for calm frames after the app is on screen.
const _calmWait = Duration(milliseconds: 1500);

/// A frame no longer than this is on time (60 Hz with some slack).
const _calmFrame = Duration(milliseconds: 40);

/// The most one frame moves the intro on: a slow frame slows it down, never skips a part.
const _maxStep = Duration(milliseconds: 34);

/// The first screen with the intro over it on a cold start.
///
/// The clock starts only once the first frame is on screen (Android's splash covers the app
/// until then, longest in a debug build) and the frames come on time, and it moves by at most
/// [_maxStep] per frame, so start-up work never eats the bird's arrival.
class IntroGate extends StatefulWidget {
  final Widget child;
  const IntroGate({super.key, required this.child});

  static bool _played = false;

  /// Plays the intro again on the next build (tests).
  @visibleForTesting
  static void reset() => _played = false;

  /// Completes when the app's first frame is on screen (tests replace it: the test binding
  /// reports no frame timings).
  @visibleForTesting
  static Future<void> Function() presented = () => WidgetsBinding.instance.waitUntilFirstFrameRasterized;

  @override
  State<IntroGate> createState() => _IntroGateState();
}

class _IntroGateState extends State<IntroGate> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _t = ValueNotifier<double>(0);
  bool _showing = false;
  bool _decided = false;
  bool _presented = false;
  bool _running = false;
  Duration _last = Duration.zero;
  Duration _waited = Duration.zero;
  Duration _longest = Duration.zero;
  int _calm = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    final reduce = !GlassMotion.enabled || (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (IntroGate._played || reduce) {
      IntroGate._played = true;
      return;
    }
    IntroGate._played = true;
    _showing = true;
    // The bird is drawn from the logo; it loads while the first frame (empty) holds.
    MosaicScene.load();
    IntroGate.presented().then((_) => _presented = true, onError: (_) => _presented = true);
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    final dt = elapsed - _last;
    _last = elapsed;
    if (!_running) {
      // Holding the first frame: until the app is on screen, then the guard, then a few
      // frames in a row on time (or long enough).
      if (!_presented) return;
      _waited += dt;
      _calm = dt <= _calmFrame ? _calm + 1 : 0;
      if ((_waited >= introStartGuard && _calm >= 3) || _waited >= _calmWait) _running = true;
      return;
    }
    if (dt > _longest) _longest = dt;
    final step = dt > _maxStep ? _maxStep : dt;
    _t.value = math.min(1.0, _t.value + step.inMicroseconds / introDuration.inMicroseconds);
    if (_t.value >= 1) _finish();
  }

  void _finish() {
    _ticker.stop();
    if (!kReleaseMode || _longest > _maxStep) {
      debugPrint('Perch intro: started ${_waited.inMilliseconds} ms after the first frame; '
          'longest frame ${_longest.inMilliseconds} ms');
    }
    if (mounted && _showing) setState(() => _showing = false);
  }

  /// A tap: straight to the bird leaving.
  void _skip() {
    _running = true;
    if (_t.value < introLeaveAt) _t.value = introLeaveAt;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(textDirection: TextDirection.ltr, children: [
        widget.child,
        if (_showing)
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('intro'),
              behavior: HitTestBehavior.opaque,
              onTap: _skip,
              child: Semantics(
                label: 'Perch',
                button: true,
                hint: 'Tap to skip',
                child: ValueListenableBuilder<double>(
                    valueListenable: _t, builder: (context, t, _) => IntroFrame(t: t)),
              ),
            ),
          ),
      ]);
}

// The timeline, as fractions of [introDuration].
const _flapInEnd = 0.24; // the last beat on the way in; then it glides, wing half open
const _inEnd = 0.29; // the bird has landed
const _settle = (0.30, 0.37); // one small settling of the wing
const _branchIn = (0.12, 0.26); // the branch grows, before the landing
const _nameIn = (0.27, 0.43);
const _nameOut = (0.62, 0.74); // the name and the branch go together

/// When the bird takes off (a tap skips to here).
const introLeaveAt = 0.60;
const _leaveEnd = 0.88; // beyond the top-right corner
const _fadeFrom = 0.80; // the first screen shows through

/// Wing beats on the way in and on the way out (the take-off beats faster).
const _beatsIn = 3, _beatsOut = 5;

double _seg(double t, double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

/// [n] wing beats from [a] to [b]: up and down, folded at each end.
double _beats(double t, double a, double b, int n) => 0.5 - 0.5 * math.cos(2 * math.pi * n * _seg(t, a, b));

// The logo's coordinates (viewBox 1023 x 1031): the bird stands at [_feet] on the terminal's
// top edge; its body is above y 552, its legs reach down to y 622.
const _feet = Offset(555, 622);

/// The farthest any part of the bird reaches from [_feet] (its raised wing included).
const _reach = 800.0;

/// The bird alone in the logo: everything above its belly, and its legs; never the leaf, the
/// twig crossing under it or the terminal it stands on.
final introBirdOnly = Path()
  ..addPolygon(const [
    Offset(0, -60),
    Offset(1100, -60),
    Offset(1100, 552),
    Offset(232, 552),
    Offset(232, 495),
    Offset(0, 495),
  ], true)
  ..addPolygon(const [Offset(468, 546), Offset(585, 546), Offset(640, 621), Offset(500, 621)], true);

/// The branch: the terminal's top edge in the logo, from right of the twig to before its title
/// bar; it is drawn with its mirror image for a longer branch.
const _branchStrip = Rect.fromLTRB(372, 623, 655, 676);

/// How much longer than the logo's line the branch is drawn.
const _branchStretch = 1.3;

/// Where things are on a screen of [size]: the bird's scale (screen pixels per logo unit),
/// where its feet rest on the branch and where the name's top is.
({double s, Offset rest, double perchY, double nameTop}) introLayout(Size size) {
  // The bird (about 680 logo units wide) is about a third of the narrower side.
  final s = math.min(size.width, size.height) * 0.36 / 680;
  final perchY = size.height / 2 + 32;
  // The body's middle (x 585) over the centre of the screen.
  final rest = Offset(size.width / 2 - (585 - _feet.dx) * s, perchY);
  return (s: s, rest: rest, perchY: perchY, nameTop: perchY + 50 * s + 6);
}

Offset _bezier(Offset a, Offset c, Offset b, double k) => a * ((1 - k) * (1 - k)) + c * (2 * k * (1 - k)) + b * (k * k);
Offset _bezierDir(Offset a, Offset c, Offset b, double k) => (c - a) * (2 * (1 - k)) + (b - c) * (2 * k);

/// One frame of the intro at [t] (0..1).
class IntroFrame extends StatelessWidget {
  final double t;
  const IntroFrame({super.key, required this.t});

  /// The bird at [t] on a screen of [size]: where its feet are (screen pixels), how far it
  /// leans (radians, about its feet), how big it is (1 on the branch) and how far its wing is
  /// raised (0 folded … 1 up).
  static ({Offset feet, double lean, double scale, double lift}) birdAt(double t, Size size) {
    final l = introLayout(size);
    double leanOf(Offset dir) => (math.atan2(dir.dy, dir.dx) * 0.3).clamp(-0.35, 0.25);
    if (t < _inEnd) {
      const scale0 = 0.7;
      final r = _reach * l.s * scale0 + 4;
      final from = Offset(-r, size.height + r);
      final via = Offset(l.rest.dx - 0.18 * size.width, l.rest.dy - 0.12 * size.height);
      // Quick across the screen, braking only near the branch.
      final k = 1 - math.pow(1 - _seg(t, 0, _inEnd), 1.5).toDouble();
      final lift = t < _flapInEnd ? _beats(t, 0, _flapInEnd, _beatsIn) : 0.45 * math.sin(math.pi * _seg(t, _flapInEnd, _inEnd));
      return (
        feet: _bezier(from, via, l.rest, k),
        lean: leanOf(_bezierDir(from, via, l.rest, k)) * (1 - k),
        scale: scale0 + (1 - scale0) * k,
        lift: lift,
      );
    }
    if (t < introLeaveAt) {
      // On the branch: the wing settles once, then stays folded.
      final k = _seg(t, _settle.$1, _settle.$2);
      return (feet: l.rest, lean: 0.0, scale: 1.0, lift: k > 0 && k < 1 ? 0.2 * math.sin(math.pi * k) : 0.0);
    }
    const scale1 = 0.75;
    final r = _reach * l.s + 4;
    final to = Offset(size.width + r, -r);
    final via = Offset(l.rest.dx + 0.04 * size.width, l.rest.dy - 0.22 * size.height);
    final k = Curves.easeInCubic.transform(_seg(t, introLeaveAt, _leaveEnd));
    return (
      feet: _bezier(l.rest, via, to, k),
      lean: leanOf(_bezierDir(l.rest, via, to, math.max(k, 0.05))) * _seg(t, introLeaveAt, introLeaveAt + 0.08),
      scale: 1 - (1 - scale1) * k,
      lift: t < _leaveEnd ? _beats(t, introLeaveAt, _leaveEnd, _beatsOut) : 0.0,
    );
  }

  /// A circle around everything of the bird drawn at [t] (screen pixels).
  static ({Offset centre, double radius}) birdReach(double t, Size size) {
    final b = birdAt(t, size);
    return (centre: b.feet, radius: _reach * introLayout(size).s * b.scale);
  }

  /// How far the branch has grown (0..1) and how visible it is at [t].
  static ({double grown, double opacity}) branchAt(double t) => (
        grown: Curves.easeOutCubic.transform(_seg(t, _branchIn.$1, _branchIn.$2)),
        opacity: _seg(t, _branchIn.$1, _branchIn.$1 + 0.06) * (1 - _seg(t, _nameOut.$1, _nameOut.$2)),
      );

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final fade = 1 - Curves.easeOut.transform(_seg(t, _fadeFrom, 1));
    final nameIn = Curves.easeOutCubic.transform(_seg(t, _nameIn.$1, _nameIn.$2));
    final name = nameIn * (1 - _seg(t, _nameOut.$1, _nameOut.$2));
    final l = introLayout(size);
    return Opacity(
      opacity: fade,
      child: ColoredBox(
        color: Perch.ink,
        child: Stack(textDirection: TextDirection.ltr, children: [
          Positioned.fill(
            child: ValueListenableBuilder<bool>(
              valueListenable: MosaicScene.ready,
              builder: (context, ready, _) => CustomPaint(painter: _IntroPainter(t, size, ready)),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: l.nameTop,
            child: Opacity(
              opacity: name,
              child: Transform.translate(
                offset: Offset(0, 10 * (1 - nameIn)),
                child: Text('Perch',
                    key: const ValueKey('intro-name'),
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.ltr,
                    style: gSerif(44, w: FontWeight.w500, color: Perch.cream, height: 1.1)
                        .copyWith(letterSpacing: 1.5 + 2 * (1 - nameIn), decoration: TextDecoration.none)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Draws the branch and the bird of one frame.
class _IntroPainter extends CustomPainter {
  final double t;
  final Size screen;
  final bool ready;
  _IntroPainter(this.t, this.screen, this.ready);

  @override
  void paint(Canvas canvas, Size size) {
    final logo = MosaicScene.logo;
    if (logo == null) return;
    final l = introLayout(screen);
    _branch(canvas, logo, l.s, Offset(screen.width / 2, l.perchY));
    final b = IntroFrame.birdAt(t, screen);
    final s = l.s * b.scale;
    final reach = _reach * s;
    // Nothing to draw while the bird is beyond the screen (the first and last frames).
    if (!(Offset.zero & screen).inflate(1).overlaps(Rect.fromCircle(center: b.feet, radius: reach))) return;
    canvas.save();
    canvas.translate(b.feet.dx, b.feet.dy);
    canvas.rotate(b.lean);
    canvas.scale(s);
    canvas.translate(-_feet.dx, -_feet.dy);
    MosaicScene.drawBird(canvas, logo, b.lift, only: introBirdOnly);
    canvas.restore();
  }

  /// The branch, its middle at [mid] (its top edge there), grown out from the middle.
  void _branch(Canvas c, ui.Picture logo, double s, Offset mid) {
    final br = IntroFrame.branchAt(t);
    if (br.opacity <= 0 || br.grown <= 0) return;
    final half = _branchStrip.width * s * _branchStretch;
    final thick = _branchStrip.height * s;
    // Tapered ends, like a twig.
    final shape = Path()
      ..moveTo(mid.dx - half, mid.dy + thick * 0.35)
      ..lineTo(mid.dx - half * 0.8, mid.dy - 2)
      ..lineTo(mid.dx + half * 0.8, mid.dy - 2)
      ..lineTo(mid.dx + half, mid.dy + thick * 0.35)
      ..lineTo(mid.dx + half * 0.8, mid.dy + thick + 2)
      ..lineTo(mid.dx - half * 0.8, mid.dy + thick + 2)
      ..close();
    final grown = half * br.grown;
    c.save();
    c.clipRect(Rect.fromLTRB(mid.dx - grown, mid.dy - thick, mid.dx + grown, mid.dy + 2 * thick));
    c.clipPath(shape);
    c.saveLayer(shape.getBounds(), Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: br.opacity));
    for (final side in const [1.0, -1.0]) {
      c.save();
      c.translate(mid.dx, mid.dy);
      c.scale(side * s * _branchStretch, s);
      c.translate(-_branchStrip.right, -_branchStrip.top);
      // A little past the middle: the two halves overlap, no hairline between them.
      c.clipRect(Rect.fromLTRB(_branchStrip.left, _branchStrip.top, _branchStrip.right + 3, _branchStrip.bottom));
      c.drawPicture(logo);
      c.restore();
    }
    c.restore();
    c.restore();
  }

  @override
  bool shouldRepaint(_IntroPainter old) => old.t != t || old.screen != screen || old.ready != ready;
}
