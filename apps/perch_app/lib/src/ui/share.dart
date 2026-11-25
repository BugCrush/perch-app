// Share a task or a whole project as JSON (docs/superpowers/specs/2026-11-24-projects-first-board-design.md,
// section 6): everything about it, pretty-printed, copied to the clipboard ("Copied") and
// offered through Android's share panel (Gemini, Claude, email, notes…). The board page in
// a browser copies only.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:share_plus/share_plus.dart';

import '../connection/board_store.dart';
import '../connection/host_connection.dart';
import 'glass/widgets.dart' show say;

/// Opens the platform's share panel with [text] (replaced in tests).
typedef ShareText = Future<void> Function(String text, {String? subject});

Future<void> _sharePlus(String text, {String? subject}) async {
  await SharePlus.instance.share(ShareParams(text: text, subject: subject));
}

/// What Share uses to open the share panel.
ShareText shareText = _sharePlus;

/// On the web (the board page) Share only copies; replaceable in tests.
bool shareCopiesOnly = kIsWeb;

/// The names of the paired machines, by id.
Map<String, String> machineNamesOf(Iterable<HostConnection> all) => {for (final c in all) c.machine.id: c.displayName.value};

Future<void> _share(BuildContext context, String json, String subject) async {
  await Clipboard.setData(ClipboardData(text: json));
  if (context.mounted) say(context, 'Copied');
  if (shareCopiesOnly) return;
  try {
    await shareText(json, subject: subject);
  } catch (_) {
    // No share panel here: it is on the clipboard.
  }
}

/// Shares [t] (with its project) as JSON.
Future<void> shareTask(BuildContext context, BoardTask t,
    {required BoardStore store, Iterable<HostConnection> all = const []}) {
  final names = machineNamesOf(all);
  final json = taskShareJson(t,
      project: store.projects.byId(t.projectId), machineName: names[t.machineId], models: store.table);
  return _share(context, json, t.title);
}

/// Shares [p] and every one of its tasks (all columns, Done included) as JSON.
Future<void> shareProject(BuildContext context, Project p,
    {required BoardStore store, Iterable<HostConnection> all = const []}) {
  final tasks = store.file?.board.tasksOf(p.id) ?? const <BoardTask>[];
  final json = projectShareJson(p, tasks, machineNames: machineNamesOf(all), models: store.table);
  return _share(context, json, p.name);
}
