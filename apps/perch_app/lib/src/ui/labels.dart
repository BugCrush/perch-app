// The words the app uses for states, folders, links and usage, and what each session's
// menu offers. Shared by every screen (and by the tests).
import 'package:flutter/widgets.dart';
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/host_connection.dart';
import '../state/providers.dart';
import 'glass/mosaic.dart' show G;
import 'glass/palette.dart';

String stateLabel(SessionSummary s) => !s.live
    ? 'Not running'
    : switch (s.state) {
        SessionState.working => 'Working',
        SessionState.waitingQuestion => 'Asked a question',
        SessionState.waitingPermission => 'Needs permission',
        SessionState.waitingPlan => 'Plan to approve',
        SessionState.idle => 'Idle',
        SessionState.blocked => (s.reason == null || s.reason!.trim().isEmpty) ? 'Blocked' : 'Blocked: ${s.reason}',
        SessionState.finished => 'Finished',
        SessionState.stopped => 'Stopped',
      };

/// The last two segments of a folder path.
String shortFolder(String cwd) {
  final sep = cwd.contains(r'\') ? r'\' : '/';
  final parts = cwd.split(RegExp(r'[\\/]+')).where((p) => p.isNotEmpty).toList();
  if (parts.length <= 2) return parts.join(sep);
  return parts.sublist(parts.length - 2).join(sep);
}

/// The last segment of a folder path.
String lastFolder(String cwd) {
  final parts = cwd.split(RegExp(r'[\\/]+')).where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? cwd : parts.last;
}

/// What a watch-only device shows where it cannot act.
const watchOnlyHint = 'Watch only on this machine';

String linkLabel(LinkState s) => switch (s) {
      LinkState.online => 'Online',
      LinkState.connecting => 'Connecting…',
      LinkState.offline => 'Offline',
      LinkState.refused => 'Host needs an update',
      LinkState.stopped => 'Remote access stopped on host',
      LinkState.needsPairing => 'Not paired',
      LinkState.awaitingApproval => 'Waiting for approval',
      LinkState.denied => 'Not allowed',
      LinkState.removed => 'Removed by the machine',
    };

Color linkColor(LinkState s) => switch (s) {
      LinkState.online => Perch.led,
      LinkState.connecting || LinkState.awaitingApproval => Perch.amber,
      LinkState.offline => G.muted,
      LinkState.refused ||
      LinkState.stopped ||
      LinkState.needsPairing ||
      LinkState.denied ||
      LinkState.removed =>
        Perch.orange,
    };

String routeLabel(LinkRoute r) => switch (r) {
      LinkRoute.lan => 'On this network',
      LinkRoute.relay => 'Through relay',
    };

/// What the app calls the machine (this device's alias, else the host's own name). Widgets
/// that show it listen to [HostConnection.displayName].
String machineTitle(HostConnection c) => c.displayName.value;

/// Number of running sessions on a connection.
int activeSessions(HostConnection c) => c.sessions.value.where((s) => s.live && isActive(s.state)).length;

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// A usage window's reset time on the phone's clock: `4:30 pm`, or `Mon 9:00 am` when
/// [withDay].
String resetClock(int unixSeconds, {bool withDay = false}) {
  final t = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final clock = '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'am' : 'pm'}';
  return withDay ? '${_days[t.weekday - 1]} $clock' : clock;
}

/// A usage share as a whole percentage.
int percent(UsageWindow w) => (w.utilization * 100).round().clamp(0, 999);

/// Whether item [i] is the usage-limit choice that applies to session [id] now.
bool sessionMenuChosen(SessionMenuItem i, String id, UsageLimit? limit) => switch (i) {
      SessionMenuItem.limitContinue => limit?.choiceFor(id) == LimitChoices.continueWhenAvailable,
      SessionMenuItem.limitWait => limit?.choiceFor(id) == LimitChoices.wait,
      _ => false,
    };

/// Whether a session wants the owner (the attention list): an open card, or a state that
/// needs them, while it runs.
bool wantsYou(SessionSummary s) => s.live && (s.openPrompts > 0 || needsAttention(s.state));

/// The working folder of the most recently started session, if any.
String? mostRecentFolder(List<SessionSummary> sessions) {
  final sorted = [...sessions]..sort((a, b) => b.startedAtMs.compareTo(a.startedAtMs));
  for (final s in sorted) {
    if (s.cwd.isNotEmpty) return s.cwd;
  }
  return null;
}

/// What a session's menu offers, in order (only what applies to its state now).
enum SessionMenuItem {
  limitContinue,
  limitWait,
  interrupt,
  mute,
  unmute,
  rename,
  model,
  pin,
  unpin,
  newHere,
  switchAccount,
  resume,
  hide,
  end,
  delete
}

/// The items of [s]'s menu. While the machine's usage [limit] pauses it, its own choice
/// comes first.
/// [accounts]: the machine has accounts to switch between (a running session can move).
/// [control] false (a watch-only device): only what stays on this phone (mute, pin, hide).
List<SessionMenuItem> sessionMenuItems(SessionSummary s,
        {required bool pinned, required bool muted, UsageLimit? limit, bool accounts = false, bool control = true}) =>
    !control
        ? [
            muted ? SessionMenuItem.unmute : SessionMenuItem.mute,
            pinned ? SessionMenuItem.unpin : SessionMenuItem.pin,
            if (!s.live) SessionMenuItem.hide,
          ]
        : [
      if (limit?.session(s.id) != null) ...[SessionMenuItem.limitContinue, SessionMenuItem.limitWait],
      if (s.live && s.state == SessionState.working) SessionMenuItem.interrupt,
      muted ? SessionMenuItem.unmute : SessionMenuItem.mute,
      SessionMenuItem.rename,
      if (s.live) SessionMenuItem.model,
      pinned ? SessionMenuItem.unpin : SessionMenuItem.pin,
      if (s.cwd.isNotEmpty) SessionMenuItem.newHere,
      if (accounts && s.live) SessionMenuItem.switchAccount,
      if (!s.live) SessionMenuItem.resume,
      if (!s.live) SessionMenuItem.hide,
      if (s.live) SessionMenuItem.end,
      SessionMenuItem.delete,
    ];

String sessionMenuLabel(SessionMenuItem i) => switch (i) {
      SessionMenuItem.limitContinue => 'Continue when available',
      SessionMenuItem.limitWait => 'Wait',
      SessionMenuItem.interrupt => 'Interrupt',
      SessionMenuItem.mute => 'Mute notifications',
      SessionMenuItem.unmute => 'Unmute notifications',
      SessionMenuItem.rename => 'Rename…',
      SessionMenuItem.model => 'Model…',
      SessionMenuItem.pin => 'Pin to top',
      SessionMenuItem.unpin => 'Unpin',
      SessionMenuItem.newHere => 'New session here…',
      SessionMenuItem.switchAccount => "Switch this session's account…",
      SessionMenuItem.resume => 'Resume',
      SessionMenuItem.hide => 'Hide',
      SessionMenuItem.end => 'End session…',
      SessionMenuItem.delete => 'Delete…',
    };
