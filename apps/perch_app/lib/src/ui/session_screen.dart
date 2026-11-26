// A session: its picture on top, then the conversation read like an essay, with Claude's
// open card and the composer floating on glass at the bottom.
import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Icons, SelectionArea;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/attachment_upload.dart';
import '../connection/host_connection.dart';
import '../time_format.dart';
import 'cards/prompt_cards.dart';
import 'cards/question_deck.dart';
import 'conversation.dart';
import 'glass/dots.dart';
import 'glass/mosaic.dart';
import 'glass/widgets.dart';
import 'labels.dart';
import 'session_menu.dart';
import 'session_row.dart' show prefsOf;
import 'board_screen.dart' show openSessionBoard;
import 'glass/click.dart';
import 'drafts.dart';
import 'usage_limit_card.dart' show UsageLimitCard;
import 'attachment_chips.dart';
import 'sent_attachments.dart';

/// Perch's own command (the host lists it with the session's commands).
const perchCommandName = '/perch';

/// One item of the rendered conversation: an event, or a subagent group.
sealed class _Item {
  /// The seq of the event that put this item in the list.
  int get seq;
}

class _EventItem extends _Item {
  final ConversationEvent event;
  _EventItem(this.event);
  @override
  int get seq => event.seq;
}

class _GroupItem extends _Item {
  final String parent;
  @override
  final int seq;
  SubagentStarted? started;
  bool finished = false;
  final List<ConversationEvent> children = [];
  _GroupItem(this.parent, this.seq);
}

/// Groups subagent events under their SubagentStarted header, at the place the
/// subagent started; pairs tool results with their calls.
({List<_Item> items, Map<String, ToolResult> results}) _layout(List<ConversationEvent> events) {
  final items = <_Item>[];
  final groups = <String, _GroupItem>{};
  final results = <String, ToolResult>{};
  final calls = <String>{};
  for (final e in events) {
    if (e is ToolCall) calls.add(e.toolUseId);
    if (e is ToolResult) results[e.toolUseId] = e;
  }
  _GroupItem groupFor(String parent, int seq) => groups.putIfAbsent(parent, () {
        final g = _GroupItem(parent, seq);
        items.add(g);
        return g;
      });
  final taskToParent = <String, String>{};
  for (final e in events) {
    if (e is SubagentStarted) {
      final g = groupFor(e.toolUseId, e.seq);
      g.started = e;
      taskToParent[e.taskId] = e.toolUseId;
      continue;
    }
    if (e is SubagentFinished) {
      final parent = taskToParent[e.taskId];
      if (parent != null) groups[parent]?.finished = true;
      continue;
    }
    if (e is ToolResult && calls.contains(e.toolUseId)) continue; // shown inside its call
    final parent = e.parentToolUseId;
    if (parent != null) {
      groupFor(parent, e.seq).children.add(e);
    } else {
      items.add(_EventItem(e));
    }
  }
  return (items: items, results: results);
}

class SessionScreen extends StatefulWidget {
  final HostConnection connection;
  final String sessionId;

  /// The current time (replaced in tests); times are shown in IST.
  final DateTime Function() clock;

  /// `/perch` picked or sent in the composer: the app's own board for the session's
  /// project opens (nothing goes to the terminal). Replaced in tests.
  final void Function(BuildContext context, HostConnection connection, String cwd) openPerch;

  /// Where attachments come from (null: the phone's photo and file pickers).
  final AttachmentPicker? picker;
  const SessionScreen(
      {super.key,
      required this.connection,
      required this.sessionId,
      this.clock = DateTime.now,
      this.openPerch = openSessionBoard,
      this.picker});

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  late final SessionFeed _feed;
  final _text = TextEditingController();
  final _scroll = ScrollController();

  /// The attachments of the message being written (uploading as soon as picked).
  late final AttachmentUploader _uploads;
  StreamSubscription<ErrorMessage>? _errors;
  bool _stickToBottom = true;

  /// Scrolled up from the newest message: the go-to-bottom button shows.
  final _showDown = ValueNotifier<bool>(false);

  /// Items from this seq on sit below the scroll view's center; older ones (loaded later)
  /// grow upwards above it, so prepending them does not move what is on screen.
  int? _anchorSeq;
  final _centerKey = GlobalKey();

  /// The height of what floats at the bottom (banner, card, composer): the conversation
  /// ends above it.
  double _bottom = 80;

  /// The last text sent to a terminal session, kept in case the host cannot type it
  /// (`cannotType`) or a take-over finds Claude busy (`sessionBusy`).
  String? _pendingText;

  HostConnection get conn => widget.connection;

  /// The session's slash commands (asked for when the owner first types `/`).
  List<SlashCommandInfo>? _commands;
  bool _askedCommands = false;

  /// What the composer's `/` list shows now (empty: the list is closed).
  List<SlashCommandInfo> get _suggestions {
    final t = _text.text;
    if (!t.startsWith('/') || t.contains(RegExp(r'\s'))) return const [];
    return matchCommands(_commands ?? const [], t).take(40).toList();
  }

  /// The last files the host listed for an `@` mention, and for which text after the `@`.
  List<FileMention> _files = const [];
  String? _filesQuery;

  /// One request at a time: what is typed meanwhile is asked for when it answers.
  bool _filesAsking = false;

  /// An older host lists no files: the composer stops asking.
  bool _filesUnsupported = false;

  /// The `@` mention the cursor is in, if any.
  ({int start, String query})? get _mention {
    final sel = _text.selection;
    final at = sel.isValid && sel.isCollapsed ? sel.baseOffset : _text.text.length;
    return mentionAt(_text.text, at);
  }

  /// What the composer's `@` list shows now (empty: the list is closed): the host's last
  /// answer, narrowed at once to what is typed since.
  List<FileMention> get _fileSuggestions {
    final m = _mention;
    if (m == null || _files.isEmpty) return const [];
    return matchFiles(_files, m.query, limit: 40);
  }

  void _askFiles(String query) {
    if (_filesAsking || _filesUnsupported || query == _filesQuery) return;
    _filesAsking = true;
    conn.listFiles(widget.sessionId, query).then((found) {
      _filesAsking = false;
      if (!mounted) return;
      if (found == null) {
        _filesUnsupported = true;
        return;
      }
      setState(() {
        _files = found;
        _filesQuery = query;
      });
      final now = _mention?.query;
      if (now != null && now != query) _askFiles(now);
    });
  }

  /// A tap on a file: `@path ` replaces what was typed after the `@`; a folder goes in as
  /// `@folder/` and the list moves into it.
  void _pickFile(FileMention f) {
    final m = _mention;
    if (m == null) return;
    final sel = _text.selection;
    final end = sel.isValid && sel.isCollapsed ? sel.baseOffset : _text.text.length;
    final insert = f.dir ? f.mention : '${f.mention} ';
    final text = _text.text.replaceRange(m.start, end, insert);
    _text.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: m.start + insert.length));
  }

  void _onTyped() {
    final t = _text.text;
    Drafts.set(conn.machine.id, widget.sessionId, t);
    final m = _mention;
    if (m != null) _askFiles(m.query);
    if (t.startsWith('/') && !_askedCommands) {
      _askedCommands = true;
      conn.listCommands(widget.sessionId).then((c) {
        if (!mounted) return;
        setState(() => _commands = c);
        if (c.isEmpty) _askedCommands = false;
      });
    }
    setState(() {});
  }

  void _pickCommand(SlashCommandInfo c) {
    if (c.name == perchCommandName) {
      _openPerch();
      return;
    }
    final text = '${c.name} ';
    _text.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  @override
  void initState() {
    super.initState();
    // A message typed here earlier and not sent comes back (kept on the phone).
    _text.text = Drafts.get(conn.machine.id, widget.sessionId);
    _text.addListener(_onTyped);
    _uploads = AttachmentUploader(conn)..addListener(_onUploads);
    _feed = conn.feed(widget.sessionId);
    // While this screen is open the host sends this device no notification for it.
    conn.focusSession(widget.sessionId);
    _feed.events.addListener(_onEvents);
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final p = _scroll.position;
      if (_gliding) return;
      _stickToBottom = p.pixels >= p.maxScrollExtent - 80;
      _showDown.value = _bottomTarget() - p.pixels > 160;
      // Near the top (the picture and the Load earlier pill) with older events on the host:
      // fetch them.
      if (_feed.hasEarlier.value && p.pixels <= p.minScrollExtent + 500) conn.loadEarlier(widget.sessionId);
    });
    _errors = conn.errors.listen(_onError);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  @override
  void dispose() {
    _feed.events.removeListener(_onEvents);
    conn.unfocusSession(widget.sessionId);
    _errors?.cancel();
    unawaited(Drafts.flush());
    _uploads.dispose();
    _text.dispose();
    _scroll.dispose();
    _showDown.dispose();
    super.dispose();
  }

  void _onEvents() {
    if (_stickToBottom) WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  /// Shows the end of the conversation right above the composer; a short conversation
  /// shows from its picture.
  void _jumpToBottom() {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.jumpTo(_bottomTarget());
    _stickToBottom = true;
  }

  /// Where the end of the conversation sits right above the composer: the very end of a
  /// conversation longer than the screen; a short one shows from its picture.
  double _bottomTarget() {
    final p = _scroll.position;
    final center = _centerKey.currentContext?.findRenderObject();
    if (center is RenderSliver && center.geometry != null && center.geometry!.scrollExtent < p.viewportDimension) {
      return (center.geometry!.scrollExtent - p.viewportDimension).clamp(p.minScrollExtent, p.maxScrollExtent);
    }
    return p.maxScrollExtent;
  }

  /// The go-to-bottom button is gliding down: the conversation counts as at its end.
  bool _gliding = false;

  /// The go-to-bottom button: glides back to the newest message. The list knows its exact
  /// length only near what it has laid out, and messages may arrive meanwhile: the end can
  /// move while it glides, so it goes on until it is really there.
  Future<void> _toBottom() async {
    if (!mounted || !_scroll.hasClients) return;
    _gliding = true;
    _stickToBottom = true;
    _showDown.value = false;
    try {
      for (var i = 0; i < 8 && mounted && _scroll.hasClients; i++) {
        final p = _scroll.position;
        final target = _bottomTarget();
        if ((target - p.pixels).abs() < 0.5) break;
        // The owner took over with a drag: stop.
        if (i > 0 && p.userScrollDirection != ScrollDirection.idle) return;
        await _scroll.animateTo(target,
            duration: Duration(milliseconds: i == 0 ? 320 : 140), curve: Curves.easeOutCubic);
      }
    } finally {
      _gliding = false;
    }
    if (!mounted || !_scroll.hasClients || _scroll.position.userScrollDirection != ScrollDirection.idle) return;
    _jumpToBottom();
    _settleAtBottom(24);
  }

  /// A few more frames: rows laid out only now can still lengthen the list.
  void _settleAtBottom(int frames) {
    if (frames <= 0 || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_stickToBottom) return;
      if (_scroll.position.pixels < _bottomTarget() - 0.5) _jumpToBottom();
      _settleAtBottom(frames - 1);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _onBottom(Size size) {
    if (!mounted || (size.height - _bottom).abs() < 0.5) return;
    setState(() => _bottom = size.height);
    if (_stickToBottom) WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  SessionSummary? get _session {
    for (final s in conn.sessions.value) {
      if (s.id == widget.sessionId) return s;
    }
    return null;
  }

  Future<void> _onError(ErrorMessage e) async {
    if (!mounted) return;
    final where = machineTitle(conn);
    switch (e.code) {
      case ErrorCodes.cannotType:
        final text = _pendingText;
        if (text == null) return;
        _pendingText = null;
        final ok = await confirmSheet(context,
            title: 'Perch cannot type into this terminal',
            body: 'Continue this session on your phone? It will close in the terminal on $where. '
                'Run claude --resume there to take it back.',
            yes: 'Continue');
        if (ok) {
          _pendingText = text;
          conn.takeOver(widget.sessionId);
          conn.send(widget.sessionId, text);
        }
      case ErrorCodes.sessionBusy:
        final text = _pendingText;
        if (text == null) return;
        _pendingText = null;
        final ok = await confirmSheet(context,
            title: 'Claude is busy',
            body: 'Claude is still working in the terminal. Stop it and continue here?',
            yes: 'Stop and continue');
        if (ok) {
          conn.takeOver(widget.sessionId, force: true);
          conn.send(widget.sessionId, text);
        }
      case ErrorCodes.terminalDialog:
        // Nothing was typed: one of Claude Code's own questions is on the screen. The text
        // goes back into the composer to send again once it is answered.
        final text = _pendingText;
        _pendingText = null;
        if (text != null && _text.text.trim().isEmpty) _text.text = text;
        say(context, 'Claude Code is asking something in the terminal on $where. Answer it there, then send again.');
      case ErrorCodes.cannotAnswerInTerminal:
        // The card stays; it is shown afresh so it can be used again.
        say(context, 'Answer this one in the terminal on $where');
        if (mounted) setState(() => _cardAttempt++);
      case ErrorCodes.promptAlreadyAnswered:
        say(context, 'Already answered on another device');
        final id = _answeredPromptId;
        if (id != null) conn.dropPrompt(widget.sessionId, id);
        _answeredPromptId = null;
      default:
        say(context, e.message);
    }
  }

  /// `/perch`: the board for this session's project, in the app.
  void _openPerch() {
    _text.clear();
    widget.openPerch(context, conn, _session?.cwd ?? '');
  }

  /// The machine's usage limit when it paused this session (null: not paused).
  UsageLimit? get _limitHere {
    final l = conn.usageLimit.value;
    if (l == null || conn.link.value != LinkState.online) return null;
    return l.sessions.any((x) => x.id == widget.sessionId) ? l : null;
  }

  void _onUploads() {
    if (mounted) setState(() {});
  }

  /// Picks a photo or a file and starts uploading it into the session's folder.
  Future<void> _attach() async {
    final picked = await pickAttachment(context, widget.picker ?? const SystemAttachmentPicker());
    if (picked == null || !mounted) return;
    _uploads.add(
        name: picked.name, bytes: picked.bytes, mime: picked.mime, sessionId: widget.sessionId, size: picked.size);
  }

  /// Send waits while an attachment uploads or has failed (Retry or Remove it first).
  bool get _attachmentsReady => !_uploads.uploading && !_uploads.hasFailed;

  void _send() {
    final typed = _text.text.trim();
    final paths = _uploads.donePaths;
    if (typed.isEmpty && paths.isEmpty) return;
    if (!_attachmentsReady) return;
    if (typed == perchCommandName && paths.isEmpty) {
      _openPerch();
      return;
    }
    final text = withAttachments(typed, paths);
    for (final a in _uploads.items) {
      final path = a.path;
      if (a.state == AttachmentState.done && path != null && a.isImage) {
        SentAttachmentCache.put(conn.machine.id, _session?.cwd ?? '', path, a.bytes);
      }
    }
    // A terminal session gets the message typed into it; keep it in case that fails.
    _pendingText = _session?.origin == SessionOrigin.external ? text : null;
    conn.send(widget.sessionId, text);
    _uploads.clear();
    _text.clear();
    _stickToBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  /// Stop: Claude is cut off mid-step, after a confirmation.
  Future<void> _stop() async {
    final name = _session?.name ?? '';
    if (!await confirmDanger(context,
        title: 'Stop Claude in ${name.isEmpty ? 'this session' : name}?',
        lost: 'What Claude is doing now is cut off mid-step and left unfinished. '
            'The session and its conversation stay; you can send a new message.',
        yes: 'Stop')) {
      return;
    }
    conn.interrupt(widget.sessionId);
  }

  void _continueOnPhone() {
    conn.takeOver(widget.sessionId, force: true);
    conn.send(widget.sessionId, 'please continue');
  }

  /// The prompt this device answered last (to drop its card if another device was first).
  String? _answeredPromptId;

  /// Bumped when the host could not answer in the terminal, to rebuild the card enabled.
  int _cardAttempt = 0;

  void _answer(PromptRequest p, PromptAnswer a) {
    _answeredPromptId = p.promptId;
    conn.answer(widget.sessionId, p.promptId, a);
  }

  /// The card for the newest open prompt, chosen by its kind.
  Widget? _promptCard(List<PromptRequest> prompts) {
    if (prompts.isEmpty) return null;
    final p = prompts.last;
    final key = ValueKey('${p.promptId}#$_cardAttempt');
    if (!conn.canControl) {
      // A watch-only device sees the card but cannot answer it.
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 4),
          child: Text(watchOnlyHint, key: const ValueKey('card-watch-only'), style: gSans(12.5, FontWeight.w600, color: G.muted)),
        ),
        AbsorbPointer(child: Opacity(opacity: 0.55, child: _cardFor(p, key))),
      ]);
    }
    return _cardFor(p, key);
  }

  Widget _cardFor(PromptRequest p, Key key) {
    return switch (p.kind) {
      PromptKind.question => QuestionDeck(key: key, prompt: p, onSubmit: (a) => _answer(p, a)),
      PromptKind.permission when p.toolName == trustFolderTool =>
        TrustCard(key: key, prompt: p, onAnswer: (a) => _answer(p, a)),
      PromptKind.permission => PermissionCard(key: key, prompt: p, onAnswer: (a) => _answer(p, a)),
      PromptKind.plan => PlanCard(key: key, prompt: p, onAnswer: (a) => _answer(p, a)),
    };
  }

  Widget _tile(_Item item, Map<String, ToolResult> results) => switch (item) {
        _EventItem(:final event) => EventView(
            event,
            key: ValueKey(event.seq),
            result: event is ToolCall ? results[event.toolUseId] : null,
            machineId: conn.machine.id,
            folder: _session?.cwd,
          ),
        final _GroupItem g => SubagentAside(
            key: ValueKey('group-${g.parent}'),
            started: g.started,
            finished: g.finished,
            children: [
              for (final e in g.children) EventView(e, key: ValueKey(e.seq), result: e is ToolCall ? results[e.toolUseId] : null),
            ],
          ),
      };

  /// The keyboard's height plus the composer's lift at the last build.
  double _keyboard = 0;

  @override
  Widget build(BuildContext context) {
    final outer = context;
    return ListenableBuilder(
      listenable:
          Listenable.merge([conn.sessions, _feed.events, _feed.openPrompts, _feed.hasEarlier, conn.displayName, conn.usageLimit]),
      builder: (context, _) {
        final s = _session;
        final state = s?.state ?? SessionState.idle;
        final external = s?.origin == SessionOrigin.external;
        final ended = state == SessionState.finished || state == SessionState.stopped;
        final working = state == SessionState.working && (s?.live ?? true);
        final events = _feed.events.value;
        if (_anchorSeq == null && events.isNotEmpty) _anchorSeq = events.first.seq;
        final layout = _layout(events);
        final anchor = _anchorSeq;
        var split = anchor == null ? 0 : layout.items.indexWhere((it) => it.seq >= anchor);
        if (split < 0) split = layout.items.length;
        final older = layout.items.sublist(0, split);
        final newer = layout.items.sublist(split);
        final hasEarlier = _feed.hasEarlier.value;
        final card = _promptCard(_feed.openPrompts.value);
        // Waiting with no card: only the terminal can show what Claude asks.
        final waitingInTerminal = external &&
            card == null &&
            (state == SessionState.waitingQuestion ||
                state == SessionState.waitingPermission ||
                state == SessionState.waitingPlan);
        const gap = 16.0;
        return GlassScaffold(
          bleedTop: true,
          background: ColoredBox(color: G.panel),
          // Measured inside the scaffold, which already shrinks above the keyboard: the bar
          // without a keyboard, nothing with one.
          child: Builder(builder: (context) {
            final lift = 10 + systemBottom(context);
            // The keyboard opening (or closing) or the navigation bar changing resizes the
            // conversation: the newest message stays right above the composer.
            final keyboard = MediaQuery.viewInsetsOf(outer).bottom + lift;
            if (keyboard != _keyboard) {
              _keyboard = keyboard;
              if (_stickToBottom) WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
            }
            return Stack(children: [
            Positioned.fill(
              // Long press selects text anywhere in the conversation; a drag scrolls.
              child: SelectionArea(
                child: CustomScrollView(
                controller: _scroll,
                center: _centerKey,
                slivers: [
                  // Before the center, laid out upwards: the picture on top, then older items.
                  SliverToBoxAdapter(child: _header(context, s, working)),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, gap),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        // Index 0 is the newest of the older items.
                        (context, i) => i == older.length
                            ? Padding(
                                padding: const EdgeInsets.only(top: 18, bottom: gap),
                                child: Center(
                                  child: GlassButton(
                                    key: const ValueKey('load-earlier'),
                                    label: 'Load earlier messages',
                                    compact: true,
                                    icon: Icons.expand_less_rounded,
                                    onTap: () => conn.loadEarlier(widget.sessionId),
                                  ),
                                ),
                              )
                            : Padding(
                                padding: const EdgeInsets.only(top: gap),
                                child: _tile(older[older.length - 1 - i], layout.results)),
                        childCount: older.length + (hasEarlier ? 1 : 0),
                      ),
                    ),
                  ),
                  SliverPadding(
                    key: _centerKey,
                    // The composer's height and its lift off the bottom: the newest message
                    // ends above it.
                    padding: EdgeInsets.fromLTRB(20, 0, 20, _bottom + lift + 8),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => i == newer.length
                            ? Padding(
                                padding: const EdgeInsets.only(top: gap),
                                child: Row(children: [
                                  const WorkingWave(width: 58, height: 24),
                                  const SizedBox(width: 12),
                                  Text('Claude is working…', style: gSerif(16.5, style: FontStyle.italic)),
                                ]),
                              )
                            : Padding(padding: const EdgeInsets.only(top: gap), child: _tile(newer[i], layout.results)),
                        childCount: newer.length + (working ? 1 : 0),
                      ),
                    ),
                  ),
                ],
              ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: lift,
              child: MeasureSize(
                onChange: _onBottom,
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  // A usage limit paused this session: its choices right here (the phone gets no
                  // notification for a session it shows).
                  if (_limitHere case final limit?)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: UsageLimitCard(key: const ValueKey('usage-limit-here'), connection: conn, limit: limit),
                    ),
                  if (waitingInTerminal)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Frost(
                        key: const ValueKey('waiting-in-terminal'),
                        tone: G.deep,
                        tint: 0.78,
                        rim: true,
                        radius: 24,
                        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                        child: Row(children: [
                          const Icon(Icons.terminal_rounded, size: 18, color: G.glow),
                          const SizedBox(width: 10),
                          Expanded(child: Text('Waiting for you in the terminal', style: gSans(14, FontWeight.w700))),
                          GlassButton(label: 'Continue on phone', compact: true, onTap: _continueOnPhone),
                        ]),
                      ),
                    ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 380),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.bottomCenter,
                    child: card == null
                        ? const SizedBox(width: double.infinity)
                        : ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.56),
                            child: SingleChildScrollView(
                                padding: const EdgeInsets.only(bottom: 10), child: SelectionArea(child: PixelReveal(child: card))),
                          ),
                  ),
                  if (_suggestions.isNotEmpty) _commandList(_suggestions),
                  if (_fileSuggestions.isNotEmpty) _fileList(_fileSuggestions),
                  _composer(working, ended),
                ]),
              ),
            ),
            // Scrolled up a little: a round arrow back to the newest message.
            Positioned(
              right: 18,
              bottom: lift + _bottom + 12,
              child: ValueListenableBuilder<bool>(
                valueListenable: _showDown,
                builder: (context, show, _) => IgnorePointer(
                  ignoring: !show,
                  child: AnimatedScale(
                    scale: show ? 1 : 0.6,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      opacity: show ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: show
                          ? GlassOrb(
                              key: const ValueKey('to-bottom'),
                              icon: Icons.keyboard_arrow_down_rounded,
                              label: 'Go to the newest message',
                              size: 44,
                              onTap: _toBottom,
                            )
                          : const SizedBox.square(dimension: 44),
                    ),
                  ),
                ),
              ),
            ),
          ]);
          }),
        );
      },
    );
  }

  Widget _header(BuildContext context, SessionSummary? s, bool working) {
    final top = MediaQuery.paddingOf(context).top;
    final now = widget.clock();
    final last = s?.lastPromptAtMs;
    final started = (s?.startedAtMs ?? 0) > 0 ? formatIst(s!.startedAtMs, now: now) : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The picture: the session's own mosaic, rounded off at the bottom.
      ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(34)),
        child: SizedBox(
          height: 250 + top,
          child: Stack(fit: StackFit.expand, children: [
            MosaicBackdrop(seed: seedOf(widget.sessionId), pixel: 0.95, cells: 26, flap: true),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0x00000000), Color(0xB31B1519)],
                  stops: [0, 0.45, 1],
                ),
              ),
            ),
            Positioned(
              left: 16,
              top: top + 6,
              child: GlassOrb(
                  key: const ValueKey('back'),
                  icon: Icons.arrow_back_rounded,
                  label: 'Back',
                  onTap: () => Navigator.of(context).maybePop()),
            ),
            Positioned(
              right: 16,
              top: top + 6,
              child: GlassOrb(
                key: const ValueKey('session-menu-button'),
                icon: Icons.more_horiz_rounded,
                label: 'Session menu',
                onTap: s == null
                    ? null
                    : () => showSessionMenu(context,
                        connection: conn,
                        session: s,
                        prefs: prefsOf(context),
                        onDeleted: () {
                          if (mounted) Navigator.of(context).maybePop();
                        }),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 18,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (working)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Frost(
                      radius: 99,
                      tone: G.deep,
                      tint: 0.5,
                      padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const WorkingWave(width: 30, height: 14, bars: 7),
                        const SizedBox(width: 8),
                        Text('Working', style: gSans(12.5, FontWeight.w700, height: 1)),
                      ]),
                    ),
                  ),
                Text(machineTitle(conn), style: gSans(12.5, FontWeight.w600).copyWith(shadows: lift)),
                Text(s == null || s.name.isEmpty ? 'Session' : s.name,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: gSerif(30, w: FontWeight.w500, height: 1.1).copyWith(shadows: lift)),
              ]),
            ),
          ]),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Row(children: [
          Expanded(
              child: _Meta(icon: Icons.schedule_rounded, value: last == null ? '—' : formatIst(last, now: now), label: 'Last message')),
          Expanded(child: _Meta(icon: Icons.folder_outlined, value: s == null ? '—' : lastFolder(s.cwd), label: 'Folder')),
          Expanded(
              child: _Meta(
                  icon: s?.origin == SessionOrigin.external ? Icons.terminal_rounded : Icons.play_arrow_rounded,
                  value: started ?? '—',
                  label: 'Started',
                  dots: started != null && !started.contains(' '))),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        child: Container(height: 1, color: const Color(0x1FFFFFFF)),
      ),
      if (s != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          child: Text(stateLabel(s).toUpperCase(), style: gCaps(11, color: needsAttentionNow(s) ? G.glow : G.muted)),
        ),
    ]);
  }

  /// The composer's `/` list: the commands matching what is typed, with what each does.
  Widget _commandList(List<SlashCommandInfo> items) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Frost(
          key: const ValueKey('command-list'),
          tone: G.deep,
          tint: 0.86,
          rim: true,
          radius: 22,
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.34),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final c in items)
                  ClickDetector(
                    key: ValueKey('command-suggestion-${c.name}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _pickCommand(c),
                    child: Semantics(
                      button: true,
                      label: '${c.name}, ${c.description}',
                      excludeSemantics: true,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 7, 14, 7),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Flexible(child: Text(c.name, style: gMono(13.5, color: G.glow))),
                            if (c.argumentHint.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Flexible(
                                  child: Text(c.argumentHint,
                                      style: gMono(12, color: G.muted), maxLines: 1, overflow: TextOverflow.ellipsis)),
                            ],
                            if (c.source != 'built-in') ...[const SizedBox(width: 8), GlassTag(c.source)],
                          ]),
                          if (c.description.isNotEmpty)
                            Text(c.description,
                                style: gSans(12.5, FontWeight.w500, color: G.muted),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );

  /// The composer's `@` list: files and folders of the session's folder (folders end in `/`).
  Widget _fileList(List<FileMention> items) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Frost(
          key: const ValueKey('mention-list'),
          tone: G.deep,
          tint: 0.86,
          rim: true,
          radius: 22,
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.34),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final f in items)
                  ClickDetector(
                    key: ValueKey('mention-suggestion-${f.path}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _pickFile(f),
                    child: Semantics(
                      button: true,
                      label: f.dir ? 'Folder ${f.path}' : 'File ${f.path}',
                      excludeSemantics: true,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 14, 8),
                        child: Row(children: [
                          Icon(f.dir ? Icons.folder_outlined : Icons.description_outlined,
                              size: 17, color: f.dir ? G.glow : G.muted),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(f.dir ? '${f.path}/' : f.path,
                                style: gMono(13, color: f.dir ? G.glow : G.text),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );

  Widget _composer(bool working, bool ended) => ListenableBuilder(
      listenable: Listenable.merge([conn.permission, conn.attachmentsListenable, conn.route]),
      builder: (context, _) {
        final watch = !conn.canControl;
        final row = _composerRow(working, ended, watch: watch);
        if (_uploads.items.isEmpty) return row;
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AttachmentChips(
              items: _uploads.items,
              viaRelay: conn.route.value == LinkRoute.relay,
              onRetry: _uploads.retry,
              onRemove: _uploads.remove),
          row,
        ]);
      });

  Widget _composerRow(bool working, bool ended, {required bool watch}) =>
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (conn.attachments && !watch && !ended) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: AttachButton(key: const ValueKey('attach'), onTap: _attach),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: GlassField(
            key: const ValueKey('composer'),
            controller: _text,
            enabled: !ended && !watch,
            hint: watch ? watchOnlyHint : (ended ? 'This session has ended' : 'Message Claude'),
            minLines: 1,
            maxLines: 5,
            radius: 26,
          ),
        ),
        const SizedBox(width: 10),
        if (working && !watch) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: DangerButton(key: const ValueKey('stop'), label: 'Stop', icon: Icons.stop_rounded, onTap: _stop),
          ),
          const SizedBox(width: 10),
        ],
        GlassOrb(
            key: const ValueKey('send'),
            icon: Icons.arrow_upward_rounded,
            size: 52,
            warm: true,
            label: 'Send',
            onTap: ended || watch || !_attachmentsReady ? null : _send),
      ]);
}

/// Whether the session's state line is drawn in the attention colour.
bool needsAttentionNow(SessionSummary s) => wantsYou(s);

class _Meta extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  /// Show the value in LED dots (a time).
  final bool dots;
  const _Meta({required this.icon, required this.value, required this.label, this.dots = false});
  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 18, color: G.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (dots)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: FittedBox(
                    fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: DotMatrix(value, dot: 2.6, glow: null)),
              )
            else
              Text(value, style: gSans(13.5, FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(label, style: gSans(11.5, FontWeight.w500, color: G.muted)),
          ]),
        ),
      ]);
}
