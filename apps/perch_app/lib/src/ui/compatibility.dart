// What Perch knows about a machine's Claude Code: the loud notice when Perch can no longer
// read it, the amber line for a version not checked yet, and the details page.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Icons, SelectionArea;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/host_connection.dart';
import 'app_theme.dart';
import 'glass/dots.dart';
import 'glass/mosaic.dart';
import 'glass/palette.dart';
import 'glass/pressable.dart';
import 'glass/widgets.dart';
import 'labels.dart';

Future<void> openCompatibility(BuildContext context, HostConnection connection) =>
    openGlass<void>(context, CompatibilityScreen(connection: connection));

/// Text of the red alert's evidence, as copied.
String driftDetailsText(Compatibility c) => [c.reason ?? '', if (c.evidence != null) c.evidence!].join('\n\n');

/// The loud line when Claude Code changed on [machine].
String driftLine(String machine) =>
    "Claude Code changed on $machine. Perch can't read its prompts any more. Answer in the terminal and update Perch.";

const selfTestExplanation = 'When Claude Code updates, Perch opens a short Claude Code session (Haiku) in a window on '
    'this machine, answers a question, a permission request and a plan in it, and checks the result. '
    "It uses a little of your plan's usage.";

/// Says loudly when the host can no longer read its Claude Code, or quietly (amber) that it
/// runs a Claude Code version not checked yet. Both open the details. Nothing when all is
/// well. [bare] draws the amber line without its own glass (inside a panel).
class CompatibilityNotice extends StatelessWidget {
  final HostConnection connection;
  final bool bare;

  /// Which notices this one shows (the first screen puts the loud one at the top and the
  /// amber line inside the machine's row).
  final bool drift;
  final bool untested;
  const CompatibilityNotice(
      {super.key, required this.connection, this.bare = false, this.drift = true, this.untested = true});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([connection.compatibility, connection.displayName]),
      builder: (context, _) {
        final c = connection.compatibility.value;
        if (c == null) return const SizedBox.shrink();
        switch (c.status) {
          case CompatibilityStatus.ok:
            return const SizedBox.shrink();
          case CompatibilityStatus.untested:
            if (!untested) return const SizedBox.shrink();
            final line = Pressable(
              onTap: () => openCompatibility(context, connection),
              semanticLabel: untestedLine(c),
              builder: (context, p, child) => Opacity(opacity: 1 - p.clamp(0, 1) * 0.3, child: child),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: bare ? 4 : 0),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.info_outline_rounded, size: 17, color: Perch.amber),
                  const SizedBox(width: 8),
                  Expanded(child: Text(untestedLine(c), style: gSans(12.5, FontWeight.w600, color: G.muted))),
                  const Icon(Icons.chevron_right_rounded, size: 18, color: G.muted),
                ]),
              ),
            );
            if (bare) return line;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Frost(tone: G.deep, tint: 0.55, radius: 20, padding: const EdgeInsets.fromLTRB(14, 10, 10, 10), child: line),
            );
          case CompatibilityStatus.drifted:
            if (!drift) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Frost(
                tone: G.deep,
                tint: 0.78,
                radius: 24,
                rim: true,
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.warning_amber_rounded, size: 20, color: Perch.ember),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(driftLine(machineTitle(connection)), style: gSans(14, FontWeight.w700)),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: GlassButton(label: 'Details', compact: true, onTap: () => openCompatibility(context, connection)),
                  ),
                ]),
              ),
            );
        }
      },
    );
  }
}

/// The details: the red alert's evidence, what the release notes say, what has been seen
/// working, and the self-test.
class CompatibilityScreen extends StatelessWidget {
  final HostConnection connection;
  const CompatibilityScreen({super.key, required this.connection});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([connection.compatibility, connection.displayName, connection.link]),
      builder: (context, _) {
        final c = connection.compatibility.value;
        return GlassScaffold(
          background: MosaicBackdrop(seed: seedOf(connection.machine.id), fade: G.deep, fadeFrom: 0.18, pixel: 0.5, flap: true),
          child: SelectionArea(
            child: ListView(
            padding: screenPadding(context),
            children: [
              Row(children: [
                GlassOrb(
                    key: const ValueKey('back'),
                    icon: Icons.arrow_back_rounded,
                    label: 'Back',
                    onTap: () => Navigator.of(context).maybePop()),
                Expanded(child: Text('CLAUDE CODE CHECKS', textAlign: TextAlign.center, style: gCaps(11, color: G.text))),
                const SizedBox(width: 46),
              ]),
              const SizedBox(height: 40),
              Text('Claude Code on ${machineTitle(connection)}',
                  style: gSerif(32, w: FontWeight.w500, height: 1.1).copyWith(shadows: lift)),
              const SizedBox(height: 18),
              if (c == null)
                _Section(children: [
                  Text('This machine runs an older Perch host without version checks.', style: gSans(15, FontWeight.w500)),
                ])
              else ...[
                _Section(children: [Text(_headline(c), style: gSerif(19, w: FontWeight.w600, height: 1.3))]),
                if (c.status == CompatibilityStatus.drifted) _Drift(c),
                if (c.status == CompatibilityStatus.untested || c.releaseNotes != null)
                  _Section(title: 'RELEASE NOTES', children: _notes(c)),
                if (c.status == CompatibilityStatus.untested ||
                    (c.status == CompatibilityStatus.drifted && c.seenWorking.isNotEmpty))
                  _Section(title: 'REAL USE', children: [
                    Text(seenWorkingLine(c), style: gSans(15, FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(
                      'The version counts as checked once a question, a permission request and a plan have each '
                      'been answered from Perch in a terminal on this machine.',
                      style: gSans(13, FontWeight.w500, color: G.muted),
                    ),
                  ]),
                if (c.selfTest != null)
                  _Section(title: 'SELF-TEST', children: [
                    _SelfTest(connection: connection, status: c.selfTest!, untested: c.status != CompatibilityStatus.ok),
                  ]),
              ],
            ],
          ),
          ),
        );
      },
    );
  }

  static String _headline(Compatibility c) {
    final v = c.claudeVersion ?? 'version unknown';
    return switch (c.status) {
      CompatibilityStatus.ok => 'Claude Code $v: checked with this Perch.',
      CompatibilityStatus.untested => "Claude Code $v hasn't been checked yet.",
      CompatibilityStatus.drifted => "Claude Code $v changed: Perch can't read its prompts any more. "
          'Answer in the terminal and update Perch.',
    };
  }

  static List<Widget> _notes(Compatibility c) {
    final f = c.releaseNotes;
    final body = gSans(15, FontWeight.w500);
    if (f == null) {
      return [
        Text(c.status == CompatibilityStatus.ok ? 'Not needed for a checked version.' : 'Reading the release notes…', style: body)
      ];
    }
    final versions = f.versions.isEmpty ? '' : ' (${f.versions.join(', ')})';
    if (!f.checked) {
      return [
        Text('The release notes could not be read$versions.', style: body),
        if (f.error != null) Text(f.error!, style: gSans(13, FontWeight.w500, color: G.muted)),
      ];
    }
    if (f.relevantLines.isEmpty) return [Text('Nothing in the release notes$versions affects Perch.', style: body)];
    return [
      Text('The release notes$versions mention ${f.topics.isEmpty ? 'things Perch relies on' : f.topics.join(', ')}:',
          style: body),
      for (final l in f.relevantLines)
        Container(
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.only(left: 12),
          decoration: const BoxDecoration(border: Border(left: BorderSide(color: Perch.amber, width: 2.5))),
          child: Text(l, style: gSerif(15.5, style: FontStyle.italic, height: 1.4)),
        ),
    ];
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

class _Drift extends StatelessWidget {
  final Compatibility c;
  const _Drift(this.c);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Frost(
          tone: G.deep,
          tint: 0.7,
          rim: true,
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('WHAT PERCH SAW', style: gCaps(10.5, color: G.glow)),
            const SizedBox(height: 8),
            CodeWell(child: Text(driftDetailsText(c), style: gMono(12, height: 1.45))),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: GlassButton(
                label: 'Copy',
                compact: true,
                icon: Icons.copy_rounded,
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: driftDetailsText(c)));
                  if (context.mounted) say(context, 'Copied');
                },
              ),
            ),
          ]),
        ),
      );
}

class _SelfTest extends StatelessWidget {
  final HostConnection connection;
  final SelfTestStatus status;
  final bool untested;
  const _SelfTest({required this.connection, required this.status, required this.untested});

  @override
  Widget build(BuildContext context) {
    final online = connection.link.value == LinkState.online;
    final running = status.state == SelfTestState.running;
    final result = switch (status.state) {
      SelfTestState.idle => null,
      SelfTestState.running => 'Running… a Claude Code window is open on the machine.',
      SelfTestState.passed => 'Passed on Claude Code ${status.version ?? ''}.',
      SelfTestState.failed => 'Failed on Claude Code ${status.version ?? ''}: ${status.reason ?? 'no reason given'}',
      SelfTestState.unsupported => status.reason ?? 'This machine cannot run the self-test.',
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Self-test new Claude Code versions', style: gSans(15, FontWeight.w700)),
            const SizedBox(height: 4),
            Text(selfTestExplanation, style: gSans(13, FontWeight.w500, color: G.muted)),
          ]),
        ),
        const SizedBox(width: 12),
        GlassToggle(
          key: const ValueKey('selftest-toggle'),
          value: status.enabled,
          onChanged: online ? connection.setSelfTest : null,
        ),
      ]),
      const SizedBox(height: 14),
      Row(children: [
        GlassButton(
          label: 'Run self-test now',
          warm: true,
          onTap: online && !running && status.state != SelfTestState.unsupported ? connection.runSelfTest : null,
        ),
        if (running) ...[const SizedBox(width: 14), const WorkingWave(width: 40, height: 18, bars: 8)],
      ]),
      if (result != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (status.state == SelfTestState.passed) ...[
              const Icon(Icons.check_circle_rounded, size: 18, color: Perch.led),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(result,
                  style: gSans(14, FontWeight.w600, color: status.state == SelfTestState.failed ? G.glow : G.text)),
            ),
          ]),
        ),
      if (!untested && status.enabled && status.state == SelfTestState.idle)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('The installed version is checked; the self-test runs by itself the next time Claude Code updates.',
              style: gSans(13, FontWeight.w500, color: G.muted)),
        ),
    ]);
  }
}
