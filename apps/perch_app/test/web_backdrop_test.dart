// The board page (the app in a browser on Windows and the Mac): big backgrounds are a plain
// gradient without the bird; the small pictures of sessions keep their mosaic.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/ui/glass/mosaic.dart';

import 'glass_harness.dart';

void main() {
  tearDown(() => MosaicBackdrop.plainBackdrops = false);

  testWidgets('in the browser a backdrop is the glass grid over a gradient, without the bird', (tester) async {
    MosaicBackdrop.plainBackdrops = true;
    await tester.pumpWidget(glassApp(const Column(children: [
      SizedBox(height: 300, child: MosaicBackdrop(key: ValueKey('big'), seed: 7, pixel: 0.75)),
      SizedBox(height: 40, width: 40, child: MosaicBackdrop(key: ValueKey('small'), seed: 3, cells: 8, pixel: 1.6)),
    ])));
    final big = find.byKey(const ValueKey('big'));
    final painters = [
      for (final p in tester.widgetList<CustomPaint>(find.descendant(of: big, matching: find.byType(CustomPaint)))) p.painter
    ];
    // The grid of glass squares (the owner's choice for the board page), and nothing that draws the bird.
    expect(painters.whereType<GradientGridPainter>(), hasLength(1));
    expect(painters.map((p) => p.runtimeType.toString()), isNot(contains('_PixelPainter')));
    expect(painters.map((p) => p.runtimeType.toString()), isNot(contains('_SoftPainter')));
    expect(find.descendant(of: find.byKey(const ValueKey('small')), matching: find.byType(CustomPaint)), findsWidgets);
  });

  test('the grid follows the gradient over the whole page and its squares differ a little', () {
    const p = GradientGridPainter(seed: 7, cells: 30, base: Color(0xFF161310), dark: true);
    final topLeft = p.cellColor(0, 0, 30, 60);
    final bottomRight = p.cellColor(29, 59, 30, 60);
    // Warm (more red) at the top left, the deep colour at the bottom right.
    expect((topLeft.r - bottomRight.r).abs(), greaterThan(0.15));
    final neighbours = {for (var x = 10; x < 16; x++) p.cellColor(x, 20, 30, 60).toARGB32()};
    expect(neighbours.length, greaterThan(1));
  });

  testWidgets('on the phone the backdrop is the mosaic', (tester) async {
    await tester.pumpWidget(glassApp(const SizedBox(height: 300, child: MosaicBackdrop(key: ValueKey('big'), seed: 7))));
    expect(find.descendant(of: find.byKey(const ValueKey('big')), matching: find.byType(CustomPaint)), findsWidgets);
  });
}
