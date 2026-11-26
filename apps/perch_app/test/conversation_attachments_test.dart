// A message's `@perch-attachments/…` mentions show as attachment chips under its text: the
// picture when this phone sent it, else the file's name. Other `@` mentions stay text.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/ui/conversation.dart';
import 'package:perch_app/src/ui/glass/widgets.dart' show GlassScaffold;
import 'package:perch_app/src/ui/sent_attachments.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'glass_harness.dart';

// A 1×1 transparent PNG.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  const path = 'perch-attachments/2026-11-26_1612_x.png';
  setUp(SentAttachmentCache.clearMemory);

  Future<void> show(WidgetTester tester, String text, {String folder = '/work/a'}) async {
    tallPhone(tester, height: 2340);
    await tester.pumpWidget(glassApp(GlassScaffold(child: EventView(UserMessage(text, seq: 1), machineId: 'm', folder: folder))));
    await tester.pumpAndSettle();
  }

  testWidgets('the mention line becomes a chip with the name after the time', (tester) async {
    await show(tester, 'Look\n@$path');
    expect(find.text('Look'), findsOneWidget);
    expect(find.textContaining('@perch-attachments'), findsNothing);
    expect(find.byKey(const ValueKey('sent-attachment')), findsOneWidget);
    expect(find.text('x.png'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('an image this phone sent shows as a picture', (tester) async {
    SentAttachmentCache.put('m', '/work/a', path, _png);
    await show(tester, 'Look\n@$path');
    expect(find.byType(Image), findsOneWidget);
  });

  // The same name sent into two sessions' folders in the same minute: each conversation
  // shows its own picture (the key is machine, session folder and path).
  testWidgets('the same file name in another session folder is not mixed up', (tester) async {
    SentAttachmentCache.put('m', '/work/a', path, _png);
    await show(tester, 'Look\n@$path', folder: '/work/b');
    expect(find.byType(Image), findsNothing);
    expect(find.text('x.png'), findsOneWidget);
    expect(SentAttachmentCache.get('m', '/work/b', path), isNull);
    expect(SentAttachmentCache.get('m', '/work/a', path), _png);
  });

  testWidgets('only attachments: just the chips', (tester) async {
    await show(tester, '@$path @perch-attachments/2026-11-26_1613_notes.pdf');
    expect(find.byKey(const ValueKey('sent-attachment')), findsNWidgets(2));
    expect(find.text('notes.pdf'), findsOneWidget);
  });

  testWidgets('other mentions stay as they are', (tester) async {
    await show(tester, 'see @src/a.dart');
    expect(find.text('see @src/a.dart'), findsOneWidget);
    expect(find.byKey(const ValueKey('sent-attachment')), findsNothing);
  });

  test('a picture read from the disk copy stays in memory (no re-read on every rebuild)', () async {
    final dir = Directory.systemTemp.createTempSync('perch_sent_');
    final before = SentAttachmentCache.folder;
    SentAttachmentCache.folder = () async => dir;
    try {
      SentAttachmentCache.put('m', '/work/a', path, _png);
      await Future<void>.delayed(const Duration(milliseconds: 100)); // the disk copy is written
      SentAttachmentCache.clearMemory(); // as after a restart
      expect(SentAttachmentCache.get('m', '/work/a', path), isNull);
      expect(await SentAttachmentCache.read('m', '/work/a', path), _png);
      expect(SentAttachmentCache.get('m', '/work/a', path), _png);
    } finally {
      SentAttachmentCache.folder = before;
      dir.deleteSync(recursive: true);
    }
  });
}
