// A machine's usage limit (PRD 7.6): one card per machine, on top of its sessions. It shows
// when usage is back (a dot-matrix countdown for the 5-hour window, a date for a weekly
// one), the sessions it paused, and the owner's choice: Continue when available, or Wait.
// Switch account moves the paused sessions to another account. After the reset it turns into "Usage is
// back" with Continue and Open.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/host_connection.dart';
import '../state/providers.dart';
import '../time_format.dart';
import 'accounts_screen.dart' show machineAccountIds, machineAccountName, openAccounts, showAccountPicker;
import 'glass/dots.dart';
import 'glass/mosaic.dart';
import 'glass/palette.dart';
import 'glass/widgets.dart';
import 'session_row.dart' show OpenSession, openSessionScreen;
import 'glass/click.dart';

String _two(int n) => n.toString().padLeft(2, '0');

/// `5-HOUR`, `WEEKLY`, `OPUS`, `SONNET`, or nothing.
String limitWindowLabel(String? window) => switch (window) {
      LimitWindows.fiveHour => '5-hour',
      LimitWindows.sevenDay => 'Weekly',
      LimitWindows.opus => 'Opus',
      LimitWindows.sonnet => 'Sonnet',
      _ => '',
    };

/// The time left until [resetsAtMs] as `HH:MM` (rounded up to the minute), when it is less
/// than a day away; null otherwise (a date reads better then).
String? limitCountdown(int resetsAtMs, DateTime now) {
  final left = DateTime.fromMillisecondsSinceEpoch(resetsAtMs).difference(now);
  if (left.isNegative) return '00:00';
  if (left >= const Duration(hours: 24)) return null;
  final minutes = (left.inSeconds + 59) ~/ 60;
  return '${_two(minutes ~/ 60)}:${_two(minutes % 60)}';
}

/// One line for the machine's limit: `Usage limit · resets 15:45`, `Usage is back`.
String limitSummary(UsageLimit l, DateTime now) {
  if (l.back) return 'Usage is back';
  final at = l.resetsAtMs;
  return at == null ? 'Usage limit · reset time unknown' : 'Usage limit · resets ${formatIst(at, now: now)}';
}

/// What a paused session will do at the reset, in a few words.
String limitedSessionLine(UsageLimit l, LimitedSession s) {
  final choice = l.choiceFor(s.id);
  final own = s.override != null ? ' (this session)' : '';
  if (choice == LimitChoices.wait) return 'Waits for you$own';
  return switch (s.claudeWaiting) {
    true => 'Claude Code continues by itself$own',
    _ => 'Perch sends please continue$own',
  };
}

class UsageLimitCard extends StatefulWidget {
  final HostConnection connection;
  final UsageLimit limit;
  final OpenSession onOpenSession;

  /// The current time (replaced in tests).
  final DateTime Function() clock;

  /// "Choose account per session" (null: the app's setting). Off: Switch account also
  /// becomes the machine's account for new sessions.
  final bool? perSession;
  const UsageLimitCard(
      {super.key,
      required this.connection,
      required this.limit,
      this.onOpenSession = openSessionScreen,
      this.clock = DateTime.now,
      this.perSession});

  @override
  State<UsageLimitCard> createState() => _UsageLimitCardState();
}

class _UsageLimitCardState extends State<UsageLimitCard> {
  Timer? _tick;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // The countdown moves a minute at a time.
    _tick = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _choose(String choice) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.connection.chooseLimit(choice);
      if (mounted && choice == LimitChoices.continueNow) say(context, 'Sending please continue…');
    } on SessionActionFailed catch (e) {
      if (mounted) say(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(String sessionId) => widget.onOpenSession(context, widget.connection, sessionId);

  /// The accounts the paused sessions run on (the one the limit hit, usually one).
  Set<String> _limitedAccounts() {
    final ids = {for (final s in widget.limit.sessions) s.id};
    return {
      for (final s in widget.connection.sessions.value)
        if (ids.contains(s.id) && s.accountId != null) s.accountId!
    };
  }

  bool _perSession() {
    final given = widget.perSession;
    if (given != null) return given;
    try {
      return ProviderScope.containerOf(context, listen: false).read(phoneAccountsProvider).perSession;
    } catch (_) {
      return false;
    }
  }

  Widget _switchRow() {
    final m = widget.connection.accounts.value;
    final hit = _limitedAccounts();
    final others = m == null ? const <String>[] : [for (final id in machineAccountIds(m)) if (!(hit.length == 1 && hit.contains(id))) id];
    final String detail;
    final VoidCallback? onTap;
    if (m == null) {
      detail = 'Update Perch on this machine to switch accounts';
      onTap = null;
    } else if (others.isEmpty || m.accounts.isEmpty) {
      detail = 'Add another account first';
      onTap = () => openAccounts(context);
    } else {
      detail = 'Restart the paused sessions on another account and continue them';
      onTap = _busy ? null : () => _switchAccount(exclude: hit.length == 1 ? hit : const {});
    }
    return _ChoiceRow(
        key: const ValueKey('limit-switch-account'), label: 'Switch account', detail: detail, chosen: false, onTap: onTap);
  }

  Future<void> _switchAccount({required Set<String> exclude}) async {
    final c = widget.connection;
    final perSession = _perSession();
    final to = await showAccountPicker(context, c,
        title: 'Switch account',
        body: 'Each paused session ends and resumes its conversation on the account you pick, then continues '
            '(Perch sends please continue only at its prompt, and only if you sent nothing since the limit).'
            '${perSession ? '' : ' New sessions on ${c.displayName.value} start on it too.'}',
        exclude: exclude);
    if (to == null || !mounted) return;
    setState(() => _busy = true);
    try {
      say(context, 'Moving the paused sessions…');
      await c.chooseLimit(LimitChoices.switchAccount, accountId: to, makeDefault: !perSession);
      if (mounted) say(context, 'Moved to ${machineAccountName(c.accounts.value!, to)}');
    } on SessionActionFailed catch (e) {
      if (mounted) say(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.limit;
    final now = widget.clock();
    final window = limitWindowLabel(l.window);
    final at = l.resetsAtMs;
    final countdown = at == null || l.back ? null : limitCountdown(at, now);
    final n = l.sessions.length;
    return Frost(
      key: const ValueKey('usage-limit-card'),
      rim: true,
      tone: G.deep,
      tint: 0.55,
      radius: 30,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: Text((l.back ? 'Usage is back' : 'Usage limit').toUpperCase(), style: gCaps(11, color: G.text))),
          if (window.isNotEmpty) GlassTag(window),
        ]),
        const SizedBox(height: 12),
        if (l.back)
          Text('$n ${n == 1 ? 'session' : 'sessions'} paused', style: gSerif(24, w: FontWeight.w500, height: 1.2))
        else if (countdown != null)
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Resets in', style: gSans(13, FontWeight.w600, color: G.muted)),
              const SizedBox(height: 6),
              DotMatrix(countdown, dot: 6, key: const ValueKey('limit-countdown')),
            ]),
            const SizedBox(width: 14),
            Expanded(
              child: Text('at ${formatIst(at!, now: now)}',
                  style: gSans(13.5, FontWeight.w600, color: G.muted), textAlign: TextAlign.right),
            ),
          ])
        else
          Text(at == null ? 'Reset time unknown' : 'Resets ${formatIst(at, now: now)}',
              style: gSerif(24, w: FontWeight.w500, height: 1.2)),
        const SizedBox(height: 12),
        for (final s in l.sessions)
          ClickDetector(
            key: ValueKey('limited-${s.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => _open(s.id),
            child: Semantics(
              button: true,
              label: 'Open ${s.name}',
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  MosaicThumb(seed: seedOf(s.id), size: 30, radius: 9),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.name.isEmpty ? 'Session' : s.name,
                          style: gSans(14.5, FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(limitedSessionLine(l, s), style: gSans(12.5, FontWeight.w500, color: G.muted)),
                    ]),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: G.muted, size: 20),
                ]),
              ),
            ),
          ),
        if (l.problem != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.error_outline_rounded, size: 17, color: G.glow),
              const SizedBox(width: 8),
              Expanded(child: Text(l.problem!, style: gSans(13, FontWeight.w700, color: G.glow))),
            ]),
          ),
        const SizedBox(height: 14),
        if (l.back)
          Row(children: [
            Expanded(
              child: GlassButton(
                  key: const ValueKey('limit-continue-now'),
                  label: 'Continue',
                  warm: true,
                  icon: Icons.play_arrow_rounded,
                  onTap: _busy ? null : () => _choose(LimitChoices.continueNow)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GlassButton(
                  key: const ValueKey('limit-open'),
                  label: 'Open',
                  onTap: l.sessions.isEmpty ? null : () => _open(l.sessions.first.id)),
            ),
          ])
        else ...[
          _ChoiceRow(
            key: const ValueKey('limit-choose-continue'),
            label: 'Continue when available',
            detail: 'Resumes on its own at the reset; Perch nudges it if needed',
            chosen: l.choice == LimitChoices.continueWhenAvailable,
            onTap: _busy ? null : () => _choose(LimitChoices.continueWhenAvailable),
          ),
          const SizedBox(height: 8),
          _ChoiceRow(
            key: const ValueKey('limit-choose-wait'),
            label: 'Wait',
            detail: 'Nothing is sent for you; you are told when usage is back',
            chosen: l.choice == LimitChoices.wait,
            onTap: _busy ? null : () => _choose(LimitChoices.wait),
          ),
          const SizedBox(height: 8),
          _switchRow(),
        ],
      ]),
    );
  }
}

/// One of the card's choices: a frosted row, orange-ringed when chosen; greyed when it
/// cannot be chosen.
class _ChoiceRow extends StatelessWidget {
  final String label;
  final String detail;
  final bool chosen;
  final VoidCallback? onTap;
  const _ChoiceRow({super.key, required this.label, required this.detail, required this.chosen, required this.onTap});

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null && !chosen ? 0.45 : 1,
        child: ClickDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Semantics(
            button: onTap != null,
            selected: chosen,
            enabled: onTap != null,
            label: '$label. $detail',
            excludeSemantics: true,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: chosen ? Perch.orange.withValues(alpha: 0.18) : const Color(0x14FFFFFF),
                border: Border.all(color: chosen ? Perch.orange : const Color(0x33FFFFFF), width: chosen ? 1.6 : 1),
              ),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: gSans(14.5, FontWeight.w700)),
                    Text(detail, style: gSans(12, FontWeight.w500, color: G.muted)),
                  ]),
                ),
                Icon(chosen ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                    size: 20, color: chosen ? Perch.orange : G.muted),
              ]),
            ),
          ),
        ),
      );
}
