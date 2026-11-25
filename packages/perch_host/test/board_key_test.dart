// The board key on the host (docs/superpowers/plans/2026-11-24-projects-first-board.md,
// Task 11): a full device gives it to the host, which keeps the newest one and hands it to
// the other devices; a newly allowed device gets it right after its own key; removing a
// device rotates it; the key never shows in console lines or the device list.
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_board.dart';
import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/task_board.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'server_board_sync_test.dart' show Device;
import 'server_test.dart' show TestClient;

final sep = Platform.pathSeparator;

void main() {
  late Directory tmp;
  late HostState state;
  late SessionManager manager;
  late TaskBoard board;
  late PerchServer server;
  late int port;
  final notices = <String>[];
  final clients = <TestClient>[];

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_board_key_');
    state = HostState.load('${tmp.path}${sep}state');
    manager = SessionManager(launcher: fakeLauncher(), external: FakeExternalSessions());
    board = TaskBoard(
        board: HostBoard(stateDir: state.directory, machineId: state.machineId, remoteOf: (_) => null),
        sessions: ManagerTaskSessions(manager))
      ..start();
    server = PerchServer(
        manager: manager,
        state: state,
        machineName: 'Desk',
        bindAddress: '127.0.0.1',
        port: 0,
        board: board,
        pollInterval: const Duration(minutes: 10),
        relayPoster: (uri, headers, body) async => (status: 200, body: '{}'));
    port = await server.start();
    notices.clear();
    server.deviceNotices.listen(notices.add);
  });

  tearDown(() async {
    for (final c in clients) {
      await c.close();
    }
    clients.clear();
    await server.close();
    await board.dispose();
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Device> device({String permission = DevicePermissions.full}) async {
    final d = Device(server, state, permission: permission);
    await d.hello();
    return d;
  }

  String version(int ms) => Hlc(ms, 0, 'phone').encode();

  test('a_full_device_gives_the_host_the_key_and_it_is_kept', () async {
    final a = await device();
    final b = await device();
    final k = newBoardKey();
    final fromB = b.received.length;
    a.send(BoardKeyFromApp(boardId: k.boardId, key: base64UrlNoPad(k.key), keyVersion: version(100)));
    final got = await b.next<BoardKeyFromHost>(from: fromB);
    expect(got.boardId, k.boardId);
    expect(base64UrlDecodeNoPad(got.key), k.key);
    expect(state.boardId, k.boardId);
    expect(HostState.load(state.directory).boardKeyBytes, k.key, reason: 'kept in host.json');
    // A device that sends a summary later gets it too.
    final c = await device();
    c.send(const BoardSummaryFromApp(summary: {}));
    expect((await c.next<BoardKeyFromHost>()).boardId, k.boardId);
    // A watch-only device neither gets it nor may set it.
    final w = await device(permission: DevicePermissions.watch);
    w.send(const BoardSummaryFromApp(summary: {}));
    await w.next<BoardRecordsFromHost>();
    final other = newBoardKey();
    w.send(BoardKeyFromApp(boardId: other.boardId, key: base64UrlNoPad(other.key), keyVersion: version(999)));
    expect((await w.next<ErrorMessage>()).code, ErrorCodes.watchOnly);
    expect(w.received.whereType<BoardKeyFromHost>(), isEmpty);
    expect(state.boardId, k.boardId);
  });

  test('an_older_key_never_replaces_a_newer_one', () async {
    final a = await device();
    final newer = newBoardKey(), older = newBoardKey();
    a.send(BoardKeyFromApp(boardId: newer.boardId, key: base64UrlNoPad(newer.key), keyVersion: version(500)));
    await waitUntil(() => state.boardId == newer.boardId);
    final b = await device();
    final from = b.received.length;
    b.send(BoardKeyFromApp(boardId: older.boardId, key: base64UrlNoPad(older.key), keyVersion: version(400)));
    // The device with the older key is told the newer one.
    final told = await b.next<BoardKeyFromHost>(from: from);
    expect(told.boardId, newer.boardId);
    expect(state.boardId, newer.boardId);
    // Broken keys are refused.
    b.send(BoardKeyFromApp(boardId: 'short', key: 'abc', keyVersion: version(900)));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(state.boardId, newer.boardId);
  });

  test('a_newly_allowed_device_gets_the_key_after_its_device_key', () async {
    final k = newBoardKey();
    state.takeBoardKey(k.boardId, base64UrlNoPad(k.key), version(10));
    final c = await TestClient.connect(port, state, deviceId: 'dev-new', secret: state.secret);
    clients.add(c);
    c.send(const Hello(deviceName: 'Pixel', pairing: 2));
    await c.next<PairingPending>();
    await server.decideDevice('dev-new', DeviceDecisions.full);
    await c.next<BoardKeyFromHost>();
    final kinds = [for (final m in c.received) if (m is DeviceKey || m is BoardKeyFromHost || m is Welcome) m.runtimeType];
    expect(kinds.take(3), [DeviceKey, BoardKeyFromHost, Welcome]);
    expect(c.received.whereType<BoardKeyFromHost>().first.boardId, k.boardId);
  });

  test('removing_a_device_rotates_the_key_and_tells_the_others', () async {
    final k = newBoardKey();
    state.takeBoardKey(k.boardId, base64UrlNoPad(k.key), version(10));
    final stays = await device();
    final goes = await device();
    final from = stays.received.length;
    server.removeDevice(goes.id);
    final rotated = await stays.next<BoardKeyFromHost>(from: from);
    expect(rotated.boardId, isNot(k.boardId));
    expect(base64UrlDecodeNoPad(rotated.key), isNot(k.key));
    expect(Hlc.parse(rotated.keyVersion)! > Hlc.parse(version(10))!, isTrue);
    expect(state.boardId, rotated.boardId);
    expect(goes.received.whereType<BoardKeyFromHost>().where((m) => m.boardId == rotated.boardId), isEmpty);
    // The old board is remembered for deleting from the relay.
    expect(state.oldBoards.map((b) => b.boardId), [k.boardId]);
    expect(HostState.load(state.directory).oldBoards.single.boardId, k.boardId);
    state.forgetOldBoard(k.boardId);
    expect(HostState.load(state.directory).oldBoards, isEmpty);
  });

  test('removing_a_device_with_no_host_running_rotates_in_host_json', () {
    final k = newBoardKey();
    final s = HostState.load('${tmp.path}${sep}other');
    s.takeBoardKey(k.boardId, base64UrlNoPad(k.key), version(10));
    s.approveDevice('dev-x', name: 'X', permission: DevicePermissions.full);
    s.removeDevice('dev-x');
    final again = HostState.load(s.directory);
    expect(again.boardId, isNot(k.boardId));
    expect(again.oldBoards.single.boardId, k.boardId);
  });

  test('the_key_never_appears_in_console_lines_or_devices_output', () async {
    final a = await device();
    final k = newBoardKey();
    final keyText = base64UrlNoPad(k.key);
    a.send(BoardKeyFromApp(boardId: k.boardId, key: keyText, keyVersion: version(100)));
    await waitUntil(() => state.boardId == k.boardId);
    final b = await device();
    server.removeDevice(b.id);
    a.send(const ListDevices());
    final list = await a.next<DevicesMessage>(where: (m) => m.devices.length == 1);
    final everything = [...notices, jsonEncode(list.toJson()), ...a.received.whereType<DevicesMessage>().map((m) => jsonEncode(m.toJson()))].join('\n');
    expect(everything, isNot(contains(keyText)));
    expect(everything, isNot(contains(state.boardKey!)));
    expect(everything, isNot(contains(k.boardId)));
  });
}
