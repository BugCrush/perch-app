// What a push message turns into on the device: it is opened with the pairing secret of
// the machine it names, then shown (one notification per session, replaced by the next)
// or withdrawn. A message that does not open is dropped without a trace.
import 'dart:convert';

import 'dart:async';

import 'package:perch_protocol/perch_protocol.dart';

import '../connection/host_connection.dart';
import '../connection/machine_store.dart';
import '../state/session_prefs.dart';

/// The Android notification channel for everything Perch shows.
const perchChannelId = 'perch_needs_you';
const perchChannelName = 'Sessions that need you';
const perchChannelDescription = 'A Claude Code session asks something, is blocked, or finished a turn.';

/// The one notification id for a session of a machine (FNV-1a, 31 bits).
int notificationIdFor(String machineId, String sessionId) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode('$machineId/$sessionId')) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h & 0x7fffffff;
}

/// The buttons on a notification.
abstract final class PushActions {
  /// "Usage is back": send please continue to every session still paused.
  static const continueNow = 'continue';

  /// "Resumed without the subagent": interrupt the session.
  static const stop = 'stop';

  /// Open the app there.
  static const open = 'open';
}

/// A notification's button: its id (one of [PushActions]), its label, and whether it opens
/// the app (the others act in the background).
typedef PushButton = ({String id, String label, bool opensApp});

/// The buttons a notification of [kind] has.
List<PushButton> pushButtonsFor(String kind) => switch (kind) {
      PushKinds.usageBack => const [
          (id: PushActions.continueNow, label: 'Continue', opensApp: false),
          (id: PushActions.open, label: 'Open', opensApp: true),
        ],
      PushKinds.resumedChanged => const [
          (id: PushActions.stop, label: 'Stop', opensApp: false),
          (id: PushActions.open, label: 'Open', opensApp: true),
        ],
      _ => const [],
    };

/// What a tapped notification (or one of its buttons) opens or does.
class PushTap {
  final String machineId;
  final String sessionId;
  final String? promptId;

  /// What to do as well ([PushActions.continueNow], [PushActions.stop]); null: just open.
  final String? action;
  const PushTap({required this.machineId, required this.sessionId, this.promptId, this.action});

  /// The machine's own usage-limit notification (opens the machine, not a session).
  bool get forMachine => sessionId == usageLimitPushId || sessionId == relayPoolPushId;

  PushTap withAction(String? a) => PushTap(machineId: machineId, sessionId: sessionId, promptId: promptId, action: a);

  String encode() => jsonEncode(
      {'m': machineId, 's': sessionId, if (promptId != null) 'p': promptId, if (action != null) 'a': action});

  static PushTap? decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final j = jsonDecode(payload);
      if (j is! Map || j['m'] is! String || j['s'] is! String) return null;
      return PushTap(
          machineId: j['m'] as String,
          sessionId: j['s'] as String,
          promptId: j['p'] as String?,
          action: j['a'] is String ? j['a'] as String : null);
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PushTap &&
      other.machineId == machineId &&
      other.sessionId == sessionId &&
      other.promptId == promptId &&
      other.action == action;

  @override
  int get hashCode => Object.hash(machineId, sessionId, promptId, action);
}

/// The message a notification button sends to the host (null: it only opens the app).
ClientMessage? pushActionMessage(PushTap t) => switch (t.action) {
      PushActions.continueNow =>
        UsageLimitChoice(choice: LimitChoices.continueNow, sessionId: t.forMachine ? null : t.sessionId),
      PushActions.stop => Interrupt(sessionId: t.sessionId),
      _ => null,
    };

/// Where notifications go (the platform's notification tray; a fake in tests).
abstract interface class NotificationSink {
  Future<void> show(
      {required int id,
      required String title,
      required String body,
      required String payload,
      List<PushButton> buttons = const []});
  Future<void> cancel(int id);
}

/// Handles one push message's data (`m`: machine id, `p`: sealed payload). Returns the
/// note it showed or withdrew, or null when the message was dropped. A session [muted] on
/// this phone shows nothing (withdrawals still go through); a machine's usage-limit
/// notification shows unless every session it names is muted. [foreground]: the app is in
/// front, where a resumed-differently toast says it already.
Future<PushNote?> handlePushData(Map<String, dynamic> data, List<Machine> machines, NotificationSink sink,
    {bool Function(String machineId, String sessionId)? muted, bool foreground = false}) async {
  final mid = data['m'];
  final sealed = data['p'];
  if (mid is! String || sealed is! String) return null;
  Machine? machine;
  for (final m in machines) {
    if (m.id == mid && m.secretBytes != null) machine = m;
  }
  if (machine == null) return null;
  // This device's own key first (a host with device keys), then the pairing secret.
  final key = machine.keyBytes;
  final note = (key == null ? null : openPush(key, mid, sealed)) ?? openPush(machine.secretBytes!, mid, sealed);
  if (note == null) return null;
  final id = notificationIdFor(mid, note.sessionId);
  // Only what the host sealed counts: the relay's own flag is not trusted.
  if (note.isWithdraw) {
    await sink.cancel(id);
    return note;
  }
  if (note.kind == PushKinds.resumedChanged && foreground) return null;
  if (note.sessionIds.isNotEmpty) {
    if (muted != null && note.sessionIds.every((s) => muted(mid, s))) return null;
  } else if (muted?.call(mid, note.sessionId) ?? false) {
    return null;
  }
  await sink.show(
    id: id,
    // This device's alias for the machine wins over the name the host sealed in.
    title: machine.alias ?? (note.title.isEmpty ? machine.label : note.title),
    body: note.body,
    payload: PushTap(machineId: mid, sessionId: note.sessionId, promptId: note.promptId).encode(),
    buttons: pushButtonsFor(note.kind),
  );
  return note;
}

/// [handlePushData] with the machines and muted sessions as saved now (aliases included),
/// also in the background isolate.
Future<PushNote?> showPushFromStore(Map<String, dynamic> data, NotificationSink sink, {bool foreground = false}) async {
  final prefs = SessionPrefs();
  await prefs.load(fresh: true);
  return handlePushData(data, await MachineStore().load(fresh: true), sink, muted: prefs.isMuted, foreground: foreground);
}

/// Sends what a notification button asks for ([PushTap.action]) to its machine through a
/// connection of its own (the app may not be running): the relay or the LAN, whichever
/// answers within [within]. True when the host got it.
Future<bool> sendPushAction(PushTap tap, List<Machine> machines, String deviceId,
    {ChannelFactory? channelFactory, Duration within = const Duration(seconds: 20)}) async {
  final message = pushActionMessage(tap);
  Machine? machine;
  for (final m in machines) {
    if (m.id == tap.machineId) machine = m;
  }
  if (message == null || machine == null || machine.needsPairing) return false;
  final c = HostConnection(machine,
      channelFactory: channelFactory, deviceName: 'Perch notification', deviceId: deviceId, lanTimeout: const Duration(seconds: 2));
  try {
    if (message is UsageLimitChoice) {
      // The host answers with the limit: proof it was received.
      if (!await c.sendWhenOnline(const ListSessions(), within: within)) return false;
      try {
        await c.chooseLimit(message.choice, sessionId: message.sessionId);
        return true;
      } on SessionActionFailed {
        return false;
      }
    }
    if (!await c.sendWhenOnline(message, within: within)) return false;
    // No answer comes for an interrupt: give the frame a moment to leave.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    return true;
  } finally {
    c.dispose();
  }
}
