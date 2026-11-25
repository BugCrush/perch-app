import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'glass_harness.dart';

void main() {
  Widget list() => ListView(children: [for (var i = 0; i < 60; i++) SizedBox(height: 60, child: Text('Row $i'))]);

  testWidgets('a solid band covers the status bar, over every screen, the height of the bar', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 120);
    tester.view.viewPadding = const FakeViewPadding(top: 120);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(glassApp(list()));
    final shade = find.byKey(const ValueKey('status-bar-shade'));
    expect(shade, findsOneWidget);
    expect(tester.getRect(shade), const Rect.fromLTWH(0, 0, 360, 40));
    // Drawn after (above) the screen.
    final order = find.byWidgetPredicate((w) => w is ColoredBox || w is ListView).evaluate().map((e) => e.widget).toList();
    expect(order.indexWhere((w) => w is ColoredBox && w.key == const ValueKey('status-bar-shade')),
        greaterThan(order.indexWhere((w) => w is ListView)));
  });

  testWidgets('no status bar (the board page in a browser): no band', (tester) async {
    await tester.pumpWidget(glassApp(list()));
    expect(find.byKey(const ValueKey('status-bar-shade')), findsNothing);
  });
}
