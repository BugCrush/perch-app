import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:perch_app/src/connection/machine_store.dart';
import 'package:perch_app/src/push/push_notes.dart';
import 'package:perch_app/src/push/push_registrar.dart';
import 'package:perch_app/src/state/session_prefs.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

class FakeSink implements NotificationSink {
  final shown = <({int id, String title, String body, String payload})>[];
  final buttons = <List<PushButton>>[];
  final cancelled = <int>[];
  @override
  Future<void> show(
      {required int id,
      required String title,
      required String body,
      required String payload,
      List<PushButton> buttons = const []}) async {
    shown.add((id: id, title: title, body: body, payload: payload));
    this.buttons.add(buttons);
  }
  @override
  Future<void> cancel(int id) async => cancelled.add(id);
}

void main() {
  final desk = testMachine(id: 'mid-desk', label: 'Desk', relayUrl: 'https://relay.example');
  final laptop = testMachine(id: 'mid-laptop', label: 'Laptop', secret: List.filled(32, 7));

  String sealed(Machine m, PushNote note) => sealPush(m.secretBytes!, m.id, note);

  group('incoming push', () {
    test('opens with the machine it names and shows one notification per session', () async {
      final sink = FakeSink();
      const note = PushNote(
          title: 'Desk',
          body: 'Fix login: asked a question',
          machineId: 'mid-desk',
          sessionId: 's1',
          kind: PushKinds.question,
          promptId: 'toolu_1');
      final got = await handlePushData({'m': 'mid-desk', 'p': sealed(desk, note), 'w': '0'}, [laptop, desk], sink);
      expect(got?.body, 'Fix login: asked a question');
      expect(sink.shown.single.title, 'Desk');
      expect(sink.shown.single.body, 'Fix login: asked a question');
      expect(sink.shown.single.id, notificationIdFor('mid-desk', 's1'));
      expect(PushTap.decode(sink.shown.single.payload),
          const PushTap(machineId: 'mid-desk', sessionId: 's1', promptId: 'toolu_1'));

      // A newer one for the same session replaces it (same id).
      await handlePushData(
          {'m': 'mid-desk', 'p': sealed(desk, const PushNote(title: 'Desk', body: 'Fix login: finished', machineId: 'mid-desk', sessionId: 's1', kind: PushKinds.finished))},
          [desk],
          sink);
      expect(sink.shown.map((s) => s.id).toSet(), {notificationIdFor('mid-desk', 's1')});
    });

    test('a notification sealed with this device\'s own key opens; so does one sealed with the pairing secret', () async {
      final key = List.generate(32, (i) => (i * 5 + 3) & 0xff);
      final keyed = desk.copyWith(deviceKey: base64UrlNoPad(key));
      final sink = FakeSink();
      const note = PushNote(
          title: 'Desk', body: 'Fix login: finished', machineId: 'mid-desk', sessionId: 's1', kind: PushKinds.finished);
      expect(await handlePushData({'m': 'mid-desk', 'p': sealPush(key, 'mid-desk', note)}, [keyed], sink), isNotNull);
      expect(await handlePushData({'m': 'mid-desk', 'p': sealed(desk, note)}, [keyed], sink), isNotNull);
      expect(await handlePushData({'m': 'mid-desk', 'p': sealPush(key, 'mid-desk', note)}, [desk], sink), isNull,
          reason: 'without the key it cannot be read');
      expect(sink.shown, hasLength(2));
    });

    test('the title is this device\'s alias for the machine, else the host\'s name', () async {
      final sink = FakeSink();
      const note = PushNote(
          title: 'Desk', body: 'Fix login: finished', machineId: 'mid-desk', sessionId: 's1', kind: PushKinds.finished);
      final renamed = desk.copyWith(alias: 'Big rig');
      await handlePushData({'m': 'mid-desk', 'p': sealed(desk, note)}, [renamed], sink);
      expect(sink.shown.last.title, 'Big rig');
      await handlePushData({'m': 'mid-desk', 'p': sealed(desk, note)}, [desk], sink);
      expect(sink.shown.last.title, 'Desk');
      // A note without a title: the saved own name.
      const untitled =
          PushNote(body: 'Fix login: finished', machineId: 'mid-desk', sessionId: 's1', kind: PushKinds.finished);
      await handlePushData({'m': 'mid-desk', 'p': sealed(desk, untitled)}, [desk], sink);
      expect(sink.shown.last.title, 'Desk');
    });

    test('the background handler reads the alias saved by the app', () async {
      SharedPreferences.setMockInitialValues({});
      await MachineStore().save(desk.copyWith(alias: 'Big rig'));
      final sink = FakeSink();
      const note = PushNote(
          title: 'Desk', body: 'Fix login: finished', machineId: 'mid-desk', sessionId: 's1', kind: PushKinds.finished);
      await showPushFromStore({'m': 'mid-desk', 'p': sealed(desk, note)}, sink);
      expect(sink.shown.single.title, 'Big rig');
    });

    test('a session muted on this phone shows nothing, also in the background handler; withdrawals still go', () async {
      SharedPreferences.setMockInitialValues({});
      await MachineStore().save(desk);
      final prefs = SessionPrefs();
      await prefs.mute('mid-desk', 's1');
      final sink = FakeSink();
      const note = PushNote(
          title: 'Desk', body: 'Fix login: finished', machineId: 'mid-desk', sessionId: 's1', kind: PushKinds.finished);
      expect(await showPushFromStore({'m': 'mid-desk', 'p': sealed(desk, note)}, sink), isNull);
      expect(sink.shown, isEmpty);
      // Another session, and the same session id on another machine, are not muted.
      const other = PushNote(
          title: 'Desk', body: 'Docs: finished', machineId: 'mid-desk', sessionId: 's2', kind: PushKinds.finished);
      await showPushFromStore({'m': 'mid-desk', 'p': sealed(desk, other)}, sink);
      expect(sink.shown.single.body, 'Docs: finished');
      const w = PushNote(machineId: 'mid-desk', sessionId: 's1', kind: PushKinds.withdraw);
      await showPushFromStore({'m': 'mid-desk', 'p': sealed(desk, w)}, sink);
      expect(sink.cancelled, [notificationIdFor('mid-desk', 's1')]);

      await prefs.unmute('mid-desk', 's1');
      await showPushFromStore({'m': 'mid-desk', 'p': sealed(desk, note)}, sink);
      expect(sink.shown.last.body, 'Fix login: finished');
    });

    test('a withdraw cancels that session\'s notification', () async {
      final sink = FakeSink();
      const w = PushNote(machineId: 'mid-desk', sessionId: 's1', kind: PushKinds.withdraw);
      await handlePushData({'m': 'mid-desk', 'p': sealed(desk, w), 'w': '1'}, [desk], sink);
      expect(sink.cancelled, [notificationIdFor('mid-desk', 's1')]);
      expect(sink.shown, isEmpty);
    });

    test('a payload that does not open is dropped silently', () async {
      final sink = FakeSink();
      const note = PushNote(title: 'x', body: 'y', machineId: 'mid-desk', sessionId: 's1', kind: PushKinds.question);
      // Sealed with another machine's secret, for an unknown machine, garbage, missing fields.
      expect(await handlePushData({'m': 'mid-desk', 'p': sealed(laptop, note)}, [desk], sink), isNull);
      expect(await handlePushData({'m': 'mid-other', 'p': sealed(desk, note)}, [desk], sink), isNull);
      expect(await handlePushData({'m': 'mid-desk', 'p': 'Zm9v'}, [desk], sink), isNull);
      expect(await handlePushData({'p': sealed(desk, note)}, [desk], sink), isNull);
      // The relay's flag alone cannot withdraw anything.
      expect((await handlePushData({'m': 'mid-desk', 'p': sealed(desk, note), 'w': '1'}, [desk], sink))?.kind,
          PushKinds.question);
      expect(sink.cancelled, isEmpty);
      expect(sink.shown, hasLength(1));
    });

    test('notification ids differ by machine and session and fit in 31 bits', () {
      final ids = {
        notificationIdFor('a', 's1'),
        notificationIdFor('a', 's2'),
        notificationIdFor('b', 's1'),
      };
      expect(ids, hasLength(3));
      for (final id in ids) {
        expect(id, inInclusiveRange(0, 0x7fffffff));
      }
      expect(notificationIdFor('a', 's1'), notificationIdFor('a', 's1'));
      expect(PushTap.decode('nonsense'), isNull);
      expect(PushTap.decode(null), isNull);
    });
  });

  group('push token registration', () {
    test('posts the token to each machine with a relay, with the device token, once', () async {
      final calls = <({Uri uri, Map<String, String> headers, String body})>[];
      final r = PushRegistrar(
          deviceId: 'dev-7',
          post: (uri, headers, body) async {
            calls.add((uri: uri, headers: headers, body: body));
            return 200;
          });
      await r.sync([desk, laptop], 'fcm-token-1');
      expect(calls, hasLength(1), reason: 'the laptop has no relay');
      expect(calls.single.uri.toString(), 'https://relay.example/m/mid-desk/devices/dev-7/push-token');
      expect(calls.single.headers['Authorization'], 'Bearer ${relayDeviceToken(desk.secretBytes!)}');
      expect(jsonDecode(calls.single.body), {'token': 'fcm-token-1'});

      await r.sync([desk], 'fcm-token-1');
      expect(calls, hasLength(1));
      await r.sync([desk], 'fcm-token-2');
      expect(calls, hasLength(2));

      await r.unregister(desk);
      expect(jsonDecode(calls.last.body), {'token': null});
    });

    test('a failed registration is tried again next time', () async {
      var status = 503;
      var n = 0;
      final r = PushRegistrar(
          deviceId: 'dev-7',
          post: (uri, headers, body) async {
            n++;
            return status;
          });
      expect(await r.register(desk, 't'), isFalse);
      status = 200;
      expect(await r.register(desk, 't'), isTrue);
      expect(await r.register(desk, 't'), isTrue);
      expect(n, 2);
    });
  });
}
