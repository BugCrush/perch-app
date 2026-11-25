import 'dart:async';

import 'package:perch_app/src/ui/glass/palette.dart';

/// Every test runs with Memory Glass's looping motion off (the bird, the wave, the line
/// loaders); tests of the motion turn it on themselves.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  GlassMotion.enabled = false;
  await testMain();
}
