// Memory Glass's visual language for settings and information.
//
// What can be changed always shows how: a [SettingRow] is a whole tappable row (it dims and
// tints while pressed) with an orange-edged pill naming the verb ("Change", "Edit", "Set")
// and a chevron; a [ToggleRow] has a switch. What is only information is plain text in an
// [InfoRow]: muted label, value, no pill, no chevron, no pressed state. Groups of either sit
// in a [SettingsGroup] under a small-capitals caption.
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Icons;

import 'mosaic.dart';
import 'palette.dart';
import 'pressable.dart';
import 'widgets.dart';

/// The button that marks a row as changeable (the verb, or the value it changes): the text in
/// the accent, an orange edge, a rounded rectangle sized to its text (an oval looked odd and
/// clipped longer words).
class ValuePill extends StatelessWidget {
  final String text;
  const ValuePill(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: const Color(0x26F7532B),
          border: Border.all(color: Perch.orange, width: 1.2),
        ),
        child: Text(text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: gSans(12.5, FontWeight.w800, color: G.glow, height: 1.1)),
      );
}

/// A setting: its [label], its current [value], and the [verb] pill with a chevron. The
/// whole row is the button.
class SettingRow extends StatelessWidget {
  final String label;
  final String? value;

  /// Shown in the code font (paths).
  final bool mono;
  final String verb;
  final IconData? icon;

  /// A line under the value (a hint such as "Found by git remote").
  final String? note;
  final VoidCallback? onTap;
  const SettingRow(
      {super.key,
      required this.label,
      this.value,
      this.mono = false,
      this.verb = 'Change',
      this.icon,
      this.note,
      required this.onTap});

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Pressable(
          onTap: onTap,
          haptic: Haptic.selection,
          semanticLabel: '$label${value == null ? '' : ', $value'}, $verb',
          builder: (context, p, child) => AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: Color.lerp(const Color(0x00FFFFFF), const Color(0x24FFFFFF), p.clamp(0, 1)),
            ),
            child: child,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
            child: Row(children: [
              if (icon != null) ...[Icon(icon, size: 20, color: G.text), const SizedBox(width: 12)],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: gSans(15, FontWeight.w700)),
                  if (value != null) ...[
                    const SizedBox(height: 2),
                    Text(value!,
                        style: mono ? gMono(12.5, color: G.muted) : gSans(13.5, FontWeight.w600, color: G.muted),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis),
                  ],
                  if (note != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(note!, style: gSans(12, FontWeight.w700, color: G.glow)),
                    ),
                ]),
              ),
              const SizedBox(width: 10),
              ValuePill(verb),
              const Icon(Icons.chevron_right_rounded, color: G.glow, size: 22),
            ]),
          ),
        ),
      );
}

/// An on/off setting: its label, a line under it, and the switch.
class ToggleRow extends StatelessWidget {
  final String label;
  final String? detail;
  final bool value;
  final ValueChanged<bool>? onChanged;
  const ToggleRow({super.key, required this.label, this.detail, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: gSans(15, FontWeight.w700)),
              if (detail != null) Text(detail!, style: gSans(13, FontWeight.w500, color: G.muted)),
            ]),
          ),
          const SizedBox(width: 10),
          GlassToggle(value: value, onChanged: onChanged),
        ]),
      );
}

/// Information only: a muted label and its value, nothing to press.
class InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  const InfoRow({super.key, required this.label, required this.value, this.mono = false});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: gSans(12, FontWeight.w600, color: G.muted)),
          const SizedBox(height: 1),
          Text(value, style: mono ? gMono(12.5) : gSans(14.5, FontWeight.w600)),
        ]),
      );
}

/// A caption in small capitals and its rows on dark glass.
class SettingsGroup extends StatelessWidget {
  final String caption;
  final List<Widget> children;
  final Widget? trailing;
  const SettingsGroup({super.key, required this.caption, required this.children, this.trailing});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(children: [Expanded(child: Text(caption.toUpperCase(), style: gCaps(11))), ?trailing]),
        ),
        Frost(
          tone: G.deep,
          tint: 0.5,
          rim: true,
          radius: 24,
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, c) in children.indexed) ...[
              if (i > 0) Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 6), color: const Color(0x14FFFFFF)),
              c,
            ],
          ]),
        ),
      ]);
}
