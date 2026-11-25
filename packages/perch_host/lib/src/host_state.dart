// The host's own state in `<state dir>/host.json`: its machine identity (machine id and
// pairing secret), the relay URL, whether any device has ever paired, the name and
// port of the last `serve` (so `perch_host pair` can print the same link), and the
// machine's own name if one was set with `perch_host name set`.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:perch_protocol/perch_protocol.dart';

import 'host_accounts.dart' show AccountsPersistence;
import 'limit_tracker.dart' show LimitStore;

/// The longest machine name `perch_host name set` accepts (the app's alias has the same limit).
const maxMachineNameLength = 40;

/// The name `serve` uses: `--name` for that run, else the one set with `perch_host name
/// set`, else the computer name.
String serveName(HostState state, {String? flag}) => flag ?? state.machineName ?? Platform.localHostname;

/// One device allowed on this machine (`devices` in host.json).
class DeviceRecord {
  final String id;
  String name;

  /// [DevicePermissions.full] or [DevicePermissions.watch].
  String permission;

  /// The device's own key (base64url). Records without one (the "legacy" devices of older
  /// apps) are dropped on load: keyless access was removed on 2026-11-19.
  String? key;

  /// The device has connected with [key] at least once: from then on the pairing secret no
  /// longer opens a connection for its id (before, it only hands the device its key).
  bool keyed;
  final int approvedAtMs;
  int? lastSeenAtMs;

  DeviceRecord({
    required this.id,
    required this.name,
    required this.permission,
    this.key,
    this.keyed = false,
    required this.approvedAtMs,
    this.lastSeenAtMs,
  });

  bool get full => permission == DevicePermissions.full;

  /// The key as bytes (null: legacy, or a broken entry).
  List<int>? get keyBytes {
    final k = key;
    if (k == null) return null;
    final b = base64UrlDecodeNoPad(k);
    return b != null && b.length == pairingSecretLength ? b : null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'permission': permission,
        'key': key,
        'keyed': keyed,
        'approvedAtMs': approvedAtMs,
        'lastSeenAtMs': lastSeenAtMs,
      };

  static DeviceRecord? tryFromJson(Object? v) {
    if (v is! Map) return null;
    final id = v['id'];
    if (id is! String || id.isEmpty) return null;
    final p = v['permission'];
    final key = v['key'];
    // No usable key: a legacy device of an older app. Keyless access was removed
    // (2026-11-19), so the record is dropped; the device asks to pair again with a new app.
    if (key is! String) return null;
    final bytes = base64UrlDecodeNoPad(key);
    if (bytes == null || bytes.length != pairingSecretLength) return null;
    return DeviceRecord(
      id: id,
      name: v['name'] is String ? v['name'] as String : '',
      // An unknown permission is the safe one.
      permission: p == DevicePermissions.full ? DevicePermissions.full : DevicePermissions.watch,
      key: key,
      keyed: v['keyed'] == true,
      approvedAtMs: v['approvedAtMs'] is num ? (v['approvedAtMs'] as num).toInt() : 0,
      lastSeenAtMs: v['lastSeenAtMs'] is num ? (v['lastSeenAtMs'] as num).toInt() : null,
    );
  }
}

class HostState implements LimitStore, AccountsPersistence {
  final String directory;

  /// True when this load created a new identity (first run, or a phase 1 state file).
  final bool createdNow;

  String machineId;
  Uint8List secret;
  String? relayUrl;

  /// The relay's invite code (a relay with invites refuses a machine's first contact
  /// without one). Never printed.
  String? relayInvite;
  bool everPaired;
  String? lastName;
  int? lastPort;

  /// The machine's own name (`perch_host name set`); null: the computer name.
  String? machineName;

  /// The owner's usage-limit choice and the machine's limit now (see limit_tracker.dart);
  /// kept by the running host, so a restart picks them up again.
  Map<String, dynamic>? usageLimits;

  /// The accounts (names, emails, dates; never tokens), the active one and which account
  /// each session Perch started runs on (see host_accounts.dart).
  Map<String, dynamic>? accounts;

  /// The model table synced from the phone (null: the starting table).
  ModelTable? modelTable;

  /// The owner's projects, synced from the phone like the model table (machine-agnostic:
  /// every host keeps the whole list; each keeps its own tasks).
  ProjectList projects;

  /// The devices allowed on this machine, oldest first.
  List<DeviceRecord> devices;

  /// The board's id and key (base64url, 32 bytes; as secret as the pairing secret: never
  /// printed) and the key's version (an encoded [Hlc]: the newest key wins everywhere).
  String? boardId;
  String? boardKey;
  String? boardKeyVersion;

  /// Boards left behind by a key rotation, still to be deleted from the relay.
  List<({String boardId, String key})> oldBoards = [];

  Uint8List? get boardKeyBytes {
    final k = boardKey;
    return k == null ? null : base64UrlDecodeNoPad(k);
  }

  /// Keeps the board key when it is newer than the one here (or there is none). True when
  /// it was taken. A malformed id, key or version is refused.
  bool takeBoardKey(String id, String key, String version) {
    final v = Hlc.parse(version);
    final bytes = base64UrlDecodeNoPad(key);
    if (v == null || bytes == null || bytes.length != pairingSecretLength || !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(id)) {
      return false;
    }
    final mine = boardKeyVersion == null ? null : Hlc.parse(boardKeyVersion!);
    if (mine != null && !(v > mine)) return false;
    final oldId = boardId, oldKey = boardKey;
    if (oldId != null && oldKey != null && oldId != id && !oldBoards.any((b) => b.boardId == oldId)) {
      oldBoards.add((boardId: oldId, key: oldKey));
    }
    oldBoards.removeWhere((b) => b.boardId == id);
    boardId = id;
    boardKey = key;
    boardKeyVersion = v.encode();
    save();
    return true;
  }

  /// A new board key (a device was removed and keeps the old one): the old board is kept in
  /// [oldBoards] until the relay copy is moved. Nothing when there is no board key yet.
  bool rotateBoardKey({DateTime? now}) {
    final cur = boardKeyVersion == null ? null : Hlc.parse(boardKeyVersion!);
    if (cur == null || boardKey == null) return false;
    final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final v = ms > cur.ms ? Hlc(ms, 0, machineId) : Hlc(cur.ms, cur.counter + 1, machineId);
    final k = newBoardKey();
    return takeBoardKey(k.boardId, base64UrlNoPad(k.key), v.encode());
  }

  /// The relay copy of [id] was deleted.
  void forgetOldBoard(String id) {
    final before = oldBoards.length;
    oldBoards.removeWhere((b) => b.boardId == id);
    if (oldBoards.length != before) save();
  }

  HostState._(this.directory, this.createdNow, this.machineId, this.secret, this.relayUrl, this.everPaired,
      this.lastName, this.lastPort, this.machineName, this.usageLimits, this.accounts, this.modelTable,
      [this.projects = const ProjectList(), List<DeviceRecord>? devices])
      : devices = devices ?? [];

  DeviceRecord? device(String id) => devices.where((d) => d.id == id).firstOrNull;

  /// The device whose id is [idOrPrefix] or starts with it (at least 4 characters). Null:
  /// none. Throws [ArgumentError] for a prefix that is too short or fits several devices.
  DeviceRecord? findDevice(String idOrPrefix) => pickByPrefix(devices, idOrPrefix, (d) => d.id);

  /// Allows device [id] (replacing any earlier record of it) with its own new key.
  DeviceRecord approveDevice(String id, {required String name, required String permission, int? nowMs}) {
    if (!DevicePermissions.all.contains(permission)) throw ArgumentError('Unknown permission: $permission');
    devices.removeWhere((d) => d.id == id);
    final d = DeviceRecord(
      id: id,
      name: _deviceName(name),
      permission: permission,
      key: newDeviceKey(),
      approvedAtMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
    );
    devices.add(d);
    save();
    return d;
  }

  /// The device connected with its own key: the pairing secret no longer works for it.
  void confirmKey(String id) {
    final d = device(id);
    if (d == null || d.key == null || d.keyed) return;
    d.keyed = true;
    save();
  }

  void deviceSeen(String id, int atMs) {
    final d = device(id);
    if (d == null) return;
    d.lastSeenAtMs = atMs;
    save();
  }

  void renameDevice(String id, String name) {
    final d = device(id) ?? (throw ArgumentError('No such device: $id'));
    final n = name.trim();
    if (n.isEmpty) throw ArgumentError('The device name cannot be empty.');
    if (n.length > maxDeviceNameLength) {
      throw ArgumentError('The device name can have at most $maxDeviceNameLength characters.');
    }
    d.name = n;
    save();
  }

  void setDevicePermission(String id, String permission) {
    if (!DevicePermissions.all.contains(permission)) throw ArgumentError('Unknown permission: $permission');
    final d = device(id) ?? (throw ArgumentError('No such device: $id'));
    d.permission = permission;
    save();
  }

  /// Removes device [id]; returns its record (null: there was none).
  /// Removes a device; the board key is rotated (the device keeps the key it had).
  DeviceRecord? removeDevice(String id) {
    final d = device(id);
    if (d == null) return null;
    devices.remove(d);
    save();
    rotateBoardKey();
    return d;
  }

  static String _deviceName(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'Device';
    return n.length > maxDeviceNameLength ? n.substring(0, maxDeviceNameLength) : n;
  }

  /// Keeps [list] when it is at least as new as the one here; returns the list in use.
  ProjectList syncProjects(ProjectList list) {
    if (list.updatedAtMs < projects.updatedAtMs) return projects;
    projects = list;
    save();
    return list;
  }

  /// The model table sessions started from tasks use.
  ModelTable get models => modelTable ?? ModelTable.starting;

  /// Keeps [table] when it is at least as new as the one here; returns the table in use.
  ModelTable syncModelTable(ModelTable table) {
    if (table.updatedAtMs < models.updatedAtMs) return models;
    modelTable = table;
    save();
    return table;
  }

  @override
  Map<String, dynamic>? loadAccounts() => accounts;

  @override
  void saveAccounts(Map<String, dynamic> json) {
    accounts = json;
    save();
  }

  @override
  Map<String, dynamic>? loadLimits() => usageLimits;

  @override
  void saveLimits(Map<String, dynamic> json) {
    usageLimits = json;
    save();
  }

  File get _file => File('$directory${Platform.pathSeparator}host.json');

  /// Where `perch_host pair` writes the QR code as a picture.
  String get pngPath => '$directory${Platform.pathSeparator}pair.png';

  static Uint8List _newSecret() => randomBytes(pairingSecretLength);
  static String _newMachineId() => base64UrlNoPad(randomBytes(16));

  /// Loads the state; creates an identity when there is none.
  /// [environment] (default: the process's) gives a new host its relay: [defaultRelayUrl].
  static HostState load(String directory, {Map<String, String>? environment}) {
    final file = File('$directory${Platform.pathSeparator}host.json');
    Map<String, dynamic> j = const {};
    try {
      if (file.existsSync()) {
        final v = jsonDecode(file.readAsStringSync());
        if (v is Map) j = v.cast<String, dynamic>();
      }
    } catch (_) {}
    final id = j['machineId'];
    final secret = j['secret'] is String ? base64UrlDecodeNoPad(j['secret'] as String) : null;
    final valid = id is String && id.isNotEmpty && secret != null && secret.length == pairingSecretLength;
    final relay = j['relayUrl'];
    final s = HostState._(
      directory,
      !valid,
      valid ? id : _newMachineId(),
      valid ? secret : _newSecret(),
      relay is String && PairingLink.validRelayUrl(relay)
          ? relay
          : !valid && !j.containsKey('relayUrl')
              ? defaultRelayUrl(environment ?? Platform.environment)
              : null,
      valid && j['everPaired'] == true,
      j['lastName'] is String ? j['lastName'] as String : null,
      j['lastPort'] is int ? j['lastPort'] as int : null,
      j['machineName'] is String && (j['machineName'] as String).trim().isNotEmpty
          ? (j['machineName'] as String).trim()
          : null,
      j['usageLimits'] is Map ? (j['usageLimits'] as Map).cast<String, dynamic>() : null,
      j['accounts'] is Map ? (j['accounts'] as Map).cast<String, dynamic>() : null,
      ModelTable.tryFromJson(j['modelTable']),
      ProjectList.tryFromJson(j['projects']) ?? const ProjectList(),
      valid
          ? [for (final d in (j['devices'] is List ? j['devices'] as List : const [])) ?DeviceRecord.tryFromJson(d)]
          : null,
    );
    if (valid) {
      final bk = j['board'];
      if (bk is Map && bk['id'] is String && bk['key'] is String && bk['version'] is String) {
        s
          ..boardId = bk['id'] as String
          ..boardKey = bk['key'] as String
          ..boardKeyVersion = bk['version'] as String;
      }
      s.oldBoards = [
        for (final o in (j['oldBoards'] is List ? j['oldBoards'] as List : const []))
          if (o is Map && o['id'] is String && o['key'] is String) (boardId: o['id'] as String, key: o['key'] as String)
      ];
      final invite = j['relayInvite'];
      if (invite is String && invite.trim().isNotEmpty) s.relayInvite = invite.trim();
    }
    if (!valid) s.save();
    return s;
  }

  void save() {
    Directory(directory).createSync(recursive: true);
    _file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'machineId': machineId,
      'secret': base64UrlNoPad(secret),
      'relayUrl': relayUrl,
      if (relayInvite != null) 'relayInvite': relayInvite,
      'everPaired': everPaired,
      'lastName': lastName,
      'lastPort': lastPort,
      'machineName': machineName,
      if (usageLimits != null) 'usageLimits': usageLimits,
      if (accounts != null) 'accounts': accounts,
      if (modelTable != null) 'modelTable': modelTable!.toJson(),
      if (projects.updatedAtMs > 0 || projects.projects.isNotEmpty) 'projects': projects.toJson(),
      'devices': [for (final d in devices) d.toJson()],
      if (boardId != null && boardKey != null && boardKeyVersion != null)
        'board': {'id': boardId, 'key': boardKey, 'version': boardKeyVersion},
      if (oldBoards.isNotEmpty) 'oldBoards': [for (final o in oldBoards) {'id': o.boardId, 'key': o.key}],
    }));
  }

  /// Sets (or with null, clears) the machine's own name. Throws [ArgumentError] for an
  /// empty name or one longer than [maxMachineNameLength].
  void setMachineName(String? name) {
    if (name != null) {
      final n = name.trim();
      if (n.isEmpty) throw ArgumentError('The machine name cannot be empty.');
      if (n.length > maxMachineNameLength) {
        throw ArgumentError('The machine name can have at most $maxMachineNameLength characters.');
      }
      machineName = n;
    } else {
      machineName = null;
    }
    save();
  }

  /// Every paired device must scan again (and is forgotten): a new secret, and a new machine id so the relay
  /// (which trusts the first tokens it saw for an id) starts fresh too.
  void forgetDevices() {
    secret = _newSecret();
    machineId = _newMachineId();
    everPaired = false;
    devices = [];
    save();
    rotateBoardKey(); // every device is forgotten: none keeps a working board key
    try {
      File(pngPath).deleteSync();
    } catch (_) {}
  }

  /// Sets (or with null, clears) the relay URL. Throws [ArgumentError] for a bad URL.
  void setRelay(String? url) {
    if (url != null) {
      var u = url.trim();
      while (u.endsWith('/')) {
        u = u.substring(0, u.length - 1);
      }
      if (!PairingLink.validRelayUrl(u)) throw ArgumentError('Not a relay URL: $url');
      relayUrl = u;
    } else {
      relayUrl = null;
    }
    save();
  }

  /// Sets (or with null or blank, clears) the relay's invite code.
  void setRelayInvite(String? code) {
    final c = code?.trim().replaceAll(RegExp(r'\s+'), '');
    relayInvite = c == null || c.isEmpty ? null : c;
    save();
  }

  void markPaired() {
    if (everPaired) return;
    everPaired = true;
    save();
  }

  void rememberServe({required String name, required int port}) {
    lastName = name;
    lastPort = port;
    save();
  }

  String get hostToken => relayHostToken(secret);
  String get deviceToken => relayDeviceToken(secret);

  PairingLink link({required String name, required List<String> lan}) =>
      PairingLink(name: name, machineId: machineId, secret: secret, relayUrl: relayUrl, lan: lan);
}

/// The item whose id is [idOrPrefix] or starts with it (at least 4 characters). Null: none.
/// Throws [ArgumentError] for a prefix that is too short or fits several items.
T? pickByPrefix<T>(Iterable<T> items, String idOrPrefix, String Function(T) idOf) {
  final p = idOrPrefix.trim();
  final exact = items.where((i) => idOf(i) == p).firstOrNull;
  if (exact != null) return exact;
  if (p.length < 4) throw ArgumentError('Give at least 4 characters of the device id.');
  final hits = items.where((i) => idOf(i).startsWith(p)).toList();
  if (hits.length > 1) throw ArgumentError('More than one device starts with "$p": give more of its id.');
  return hits.firstOrNull;
}

/// The relay a release build names, set when it is compiled
/// (`dart compile exe -DPERCH_DEFAULT_RELAY=<url>`; the release workflow takes it from the
/// repository variable PERCH_DEFAULT_RELAY). Empty: none.
const builtInRelayUrl = String.fromEnvironment('PERCH_DEFAULT_RELAY');

/// The relay a NEW host starts with: `PERCH_RELAY_URL`, else [builtInRelayUrl], else none
/// (the phone then connects on the local network only, until `perch_host relay set`). A
/// host that exists keeps what it has, and `relay clear` stays cleared.
String? defaultRelayUrl(Map<String, String> env) {
  for (final u in [env['PERCH_RELAY_URL'], builtInRelayUrl]) {
    var v = (u ?? '').trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    if (v.isNotEmpty && PairingLink.validRelayUrl(v)) return v;
  }
  return null;
}
