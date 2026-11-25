// The intro's frames as pixels: the first frame is empty, the bird shows on its way in and
// nothing hangs under it, and it has gone at the end. A file of its own: the logo must load
// for real (a load started inside another test's fake clock never completes).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/ui/glass/mosaic.dart';
import 'package:perch_app/src/ui/glass/palette.dart';
import 'package:perch_app/src/ui/intro.dart';

const phone = Size(411, 891);

/// The pixels of one intro frame at [t] on a phone-sized screen (RGBA, one per logical pixel).
Future<({ByteData bytes, int w, int h})> frameAt(WidgetTester tester, double t) async {
  final key = GlobalKey();
  tester.view.physicalSize = phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(MosaicScene.load);
  await tester.pumpWidget(MediaQuery(
    data: const MediaQueryData(size: phone),
    child: RepaintBoundary(key: key, child: IntroFrame(t: t)),
  ));
  final ro = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late ByteData bytes;
  late int w, h;
  await tester.runAsync(() async {
    final img = await ro.toImage();
    w = img.width;
    h = img.height;
    bytes = (await img.toByteData())!;
  });
  return (bytes: bytes, w: w, h: h);
}

/// Pixels of the bird's or the branch's colours (orange or cream; not the warm black).
int birdPixels(ByteData b, {int fromRow = 0, int? toRow, required int w}) {
  var n = 0;
  final rows = (toRow ?? b.lengthInBytes ~/ (4 * w));
  for (var y = fromRow; y < rows; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      if (b.getUint8(i) > 120) n++; // red: the orange body and the cream both have it
    }
  }
  return n;
}

void main() {
  testWidgets('the first frame is empty; the bird shows on its way in', (tester) async {
    if (!File(logoAsset).existsSync()) return;
    var f = await frameAt(tester, 0);
    expect(birdPixels(f.bytes, w: f.w), 0, reason: 'nothing of the bird before it flies in');
    f = await frameAt(tester, 0.16);
    expect(birdPixels(f.bytes, w: f.w), greaterThan(500), reason: 'it is flying in');
    final l = introLayout(phone);
    final branch = IntroFrame.branchAt(0.16);
    expect(branch.opacity, greaterThan(0), reason: 'the branch shows before the landing');
    f = await frameAt(tester, 0.95);
    expect(birdPixels(f.bytes, w: f.w), 0, reason: 'gone at the end');
    // Mid-flight, early: nothing under the bird's feet but the warm black (no terminal or twig
    // travels with it). The branch is not shown yet.
    final early = IntroFrame.birdAt(0.08, phone);
    expect(IntroFrame.branchAt(0.08).opacity, 0);
    f = await frameAt(tester, 0.08);
    final below = (early.feet.dy + 4).ceil();
    if (below < f.h) {
      expect(birdPixels(f.bytes, w: f.w, fromRow: below), 0, reason: 'nothing hangs under the flying bird');
    }
    expect(l.nameTop, greaterThan(l.perchY), reason: 'the branch sits above the name');
  });

}
