import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/main.dart';
import 'package:perch_app/src/state/providers.dart';
import 'package:perch_app/src/ui/add_machine_screen.dart';
import 'package:perch_app/src/ui/conversation.dart';
import 'package:perch_app/src/ui/glass/dots.dart';
import 'package:perch_app/src/ui/glass/mosaic.dart';
import 'package:perch_app/src/ui/glass/palette.dart';
import 'package:perch_app/src/ui/glass/theme.dart';
import 'package:perch_app/src/ui/glass/widgets.dart';
import 'package:perch_app/src/ui/home_screen.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'glass_harness.dart';
import 'push_app_test.dart' show FakePush;

void main() {
  late FakeChannels channels;

  setUp(() {
    channels = FakeChannels();
    GlassTheme.reset();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tallPhone(tester);
    await tester.pumpWidget(ProviderScope(overrides: [
      channelFactoryProvider.overrideWithValue(channels.factory),
      pushServiceProvider.overrideWithValue(FakePush()),
      qrScannerProvider.overrideWithValue(null),
    ], child: const PerchApp()));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
  }

  testWidgets('the app opens on Memory Glass: the bird, the hero and no way out to another app', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpApp(tester);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(MosaicBackdrop), findsWidgets);
    expect(find.byKey(const ValueKey('hero')), findsOneWidget);
    expect(find.text('sessions need you'), findsOneWidget);
    expect(find.text('Real app'), findsNothing);
  });

  group('the bird', () {
    setUp(() => GlassMotion.enabled = true);
    tearDown(() => GlassMotion.enabled = false);

    Future<MosaicBackdropState> pumpBird(WidgetTester tester, {required bool reduceMotion}) async {
      await tester.pumpWidget(MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 400, height: 800, child: MosaicBackdrop(seed: 7, flap: true)),
        ),
      ));
      return tester.state<MosaicBackdropState>(find.byType(MosaicBackdrop));
    }

    testWidgets('stays still when the platform asks for reduced motion', (tester) async {
      final bird = await pumpBird(tester, reduceMotion: true);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        expect(bird.pose, 0);
      }
      expect(bird.bursts, 0);
      expect(bird.blinks, 0);
      expect(bird.eye, eyeOpen);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('flaps in bursts, then rests without drawing frames', (tester) async {
      final bird = await pumpBird(tester, reduceMotion: false);
      final poses = <int>{};
      // Until the first burst is over (a blink can put it off by a moment).
      for (var i = 0; i < 200 && (bird.bursts == 0 || bird.flapping); i++) {
        await tester.pump(const Duration(milliseconds: 50));
        poses.add(bird.pose);
      }
      expect(bird.bursts, 1);
      expect(poses.reduce((a, b) => a > b ? a : b), greaterThanOrEqualTo(2),
          reason: 'the wing lifts (a tired two-beat burst can peak at half way)');
      // After the burst the wing is folded and nothing animates until the next one (a blink
      // may be closing the eye just then: wait for it).
      await tester.pump(const Duration(milliseconds: 2000));
      for (var i = 0; i < 40 && bird.blinking; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(bird.pose, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('blinks now and then, never during a flap, and draws nothing in between', (tester) async {
      final bird = await pumpBird(tester, reduceMotion: false);
      final eyes = <int>{};
      var idleBefore = false;
      for (var i = 0; i < 900; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(bird.flapping && bird.blinking, isFalse, reason: 'a blink and a flap at once');
        expect(bird.eye != eyeOpen && bird.pose != 0, isFalse, reason: 'eye closed while the wing is up');
        eyes.add(bird.eye);
        final idle = !bird.flapping && !bird.blinking;
        if (idle && idleBefore) expect(tester.binding.hasScheduledFrame, isFalse, reason: 'frames while resting');
        idleBefore = idle;
      }
      expect(bird.blinks, greaterThanOrEqualTo(3));
      expect(bird.bursts, greaterThanOrEqualTo(2));
      expect(eyes, containsAll([eyeOpen, eyeHalf, eyeShut]));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the working wave stands still with reduced motion', (tester) async {
      Future<void> wave(bool reduce) => tester.pumpWidget(MediaQuery(
            data: MediaQueryData(disableAnimations: reduce),
            child: const Directionality(textDirection: TextDirection.ltr, child: Center(child: WorkingWave())),
          ));
      await wave(true);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await wave(false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('theme', () {
    Finder backdrop() => find.byWidgetPredicate((w) => w is MosaicBackdrop && w.fade != null);
    tearDown(() => TestWidgetsFlutterBinding.instance.platformDispatcher.clearPlatformBrightnessTestValue());

    testWidgets('follows the phone; the switch picks light or dark at once and remembers it', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await pumpApp(tester);
      expect(G.dark, isTrue);
      expect(tester.widget<MosaicBackdrop>(backdrop()).fade, G.deep);

      await tapKey(tester, 'open-menu');
      await tapKey(tester, 'theme-light');
      expect(G.dark, isFalse);
      expect(tester.widget<MosaicBackdrop>(backdrop()).fade, const Color(0xFF1B1519), reason: 'the screen redrew in light');
      expect((await SharedPreferences.getInstance()).getString(GlassTheme.prefsKey), 'light');

      await tapKey(tester, 'theme-dark');
      expect(G.dark, isTrue);
      expect(tester.widget<MosaicBackdrop>(backdrop()).fade, const Color(0xFF0E0A0D));

      await tapKey(tester, 'menu-close');
      // Other screens follow too.
      await tapKey(tester, 'add-machine');
      expect(find.byType(AddMachineScreen), findsOneWidget);
      expect(tester.widget<MosaicBackdrop>(backdrop().last).fade, const Color(0xFF0E0A0D));
      await tapKey(tester, 'back');

      // Following the phone again: the phone turns light, so does Memory Glass.
      await tapKey(tester, 'open-menu');
      await tapKey(tester, 'theme-system');
      await tapKey(tester, 'menu-close');
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(G.dark, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a remembered choice wins over the phone', (tester) async {
      SharedPreferences.setMockInitialValues({GlassTheme.prefsKey: 'dark'});
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await pumpApp(tester);
      expect(GlassTheme.mode.value, GlassMode.dark);
      expect(G.dark, isTrue);
    });

    testWidgets('the choice made in the prototype carries over', (tester) async {
      SharedPreferences.setMockInitialValues({GlassTheme.legacyKey: 'light'});
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await pumpApp(tester);
      expect(GlassTheme.mode.value, GlassMode.light);
      expect(G.dark, isFalse);
    });

    test('text stays WCAG AA on the glass in both themes', () {
      double ratio(Color a, Color b) {
        final la = a.computeLuminance(), lb = b.computeLuminance();
        return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
      }

      for (final dark in [false, true]) {
        G.dark = dark;
        // The lightest glass text sits on: frost at its strongest tint over the panel.
        final frost = Color.alphaBlend(G.frost.withValues(alpha: (0.18 * G.frostScale) + 0.05), G.panel);
        for (final bg in [G.deep, G.panel, frost]) {
          for (final fg in [G.text, G.muted, G.glow]) {
            expect(ratio(fg, bg), greaterThanOrEqualTo(4.5), reason: 'dark=$dark fg=$fg bg=$bg');
          }
        }
        // The amber note and the orange text on deep glass.
        expect(ratio(Perch.amber, G.deep), greaterThanOrEqualTo(4.5));
        expect(ratio(Perch.ember, G.deep), greaterThanOrEqualTo(4.5));
      }
      G.dark = false;
    });
  });

  testWidgets('glass keeps blurring while a list is pulled past its top', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpApp(tester);
    expect(find.byType(StretchingOverscrollIndicator), findsNothing);
    final list = find.byKey(const ValueKey('home-list'));
    final gesture = await tester.startGesture(tester.getTopLeft(list) + const Offset(40, 300));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Still holding, pulled past the top: the list shows overscroll feedback (a bounce) ...
    final position = tester.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable))).position;
    expect(position.pixels, lessThan(0));
    // ... and every pane of glass still blurs what is behind it: no image filter layer (the
    // stretch's) sits between a backdrop filter and the mosaic.
    final backdrops = tester.layers.whereType<BackdropFilterLayer>().toList();
    expect(backdrops, isNotEmpty);
    for (final b in backdrops) {
      expect(b.filter, isA<ui.ImageFilter>());
      for (Layer? p = b.parent; p != null; p = p.parent) {
        expect(p, isNot(isA<ImageFilterLayer>()), reason: 'a backdrop filter inside an image filter blurs nothing');
      }
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
  });

  testWidgets('Claude\'s replies are set in the glass type, readable on the panel', (tester) async {
    await tester.pumpWidget(glassApp(GlassScaffold(
      child: ListView(children: [
        EventView(AssistantText('Plain body text here\n\n# A heading\n\n- a list item\n\nA [link here](https://example.com) '
            'and `inline code` too\n\n```\nblock code line\n```')),
      ]),
    )));
    await tester.pumpAndSettle();
    TextStyle? styleOf(String needle) {
      TextStyle? found;
      void walk(InlineSpan span, TextStyle? inherited) {
        if (found != null) return;
        final style = inherited == null ? span.style : inherited.merge(span.style);
        if (span is TextSpan) {
          if ((span.text ?? '').contains(needle)) {
            found = style;
            return;
          }
          for (final c in span.children ?? const <InlineSpan>[]) {
            walk(c, style);
          }
        }
      }

      for (final r in tester.allRenderObjects) {
        if (r is RenderParagraph) walk(r.text, null);
      }
      return found;
    }

    expect(styleOf('Plain body text')?.color, G.text);
    expect(styleOf('Plain body text')?.fontFamily, GlassFonts.serif);
    expect(styleOf('A heading')?.color, G.text);
    expect(styleOf('a list item')?.color, G.text);
    expect(styleOf('link here')?.color, G.glow);
    expect(styleOf('inline code')?.color, G.glow);
    expect(styleOf('block code line')?.fontFamily, GlassFonts.mono);
  });

  test('tool captions summarise their input', () {
    expect(toolCaption(ToolCall('t', 'Bash', {'command': 'ls -la\nmore'})), 'Bash · ls -la');
    expect(toolCaption(ToolCall('t', 'Read', {'file_path': r'D:\x'})), r'Read · D:\x');
    expect(toolCaption(ToolCall('t', 'Thing', {})), 'Thing');
  });
}
