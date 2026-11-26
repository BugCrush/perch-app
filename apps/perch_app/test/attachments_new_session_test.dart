// Attachments in the New session sheet: once a folder is chosen, a picked file uploads into
// that folder; Start waits for it and the first instruction ends with its mention; another
// folder drops the chips.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/ui/attachment_chips.dart';
import 'package:perch_app/src/ui/glass/widgets.dart' show GlassScaffold;
import 'package:perch_app/src/ui/new_session_sheet.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'fakes.dart';
import 'glass_harness.dart';

class FakePicker implements AttachmentPicker {
  PickedFile? next;
  @override
  Future<PickedFile?> photo() async => next;
  @override
  Future<PickedFile?> file() async => next;
}

void main() {
  late FakeChannels channels;
  late HostConnection c;
  late FakeHostSide host;
  final picker = FakePicker();
  const attachWelcome = Welcome(machineName: 'devbox', os: 'macos', hostVersion: '1.1.0', attachments: true);
  const path = 'perch-attachments/2026-11-26_1612_shot.png';

  setUp(() => channels = FakeChannels());
  tearDown(() => c.dispose());

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => pump(40));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    c = HostConnection(testMachine(id: 'm1', label: 'Desk'), channelFactory: channels.factory);
    c.connect();
    host = channels.last;
    host.send(attachWelcome);
    host.send(const Sessions(sessions: []));
    await tester.runAsync(() => eventually(() => c.link.value == LinkState.online));
    tallPhone(tester);
    await tester.pumpWidget(glassApp(GlassScaffold(child: NewSessionSheet(connection: c, perSession: false, picker: picker))));
    await settle(tester);
  }

  Future<void> useFolder(WidgetTester tester, String folder) async {
    host.send(DirListing(path: folder, parent: '/'));
    await settle(tester);
    await tester.tap(button('Use this folder'));
    await settle(tester);
  }

  Future<void> pick(WidgetTester tester) async {
    picker.next = PickedFile(name: 'shot.png', bytes: Uint8List.fromList([1, 2, 3]), mime: 'image/png');
    await tester.tap(find.byKey(const ValueKey('attach')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-Photo')));
    await settle(tester);
  }

  List<T> sent<T extends ClientMessage>() => host.messages.whereType<T>().toList();

  testWidgets('no attach button before a folder is chosen', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('attach')), findsNothing);
    await useFolder(tester, '/work');
    expect(find.byKey(const ValueKey('attach')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a picked photo uploads into the folder; Start waits, then sends the mention', (tester) async {
    await open(tester);
    await useFolder(tester, '/work');
    await pick(tester);
    final start = sent<AttachStart>().single;
    expect((start.cwd, start.sessionId), ('/work', null));
    await tester.enterText(field('First instruction'), 'Fix this');
    await tester.pump();
    expect(enabled(tester, 'Start'), isFalse);
    host.send(AttachDone(uploadId: start.uploadId, path: path));
    await settle(tester);
    expect(enabled(tester, 'Start'), isTrue);
    await tester.tap(button('Start'));
    await settle(tester);
    expect(sent<StartSession>().single.prompt, 'Fix this\n@$path');
    expect(sent<StartSession>().single.cwd, '/work');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an attachment alone is enough for Start', (tester) async {
    await open(tester);
    await useFolder(tester, '/work');
    await pick(tester);
    host.send(AttachDone(uploadId: sent<AttachStart>().single.uploadId, path: path));
    await settle(tester);
    await tester.tap(button('Start'));
    await settle(tester);
    expect(sent<StartSession>().single.prompt, '@$path');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('another folder drops the chips', (tester) async {
    await open(tester);
    await useFolder(tester, '/work');
    await pick(tester);
    expect(find.byKey(const ValueKey('attachment-chip')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('folder-up')));
    await settle(tester);
    await useFolder(tester, '/other');
    expect(find.text('Folder: /other'), findsOneWidget);
    expect(find.byKey(const ValueKey('attachment-chip')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
