// The permission, plan and trust-this-folder cards on glass. Each answers once; the session
// screen builds it afresh (a new key) when the host could not use the answer.
import 'package:flutter/widgets.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:perch_protocol/perch_protocol.dart';

import '../conversation.dart' show glassMarkdown, prettyJson;
import '../glass/mosaic.dart';
import '../glass/widgets.dart';

/// Tool name the host uses for Claude Code's "trust this folder" dialog.
const trustFolderTool = 'TrustFolder';

const _shellTools = {'Bash', 'PowerShell'};

/// A permission request: exactly what Claude wants to run, with Claude Code's choices.
class PermissionCard extends StatefulWidget {
  final PromptRequest prompt;
  final void Function(PermissionAnswer) onAnswer;
  const PermissionCard({super.key, required this.prompt, required this.onAnswer});

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard> {
  bool _denying = false;
  bool _done = false;
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _answer(PermissionAnswer a) {
    if (_done) return;
    setState(() => _done = true);
    widget.onAnswer(a);
  }

  Widget _body() {
    final input = widget.prompt.input;
    final command = input['command'];
    if (_shellTools.contains(widget.prompt.toolName) || command is String) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (input['description'] is String) ...[
          Text('${input['description']}', style: gSerif(19, w: FontWeight.w600, height: 1.3)),
          const SizedBox(height: 10),
        ],
        CodeWell(child: Text('${command ?? ''}', style: gMono(13))),
      ]);
    }
    final path = input['file_path'];
    if (path is String) {
      final preview = [input['content'], input['new_string'], input['old_string']].whereType<String>().firstOrNull;
      return CodeWell(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(path, style: gMono(13).copyWith(fontWeight: FontWeight.w700, color: G.glow)),
          if (preview != null) ...[
            const SizedBox(height: 6),
            Text(preview.length > 2000 ? '${preview.substring(0, 2000)}…' : preview, style: gMono(12.5)),
          ],
        ]),
      );
    }
    return CodeWell(child: Text(prettyJson(input), style: gMono(12.5)));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.prompt;
    final on = !_done;
    return GlassPanel(
      caption: 'PERMISSION · ${p.toolName.toUpperCase()}',
      trailing: p.parentToolUseId != null ? const GlassTag('From a subagent') : null,
      children: [
        Text('Claude wants to use ${p.toolName}', style: gSerif(22, w: FontWeight.w600, height: 1.25)),
        const SizedBox(height: 10),
        ConstrainedBox(constraints: const BoxConstraints(maxHeight: 220), child: SingleChildScrollView(child: _body())),
        const SizedBox(height: 14),
        if (_denying) ...[
          GlassField(controller: _reason, label: 'Reason (optional)', hint: 'Tell Claude why'),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: GlassButton(label: 'Back', onTap: on ? () => setState(() => _denying = false) : null)),
            const SizedBox(width: 10),
            Expanded(
              child: GlassButton(
                label: 'Send denial',
                warm: true,
                onTap: on
                    ? () => _answer(
                        PermissionAnswer(allow: false, message: _reason.text.trim().isEmpty ? null : _reason.text.trim()))
                    : null,
              ),
            ),
          ]),
        ] else ...[
          if (p.suggestions.isNotEmpty) ...[
            GlassButton(
                label: 'Always allow', onTap: on ? () => _answer(const PermissionAnswer(allow: true, always: true)) : null),
            const SizedBox(height: 8),
          ],
          Row(children: [
            Expanded(child: GlassButton(label: 'Deny', onTap: on ? () => setState(() => _denying = true) : null)),
            const SizedBox(width: 10),
            Expanded(
                child: GlassButton(
                    label: 'Allow', warm: true, onTap: on ? () => _answer(const PermissionAnswer(allow: true)) : null)),
          ]),
        ],
      ],
    );
  }
}

/// A plan to approve, or to send back with what should change.
class PlanCard extends StatefulWidget {
  final PromptRequest prompt;
  final void Function(PlanAnswer) onAnswer;
  const PlanCard({super.key, required this.prompt, required this.onAnswer});

  @override
  State<PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<PlanCard> {
  bool _feedbackOpen = false;
  bool _done = false;
  String? _error;
  final _feedback = TextEditingController();
  static final _sheet = glassMarkdown(body: gSerif(15.5, height: 1.45), heading: gSerif(21, w: FontWeight.w600, height: 1.25));

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  void _answer(PlanAnswer a) {
    if (_done) return;
    setState(() => _done = true);
    widget.onAnswer(a);
  }

  void _sendFeedback() {
    final text = _feedback.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Tell Claude what to change');
      return;
    }
    _answer(PlanAnswer(approve: false, feedback: text));
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.prompt.input['plan'];
    final on = !_done;
    return GlassPanel(caption: 'A PLAN TO APPROVE', children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 260),
        child: SingleChildScrollView(child: MarkdownBody(data: plan is String ? plan : '', styleSheet: _sheet)),
      ),
      const SizedBox(height: 14),
      if (_feedbackOpen) ...[
        GlassField(
          controller: _feedback,
          label: 'What should change?',
          minLines: 1,
          maxLines: 4,
          error: _error,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: GlassButton(label: 'Send feedback', warm: true, onTap: on ? _sendFeedback : null),
        ),
      ] else
        Row(children: [
          Expanded(child: GlassButton(label: 'Keep planning', onTap: on ? () => setState(() => _feedbackOpen = true) : null)),
          const SizedBox(width: 10),
          Expanded(
              child: GlassButton(label: 'Approve', warm: true, onTap: on ? () => _answer(const PlanAnswer(approve: true)) : null)),
        ]),
    ]);
  }
}

/// Claude Code asks whether to trust a folder before it starts working there.
class TrustCard extends StatefulWidget {
  final PromptRequest prompt;
  final void Function(PermissionAnswer) onAnswer;
  const TrustCard({super.key, required this.prompt, required this.onAnswer});

  @override
  State<TrustCard> createState() => _TrustCardState();
}

class _TrustCardState extends State<TrustCard> {
  bool _done = false;

  void _answer(bool allow) {
    if (_done) return;
    setState(() => _done = true);
    widget.onAnswer(PermissionAnswer(allow: allow));
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.prompt.input['path'];
    final on = !_done;
    return GlassPanel(caption: 'BEFORE CLAUDE STARTS', children: [
      Text('Trust this folder?', style: gSerif(22, w: FontWeight.w600, height: 1.25)),
      const SizedBox(height: 10),
      CodeWell(child: Text(path is String ? path : '', style: gMono(13))),
      const SizedBox(height: 8),
      Text('Claude Code will be able to read, edit and run files here.', style: gSans(14, FontWeight.w500, color: G.muted)),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: GlassButton(label: "Don't trust", onTap: on ? () => _answer(false) : null)),
        const SizedBox(width: 10),
        Expanded(child: GlassButton(label: 'Trust', warm: true, onTap: on ? () => _answer(true) : null)),
      ]),
    ]);
  }
}
