// The pieces every Memory Glass screen is built from: text styles, the round orb and pill
// buttons, sheets (Memory Glass's dialogs), fields, notes, the menu rows and the scaffold.
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart'
    show
        Icons,
        InputBorder,
        InputDecoration,
        Material,
        MaterialType,
        Scaffold,
        ScaffoldMessenger,
        SnackBar,
        SnackBarBehavior,
        TextField,
        showModalBottomSheet;
import 'package:flutter/services.dart' show TextInputType, TextInputFormatter;

import 'mosaic.dart';
import 'palette.dart';
import 'pressable.dart';
import 'theme.dart';
import 'click.dart';

// ---- Text ----

/// A soft shadow that keeps text readable over the mosaic.
const lift = [Shadow(color: Color(0xB31B1519), blurRadius: 14), Shadow(color: Color(0x801B1519), blurRadius: 4)];

/// UI text (Manrope).
TextStyle gSans(double size, FontWeight w, {Color color = G.text, double height = 1.3}) =>
    glassFont(GlassFonts.sans, size, w, color, height: height);

/// Reading and title text (Newsreader).
TextStyle gSerif(double size, {FontWeight w = FontWeight.w400, Color color = G.text, double height = 1.5, FontStyle? style}) =>
    glassFont(GlassFonts.serif, size, w, color, height: height, style: style);

/// Small spaced capitals (section titles, captions); the text itself is written in capitals.
TextStyle gCaps(double size, {Color color = G.muted}) =>
    glassFont(GlassFonts.sans, size, FontWeight.w700, color, height: 1.2, spacing: 1.4);

/// Code and paths.
TextStyle gMono(double size, {Color color = G.text, double height = 1.45}) =>
    glassFont(GlassFonts.mono, size, FontWeight.w500, color, height: height);

// ---- Buttons ----

/// A circular frosted button; [warm] makes it the orange main action.
class GlassOrb extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String label;
  final double size;
  final bool warm;
  const GlassOrb(
      {super.key, required this.icon, required this.onTap, required this.label, this.size = 46, this.warm = false});
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Pressable(
          onTap: onTap,
          semanticLabel: label,
          builder: (context, p, _) => Transform.scale(
            scale: 1 - p.clamp(0, 1) * 0.08,
            child: SizedBox.square(
              dimension: size,
              child: warm
                  ? Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Perch.orange,
                        boxShadow: [BoxShadow(color: Perch.orange.withValues(alpha: 0.4), blurRadius: 16)],
                      ),
                      child: Icon(icon, color: Perch.ink, size: size * 0.44),
                    )
                  : Frost(
                      radius: size / 2,
                      padding: EdgeInsets.zero,
                      tint: 0.16,
                      child: Center(child: Icon(icon, color: G.text, size: size * 0.44))),
            ),
          ),
        ),
      );
}

/// A pill button: frosted glass, or [warm] orange for the main action. Null [onTap]
/// shows it disabled.
class GlassButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool warm;
  final IconData? icon;

  /// A shorter pill (inside notes and rows).
  final bool compact;
  const GlassButton(
      {super.key, required this.label, required this.onTap, this.warm = false, this.icon, this.compact = false});
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Pressable(
          onTap: onTap,
          haptic: Haptic.medium,
          semanticLabel: label,
          builder: (context, p, _) {
            final color = warm ? Perch.ink : G.text;
            final inner = Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              if (icon != null) ...[Icon(icon, size: compact ? 16 : 18, color: color), const SizedBox(width: 8)],
              Flexible(
                child: Text(label,
                    style: gSans(compact ? 13.5 : 14.5, FontWeight.w700, color: color, height: 1),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ]);
            final pad = EdgeInsets.symmetric(horizontal: compact ? 14 : 20);
            return Transform.scale(
              scale: 1 - p.clamp(0, 1) * 0.04,
              child: SizedBox(
                height: compact ? 36 : 46,
                child: warm
                    ? Container(
                        padding: pad,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(99),
                          gradient: const LinearGradient(colors: [Color(0xFFFF8A5E), Perch.orange]),
                          boxShadow: [
                            BoxShadow(color: Perch.orange.withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 4))
                          ],
                        ),
                        child: inner,
                      )
                    : Frost(radius: 23, tint: 0.14, padding: pad, child: inner),
              ),
            );
          },
        ),
      );
}

// ---- Destructive actions ----
//
// Stopping, ending, deleting and removing cannot be undone from the phone: their buttons are
// ember (dark red glass, an ember edge, a warning glyph), never the orange of a main action,
// and their confirmation names what is lost. The most destructive (Stop all, Delete) are
// confirmed by pressing and holding.

/// The ember of destructive buttons: deep red glass and its edge.
abstract final class Danger {
  static const fill = Color(0xCC6A1408);
  static const fillPressed = Color(0xFFB0230E);
  static const edge = Color(0xFFFF7A52);
  static const text = Color(0xFFFFD9CC);
  static const icon = Icons.warning_amber_rounded;
}

/// A destructive pill: ember glass with the warning glyph. Tapped once (the confirmation
/// that follows names what is lost).
class DangerButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final IconData icon;
  final bool compact;
  const DangerButton({super.key, required this.label, required this.onTap, this.icon = Danger.icon, this.compact = false});
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Pressable(
          onTap: onTap,
          haptic: Haptic.heavy,
          semanticLabel: label,
          builder: (context, p, _) => Transform.scale(
            scale: 1 - p.clamp(0, 1) * 0.04,
            child: _dangerPill(label, icon, compact, fill: Color.lerp(Danger.fill, Danger.fillPressed, p.clamp(0, 1))!),
          ),
        ),
      );
}

Widget _dangerPill(String label, IconData icon, bool compact, {required Color fill, double progress = 0}) => Container(
      height: compact ? 36 : 48,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(99),
        color: fill,
        border: Border.all(color: Danger.edge, width: 1.4),
        boxShadow: [BoxShadow(color: const Color(0xFFB0230E).withValues(alpha: 0.35), blurRadius: 14)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: Stack(children: [
          if (progress > 0)
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: progress,
                child: const ColoredBox(color: Danger.fillPressed),
              ),
            ),
          Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 20),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: compact ? 16 : 19, color: Danger.text),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(label,
                      style: gSans(compact ? 13.5 : 14.5, FontWeight.w800, color: Danger.text, height: 1),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );

/// A destructive pill confirmed by pressing and holding it for [hold]: the ember fills from
/// the left while held; letting go early does nothing. Screen readers confirm it with a long
/// press.
class HoldButton extends StatefulWidget {
  final String label;
  final VoidCallback onConfirmed;
  final Duration hold;
  const HoldButton(
      {super.key, required this.label, required this.onConfirmed, this.hold = const Duration(milliseconds: 1200)});
  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.hold)
    ..addListener(() => setState(() {}))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed && !_done) {
        _done = true;
        buzz(Haptic.heavy);
        widget.onConfirmed();
      }
    });
  bool _done = false;

  void _down() {
    if (_done) return;
    buzz(Haptic.light);
    _c.forward();
  }

  void _up() {
    if (_done) return;
    _c.animateBack(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: widget.label,
        hint: 'Press and hold to confirm',
        onLongPress: () {
          if (_done) return;
          _done = true;
          widget.onConfirmed();
        },
        excludeSemantics: true,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _down(),
          onPointerUp: (_) => _up(),
          onPointerCancel: (_) => _up(),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _dangerPill(widget.label, Danger.icon, false, fill: Danger.fill, progress: _c.value),
            const SizedBox(height: 6),
            Text(_c.value > 0 && !_done ? 'Keep holding…' : 'Press and hold to confirm',
                textAlign: TextAlign.center, style: gSans(12, FontWeight.w600, color: G.muted)),
          ]),
        ),
      );
}

/// Asks before a destructive action: the warning glyph, [title], what is lost ([lost]),
/// Cancel and the ember [yes] (pressed and held when [hold]). True when confirmed.
Future<bool> confirmDanger(BuildContext context,
        {required String title, required String lost, required String yes, bool hold = false}) async =>
    await showGlassSheet<bool>(
      context,
      (ctx) => GlassSheet(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 40,
            height: 40,
            margin: const EdgeInsets.only(right: 12, top: 2),
            decoration: BoxDecoration(shape: BoxShape.circle, color: Danger.fill, border: Border.all(color: Danger.edge)),
            child: const Icon(Danger.icon, size: 21, color: Danger.text),
          ),
          Expanded(child: Text(title, style: gSerif(24, w: FontWeight.w500, height: 1.2))),
        ]),
        const SizedBox(height: 10),
        Container(
          key: const ValueKey('danger-lost'),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: const Color(0x33B0230E),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0x80FF7A52)),
          ),
          child: Text(lost, style: gSans(14.5, FontWeight.w600)),
        ),
        const SizedBox(height: 18),
        if (hold) ...[
          HoldButton(label: yes, onConfirmed: () => Navigator.of(ctx).pop(true)),
          const SizedBox(height: 10),
          GlassButton(label: 'Cancel', onTap: () => Navigator.of(ctx).pop(false)),
        ] else
          Row(children: [
            Expanded(child: GlassButton(label: 'Cancel', onTap: () => Navigator.of(ctx).pop(false))),
            const SizedBox(width: 10),
            Expanded(child: DangerButton(label: yes, onTap: () => Navigator.of(ctx).pop(true))),
          ]),
      ]),
    ) ??
    false;

/// A small frosted chip (shortcuts in the folder browser).
class GlassChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// The current choice among chips like it: an accent edge and tint.
  final bool selected;
  const GlassChip({super.key, required this.label, required this.icon, required this.onTap, this.selected = false});
  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        haptic: Haptic.selection,
        semanticLabel: label,
        builder: (context, p, child) => Opacity(opacity: 1 - p.clamp(0, 1) * 0.3, child: child),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            color: selected ? const Color(0x47F7532B) : const Color(0x1FFFFFFF),
            border: Border.all(color: selected ? Perch.orange : const Color(0x33FFFFFF)),
          ),
          child: Semantics(
            selected: selected,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 15, color: selected ? G.glow : G.text),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    style: gSans(13, selected ? FontWeight.w800 : FontWeight.w600, height: 1),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
        ),
      );
}

/// An on/off switch in glass: an orange track when on.
class GlassToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  const GlassToggle({super.key, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => Semantics(
        toggled: value,
        enabled: onChanged != null,
        child: Opacity(
          opacity: onChanged == null ? 0.45 : 1,
          child: ClickDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onChanged == null
                ? null
                : () {
                    buzz(Haptic.selection);
                    onChanged!(!value);
                  },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 52,
              height: 30,
              padding: const EdgeInsets.all(3),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                color: value ? Perch.orange : const Color(0x26FFFFFF),
                border: Border.all(color: const Color(0x40FFFFFF)),
              ),
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(shape: BoxShape.circle, color: value ? Perch.ink : G.text),
              ),
            ),
          ),
        ),
      );
}

/// A small round light: green online, amber connecting, grey offline, orange trouble.
class LedDot extends StatelessWidget {
  final Color color;
  final double size;
  const LedDot(this.color, {super.key, this.size = 9});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)],
        ),
      );
}

// ---- Fields ----

/// A text field in a well of frosted glass, with its [label] above it and an [error]
/// under it.
class GlassField extends StatelessWidget {
  final TextEditingController controller;

  /// Shown above the field (null: none; then [hint] names it).
  final String? label;
  final String? hint;
  final String? error;
  final bool enabled;
  final bool autofocus;
  final int minLines;
  final int maxLines;
  final int? maxLength;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final List<TextInputFormatter>? inputFormatters;
  final double radius;
  const GlassField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.error,
    this.enabled = true,
    this.autofocus = false,
    this.minLines = 1,
    this.maxLines = 1,
    this.maxLength,
    this.keyboardType,
    this.onSubmitted,
    this.onChanged,
    this.inputFormatters,
    this.radius = 20,
  });

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 5),
            child: Text(label!, style: gSans(12.5, FontWeight.w700, color: G.muted)),
          ),
        Frost(
          radius: radius,
          tint: 0.16,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: controller,
            enabled: enabled,
            autofocus: autofocus,
            minLines: minLines,
            maxLines: maxLines,
            maxLength: maxLength,
            keyboardType: keyboardType,
            onSubmitted: onSubmitted,
            onChanged: onChanged,
            inputFormatters: inputFormatters,
            style: gSans(15.5, FontWeight.w500),
            cursorColor: Perch.orange,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              counterText: '',
              contentPadding: const EdgeInsets.symmetric(vertical: 13),
              hintText: hint,
              hintStyle: gSans(15.5, FontWeight.w500, color: G.muted),
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 6),
            child: Text(error!, style: gSans(12.5, FontWeight.w700, color: G.glow)),
          ),
      ]);
}

// ---- Screens ----

/// What the system covers at the bottom of the screen: the navigation bar (gesture bar or
/// three buttons; the app draws edge to edge, under it), or the keyboard when it is open
/// and the screen does not shrink above it. Inside a [GlassScaffold] that shrinks above the
/// keyboard this is the bar alone (and 0 while the keyboard shows): measure it with a
/// context inside the scaffold, not the screen's own (above it), or the keyboard counts twice.
/// (`padding.bottom` is the bar while no keyboard covers it, 0 while one does;
/// `viewPadding` keeps the bar either way.)
double systemBottom(BuildContext context) {
  final mq = MediaQuery.of(context);
  return mq.padding.bottom + mq.viewInsets.bottom;
}

/// A scrolling screen's padding: its end clears the navigation bar by [bottom].
EdgeInsets screenPadding(BuildContext context,
        {double left = 16, double top = 6, double right = 16, double bottom = 40}) =>
    EdgeInsets.fromLTRB(left, top, right, bottom + systemBottom(context));

/// A Memory Glass screen: [background] (default: the deep colour), its content in the safe
/// area, glass-friendly scrolling, and a place for notes ([say]).
class GlassScaffold extends StatelessWidget {
  final Widget? background;
  final Widget child;

  /// Keep the content under the status bar too (a full-bleed picture).
  final bool bleedTop;

  /// Shrink the content above the keyboard (screens with fields).
  final bool avoidKeyboard;
  const GlassScaffold({super.key, this.background, required this.child, this.bleedTop = false, this.avoidKeyboard = true});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: G.deep,
        resizeToAvoidBottomInset: avoidKeyboard,
        body: DefaultTextStyle(
          style: gSans(15, FontWeight.w500),
          child: ScrollConfiguration(
            behavior: const GlassScrollBehavior(),
            child: Stack(children: [
              Positioned.fill(child: background ?? ColoredBox(color: G.deep)),
              Positioned.fill(child: SafeArea(top: !bleedTop, bottom: false, child: child)),
            ]),
          ),
        ),
      );
}

/// Shows a short note at the bottom of the screen in dark glass, with an optional action
/// (Undo). Replaces the one before it.
void say(BuildContext context, String text, {String? action, VoidCallback? onAction}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0x00000000),
      elevation: 0,
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 14),
      content: Frost(
        tone: G.deep,
        tint: 0.82,
        radius: 22,
        rim: true,
        padding: EdgeInsets.fromLTRB(16, 12, action == null ? 16 : 8, 12),
        child: Row(children: [
          Expanded(child: Text(text, style: gSans(14, FontWeight.w600))),
          if (action != null) ...[
            const SizedBox(width: 10),
            GlassButton(
              label: action,
              compact: true,
              onTap: () {
                m.hideCurrentSnackBar();
                onAction?.call();
              },
            ),
          ],
        ]),
      ),
    ));
}

/// Opens a modal glass sheet (Memory Glass's dialogs and menus); [build] draws its
/// content, usually a [GlassSheet].
Future<T?> showGlassSheet<T>(BuildContext context, Widget Function(BuildContext context) build,
        {Color barrier = const Color(0x99000000)}) =>
    showModalBottomSheet<T>(
      context: context,
      backgroundColor: const Color(0x00000000),
      elevation: 0,
      isScrollControlled: true,
      barrierColor: barrier,
      builder: (ctx) => Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle(
          style: gSans(15, FontWeight.w500),
          child: ScrollConfiguration(
            behavior: const GlassScrollBehavior(),
            child: Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
              child: SafeArea(child: Builder(builder: build)),
            ),
          ),
        ),
      ),
    );

/// A sheet of frosted glass with a grab handle; scrolls when it is taller than the screen.
class GlassSheet extends StatelessWidget {
  final List<Widget> children;
  const GlassSheet({super.key, required this.children});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
          child: Frost(
            radius: 32,
            tint: 0.18,
            rim: true,
            padding: EdgeInsets.zero,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Center(
                  child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(color: const Color(0x66FFFFFF), borderRadius: BorderRadius.circular(2))),
                ),
                const SizedBox(height: 14),
                ...children,
              ]),
            ),
          ),
        ),
      );
}

/// A serif title and a muted line under it (sheets).
List<Widget> sheetTitle(String title, [String? body]) => [
      Text(title, style: gSerif(26, w: FontWeight.w500, height: 1.2)),
      if (body != null) ...[
        const SizedBox(height: 6),
        Text(body, style: gSans(14.5, FontWeight.w500, color: G.muted)),
      ],
    ];

/// Asks a yes-or-no question in a sheet; true when [yes] was chosen.
Future<bool> confirmSheet(BuildContext context, {required String title, String? body, required String yes, String no = 'Cancel'}) async =>
    await showGlassSheet<bool>(
      context,
      (ctx) => GlassSheet(children: [
        ...sheetTitle(title, body),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: GlassButton(label: no, onTap: () => Navigator.of(ctx).pop(false))),
          const SizedBox(width: 10),
          Expanded(child: GlassButton(label: yes, warm: true, onTap: () => Navigator.of(ctx).pop(true))),
        ]),
      ]),
    ) ??
    false;

/// A menu sheet's header: a mosaic tile, a serif title and a line under it.
Widget menuHeader(int seed, String title, Widget line) => Row(children: [
      MosaicThumb(seed: seed, size: 54, radius: 16),
      const SizedBox(width: 14),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: gSerif(22, w: FontWeight.w600, height: 1.2), maxLines: 2, overflow: TextOverflow.ellipsis),
          line,
        ]),
      ),
    ]);

/// One row of a menu sheet: a round glass icon and its label; [danger] tints it orange.
class MenuRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool danger;

  /// The current choice among rows like it (a tick at the end).
  final bool selected;
  final VoidCallback onTap;

  /// A smaller line under the label (null: none).
  final String? note;
  const MenuRow(
      {super.key,
      required this.label,
      required this.icon,
      required this.onTap,
      this.danger = false,
      this.selected = false,
      this.note});
  @override
  Widget build(BuildContext context) => Pressable(
        key: ValueKey('menu-$label'),
        onTap: onTap,
        semanticLabel: label,
        builder: (context, p, child) => Opacity(opacity: 1 - p.clamp(0, 1) * 0.4, child: child),
        child: Semantics(
          selected: selected,
          child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: danger ? Danger.fill : const Color(0x1FFFFFFF),
                border: Border.all(color: danger ? Danger.edge : const Color(0x33FFFFFF)),
              ),
              child: Icon(icon, size: 19, color: danger ? Danger.text : G.text),
            ),
            const SizedBox(width: 14),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: gSans(15.5, danger ? FontWeight.w800 : FontWeight.w600, color: danger ? Danger.text : G.text)),
              if (note != null && note!.isNotEmpty)
                Text(note!, style: gSans(12.5, FontWeight.w500, color: G.muted), maxLines: 2, overflow: TextOverflow.ellipsis),
            ])),
            if (danger) const Icon(Danger.icon, size: 18, color: Danger.edge),
            if (selected) const Icon(Icons.check_rounded, size: 20, color: Perch.orange),
          ]),
        ),
        ),
      );
}

/// The frosted panel prompt cards and grouped content sit in: a caption, then [children].
class GlassPanel extends StatelessWidget {
  final String caption;
  final List<Widget> children;

  /// Next to the caption (a tag such as "From a subagent").
  final Widget? trailing;
  const GlassPanel({super.key, required this.caption, required this.children, this.trailing});
  @override
  Widget build(BuildContext context) => Frost(
        rim: true,
        tint: 0.16,
        radius: 30,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(caption, style: gCaps(10.5, color: G.text))),
            ?trailing,
          ]),
          const SizedBox(height: 6),
          ...children,
        ]),
      );
}

/// A small orange-tinted tag ("From a subagent", "In a terminal").
class GlassTag extends StatelessWidget {
  final String text;
  final IconData? icon;
  const GlassTag(this.text, {super.key, this.icon});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(99), color: const Color(0x33F7532B)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 12, color: G.glow), const SizedBox(width: 4)],
          Text(text, style: gSans(11.5, FontWeight.w700, color: G.glow, height: 1.1)),
        ]),
      );
}

/// A dark well for code, commands and paths.
class CodeWell extends StatelessWidget {
  final Widget child;
  const CodeWell({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0x661B1519),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x1FFFFFFF)),
        ),
        child: child,
      );
}

/// Reports its child's size after each layout that changes it.
class MeasureSize extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onChange;
  const MeasureSize({super.key, required this.onChange, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => RenderMeasureSize(onChange);
  @override
  void updateRenderObject(BuildContext context, RenderMeasureSize renderObject) => renderObject.onChange = onChange;
}

class RenderMeasureSize extends RenderProxyBox {
  ValueChanged<Size> onChange;
  Size? _last;
  RenderMeasureSize(this.onChange);
  @override
  void performLayout() {
    super.performLayout();
    if (size == _last) return;
    _last = size;
    final s = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(s));
  }
}

/// The chevron icon used on rows that open something.
const chevron = Icon(Icons.chevron_right_rounded, color: G.muted);
