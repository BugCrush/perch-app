import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'palette.dart';


/// Memory Glass's tokens: muted mauve, cream text, iridescent edges with an orange rim.
///
/// Two themes: light (a bright mauve dusk behind the glass) and dark (a warm-black plum night).
/// The text tokens are the same in both (cream on glass); the backdrop, the deep tones and the
/// glass itself change. [dark] is set by [GlassThemed] above every Memory Glass screen.
abstract final class G {
  /// The dark theme is showing.
  static bool dark = false;

  /// The colour the screens fade into at the bottom; also dark glass for alerts and pills.
  static Color get deep => dark ? const Color(0xFF0E0A0D) : const Color(0xFF1B1519);

  /// A session's reading background.
  static Color get panel => dark ? const Color(0xFF161015) : const Color(0xFF2A2227);

  /// The frost of plain glass (it is drawn at the glass's tint).
  static Color get frost => dark ? const Color(0xFFFFE9F3) : const Color(0xFFFFF5FA);

  /// How much of the glass's tint plain frost keeps (dark glass is smokier).
  static double get frostScale => dark ? 0.62 : 1;
  static const mauve = Color(0xFF6E5562);
  static const text = Color(0xFFF7EEE8);

  /// 9.8:1 on the light panel, 11.9:1 on the dark one, 4.7:1 on the lightest frost (sheets).
  static const muted = Color(0xFFD8CACF);
  static const lilac = Color(0xFFCDB8FF);
  static const blue = Color(0xFF9CC2FF);

  /// Warm light around lit dot-matrix numerals; also orange text on the glass (9.6:1 on the
  /// light panel, 4.7:1 on the lightest frost).
  static const glow = Color(0xFFFFBDA3);
}

/// A stable mosaic seed for a session or machine id (FNV-1a, 31 bits): each one keeps its
/// own picture across runs.
int seedOf(String id) {
  var h = 0x811c9dc5;
  for (final c in id.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h & 0x7fffffff;
}

/// The bird's wing in the logo's coordinates (viewBox 1023 x 1031): the cream wing with its
/// orange edge and the back above it, cut along the middle of the stripe that parts it from
/// the belly. It turns about [_shoulder].
final _wing = Path()
  ..addPolygon(const [
    Offset(232, 548),
    Offset(250, 500),
    Offset(320, 425),
    Offset(395, 352),
    Offset(468, 300),
    Offset(540, 266),
    Offset(612, 258),
    Offset(652, 276),
    Offset(660, 318),
    Offset(648, 356),
    Offset(612, 404),
    Offset(566, 448),
    Offset(500, 490),
    Offset(420, 522),
    Offset(330, 548),
    Offset(270, 560),
  ], true);
const _shoulder = Offset(612, 300);

/// How far the wing turns at the top of a flap (radians; clockwise lifts the wing tip).
const _wingLift = 1.85;

/// Wing poses drawn per scene: 0 is folded, [flapPoses] - 1 is fully raised.
const flapPoses = 5;

/// The bird's cream eye in the logo's coordinates.
const _eye = Offset(740, 140);

/// Eye poses: open, half shut (the lid half down), shut (a line).
const eyeOpen = 0, eyeHalf = 1, eyeShut = 2;

/// A tiny picture of the scene behind a screen, made once per seed: a soft "photo" of colour
/// blobs with the bird in it. Drawn large without smoothing it becomes a pixel mosaic.
class MosaicScene {
  static ui.Picture? _logo;
  static Size _logoSize = Size.zero;
  static Future<void>? _loading;
  static final ready = ValueNotifier(false);
  static final _cache = <(int, int, int, int, int, bool), ui.Image>{};
  static final _blurred = <(int, int, int, bool), ui.Image>{};

  static Future<void> load() => _loading ??= () async {
        try {
          final info = await vg.loadPicture(const SvgAssetLoader(logoAsset), null);
          _logo = info.picture;
          _logoSize = info.size;
        } catch (_) {
          // The mosaic is drawn without the bird.
        }
        ready.value = true;
      }();

  /// The scene for [seed], [w] by [h] pixels, with the wing in [pose] and the eye in [eye], in
  /// the current theme; null until made.
  static ui.Image? image(int seed, {int w = 30, int h = 64, int pose = 0, int eye = eyeOpen}) {
    final dark = G.dark;
    final key = (seed, w, h, pose, eye, dark);
    final hit = _cache[key];
    if (hit != null) return hit;
    if (!ready.value) return null;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final rnd = math.Random(seed);
    final size = Size(w.toDouble(), h.toDouble());
    // Base: mauve dusk, or a plum night.
    c.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.linear(
              Offset.zero,
              Offset(0, size.height),
              dark
                  ? const [Color(0xFF3E2834), Color(0xFF24161E), Color(0xFF0E0A0D)]
                  : const [Color(0xFF8E7480), Color(0xFF574350), Color(0xFF2A2026)],
              [0, 0.5, 1]));
    // Blobs of warm light (embers at night).
    const tones = [Perch.orange, Perch.cream, Color(0xFFB4879A), Color(0xFF7D8FB8), Color(0xFFE9A23B)];
    const night = [Perch.orange, Color(0xFF8A4A3A), Color(0xFF6B3F5A), Color(0xFF3E4A78), Color(0xFFB0662A)];
    for (var i = 0; i < 6; i++) {
      final center = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height * 0.8);
      final r = size.width * (0.25 + rnd.nextDouble() * 0.45);
      final a = 0.35 + rnd.nextDouble() * 0.35;
      final col = (dark ? night : tones)[(seed + i) % tones.length].withValues(alpha: dark ? a * 0.55 : a);
      c.drawCircle(center, r, Paint()..shader = ui.Gradient.radial(center, r, [col, col.withValues(alpha: 0)]));
    }
    // The bird, large and off-centre.
    final logo = _logo;
    if (logo != null && _logoSize.width > 0) {
      final bw = size.width * (0.8 + rnd.nextDouble() * 0.3);
      final s = bw / _logoSize.width;
      final at = Offset(size.width * (0.05 + rnd.nextDouble() * 0.2), size.height * (0.12 + rnd.nextDouble() * 0.12));
      c.save();
      c.translate(at.dx, at.dy);
      c.scale(s, s);
      if (dark) {
        // At night the bird glows a little less.
        c.saveLayer(Offset.zero & _logoSize, Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.86));
      }
      _bird(c, logo, pose / (flapPoses - 1));
      if (dark) c.restore();
      c.restore();
      // Big scenes draw the eye as its own 2 x 2 pixels, so that it can close.
      if (w >= 16) _eyePixels(c, at + _eye * s, eye, dark);
    }
    final img = rec.endRecording().toImageSync(w, h);
    _cache[key] = img;
    return img;
  }

  /// The logo once loaded ([load]), in its own coordinates ([logoSize]).
  static ui.Picture? get logo => _logo;
  static Size get logoSize => _logoSize;

  static void _bird(Canvas c, ui.Picture logo, double lift) => drawBird(c, logo, lift);

  /// Draws the logo with its wing raised by [lift] (0 folded … 1 up), in the logo's
  /// coordinates; only what lies inside [only] (logo coordinates, before the wing turns).
  static void drawBird(Canvas c, ui.Picture logo, double lift, {Path? only}) {
    void keep() {
      if (only != null) c.clipPath(only);
    }

    if (lift <= 0) {
      c.save();
      keep();
      c.drawPicture(logo);
      c.restore();
      return;
    }
    // The whole bird (cutting the wing out left a hairline seam around it) …
    c.save();
    keep();
    c.drawPicture(logo);
    c.restore();
    // … its orange flank over where the wing lay …
    c.save();
    keep();
    c.clipPath(_wing);
    c.saveLayer(_wing.getBounds(), Paint());
    c.drawPicture(logo);
    c.drawRect(_wing.getBounds(), Paint()
      ..color = Perch.orange
      ..blendMode = BlendMode.srcIn);
    c.restore();
    c.restore();
    // … and the wing turned up about the shoulder, a little shorter as it opens towards us.
    c.save();
    c.translate(_shoulder.dx, _shoulder.dy);
    c.rotate(_wingLift * lift);
    c.scale(1 - 0.12 * lift, 1);
    c.translate(-_shoulder.dx, -_shoulder.dy);
    keep();
    c.clipPath(_wing);
    c.drawPicture(logo);
    c.restore();
  }

  /// The eye as a crisp block of 2 x 2 mosaic pixels nearest [centre]: open it is all cream;
  /// half shut the orange lid covers the top row; shut only a faint line is left at the bottom.
  static void _eyePixels(Canvas c, Offset centre, int eye, bool dark) {
    final x = centre.dx.round() - 1.0;
    final y = centre.dy.round() - 1.0;
    Paint paint(Color col) => Paint()
      ..isAntiAlias = false
      ..color = dark ? Color.lerp(col, const Color(0xFF000000), 0.14)! : col;
    final lid = paint(Perch.orange);
    final white = paint(Perch.cream);
    final line = paint(Color.lerp(Perch.orange, Perch.cream, 0.42)!);
    final top = Rect.fromLTWH(x, y, 2, 1);
    final bottom = Rect.fromLTWH(x, y + 1, 2, 1);
    c.drawRect(top, eye == eyeOpen ? white : lid);
    c.drawRect(bottom, switch (eye) { eyeShut => line, _ => white });
  }

  /// The resting scene blurred once, at four times its size: the soft layer under the mosaic
  /// is then a plain smooth upscale, never a blur filter run per frame.
  static ui.Image? blurred(int seed, {int w = 30, int h = 64}) {
    final key = (seed, w, h, G.dark);
    final hit = _blurred[key];
    if (hit != null) return hit;
    final base = image(seed, w: w, h: h);
    if (base == null) return null;
    const k = 4;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawImageRect(
        base,
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Rect.fromLTWH(0, 0, (w * k).toDouble(), (h * k).toDouble()),
        Paint()
          ..filterQuality = FilterQuality.medium
          ..imageFilter = ui.ImageFilter.blur(sigmaX: 4.5, sigmaY: 4.5, tileMode: TileMode.clamp));
    final img = rec.endRecording().toImageSync(w * k, h * k);
    _blurred[key] = img;
    return img;
  }
}

/// Forces every flapping backdrop into one wing pose (screenshots of the flap).
@visibleForTesting
final debugFlapPose = ValueNotifier<int?>(null);

/// Forces every flapping backdrop's eye into one pose (screenshots of the wink).
@visibleForTesting
final debugEyePose = ValueNotifier<int?>(null);

/// The scene behind a screen: pixelated at the top, resolving into a soft blur lower down,
/// then into [fade] colour. With [flap] the bird now and then tries to take off: a burst of
/// two or three clumsy wing beats every several seconds, then rest; and between bursts it
/// blinks, now and then with a slow, deliberate wink.
class MosaicBackdrop extends StatefulWidget {
  final int seed;

  /// The colour the bottom fades into (null keeps the scene).
  final Color? fade;
  final double fadeFrom;

  /// How much of it is pixelated (0 smooth, 1 all mosaic).
  final double pixel;
  final int cells;

  /// Let the bird flap its wing (big backdrops; never thumbnails).
  final bool flap;
  const MosaicBackdrop(
      {super.key, required this.seed, this.fade, this.fadeFrom = 0.55, this.pixel = 0.7, this.cells = 30, this.flap = false});
  /// The board page (the app in a browser): big backgrounds are a plain gradient without
  /// the bird (the owner's choice for the desktop); small session pictures keep the mosaic.
  static bool plainBackdrops = kIsWeb;

  /// Cells from which a backdrop counts as a background, not a small picture.
  static const backgroundCells = 20;

  @override
  State<MosaicBackdrop> createState() => MosaicBackdropState();
}

/// One wing beat of a burst: up quickly, then down, maybe not all the way before the next.
typedef _Beat = ({double up, double down, double peak, double rest});

@visibleForTesting
class MosaicBackdropState extends State<MosaicBackdrop> with TickerProviderStateMixin {
  late final AnimationController _burst = AnimationController(vsync: this)..addListener(_tick);
  late final AnimationController _blink = AnimationController(vsync: this)..addListener(_blinkTick);
  final _pose = ValueNotifier(0);
  final _eye = ValueNotifier(eyeOpen);
  final _rnd = math.Random();
  Timer? _wait;
  Timer? _blinkWait;
  List<_Beat> _beats = const [];

  /// The current blink: when the lid is half down, shut, half up again (ms from its start).
  (double, double, double, double) _lid = (0, 0, 0, 0);
  bool _on = false;

  /// The wing pose shown now (0 folded).
  int get pose => _pose.value;

  /// The eye shown now ([eyeOpen], [eyeHalf], [eyeShut]).
  int get eye => _eye.value;

  /// A flap burst or a blink is running (frames are drawn only then).
  bool get flapping => _burst.isAnimating;
  bool get blinking => _blink.isAnimating;

  /// Bursts started so far.
  int bursts = 0;

  /// Blinks started so far, and how many of them were slow winks.
  int blinks = 0;
  int winks = 0;

  @override
  void initState() {
    super.initState();
    MosaicScene.load();
    MosaicScene.ready.addListener(_ready);
    _burst.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _pose.value = 0;
        _schedule(5500 + _rnd.nextInt(3500));
      }
    });
    _blink.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _eye.value = eyeOpen;
        _scheduleBlink(2600 + _rnd.nextInt(4800));
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  @override
  void didUpdateWidget(MosaicBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  /// Starts or stops flapping as [MosaicBackdrop.flap] and the motion setting say.
  void _update() {
    final on = widget.flap && glassMotionOn(context);
    if (on == _on) return;
    _on = on;
    if (on) {
      _schedule(1400 + _rnd.nextInt(1200));
      _scheduleBlink(3000 + _rnd.nextInt(2500));
    } else {
      _wait?.cancel();
      _blinkWait?.cancel();
      _burst.stop();
      _blink.stop();
      _pose.value = 0;
      _eye.value = eyeOpen;
    }
  }

  void _schedule(int ms) {
    _wait?.cancel();
    if (!_on) return;
    _wait = Timer(Duration(milliseconds: ms), _start);
  }

  void _scheduleBlink(int ms) {
    _blinkWait?.cancel();
    if (!_on) return;
    _blinkWait = Timer(Duration(milliseconds: ms), _startBlink);
  }

  /// A blink: mostly quick, now and then a slow wink that holds the eye shut. Never while the
  /// wing beats: then it waits for the burst to end.
  void _startBlink() {
    if (!mounted || !_on) return;
    if (_burst.isAnimating) {
      _scheduleBlink(700 + _rnd.nextInt(600));
      return;
    }
    blinks++;
    final slow = _rnd.nextDouble() < 0.28;
    if (slow) winks++;
    double j(double base, double spread) => base + (_rnd.nextDouble() - 0.5) * spread;
    final half = slow ? j(90, 20) : j(45, 10);
    final shut = half + (slow ? j(70, 20) : j(35, 10));
    final opening = shut + (slow ? j(420, 160) : j(70, 30));
    final end = opening + (slow ? j(110, 30) : j(60, 15));
    _lid = (half, shut, opening, end);
    _blink.duration = Duration(milliseconds: end.round());
    _blink.forward(from: 0);
  }

  void _blinkTick() {
    final ms = _blink.value * _lid.$4;
    _eye.value = ms < _lid.$1
        ? eyeHalf
        : ms < _lid.$3
            ? eyeShut
            : eyeHalf;
  }

  /// A burst: two or three beats, the first hesitant, one strong, the last tired. Never while
  /// the eye blinks: then it starts just after.
  void _start() {
    if (!mounted || !_on) return;
    if (_blink.isAnimating) {
      _schedule(500 + _rnd.nextInt(400));
      return;
    }
    bursts++;
    final n = 2 + _rnd.nextInt(2);
    double j(double base, double spread) => base + (_rnd.nextDouble() - 0.5) * spread;
    _beats = [
      for (var i = 0; i < n; i++)
        (
          up: j(i == 0 ? 230 : 170, 50),
          down: j(260, 70),
          peak: i == 0 ? j(0.6, 0.2) : (i == n - 1 ? j(0.7, 0.2) : 1.0),
          // Between beats the wing does not quite settle; after the last it does.
          rest: i == n - 1 ? 0 : j(0.2, 0.2),
        ),
    ];
    final ms = _beats.fold<double>(0, (t, b) => t + b.up + b.down) + 140 * (n - 1);
    _burst.duration = Duration(milliseconds: ms.round());
    _burst.forward(from: 0);
  }

  void _tick() {
    final lift = _liftAt(_burst.value * _burst.duration!.inMilliseconds);
    _pose.value = (lift * (flapPoses - 1)).round().clamp(0, flapPoses - 1);
  }

  /// The wing's lift (0..1) [ms] into the burst.
  double _liftAt(double ms) {
    var t = ms;
    var from = 0.0;
    for (final b in _beats) {
      if (t < b.up) return from + (b.peak - from) * Curves.easeOut.transform(t / b.up);
      t -= b.up;
      if (t < b.down) return b.peak + (b.rest - b.peak) * Curves.easeIn.transform(t / b.down);
      t -= b.down;
      if (t < 140 && b.rest > 0) return b.rest;
      if (b.rest > 0) t -= 140;
      from = b.rest;
    }
    return 0;
  }

  void _ready() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _wait?.cancel();
    _blinkWait?.cancel();
    _burst.dispose();
    _blink.dispose();
    _pose.dispose();
    _eye.dispose();
    MosaicScene.ready.removeListener(_ready);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MosaicBackdrop.plainBackdrops && widget.cells >= MosaicBackdrop.backgroundCells) return _gradient();
    return _mosaic();
  }

  /// The logo's warm orange high up, fading into the deep colour (light and dark themes).
  /// The board page: the mosaic's grid of glass squares over a warm gradient across the
  /// whole page, without the bird (the owner's choice for the desktop).
  Widget _gradient() => RepaintBoundary(
        child: CustomPaint(
          painter: GradientGridPainter(seed: widget.seed, cells: widget.cells, base: widget.fade ?? G.deep, dark: G.dark),
          child: const SizedBox.expand(),
        ),
      );

  Widget _mosaic() => RepaintBoundary(
        child: LayoutBuilder(builder: (context, box) {
          final w = widget.cells;
          final h = box.maxWidth > 0 ? (w * box.maxHeight / box.maxWidth).round().clamp(4, 200) : w;
          final soft = MosaicScene.blurred(widget.seed, w: w, h: h);
          return Stack(fit: StackFit.expand, children: [
            // Three layers: only the mosaic repaints, and only when the wing changes pose.
            RepaintBoundary(child: CustomPaint(painter: _SoftPainter(soft))),
            if (soft != null)
              RepaintBoundary(
                child: CustomPaint(
                    painter: _PixelPainter(widget.seed, w, h, widget.pixel, widget.flap ? _pose : null, widget.flap ? _eye : null)),
              ),
            if (widget.fade != null) CustomPaint(painter: _FadePainter(widget.fade!, widget.fadeFrom)),
          ]);
        }),
      );
}

/// The smooth layer: the pre-blurred scene stretched over the area.
class _SoftPainter extends CustomPainter {
  final ui.Image? img;
  final bool dark = G.dark;
  _SoftPainter(this.img);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final i = img;
    if (i == null) {
      canvas.drawRect(
          rect,
          Paint()
            ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height),
                [dark ? const Color(0xFF3E2834) : const Color(0xFF7A6270), dark ? const Color(0xFF24161E) : const Color(0xFF3A2D35), G.deep], [0, 0.5, 1]));
      return;
    }
    canvas.drawImageRect(i, Rect.fromLTWH(0, 0, i.width.toDouble(), i.height.toDouble()), rect, Paint()..filterQuality = FilterQuality.medium);
  }

  @override
  bool shouldRepaint(_SoftPainter old) => old.img != img || old.dark != dark;
}

/// The pixel mosaic over the top part, fading out downwards, in the wing's current pose.
class _PixelPainter extends CustomPainter {
  final int seed;
  final int w;
  final int h;
  final double pixel;
  final ValueNotifier<int>? pose;
  final ValueNotifier<int>? eye;
  final bool dark = G.dark;
  _PixelPainter(this.seed, this.w, this.h, this.pixel, this.pose, this.eye)
      : super(repaint: pose == null ? null : Listenable.merge([pose, eye, debugFlapPose, debugEyePose]));

  @override
  void paint(Canvas canvas, Size size) {
    final p = pose == null ? 0 : (debugFlapPose.value ?? pose!.value);
    final e = eye == null ? eyeOpen : (debugEyePose.value ?? eye!.value);
    final i = MosaicScene.image(seed, w: w, h: h, pose: p, eye: e);
    if (i == null) return;
    final rect = Offset.zero & size;
    final src = Rect.fromLTWH(0, 0, i.width.toDouble(), i.height.toDouble());
    canvas.saveLayer(rect, Paint());
    canvas.drawImageRect(i, src, rect, Paint()..filterQuality = FilterQuality.none);
    final cell = size.width / i.width;
    final grid = Paint()
      ..color = dark ? const Color(0x2E000000) : const Color(0x14000000)
      ..strokeWidth = 0.6;
    for (var x = 0; x <= i.width; x++) {
      canvas.drawLine(Offset(x * cell, 0), Offset(x * cell, size.height), grid);
    }
    for (var y = 0; y <= i.height; y++) {
      canvas.drawLine(Offset(0, y * cell), Offset(size.width, y * cell), grid);
    }
    canvas.drawRect(
        rect,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = ui.Gradient.linear(
              Offset.zero, Offset(0, size.height), [const Color(0xFF000000), const Color(0x00000000)], [pixel * 0.45, pixel]));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PixelPainter old) =>
      old.seed != seed ||
      old.w != w ||
      old.h != h ||
      old.pixel != pixel ||
      old.pose != pose ||
      old.eye != eye ||
      old.dark != dark;
}

/// The fade into the screen's colour at the bottom.
class _FadePainter extends CustomPainter {
  final Color fade;
  final double from;
  _FadePainter(this.fade, this.from);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [fade.withValues(alpha: 0.0), fade.withValues(alpha: 0.92), fade],
              [from, math.min(1, from + 0.2), 1]));
  }

  @override
  bool shouldRepaint(_FadePainter old) => old.fade != fade || old.from != from;
}

/// Covers its area with mosaic tiles that clear in a scattered order as [t] goes 0 → 1.
class PixelCover extends CustomPainter {
  final double t;
  final double cell;
  final bool dark = G.dark;
  PixelCover(this.t, {this.cell = 22});
  @override
  void paint(Canvas canvas, Size size) {
    if (t >= 1) return;
    final cols = (size.width / cell).ceil();
    final rows = (size.height / cell).ceil();
    final p = Paint();
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        final h = ((x * 73856093) ^ (y * 19349663)) & 0xffff;
        // Tiles nearer the top clear first, with scatter.
        final threshold = (h / 0xffff) * 0.75 + (y / rows) * 0.25;
        if (t > threshold) continue;
        final shade = 0.8 + (h % 40) / 200;
        p.color = Color.lerp(G.deep, G.mauve, 0.25 * shade + (h % 7) / 40)!;
        canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5), p);
      }
    }
  }

  @override
  bool shouldRepaint(PixelCover old) => old.t != t || old.dark != dark;
}

/// Reveals [child] through a dissolving mosaic when it first appears.
class PixelReveal extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final double cell;
  const PixelReveal({super.key, required this.child, this.duration = const Duration(milliseconds: 520), this.cell = 14});
  @override
  State<PixelReveal> createState() => _PixelRevealState();
}

class _PixelRevealState extends State<PixelReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce motion: shown at once.
    if (_c.isDismissed) {
      if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
        _c.value = 1;
      } else {
        _c.forward();
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) => _c.isCompleted
            ? child!
            : ClipRect(child: CustomPaint(foregroundPainter: PixelCover(_c.value, cell: widget.cell), child: child)),
      );
}

/// Frosted glass: blur behind, a tint, an iridescent edge and an orange rim light below.
class Frost extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final double tint;
  final bool rim;
  final bool blur;

  /// The glass's colour (frost by default, [G.frost]; [G.deep] for alerts over bright mosaic).
  final Color? tone;
  const Frost({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 26,
    this.tint = 0.12,
    this.rim = false,
    this.blur = true,
    this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final c = tone ?? G.frost;
    final t = tone == null ? tint * G.frostScale : tint;
    final body = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.withValues(alpha: (t + 0.05).clamp(0, 1)), c.withValues(alpha: t * 0.6)],
        ),
      ),
      child: child,
    );
    return CustomPaint(
      foregroundPainter: _EdgePainter(radius, rim),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: blur ? BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22), child: body) : body,
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  final double radius;
  final bool rim;
  _EdgePainter(this.radius, this.rim);
  @override
  void paint(Canvas canvas, Size size) {
    final rr = RRect.fromRectAndRadius((Offset.zero & size).deflate(0.5), Radius.circular(radius));
    canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..shader = ui.Gradient.linear(Offset.zero, Offset(size.width, size.height), [
            const Color(0x80FFFFFF),
            G.lilac.withValues(alpha: 0.45),
            G.blue.withValues(alpha: 0.25),
            const Color(0x14FFFFFF),
          ], [0, 0.35, 0.6, 1]));
    if (rim) {
      canvas.save();
      canvas.clipRRect(rr);
      canvas.drawRRect(
          rr.shift(const Offset(0, -1.5)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)
            ..shader = ui.Gradient.linear(Offset(0, size.height * 0.6), Offset(0, size.height),
                [Perch.orange.withValues(alpha: 0), Perch.orange.withValues(alpha: 0.95)]));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) => old.rim != rim || old.radius != radius;
}

/// A small square of a session's mosaic (thumbnails).
class MosaicThumb extends StatelessWidget {
  final int seed;
  final double size;
  final double radius;
  const MosaicThumb({super.key, required this.seed, this.size = 52, this.radius = 14});
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox.square(dimension: size, child: MosaicBackdrop(seed: seed, cells: 8, pixel: 1.6)),
      );
}

/// Squares of [cells] across, each shaded from a warm gradient that runs over the whole
/// area (the logo's orange at the top left into [base] at the bottom right), varied a little
/// square by square like the mosaic, with its fine grid lines. No bird.
class GradientGridPainter extends CustomPainter {
  final int seed;
  final int cells;
  final Color base;
  final bool dark;
  const GradientGridPainter({required this.seed, required this.cells, required this.base, required this.dark});

  /// The colour of square ([x], [y]) in a grid [w] squares wide and [h] high.
  Color cellColor(int x, int y, int w, int h) {
    final t = (((x + 0.5) / w) + ((y + 0.5) / h)) / 2;
    final warm = Color.lerp(base, Perch.orange, 0.58)!;
    final mid = Color.lerp(base, Perch.orange, 0.22)!;
    final c = t < 0.45 ? Color.lerp(warm, mid, t / 0.45)! : Color.lerp(mid, base, (t - 0.45) / 0.55)!;
    // A small, fixed variation per square (the same on every repaint).
    var n = (x * 73856093) ^ (y * 19349663) ^ (seed * 83492791);
    n = (n ^ (n >> 13)) * 1274126177;
    final v = ((n & 0xFF) / 255.0 - 0.5) * 0.16;
    return v >= 0 ? Color.lerp(c, const Color(0xFFFFFFFF), v)! : Color.lerp(c, const Color(0xFF000000), -v)!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final cell = size.width / cells;
    final rows = (size.height / cell).ceil();
    final fill = Paint();
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cells; x++) {
        fill.color = cellColor(x, y, cells, rows);
        canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5), fill);
      }
    }
    final grid = Paint()
      ..color = dark ? const Color(0x40000000) : const Color(0x1F000000)
      ..strokeWidth = 0.8;
    for (var x = 0; x <= cells; x++) {
      canvas.drawLine(Offset(x * cell, 0), Offset(x * cell, size.height), grid);
    }
    for (var y = 0; y <= rows; y++) {
      canvas.drawLine(Offset(0, y * cell), Offset(size.width, y * cell), grid);
    }
  }

  @override
  bool shouldRepaint(GradientGridPainter old) =>
      old.seed != seed || old.cells != cells || old.base != base || old.dark != dark;
}
