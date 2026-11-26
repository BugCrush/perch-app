// The first screen's menu (the button at its top left): the settings in one place, Models,
// Accounts, Projects, Appearance and each machine's Claude Code checks, and About. Every row
// that changes something has its verb pill and chevron; About is information only.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/host_connection.dart';
import '../state/providers.dart';
import 'accounts_screen.dart' show openAccounts;
import 'app_lock.dart';
import 'app_theme.dart' show openGlass;
import 'compatibility.dart' show openCompatibility;
import 'glass/mosaic.dart';
import 'glass/settings.dart';
import 'glass/theme.dart';
import 'glass/widgets.dart';
import 'home_screen.dart' show ThemeSwitch;
import 'labels.dart';
import 'model_table_screen.dart';
import 'projects_screen.dart';
import 'update_notice.dart' show versionLine;

/// The app's version as the menu shows it (pubspec.yaml).
const appVersion = '1.1.0';

/// What a machine's Claude Code checks say now, in a few words.
String checksLine(HostConnection c) {
  if (c.link.value != LinkState.online) return linkLabel(c.link.value);
  final k = c.compatibility.value;
  if (k == null) return 'Not reported yet';
  final v = k.claudeVersion == null ? 'Claude Code' : 'Claude Code ${k.claudeVersion}';
  return switch (k.status) {
    CompatibilityStatus.ok => '$v · works with Perch',
    CompatibilityStatus.untested => '$v · newer than Perch was checked with',
    CompatibilityStatus.drifted => '$v · something changed',
  };
}

String themeLabel(GlassMode m) => switch (m) {
      GlassMode.system => 'Follows the phone',
      GlassMode.light => 'Light',
      GlassMode.dark => 'Dark',
    };

/// What the "Lock after" row says.
String lockAfterLine(LockAfter a) =>
    a == LockAfter.immediately ? 'Every time Perch comes back' : '${a.label} in the background';

/// The four choices of when Perch locks again.
Future<void> showLockAfterSheet(BuildContext context) async {
  final choice = await showGlassSheet<LockAfter>(
    context,
    (ctx) => GlassSheet(children: [
      ...sheetTitle('Lock after', 'How long Perch may be in the background before it asks again.'),
      const SizedBox(height: 10),
      for (final a in LockAfter.values)
        MenuRow(
          key: ValueKey('lock-after-${a.name}'),
          label: a.label,
          icon: Icons.timer_outlined,
          selected: a == AppLock.after.value,
          onTap: () => Navigator.of(ctx).pop(a),
        ),
    ]),
  );
  if (choice != null) await AppLock.setAfter(choice);
}

Future<void> showAppMenu(BuildContext context) => showGlassSheet<void>(context, (_) => const AppMenu());

class AppMenu extends ConsumerWidget {
  const AppMenu({super.key});

  /// Closes the menu, then opens [page] from the screen under it.
  void _go(BuildContext context, void Function(BuildContext context) open) {
    final nav = Navigator.of(context);
    final under = nav.context;
    nav.pop();
    open(under);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machines = ref.watch(machinesProvider);
    final registry = ref.watch(connectionsProvider);
    final connections = [for (final m in machines) registry.of(m)];
    final store = ref.watch(boardStoreProvider);
    final accounts = ref.watch(phoneAccountsProvider);
    final auth = ref.watch(authenticatorProvider);
    return ListenableBuilder(
      listenable: Listenable.merge([
        store,
        accounts,
        GlassTheme.mode,
        AppLock.enabled,
        AppLock.after,
        for (final c in connections) ...[c.compatibility, c.link]
      ]),
      builder: (context, _) {
        final set = store.table.rows.where((r) => r.model != null).length;
        return GlassSheet(children: [
          Row(children: [
            Expanded(child: Text('Settings', style: gSerif(28, w: FontWeight.w500, height: 1.15))),
            GlassOrb(
                key: const ValueKey('menu-close'),
                icon: Icons.close_rounded,
                size: 40,
                label: 'Close',
                onTap: () => Navigator.of(context).pop()),
          ]),
          const SizedBox(height: 4),
          Text('Rows with a pill can be changed; plain lines are information.',
              style: gSans(12.5, FontWeight.w500, color: G.muted)),
          const SizedBox(height: 14),
          SettingsGroup(caption: 'Board and sessions', children: [
            SettingRow(
              key: const ValueKey('open-models'),
              label: 'Models',
              value: '${store.table.rows.length} task types · ${set == 0 ? 'all on your default' : '$set set'}',
              verb: 'Edit',
              icon: Icons.tune_rounded,
              onTap: () => _go(context, (c) => openGlass<void>(c, ModelTableScreen(store: store))),
            ),
            SettingRow(
              key: const ValueKey('open-projects'),
              label: 'Projects',
              value: store.projects.projects.isEmpty
                  ? 'None yet'
                  : '${store.projects.projects.length} ${store.projects.projects.length == 1 ? 'project' : 'projects'}',
              verb: 'Edit',
              icon: Icons.folder_copy_outlined,
              onTap: () => _go(context, openProjects),
            ),
            SettingRow(
              key: const ValueKey('open-accounts'),
              label: 'Accounts',
              value: accounts.accounts.isEmpty
                  ? "Each machine's own login"
                  : '${accounts.accounts.length} ${accounts.accounts.length == 1 ? 'account' : 'accounts'} on this phone',
              verb: 'Manage',
              icon: Icons.manage_accounts_rounded,
              onTap: () => _go(context, openAccounts),
            ),
          ]),
          const SizedBox(height: 16),
          SettingsGroup(caption: 'Appearance', children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Row(children: [
                const Icon(Icons.palette_outlined, size: 20, color: G.text),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Theme', style: gSans(15, FontWeight.w700)),
                    Text(themeLabel(GlassTheme.mode.value), style: gSans(13.5, FontWeight.w600, color: G.muted)),
                  ]),
                ),
                const ThemeSwitch(),
              ]),
            ),
          ]),
          if (!kIsWeb) ...[
            const SizedBox(height: 16),
            SettingsGroup(caption: 'Security', children: [
              if (!auth.available)
                const InfoRow(label: 'App lock', value: 'Set a screen lock on this phone to use App lock')
              else ...[
                ToggleRow(
                  key: const ValueKey('app-lock-toggle'),
                  label: 'App lock',
                  detail: "Fingerprint, face or the phone's PIN when Perch opens",
                  value: AppLock.enabled.value,
                  onChanged: AppLock.setEnabled,
                ),
                if (AppLock.enabled.value)
                  SettingRow(
                    key: const ValueKey('lock-after'),
                    label: 'Lock after',
                    value: lockAfterLine(AppLock.after.value),
                    icon: Icons.timer_outlined,
                    onTap: () => showLockAfterSheet(context),
                  ),
              ],
            ]),
          ],
          if (connections.isNotEmpty) ...[
            const SizedBox(height: 16),
            SettingsGroup(caption: 'Claude Code checks', children: [
              for (final c in connections)
                SettingRow(
                  key: ValueKey('menu-checks-${c.machine.id}'),
                  label: machineTitle(c),
                  value: checksLine(c),
                  verb: 'Open',
                  icon: Icons.fact_check_outlined,
                  onTap: () => _go(context, (ctx) => openCompatibility(ctx, c)),
                ),
            ]),
          ],
          const SizedBox(height: 16),
          SettingsGroup(caption: 'About', children: [
            InfoRow(label: 'Perch', value: versionLine(appVersion, ref.watch(updateCheckerProvider).available)),
            InfoRow(label: 'Machines paired', value: '${machines.length}'),
            const InfoRow(
                label: 'What it is',
                value: 'Your Claude Code sessions on your phone: answer what Claude asks, send messages, '
                    'and run tasks from the board.'),
          ]),
        ]);
      },
    );
  }
}
