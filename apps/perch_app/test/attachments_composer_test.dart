// Attaching images and files in a conversation's composer: the paperclip only for full devices
// on hosts that take attachments; chips with progress; Send waits for the uploads and adds an
// `@perch-attachments/…` mention per file; failures with Retry and Remove; the 20 MB limit.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/ui/attachment_chips.dart';
import 'package:perch_app/src/ui/glass/widgets.dart' show GlassOrb;
import 'package:perch_app/src/ui/session_screen.dart';
import 'package:perch_protocol/perch_protocol.dart';

import 'fakes.dart';
import 'glass_harness.dart';

class FakePicker implements AttachmentPicker {
  PickedFile? next;
  int photos = 0, files = 0;
  @override
  Future<PickedFile?> photo() async {
    photos++;
    return next;
  }

  @override
  Future<PickedFile?> file() async {
    files++;
    return next;
  }
}

void main() {
  late FakeChannels channels;
  late HostConnection conn;
  late FakePicker picker;

  setUp(() {
    channels = FakeChannels();
    picker = FakePicker();
  });
  tearDown(() => conn.dispose());

  const attachWelcome = Welcome(machineName: 'devbox', os: 'macos', hostVersion: '1.1.0', attachments: true);
  const path = 'perch-attachments/2026-11-26_1612_x.png';

  Future<void> open(WidgetTester tester,
      {Welcome w = attachWelcome, String? relayUrl, SessionState state = SessionState.idle}) async {
    conn = HostConnection(
        testMachine(id: 'm', label: 'Desk', lan: relayUrl == null ? ['10.0.0.1:8787'] : const [], relayUrl: relayUrl),
        channelFactory: channels.factory);
    conn.connect();
    channels.last.send(w);
    channels.last.send(Sessions(sessions: [summary('s1', name: 'Fix login', state: state)]));
    await tester.runAsync(() => eventually(() => conn.link.value == LinkState.online && conn.sessions.value.isNotEmpty));
    tallPhone(tester, height: 2340);
    await tester.pumpWidget(glassApp(SessionScreen(connection: conn, sessionId: 's1', picker: picker)));
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<Subscribe>().isNotEmpty));
    channels.last.send(const Events(sessionId: 's1', events: []));
    await tester.runAsync(() => pump(30));
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => pump(30));
    await tester.pumpAndSettle();
  }

  Future<void> hostSends(WidgetTester tester, HostMessage m) async {
    channels.last.send(m);
    await settle(tester);
  }

  List<T> sent<T extends ClientMessage>() => channels.last.messages.whereType<T>().toList();
  bool sendEnabled(WidgetTester tester) => tester.widget<GlassOrb>(find.byKey(const ValueKey('send'))).onTap != null;
  Finder composer() => find.descendant(of: find.byKey(const ValueKey('composer')), matching: find.byType(TextField));

  Future<void> pick(WidgetTester tester, String which, PickedFile file) async {
    picker.next = file;
    await tester.tap(find.byKey(const ValueKey('attach')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('menu-$which')));
    await tester.pumpAndSettle();
    await settle(tester);
  }

  Uint8List png() => Uint8List.fromList(List.generate(10, (i) => i));

  testWidgets('no attach button on a watch-only device or an older host', (tester) async {
    await open(tester,
        w: const Welcome(
            machineName: 'devbox', os: 'macos', hostVersion: '1.1.0', attachments: true, permission: DevicePermissions.watch));
    expect(find.byKey(const ValueKey('attach')), findsNothing);
    await hostSends(tester, welcome);
    expect(find.byKey(const ValueKey('attach')), findsNothing);
    await hostSends(tester, attachWelcome);
    expect(find.byKey(const ValueKey('attach')), findsOneWidget);
  });

  testWidgets('no attach button when the session has ended', (tester) async {
    await open(tester, state: SessionState.finished);
    expect(find.byKey(const ValueKey('attach')), findsNothing);
  });

  testWidgets('a photo uploads; Send waits for it and adds the mention', (tester) async {
    await open(tester);
    await pick(tester, 'Photo', PickedFile(name: 'x.png', bytes: png(), mime: 'image/png'));
    expect(picker.photos, 1);
    expect(find.byKey(const ValueKey('attachment-chip')), findsOneWidget);
    final start = sent<AttachStart>().single;
    expect((start.sessionId, start.name, start.size), ('s1', 'x.png', 10));
    await tester.enterText(composer(), 'Look');
    await tester.pump();
    expect(sendEnabled(tester), isFalse, reason: 'still uploading');
    await hostSends(tester, AttachAccepted(uploadId: start.uploadId, path: path));
    await hostSends(tester, AttachDone(uploadId: start.uploadId, path: path));
    expect(sendEnabled(tester), isTrue);
    await tester.tap(find.byKey(const ValueKey('send')));
    await settle(tester);
    expect(sent<SendMessage>().single.text, 'Look\n@$path');
    expect(find.byKey(const ValueKey('attachment-chip')), findsNothing);
  });

  testWidgets('only an attachment and no text: the mention alone', (tester) async {
    await open(tester);
    await pick(tester, 'File', PickedFile(name: 'x.png', bytes: png()));
    expect(picker.files, 1);
    final start = sent<AttachStart>().single;
    await hostSends(tester, AttachDone(uploadId: start.uploadId, path: path));
    expect(sendEnabled(tester), isTrue);
    await tester.tap(find.byKey(const ValueKey('send')));
    await settle(tester);
    expect(sent<SendMessage>().single.text, '@$path');
  });

  testWidgets('over the relay a chip says how many relay messages', (tester) async {
    await open(tester, relayUrl: 'https://relay.example');
    expect(conn.route.value, LinkRoute.relay);
    const size = 5 * 1024 * 1024;
    await pick(tester, 'File', PickedFile(name: 'big.pdf', bytes: Uint8List(size)));
    expect(find.textContaining('about ${attachmentRelayMessages(size)} relay messages'), findsOneWidget);
  });

  testWidgets('a refusal shows its reason; Retry starts again, Remove drops the chip', (tester) async {
    await open(tester);
    await pick(tester, 'Photo', PickedFile(name: 'x.png', bytes: png(), mime: 'image/png'));
    final first = sent<AttachStart>().single;
    await hostSends(tester, AttachFailed(uploadId: first.uploadId, reason: 'This session has ended'));
    expect(find.text('This session has ended'), findsOneWidget);
    expect(sendEnabled(tester), isFalse, reason: 'a failed attachment holds Send');
    await tester.tap(find.byKey(const ValueKey('attachment-retry')));
    await settle(tester);
    expect(sent<AttachStart>(), hasLength(2));
    expect(sent<AttachStart>().last.uploadId, isNot(first.uploadId));
    await tester.tap(find.byKey(const ValueKey('attachment-remove')));
    await settle(tester);
    expect(find.byKey(const ValueKey('attachment-chip')), findsNothing);
  });

  testWidgets('a file over 20 MB is refused on the phone', (tester) async {
    await open(tester);
    await pick(tester, 'File', PickedFile(name: 'huge.mov', bytes: Uint8List(0), size: maxAttachmentBytes + 1));
    expect(find.text('Files up to 20 MB'), findsOneWidget);
    expect(sent<AttachStart>(), isEmpty);
  });
}
