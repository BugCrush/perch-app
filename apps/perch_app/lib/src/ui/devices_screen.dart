// A machine's devices (machine menu, Devices…; full-control devices only): requests to
// pair waiting on top with Allow / Watch only / Deny, then every allowed device with its
// permission, when it was last seen, and Rename… / change permission / Remove….
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/host_connection.dart';
import 'app_theme.dart' show openGlass;
import 'board_logic.dart' show agoLabel;
import 'glass/mosaic.dart';
import 'glass/widgets.dart';
import 'labels.dart';

Future<void> openDevices(BuildContext context, HostConnection connection) {
  connection.listDevices();
  return openGlass<void>(context, DevicesScreen(connection: connection));
}

/// How a request reached the machine, in words.
String pendingRoute(String route) => route == 'relay' ? 'Over the relay' : 'From $route';

/// The short code the machine shows for a device (the first 4 characters of its id).
String shortDeviceCode(String id) => id.length <= 4 ? id : id.substring(0, 4);

class DevicesScreen extends StatelessWidget {
  final HostConnection connection;
  const DevicesScreen({super.key, required this.connection});

  @override
  Widget build(BuildContext context) {
    final c = connection;
    return ListenableBuilder(
      listenable: Listenable.merge([c.devices, c.displayName, c.link, c.permission]),
      builder: (context, _) {
        final list = c.devices.value;
        final machine = machineTitle(c);
        return GlassScaffold(
          background: MosaicBackdrop(seed: seedOf(c.machine.id), fade: G.deep, fadeFrom: 0.18, pixel: 0.5, flap: true),
          child: ListView(
            padding: screenPadding(context),
            children: [
              Row(children: [
                GlassOrb(
                    key: const ValueKey('back'),
                    icon: Icons.arrow_back_rounded,
                    label: 'Back',
                    onTap: () => Navigator.of(context).maybePop()),
                Expanded(child: Text('DEVICES', textAlign: TextAlign.center, style: gCaps(11, color: G.text))),
                const SizedBox(width: 46),
              ]),
              const SizedBox(height: 40),
              Text('Devices on $machine', style: gSerif(32, w: FontWeight.w500, height: 1.1).copyWith(shadows: lift)),
              const SizedBox(height: 18),
              if (!c.canControl)
                _Section(children: [Text('Only a device with full control manages devices.', style: gSans(15, FontWeight.w500))])
              else if (list == null)
                _Section(children: [
                  Text(c.link.value == LinkState.online ? 'Asking the machine…' : '$machine is not connected.',
                      style: gSans(15, FontWeight.w500)),
                ])
              else ...[
                if (list.pending.isNotEmpty)
                  _Section(title: 'WAITING TO PAIR', children: [
                    for (final p in list.pending) _PendingRow(connection: c, request: p),
                  ]),
                _Section(title: 'ALLOWED', children: [
                  if (list.devices.isEmpty) Text('No devices yet.', style: gSans(15, FontWeight.w500)),
                  for (final d in list.devices) _DeviceRow(connection: c, device: d),
                ]),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
                  child: Text(
                    'At $machine: perch_host devices lists them too, and fixes any change made here by mistake.',
                    style: gSans(12.5, FontWeight.w500, color: G.muted),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  const _Section({this.title, required this.children});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Frost(
          tone: G.deep,
          tint: 0.5,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (title != null) ...[Text(title!, style: gCaps(10.5, color: G.text)), const SizedBox(height: 8)],
            ...children,
          ]),
        ),
      );
}

class _PendingRow extends StatelessWidget {
  final HostConnection connection;
  final PendingDevice request;
  const _PendingRow({required this.connection, required this.request});

  @override
  Widget build(BuildContext context) {
    final r = request;
    return Padding(
      key: ValueKey('pending-${r.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(r.name.isEmpty ? 'Device' : r.name, style: gSans(16, FontWeight.w700)),
        Text('${shortDeviceCode(r.id)} · ${pendingRoute(r.route)}', style: gSans(12.5, FontWeight.w500, color: G.muted)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: GlassButton(
                key: ValueKey('allow-${r.id}'),
                label: 'Allow',
                warm: true,
                compact: true,
                onTap: () => connection.decideDevice(r.id, DeviceDecisions.full)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GlassButton(
                key: ValueKey('watch-${r.id}'),
                label: 'Watch only',
                compact: true,
                onTap: () => connection.decideDevice(r.id, DeviceDecisions.watch)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DangerButton(
                key: ValueKey('deny-${r.id}'),
                label: 'Deny',
                compact: true,
                onTap: () => connection.decideDevice(r.id, DeviceDecisions.deny)),
          ),
        ]),
      ]),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final HostConnection connection;
  final DeviceInfo device;
  const _DeviceRow({required this.connection, required this.device});

  @override
  Widget build(BuildContext context) {
    final d = device;
    final c = connection;
    final full = d.permission == DevicePermissions.full;
    final muted = gSans(12.5, FontWeight.w500, color: G.muted);
    final machine = machineTitle(c);
    final name = d.name.isEmpty ? 'Device' : d.name;
    return Padding(
      key: ValueKey('device-${d.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Flexible(child: Text(name, style: gSans(16, FontWeight.w700))),
          if (d.thisDevice) ...[const SizedBox(width: 8), const ValuePillText('This phone')],
        ]),
        Text(
            [
              full ? 'Full control' : 'Watch only',
              d.connected ? 'connected now' : (d.lastSeenAtMs == null ? 'never seen' : 'seen ${agoLabel(d.lastSeenAtMs!)}'),
              shortDeviceCode(d.id),
            ].join(' · '),
            style: muted),
        if (!d.keyed) Text('Allowed; it gets its own key when it next connects.', style: muted),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          GlassButton(
              key: ValueKey('rename-${d.id}'),
              label: 'Rename…',
              compact: true,
              onTap: () async {
                final n = await showDeviceRenameSheet(context, current: name);
                if (n != null) c.renameDevice(d.id, n);
              }),
          GlassButton(
              key: ValueKey('permission-${d.id}'),
              label: full ? 'Change to watch only' : 'Change to full control',
              compact: true,
              onTap: () async {
                if (full && d.thisDevice) {
                  final ok = await confirmDanger(context,
                      title: 'Make this phone watch only?',
                      lost: 'This phone can then only look: no messages, answers, stopping or device changes. '
                          'Give it full control again at $machine: perch_host devices full ${shortDeviceCode(d.id)}.',
                      yes: 'Watch only');
                  if (!ok) return;
                }
                c.setDevicePermission(d.id, full ? DevicePermissions.watch : DevicePermissions.full);
              }),
          DangerButton(
              key: ValueKey('remove-${d.id}'),
              label: 'Remove…',
              compact: true,
              onTap: () async {
                final ok = await confirmDanger(context,
                    title: d.thisDevice ? 'Remove this phone from $machine?' : 'Remove $name from $machine?',
                    lost: '${d.thisDevice ? 'This phone' : name} loses its key: it can no longer see or control anything '
                        'on $machine, and gets no more notifications from it. To come back it must ask to pair again, '
                        'and be allowed at the machine.',
                    yes: 'Remove device');
                if (ok) c.removeDevice(d.id);
              }),
        ]),
      ]),
    );
  }
}

/// A small pill with text (the "This phone" mark).
class ValuePillText extends StatelessWidget {
  final String text;
  const ValuePillText(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(9), border: Border.all(color: G.muted)),
        child: Text(text, style: gSans(11.5, FontWeight.w700)),
      );
}

/// Asks for a device's new name (1–40 characters). Null: cancelled.
Future<String?> showDeviceRenameSheet(BuildContext context, {required String current}) =>
    showGlassSheet<String>(context, (_) => _DeviceRenameSheet(current: current));

class _DeviceRenameSheet extends StatefulWidget {
  final String current;
  const _DeviceRenameSheet({required this.current});
  @override
  State<_DeviceRenameSheet> createState() => _DeviceRenameSheetState();
}

class _DeviceRenameSheetState extends State<_DeviceRenameSheet> {
  late final TextEditingController _text = TextEditingController(text: widget.current);
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final t = _text.text.trim();
    if (t.isEmpty || t.length > maxDeviceNameLength) {
      setState(() => _error = t.isEmpty ? 'Enter a name' : 'At most $maxDeviceNameLength characters');
      return;
    }
    Navigator.of(context).pop(t);
  }

  @override
  Widget build(BuildContext context) => GlassSheet(children: [
        ...sheetTitle('Rename device', 'The name the machine and its other devices show.'),
        const SizedBox(height: 14),
        GlassField(
          controller: _text,
          label: 'Device name',
          autofocus: true,
          maxLength: maxDeviceNameLength,
          error: _error,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: GlassButton(label: 'Cancel', onTap: () => Navigator.of(context).pop())),
          const SizedBox(width: 10),
          Expanded(child: GlassButton(key: const ValueKey('rename-save'), label: 'Save', warm: true, onTap: _save)),
        ]),
      ]);
}
