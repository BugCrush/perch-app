// Claude's questions as a deck on glass: one page per question (swipe or tap the dots),
// then the answers with Submit.
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../glass/mosaic.dart';
import '../glass/palette.dart';
import '../glass/pressable.dart';
import '../glass/widgets.dart';
import 'question_model.dart';
import '../glass/click.dart';

class QuestionDeck extends StatefulWidget {
  final PromptRequest prompt;
  final void Function(QuestionAnswer) onSubmit;
  const QuestionDeck({super.key, required this.prompt, required this.onSubmit});

  @override
  State<QuestionDeck> createState() => _QuestionDeckState();
}

class _QuestionDeckState extends State<QuestionDeck> {
  late final QuestionModel _q = QuestionModel(widget.prompt.input);
  late final List<TextEditingController> _other = [for (final _ in _q.questions) TextEditingController()];

  @override
  void dispose() {
    _q.dispose();
    for (final c in _other) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final a = _q.submit();
    if (a == null) {
      buzz(Haptic.heavy);
      return;
    }
    buzz(Haptic.medium);
    widget.onSubmit(a);
  }

  /// 1 when the last page change went forward, -1 when it went back.
  double _direction = 1;
  int _shown = 0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _q,
        builder: (context, _) {
          final n = _q.questions.length;
          final review = _q.onReview;
          final i = _q.page;
          if (i != _shown) {
            _direction = i > _shown ? 1 : -1;
            _shown = i;
          }
          return ClickDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v < -150) _q.go(_q.page + 1);
              if (v > 150) _q.go(_q.page - 1);
            },
            child: GlassPanel(
              caption: review ? 'YOUR ANSWERS' : 'CLAUDE ASKS · ${i + 1} OF $n',
              children: [
                // Pages slide like a deck, the review with Submit too: forward to the left,
                // back to the right.
                ClipRect(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 320),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (c, a) {
                      final incoming = c.key == ValueKey(review ? 'review' : 'q$i');
                      final from = Offset((incoming ? 1 : -1) * _direction, 0);
                      return SlideTransition(
                        position: Tween(begin: from, end: Offset.zero).animate(a),
                        child: FadeTransition(opacity: a, child: c),
                      );
                    },
                    layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [
                      ...previous.map((p) => Positioned(left: 0, right: 0, top: 0, child: p)),
                      ?current,
                    ]),
                    child: review ? _review() : _question(i),
                  ),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  for (var p = 0; p < _q.pages; p++)
                    ClickDetector(
                      key: ValueKey('deck-dot-$p'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        buzz(Haptic.selection);
                        _q.go(p);
                      },
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 6, 9, 6),
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: p == _q.page
                                ? Perch.orange
                                : ((p < n ? _q.answerOf(p).isNotEmpty : _q.submitted) ? G.text : const Color(0x4DFFFFFF)),
                          ),
                        ),
                      ),
                    ),
                  const Spacer(),
                  // A single choice moves on by itself; multi-select and Other need a Next.
                  if (!review && (_q.questions[i].multiSelect || _q.otherOn(i)))
                    GlassButton(label: 'Next', icon: Icons.arrow_forward_rounded, compact: true, onTap: () => _q.go(i + 1)),
                ]),
              ],
            ),
          );
        },
      );

  Widget _option(int i, String label, String description, bool selected, bool multi, VoidCallback onTap) =>
      ClickDetector(
        key: ValueKey('option-$i-$label'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          buzz(Haptic.selection);
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: selected ? const Color(0x40F7532B) : const Color(0x14FFFFFF),
            border: Border.all(color: selected ? const Color(0xFFFF9A78) : const Color(0x26FFFFFF)),
          ),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: gSans(15, FontWeight.w700)),
                if (description.isNotEmpty) Text(description, style: gSans(12.5, FontWeight.w500, color: G.muted)),
              ]),
            ),
            Icon(
              selected
                  ? (multi ? Icons.check_box_rounded : Icons.radio_button_checked_rounded)
                  : (multi ? Icons.check_box_outline_blank_rounded : Icons.radio_button_unchecked_rounded),
              color: selected ? const Color(0xFFFF9A78) : G.muted,
              size: 22,
            ),
          ]),
        ),
      );

  Widget _question(int i) {
    final q = _q.questions[i];
    return Column(key: ValueKey('q$i'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (q.header.isNotEmpty) Align(alignment: Alignment.centerLeft, child: GlassTag(q.header)),
      if (q.header.isNotEmpty) const SizedBox(height: 6),
      Text(q.question, style: gSerif(21, w: FontWeight.w600, height: 1.25)),
      if (_q.nudge == i) Text('Answer this one to continue', style: gSans(12.5, FontWeight.w700, color: G.glow)),
      if (q.multiSelect) Text('Choose any', style: gSans(12.5, FontWeight.w500, color: G.muted)),
      const SizedBox(height: 10),
      for (final o in q.options)
        _option(i, o.label, o.description, _q.isChosen(i, o.label), q.multiSelect, () => _q.choose(i, o.label)),
      _option(i, 'Other', 'Type your own answer', _q.otherOn(i), q.multiSelect, () => _q.toggleOther(i)),
      if (_q.otherOn(i))
        GlassField(
          key: ValueKey('other-$i'),
          controller: _other[i],
          hint: 'Your answer',
          autofocus: true,
          onChanged: (t) => _q.setOther(i, t),
        ),
    ]);
  }

  Widget _review() => Column(key: const ValueKey('review'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < _q.questions.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_q.questions[i].question, style: gSans(12.5, FontWeight.w500, color: G.muted)),
              Text(_q.answerOf(i).isEmpty ? 'Not answered' : _q.answerOf(i),
                  style: gSerif(19, w: FontWeight.w600, color: _q.answerOf(i).isEmpty ? G.glow : G.text)),
            ]),
          ),
        GlassButton(label: 'Submit', warm: true, onTap: _q.submitted ? null : _submit),
      ]);
}
