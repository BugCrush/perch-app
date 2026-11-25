// A session's conversation, read like an essay: the owner's messages as pull quotes,
// Claude's replies in serif, tools as quiet captions that open on tap, subagents as asides.
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../time_format.dart';
import 'glass/mosaic.dart';
import 'glass/palette.dart';
import 'glass/pressable.dart';
import 'glass/widgets.dart';
import 'glass/click.dart';

/// Whether a note says a session resumed after a usage limit but not the same way (the
/// host writes it into the conversation; it stays as a lasting note).
bool isResumedChangedNote(String text) =>
    text.startsWith('Resumed without the subagent') || text.startsWith('Resumed with a different agent');

/// One line summary of a tool call's input.
String toolSummary(Map<String, dynamic> input) {
  for (final k in ['command', 'file_path', 'pattern', 'description']) {
    final v = input[k];
    if (v is String && v.isNotEmpty) return _oneLine(v);
  }
  for (final v in input.values) {
    if (v is String && v.isNotEmpty) return _oneLine(v);
  }
  return '';
}

String _oneLine(String s) {
  final first = s.split('\n').first.trim();
  return first.length > 120 ? '${first.substring(0, 120)}…' : first;
}

String prettyJson(Object? v) {
  try {
    return const JsonEncoder.withIndent('  ').convert(v);
  } catch (_) {
    return '$v';
  }
}

/// A markdown style sheet in Memory Glass's type. Every style flutter_markdown uses is set
/// here: on its own it would fall back to Material's default light theme.
MarkdownStyleSheet glassMarkdown({required TextStyle body, TextStyle? heading}) {
  final h = heading ?? body.copyWith(fontWeight: FontWeight.w700, fontSize: (body.fontSize ?? 16) + 3, height: 1.3);
  final code = gMono((body.fontSize ?? 16) * 0.8, color: G.glow);
  return MarkdownStyleSheet(
    p: body,
    pPadding: EdgeInsets.zero,
    a: body.copyWith(color: G.glow, decoration: TextDecoration.underline, decorationColor: G.glow),
    code: code.copyWith(backgroundColor: const Color(0x00000000)),
    h1: h,
    h2: h,
    h3: h.copyWith(fontSize: (h.fontSize ?? 18) - 1),
    h1Padding: const EdgeInsets.only(bottom: 2),
    h2Padding: const EdgeInsets.only(bottom: 2),
    h3Padding: EdgeInsets.zero,
    h4: body.copyWith(fontWeight: FontWeight.w700),
    h4Padding: EdgeInsets.zero,
    h5: body.copyWith(fontWeight: FontWeight.w700),
    h5Padding: EdgeInsets.zero,
    h6: body.copyWith(fontWeight: FontWeight.w700),
    h6Padding: EdgeInsets.zero,
    em: const TextStyle(fontStyle: FontStyle.italic),
    strong: TextStyle(fontWeight: FontWeight.w800, fontVariations: const [FontVariation('wght', 800)], color: body.color),
    del: const TextStyle(decoration: TextDecoration.lineThrough),
    blockquote: body.copyWith(color: G.muted),
    blockquotePadding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
    blockquoteDecoration: const BoxDecoration(border: Border(left: BorderSide(color: G.muted, width: 2))),
    img: body,
    checkbox: body.copyWith(color: G.glow),
    blockSpacing: 10,
    listIndent: 24,
    listBullet: body.copyWith(color: G.glow, fontWeight: FontWeight.w800),
    listBulletPadding: const EdgeInsets.only(right: 6),
    tableHead: gSans(14, FontWeight.w700),
    tableBody: gSans(14, FontWeight.w500),
    tableHeadAlign: TextAlign.left,
    tablePadding: const EdgeInsets.only(bottom: 4),
    tableBorder: TableBorder.all(color: const Color(0x33FFFFFF)),
    tableColumnWidth: const FlexColumnWidth(),
    tableCellsPadding: const EdgeInsets.all(6),
    tableCellsDecoration: const BoxDecoration(),
    codeblockPadding: const EdgeInsets.all(14),
    codeblockDecoration: BoxDecoration(
      color: const Color(0xFF1B1519),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0x1FFFFFFF)),
    ),
    horizontalRuleDecoration: const BoxDecoration(border: Border(top: BorderSide(width: 1, color: Color(0x33FFFFFF)))),
  );
}

/// Claude's reply text.
final assistantMarkdown = glassMarkdown(body: gSerif(17.5, height: 1.55));

/// Renders one conversation event.
class EventView extends StatelessWidget {
  final ConversationEvent event;

  /// For a ToolCall: its result, if it has arrived.
  final ToolResult? result;

  const EventView(this.event, {super.key, this.result});

  @override
  Widget build(BuildContext context) {
    final e = event;
    switch (e) {
      case UserMessage(:final text):
        return Container(
          padding: const EdgeInsets.only(left: 14),
          decoration: const BoxDecoration(border: Border(left: BorderSide(color: Perch.orange, width: 2.5))),
          child: Text(text, style: gSerif(20, style: FontStyle.italic, height: 1.35)),
        );
      case AssistantText(:final text):
        return MarkdownBody(data: text, styleSheet: assistantMarkdown);
      case ToolCall():
        return ToolCallView(call: e, result: result);
      case ToolResult():
        // A result without a matching call.
        return ResultView(result: e);
      case SubagentStarted(:final description, :final subagentType):
        return Text('Subagent · $subagentType · $description', style: gCaps(10.5));
      case SubagentFinished():
        return const SizedBox.shrink();
      case TurnEnded(:final isError, :final text):
        if (!isError) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: const Color(0x33F7532B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0x66F7532B)),
          ),
          child: Text(text.isEmpty ? 'The turn ended with an error' : 'Stopped: $text',
              style: gSans(14, FontWeight.w600, color: G.glow)),
        );
      case Notice(:final text) when isResumedChangedNote(text):
        // A lasting note: the work did not carry on the same way after a usage limit.
        return Container(
          key: const ValueKey('resumed-changed-note'),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: const Color(0x33F7532B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0x66F7532B)),
          ),
          child: Row(children: [
            const Icon(Icons.call_split_rounded, size: 18, color: G.glow),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: gSans(14, FontWeight.w700, color: G.glow))),
            Text(formatIst(event.atMs), style: gSans(12, FontWeight.w600, color: G.muted)),
          ]),
        );
      case SlashCommand():
        // The owner's command, like their messages: the orange rule, the command as a chip.
        return Container(
          key: ValueKey('command-${e.seq}'),
          padding: const EdgeInsets.only(left: 14),
          decoration: const BoxDecoration(border: Border(left: BorderSide(color: Perch.orange, width: 2.5))),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: const Color(0x33F7532B),
                border: Border.all(color: const Color(0x80F7532B)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.terminal_rounded, size: 15, color: G.glow),
                const SizedBox(width: 6),
                Flexible(child: Text(e.line, style: gMono(14, color: G.text, height: 1.3))),
              ]),
            ),
          ),
        );
      case CommandOutput():
        return CommandOutputView(output: e);
      case Notice(:final text):
        return Center(
          child: Text('— $text —', textAlign: TextAlign.center, style: gSerif(14.5, style: FontStyle.italic, color: G.muted)),
        );
    }
  }
}

/// The caption a tool call shows while closed.
String toolCaption(ToolCall c) {
  final summary = toolSummary(c.input);
  return summary.isEmpty ? c.name : '${c.name} · $summary';
}

/// A tool call: a quiet caption that opens on tap to its input and result.
class ToolCallView extends StatefulWidget {
  final ToolCall call;
  final ToolResult? result;
  const ToolCallView({super.key, required this.call, this.result});
  @override
  State<ToolCallView> createState() => _ToolCallViewState();
}

class _ToolCallViewState extends State<ToolCallView> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.call;
    final error = widget.result?.isError == true;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Pressable(
        haptic: Haptic.selection,
        semanticLabel: toolCaption(c),
        onTap: () => setState(() => _open = !_open),
        builder: (context, p, child) => Opacity(opacity: 1 - p.clamp(0, 1) * 0.3, child: child),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Icon(_open ? Icons.remove_rounded : Icons.add_rounded, size: 15, color: G.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(toolCaption(c),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: gMono(12.5, color: G.muted, height: 1.3)),
            ),
            if (error) const Icon(Icons.error_outline_rounded, size: 16, color: G.glow),
          ]),
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: !_open
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.only(top: 8),
                child: CodeWell(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(prettyJson(c.input), style: gMono(12, color: G.muted)),
                    if (widget.result != null) ...[
                      Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 10), color: const Color(0x26FFFFFF)),
                      ResultView(result: widget.result!),
                    ],
                  ]),
                ),
              ),
      ),
    ]);
  }
}

/// A tool's output.
class ResultView extends StatelessWidget {
  final ToolResult result;
  const ResultView({super.key, required this.result});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(result.text, style: gMono(12, color: result.isError ? G.glow : G.text)),
        if (result.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Output cut at 20,000 characters', style: gSans(12, FontWeight.w600, color: G.muted)),
          ),
      ]);
}

/// A subagent's work, kept together as an aside where it started.
class SubagentAside extends StatelessWidget {
  final SubagentStarted? started;
  final bool finished;
  final List<Widget> children;
  const SubagentAside({super.key, required this.started, required this.finished, required this.children});

  /// The caption over the aside.
  static String caption(SubagentStarted? st, bool finished) =>
      st == null ? 'Subagent' : 'Subagent · ${st.subagentType}${finished ? ' · Finished' : ''}';

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(color: const Color(0x0FFFFFFF), borderRadius: BorderRadius.circular(20)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(caption(started, finished), style: gCaps(10.5)),
          if (started != null && started!.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(started!.description, style: gSerif(18, w: FontWeight.w600, height: 1.3)),
          ],
          for (final c in children) Padding(padding: const EdgeInsets.only(top: 12), child: c),
        ]),
      );
}


/// Whether [text] holds a markdown table (a `|` row followed by a `|---|` line).
bool hasMarkdownTable(String text) => RegExp(r'^\s*\|.*\|\s*\n\s*\|[\s:|-]*-[\s:|-]*\|?\s*$', multiLine: true).hasMatch(text);

/// Whether [text] is laid out in columns for a terminal: three or more lines wider than a
/// phone shows in the code font.
bool laidOut(String text) => text.split('\n').where((l) => l.length > 48).length >= 3;

/// What a slash command printed: a code well in the code font, markdown tables drawn as
/// tables; long output folds after [foldAt] lines (a tap opens it all).
class CommandOutputView extends StatefulWidget {
  final CommandOutput output;
  final int foldAt;
  const CommandOutputView({super.key, required this.output, this.foldAt = 40});
  @override
  State<CommandOutputView> createState() => _CommandOutputViewState();
}

class _CommandOutputViewState extends State<CommandOutputView> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final o = widget.output;
    final lines = o.text.split('\n');
    final folded = !_open && lines.length > widget.foldAt;
    final text = folded ? lines.take(widget.foldAt).join('\n') : o.text;
    final color = o.isError ? G.glow : G.text;
    final Widget body = hasMarkdownTable(text)
        ? MarkdownBody(
            data: text,
            styleSheet: glassMarkdown(body: gMono(12.5, color: color)).copyWith(
              tableHead: gMono(12, color: color).copyWith(fontWeight: FontWeight.w700),
              tableBody: gMono(12, color: color),
            ))
        : laidOut(text)
            // Laid out in columns (the /context grid and its legend): kept as is, scrolled
            // sideways rather than wrapped.
            ? SingleChildScrollView(
                key: const ValueKey('command-output-wide'),
                scrollDirection: Axis.horizontal,
                child: Text(text, style: gMono(11.5, color: color), softWrap: false))
            : Text(text, style: gMono(12.5, color: color));
    return Container(
      key: ValueKey('command-output-${o.seq}'),
      margin: const EdgeInsets.only(left: 16.5),
      child: CodeWell(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          body,
          if (lines.length > widget.foldAt)
            ClickDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(folded ? 'Show all ${lines.length} lines' : 'Show less',
                    style: gSans(12.5, FontWeight.w800, color: G.glow)),
              ),
            ),
        ]),
      ),
    );
  }
}
