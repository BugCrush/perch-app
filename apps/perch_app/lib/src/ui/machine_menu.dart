// A machine's menu (press and hold its row or title, or its dots), the machine rename
// sheet, and the kill switch.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/host_connection.dart';
import '../connection/machine_store.dart';
import '../state/providers.dart';
import 'add_machine_screen.dart';
import 'compatibility.dart';
import 'devices_screen.dart';
import 'glass/dots.dart';
import 'glass/mosaic.dart';
import 'glass/widgets.dart';
import 'labels.dart';
import 'glass/click.dart';

/// What the machine menu offers, in order. [control] false (a watch-only device): nothing
/// that acts on the machine; [online]: the device list can be opened (full control only).
List<(String, IconData)> machineMenuItems({bool control = true, bool online = false}) => [
      ('Rename…', Icons.edit_rounded),
      ('Reconnect', Icons.sync_rounded),
      ('Claude Code checks', Icons.fact_check_outlined),
      if (control && online) ('Devices…', Icons.devices_rounded),
      if (control) ('Stop all sessions…', Icons.stop_circle_outlined),
      ('Pair again', Icons.qr_code_scanner_rounded),
      ('Remove machine…', Icons.delete_outline_rounded),
    ];

/// Opens [connection]'s machine menu over [context] (a screen) and carries out the choice.
Future<void> showMachineMenu(BuildContext context, HostConnection connection) async {
  final working = connection.sessions.value.where((s) => s.live && s.state == SessionState.working).length;
  final online = connection.link.value == LinkState.online;
  final choice = await showGlassSheet<String>(
    context,
    barrier: const Color(0x66000000),
    (ctx) => GlassSheet(children: [
      menuHeader(
        seedOf(connection.machine.id),
        machineTitle(connection),
        Row(children: [
          if (working > 0) ...[const WorkingWave(width: 26, height: 12, bars: 6), const SizedBox(width: 7)],
          Flexible(
            child: Text(
              [
                online && connection.route.value != null ? routeLabel(connection.route.value!) : linkLabel(connection.link.value),
                if (connection.compatibility.value?.claudeVersion case final v?) 'Claude Code $v',
              ].join(' · '),
              style: gSans(13, FontWeight.w500, color: G.muted),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      for (final (label, icon) in machineMenuItems(control: connection.canControl, online: online))
        MenuRow(
          label: label,
          icon: icon,
          danger: label == 'Remove machine…' || label == 'Stop all sessions…',
          onTap: () => Navigator.of(ctx).pop(label),
        ),
    ]),
  );
  if (choice == null || !context.mounted) return;
  final machines = ProviderScope.containerOf(context, listen: false).read(machinesProvider.notifier);
  final id = connection.machine.id;
  switch (choice) {
    case 'Rename…':
      final r = await showMachineRenameSheet(context,
          current: machineTitle(connection), own: connection.ownName, hasAlias: connection.machine.alias != null);
      if (r != null) await machines.rename(id, r.alias);
    case 'Reconnect':
      connection.connect();
      say(context, 'Reconnecting to ${machineTitle(connection)}…');
    case 'Claude Code checks':
      await openCompatibility(context, connection);
    case 'Devices…':
      await openDevices(context, connection);
    case 'Stop all sessions…':
      await stopAll(context, [connection]);
    case 'Pair again':
      await openAddMachine(context, replacing: id);
    case 'Remove machine…':
      if (await confirmDanger(context,
          title: 'Remove ${machineTitle(connection)} from this phone?',
          lost: 'This phone forgets the machine and its pairing: its sessions, tasks and notifications are gone from '
              'this phone until you scan its QR code again. Nothing on the machine itself is deleted.',
          yes: 'Remove machine')) {
        await machines.remove(id);
      }
  }
}

/// Asks `Stop all N sessions on <machine>?`; true when confirmed.
Future<bool> confirmStopAll(BuildContext context, {required int count, required String where}) => confirmDanger(context,
    title: 'Stop all $count sessions on $where?',
    lost: 'Claude is cut off mid-step in every one of them: whatever each is doing now is left unfinished '
        '(half-written files, commands stopped part way). The conversations are kept.',
    yes: 'Stop all',
    hold: true);

/// The kill switch: stops every session on the given machines (those connected) after a
/// confirmation.
Future<void> stopAll(BuildContext context, List<HostConnection> connections) async {
  final online = connections.where((c) => c.link.value == LinkState.online && c.canControl).toList();
  if (online.isEmpty) {
    say(context, connections.length == 1 ? '${machineTitle(connections.single)} is not connected.' : 'No machine is connected.');
    return;
  }
  final count = online.fold<int>(0, (n, c) => n + activeSessions(c));
  final where = online.length == 1 ? machineTitle(online.single) : 'all machines';
  if (!await confirmStopAll(context, count: count, where: where)) return;
  for (final c in online) {
    c.killAll();
  }
}

/// The kill switch as a pill.
class StopAllButton extends StatelessWidget {
  final List<HostConnection> connections;
  const StopAllButton({super.key, required this.connections});
  @override
  Widget build(BuildContext context) => DangerButton(
        key: const ValueKey('stop-all'),
        label: 'Stop all sessions',
        icon: Icons.stop_circle_rounded,
        onTap: connections.isEmpty ? null : () => stopAll(context, connections),
      );
}

/// What the rename sheet decided: [alias] null means the machine's own name again.
class RenameResult {
  final String? alias;
  const RenameResult(this.alias);
}

/// Asks for this device's name for a machine, prefilled with [current]. Null: cancelled.
Future<RenameResult?> showMachineRenameSheet(BuildContext context,
        {required String current, required String own, required bool hasAlias}) =>
    showGlassSheet<RenameResult>(context, (_) => _RenameSheet(current: current, own: own, hasAlias: hasAlias));

class _RenameSheet extends StatefulWidget {
  final String current;
  final String own;
  final bool hasAlias;
  const _RenameSheet({required this.current, required this.own, required this.hasAlias});
  @override
  State<_RenameSheet> createState() => _RenameSheetState();
}

class _RenameSheetState extends State<_RenameSheet> {
  late final TextEditingController _text = TextEditingController(text: widget.current);
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final error = aliasError(_text.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(RenameResult(_text.text.trim()));
  }

  @override
  Widget build(BuildContext context) => GlassSheet(children: [
        ...sheetTitle('Rename machine', 'The name on this phone. ${widget.own} keeps its own name.'),
        const SizedBox(height: 14),
        GlassField(
          controller: _text,
          label: 'Name on this device',
          autofocus: true,
          maxLength: maxAliasLength,
          error: _error,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _save(),
        ),
        if (_error == null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 6),
            child: Text('Up to $maxAliasLength characters', style: gSans(12, FontWeight.w500, color: G.muted)),
          ),
        if (widget.hasAlias)
          Align(
            alignment: Alignment.centerLeft,
            child: ClickDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).pop(const RenameResult(null)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                child: Text("Use the machine's own name", style: gSans(14, FontWeight.w700, color: G.glow)),
              ),
            ),
          ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: GlassButton(label: 'Cancel', onTap: () => Navigator.of(context).pop())),
          const SizedBox(width: 10),
          Expanded(child: GlassButton(label: 'Save', warm: true, onTap: _save)),
        ]),
      ]);
}
