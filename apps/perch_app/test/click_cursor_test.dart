// In a browser (the board page on Windows and the Mac) every control that takes a tap
// shows the hand cursor; Flutter shows it only where a MouseRegion asks for it.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perch_app/src/ui/glass/click.dart';
import 'package:perch_app/src/ui/glass/pressable.dart';

bool showsHand(WidgetTester tester, Finder f) => tester
    .widgetList<MouseRegion>(find.ancestor(of: f, matching: find.byType(MouseRegion)))
    .any((m) => m.cursor == SystemMouseCursors.click);

void main() {
  testWidgets('a tappable control shows the hand, a disabled one does not', (tester) async {
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Column(children: [
        Pressable(onTap: () {}, builder: (_, _, _) => const Text('on')),
        Pressable(builder: (_, _, _) => const Text('off')),
        ClickDetector(onTap: () {}, child: const Text('tap')),
        ClickDetector(onLongPress: () {}, child: const Text('hold')),
        ClickDetector(onHorizontalDragEnd: (_) {}, child: const Text('swipe')),
      ]),
    ));
    expect(showsHand(tester, find.text('on')), isTrue);
    expect(showsHand(tester, find.text('off')), isFalse);
    expect(showsHand(tester, find.text('tap')), isTrue);
    expect(showsHand(tester, find.text('hold')), isTrue);
    expect(showsHand(tester, find.text('swipe')), isFalse);
  });

  test('no plain GestureDetector takes taps in the app (use ClickDetector)', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.endsWith('click.dart')) continue;
      // The intro's tap anywhere to skip covers the whole screen: no hand there.
      if (f.path.endsWith('intro.dart')) continue;
      if (f.readAsStringSync().contains('GestureDetector(')) offenders.add(f.path);
    }
    expect(offenders, isEmpty);
  });
}
