// Helpers for testing Memory Glass screens: the app shell, a phone-sized view, and finders
// for glass buttons and fields.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/ui/app_theme.dart';
import 'package:perch_app/src/ui/glass/widgets.dart';
export 'package:perch_app/src/ui/glass/widgets.dart' show DangerButton, GlassChip, HoldButton;

/// [home] in the app's shell (theme, glass builder).
Widget glassApp(Widget home) => MaterialApp(theme: perchTheme(), builder: glassAppBuilder, home: home);

/// A tall phone, so long screens are built whole.
void tallPhone(WidgetTester tester, {double height = 4200}) {
  tester.view.physicalSize = Size(1080, height);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

/// The text field of the glass field labelled (or, without a label, hinted) [label].
Finder field(String label) => find.descendant(of: find.widgetWithText(GlassField, label), matching: find.byType(TextField));

/// The glass pill labelled [label].
Finder button(String label) => find.widgetWithText(GlassButton, label);

/// Taps the glass pill labelled [label] (the last one, when a sheet covers another).
Future<void> tapButton(WidgetTester tester, String label) async {
  await tester.tap(button(label).last);
  await tester.pumpAndSettle();
}

/// Whether the glass pill labelled [label] can be pressed.
bool enabled(WidgetTester tester, String label) => tester.widget<GlassButton>(button(label).last).onTap != null;

/// Taps a widget by key and settles.
Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)).last);
  await tester.pumpAndSettle();
}

/// The ember (destructive) pill labelled [label].
Finder dangerButton(String label) => find.widgetWithText(DangerButton, label);

/// Taps the ember pill labelled [label] (the last one) and settles.
Future<void> tapDanger(WidgetTester tester, String label) async {
  await tester.tap(dangerButton(label).last);
  await tester.pumpAndSettle();
}

/// Presses and holds the hold-to-confirm pill labelled [label] for [hold], then lets go.
Future<void> holdToConfirm(WidgetTester tester, String label, {Duration hold = const Duration(milliseconds: 1400)}) async {
  final g = await tester.startGesture(tester.getCenter(find.widgetWithText(HoldButton, label).last));
  for (var t = Duration.zero; t < hold; t += const Duration(milliseconds: 100)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await g.up();
  await tester.pumpAndSettle();
}
