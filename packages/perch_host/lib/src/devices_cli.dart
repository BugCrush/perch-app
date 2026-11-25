// `perch_host devices`: the machine's devices and pending requests to pair. A running host
// makes every change itself (it holds host.json in memory and tells the devices); with no
// host running the command edits host.json directly. Requests to pair exist only in a
// running host.
import 'dart:convert';

import 'package:perch_protocol/perch_protocol.dart';

import 'approval_dialog.dart' show routeText, shortDeviceId;
import 'host_state.dart';

const devicesUsage = 'perch_host devices [--port <port>]\n'
    '       perch_host devices allow <id> [--watch] | deny <id> | full <id> | watch <id> | rename <id> <name> | remove <id>';

/// Calls the running host's `/control` with [query]; null when no host answers.
typedef ControlCall = Future<({int status, String body})?> Function(String query);

String _ago(int? ms, DateTime now) {
  if (ms == null) return 'never';
  final d = now.difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// The table `perch_host devices` prints for `/control?action=devices` JSON.
List<String> devicesTable(Map<String, dynamic> j, {DateTime? now, bool live = true}) {
  final at = now ?? DateTime.now();
  final devices = (j['devices'] as List? ?? const []).whereType<Map>().toList();
  final pending = (j['pending'] as List? ?? const []).whereType<Map>().toList();
  final lines = <String>[];
  if (devices.isEmpty) {
    lines.add('No devices are allowed on this machine yet.');
  } else {
    final rows = [
      ['ID', 'NAME', 'PERMISSION', 'KEY', 'LAST SEEN', if (live) 'CONNECTED'],
      for (final d in devices)
        [
          '${d['id']}'.length > 8 ? '${d['id']}'.substring(0, 8) : '${d['id']}',
          '${d['name']}',
          d['permission'] == DevicePermissions.full ? 'full control' : 'watch only',
          d['keyed'] == true ? 'own key' : 'waiting',
          _ago(d['lastSeenAtMs'] is num ? (d['lastSeenAtMs'] as num).toInt() : null, at),
          if (live) d['connected'] == true ? 'yes' : 'no',
        ]
    ];
    final widths = [for (var i = 0; i < rows.first.length; i++) rows.map((r) => r[i].length).reduce((a, b) => a > b ? a : b)];
    for (final r in rows) {
      lines.add([for (var i = 0; i < r.length; i++) i == r.length - 1 ? r[i] : r[i].padRight(widths[i])].join('  '));
    }
    if (devices.any((d) => d['keyed'] != true)) {
      lines.add('Waiting: allowed; it uses its own key from its next connection.');
    }
  }
  if (pending.isNotEmpty) {
    lines.add('');
    lines.add('Waiting to pair:');
    for (final p in pending) {
      lines.add('  ${shortDeviceId('${p['id']}')}  "${p['name']}" ${routeText('${p['route']}')}  '
          '(perch_host devices allow ${shortDeviceId('${p['id']}')} [--watch] | deny ${shortDeviceId('${p['id']}')})');
    }
  }
  return lines;
}

/// Runs `perch_host devices …`; returns the exit code.
Future<int> runDevicesCommand(
  List<String> rest, {
  required bool watchFlag,
  required String stateDir,
  required ControlCall control,
  required void Function(String) out,
  required void Function(String) err,
}) async {
  final sub = rest.isEmpty ? 'list' : rest.first;
  final id = rest.length > 1 ? rest[1] : '';
  if (sub != 'list' && id.isEmpty) {
    err('Give the device id (or its first 4 characters).\nUsage: $devicesUsage');
    return 64;
  }
  final String query;
  switch (sub) {
    case 'list':
      query = 'action=devices';
    case 'allow':
      query = 'action=device-decide&id=${Uri.encodeQueryComponent(id)}&decision=${watchFlag ? 'watch' : 'full'}';
    case 'deny':
      query = 'action=device-decide&id=${Uri.encodeQueryComponent(id)}&decision=deny';
    case 'full' || 'watch':
      query = 'action=device-permission&id=${Uri.encodeQueryComponent(id)}&permission=$sub';
    case 'rename':
      final name = rest.skip(2).join(' ').trim();
      if (name.isEmpty) {
        err('Give the new name: perch_host devices rename <id> <name>');
        return 64;
      }
      query = 'action=device-rename&id=${Uri.encodeQueryComponent(id)}&name=${Uri.encodeQueryComponent(name)}';
    case 'remove':
      query = 'action=device-remove&id=${Uri.encodeQueryComponent(id)}';
    default:
      err('Usage: $devicesUsage');
      return 64;
  }
  final r = await control(query);
  if (r != null) {
    if (r.status != 200) {
      err(r.body.trim());
      return 1;
    }
    if (sub == 'list') {
      try {
        devicesTable((jsonDecode(r.body) as Map).cast<String, dynamic>()).forEach(out);
      } catch (_) {
        err('The running host answered something unexpected.');
        return 1;
      }
    } else {
      out(_done(sub, id, watchFlag));
    }
    return 0;
  }
  // No host running: host.json directly.
  final state = HostState.load(stateDir);
  try {
    switch (sub) {
      case 'list':
        devicesTable({
          'devices': [
            for (final d in state.devices)
              {...d.toJson()..remove('key'), 'connected': false}
          ],
        }, live: false)
            .forEach(out);
        out('(No Perch host is running: requests to pair show only while it runs.)');
        return 0;
      case 'allow' || 'deny':
        err('No Perch host is running: a device asks to pair only while the host runs. Start it, then try again.');
        return 1;
      case 'full' || 'watch':
        final d = state.findDevice(id) ?? (throw ArgumentError('No device with the id $id.'));
        state.setDevicePermission(d.id, sub);
      case 'rename':
        final d = state.findDevice(id) ?? (throw ArgumentError('No device with the id $id.'));
        state.renameDevice(d.id, rest.skip(2).join(' '));
      case 'remove':
        final d = state.findDevice(id) ?? (throw ArgumentError('No device with the id $id.'));
        state.removeDevice(d.id);
    }
  } on ArgumentError catch (e) {
    err('${e.message}');
    return 1;
  }
  out(_done(sub, id, watchFlag));
  return 0;
}

String _done(String sub, String id, bool watch) => switch (sub) {
      'allow' => 'Allowed $id (${watch ? 'watch only' : 'full control'}).',
      'deny' => 'Denied $id.',
      'full' => '$id now has full control.',
      'watch' => '$id can now only watch.',
      'rename' => 'Renamed $id.',
      'remove' => 'Removed $id: its key no longer works.',
      _ => 'Done.',
    };
