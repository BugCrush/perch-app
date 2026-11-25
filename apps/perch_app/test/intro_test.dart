// The cold-start intro: it plays over the first screen and ends on it, a tap skips it, it
// plays once per launch, and never with reduced motion. Its clock starts only once the app is
// on screen and a slow frame never skips a part (the S24 showed the bird already leaving).
// The bird starts and ends beyond the screen, beats its wing while it flies, and flies without
// the icon's terminal and twig: it lands on a branch above the name.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/ui/glass/palette.dart';
import 'package:perch_app/src/ui/intro.dart';

Widget app({bool reduceMotion = false}) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: IntroGate(child: child!),
      ),
      home: const Scaffold(body: Center(child: Text('landing'))),
    );

double introT(WidgetTester tester) => tester.widget<IntroFrame>(find.byType(IntroFrame)).t;

/// Frames at 60 Hz for [d].
Future<void> frames(WidgetTester tester, Duration d) async {
  for (var i = 0; i < d.inMilliseconds ~/ 16; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

const phone = Size(411, 891);

/// The number of wing beats in [a]..[b]: rises of the wing past three quarters.
int beatsIn(double a, double b) {
  var n = 0;
  var up = false;
  for (var t = a; t <= b; t += 0.001) {
    final lift = IntroFrame.birdAt(t, phone).lift;
    if (!up && lift > 0.75) n++;
    up = lift > 0.75 ? true : (lift < 0.25 ? false : up);
  }
  return n;
}

void main() {
  setUp(() {
    GlassMotion.enabled = true;
    IntroGate.reset();
    IntroGate.presented = () => Future.value();
  });
  tearDown(() => GlassMotion.enabled = false);

  testWidgets('plays over the first screen and ends on it', (tester) async {
    await tester.pumpWidget(app());
    expect(find.byKey(const ValueKey('intro')), findsOneWidget);
    await frames(tester, introStartGuard + introDuration * 0.4);
    expect(find.byKey(const ValueKey('intro-name')), findsOneWidget, reason: 'the name shows while the bird rests');
    expect(introT(tester), inInclusiveRange(0.3, 0.5));
    await frames(tester, introDuration);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('intro')), findsNothing);
    expect(find.text('landing'), findsOneWidget);
    expect(introDuration, lessThan(const Duration(seconds: 2)));
  });

  test('the bird comes from beyond the bottom left and leaves beyond the top right', () {
    final screen = Offset.zero & phone;
    Rect reach(double t) {
      final r = IntroFrame.birdReach(t, phone);
      return Rect.fromCircle(center: r.centre, radius: r.radius);
    }

    // Everything the bird could cover, its raised wing included, is off the screen.
    expect(reach(0).overlaps(screen), isFalse, reason: 'nothing of it on the first frame');
    expect(reach(0).right, lessThan(0));
    expect(reach(0).top, greaterThan(0), reason: 'low on the left: it comes from the bottom left');
    expect(reach(0.9).overlaps(screen), isFalse, reason: 'gone before the end');
    expect(reach(1).overlaps(screen), isFalse);
    expect(reach(0.9).left, greaterThan(phone.width));
    expect(reach(0.9).bottom, lessThan(phone.height), reason: 'high on the right: it leaves to the top right');
    // It sits on the branch above the middle while the name shows.
    final rest = IntroFrame.birdAt(0.45, phone);
    expect(rest.feet, IntroFrame.birdAt(0.55, phone).feet);
    expect((rest.feet.dx - phone.width / 2).abs(), lessThan(20));
    expect(rest.lift, 0, reason: 'its wing folded while it sits');
  });

  test('the wing beats while it flies, faster on take-off, and folds while it sits', () {
    final arriving = beatsIn(0, 0.29);
    final leaving = beatsIn(introLeaveAt, 0.88);
    expect(arriving, greaterThanOrEqualTo(3));
    expect(leaving, greaterThanOrEqualTo(4));
    // Beats per unit of time.
    expect(leaving / (0.88 - introLeaveAt), greaterThan(arriving / 0.29));
    final poses = [for (var t = 0.0; t < 0.24; t += 0.01) IntroFrame.birdAt(t, phone).lift];
    expect(poses.reduce((a, b) => a > b ? a : b), greaterThan(0.8));
    expect(poses.reduce((a, b) => a < b ? a : b), lessThan(0.1));
    for (var t = 0.38; t < introLeaveAt; t += 0.01) {
      expect(IntroFrame.birdAt(t, phone).lift, 0, reason: 'folded at $t');
    }
    expect(IntroFrame.birdAt(0.33, phone).lift, inExclusiveRange(0, 0.3), reason: 'one small settle');
  });

  test('the flying bird is only the bird: no leaf, twig or terminal', () {
    // Points of the logo (viewBox 1023 x 1031) that are not the bird.
    const notBird = [
      Offset(150, 580), // the leaf
      Offset(100, 540),
      Offset(330, 600), // the twig under the bird
      Offset(400, 560),
      Offset(500, 640), // the terminal's top edge, under the feet
      Offset(800, 700), // its title bar
      Offset(300, 900),
    ];
    for (final p in notBird) {
      expect(introBirdOnly.contains(p), isFalse, reason: '$p');
    }
    const bird = [Offset(740, 140), Offset(500, 400), Offset(600, 300), Offset(520, 590), Offset(255, 530)];
    for (final p in bird) {
      expect(introBirdOnly.contains(p), isTrue, reason: '$p');
    }
  });

  testWidgets('waits on its first frame until the app is on screen', (tester) async {
    final shown = Completer<void>();
    IntroGate.presented = () => shown.future;
    await tester.pumpWidget(app());
    // Android's splash still covers the app: the clock has not started.
    await frames(tester, const Duration(seconds: 2));
    expect(find.byKey(const ValueKey('intro')), findsOneWidget);
    expect(introT(tester), 0, reason: 'part 1 has not begun');
    shown.complete();
    await tester.pump(const Duration(milliseconds: 16));
    expect(introT(tester), 0, reason: 'a short guard after the first frame is on screen');
    await frames(tester, introStartGuard + const Duration(milliseconds: 200));
    expect(introT(tester), greaterThan(0));
    expect(introT(tester), lessThan(0.29), reason: 'the bird is still flying in');
  });

  testWidgets('a slow frame slows the intro down instead of skipping a part', (tester) async {
    await tester.pumpWidget(app());
    await frames(tester, introStartGuard + const Duration(milliseconds: 100));
    final before = introT(tester);
    // Start-up work blocks a frame for a second (debug builds, plugins, the first screen).
    await tester.pump(const Duration(seconds: 1));
    expect(introT(tester) - before, lessThan(0.05));
    // The start-up keeps the frames slow: it waits for calm frames before starting.
    IntroGate.reset();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(introT(tester), 0, reason: 'janky frames: not started yet');
    await frames(tester, introStartGuard + const Duration(milliseconds: 100));
    expect(introT(tester), greaterThan(0), reason: 'calm frames: it starts');
  });

  testWidgets('starts anyway when the frames never calm down', (tester) async {
    await tester.pumpWidget(app());
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(introT(tester), greaterThan(0));
  });

  testWidgets('a tap skips to the end; once per launch', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('intro')));
    await frames(tester, introDuration * 0.45);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('intro')), findsNothing);
    // The app's widgets built again (another first screen): no second intro.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    expect(find.byKey(const ValueKey('intro')), findsNothing);
  });

  testWidgets('never with reduced motion', (tester) async {
    await tester.pumpWidget(app(reduceMotion: true));
    expect(find.byKey(const ValueKey('intro')), findsNothing);
    expect(find.text('landing'), findsOneWidget);
  });
}
