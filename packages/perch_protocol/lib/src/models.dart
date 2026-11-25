// Shared data models. Hand-written JSON; unknown keys are ignored.

enum SessionOrigin { perch, external }

enum SessionState { working, waitingQuestion, waitingPermission, waitingPlan, idle, blocked, finished, stopped }

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

int _int(Object? v, [int fallback = 0]) => v is num ? v.toInt() : fallback;
double _double(Object? v, [double fallback = 0]) => v is num ? v.toDouble() : fallback;
String _str(Object? v, [String fallback = '']) => v is String ? v : fallback;
String? _strOrNull(Object? v) => v is String ? v : null;
Map<String, dynamic> _map(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

class SessionSummary {
  /// Perch sessions: host-made uuid. External: Claude's id or `pid:<n>`.
  final String id;
  final String name;
  final String cwd;
  final SessionOrigin origin;
  final SessionState state;
  final String? model;
  final int startedAtMs;

  /// Set when blocked / finished abnormally.
  final String? reason;
  final int openPrompts;

  /// Whether the session's process is running. False for sessions Claude Code still lists
  /// whose process is gone. Missing in JSON from older hosts: true.
  final bool live;

  /// When the owner last sent the session a message (typed at the terminal or sent from
  /// Perch), in milliseconds since the epoch (UTC); null when unknown. Older hosts leave it
  /// out; older apps ignore it.
  final int? lastPromptAtMs;

  /// The Perch account the session runs on (an account id, or `machineLoginAccountId`);
  /// null when not known. Older hosts leave it out; older apps ignore it.
  final String? accountId;

  const SessionSummary({
    required this.id,
    required this.name,
    required this.cwd,
    required this.origin,
    required this.state,
    this.model,
    required this.startedAtMs,
    this.reason,
    this.openPrompts = 0,
    this.live = true,
    this.lastPromptAtMs,
    this.accountId,
  });

  SessionSummary copyWith({
    String? id,
    String? name,
    String? cwd,
    SessionOrigin? origin,
    SessionState? state,
    String? model,
    String? reason,
    bool clearReason = false,
    int? openPrompts,
    bool? live,
    int? lastPromptAtMs,
    String? accountId,
  }) =>
      SessionSummary(
        id: id ?? this.id,
        name: name ?? this.name,
        cwd: cwd ?? this.cwd,
        origin: origin ?? this.origin,
        state: state ?? this.state,
        model: model ?? this.model,
        startedAtMs: startedAtMs,
        reason: clearReason ? null : (reason ?? this.reason),
        openPrompts: openPrompts ?? this.openPrompts,
        live: live ?? this.live,
        lastPromptAtMs: lastPromptAtMs ?? this.lastPromptAtMs,
        accountId: accountId ?? this.accountId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'cwd': cwd,
        'origin': origin.name,
        'state': state.name,
        'model': model,
        'startedAtMs': startedAtMs,
        'reason': reason,
        'openPrompts': openPrompts,
        'live': live,
        if (lastPromptAtMs != null) 'lastPromptAtMs': lastPromptAtMs,
        'accountId': ?accountId,
      };

  factory SessionSummary.fromJson(Map<String, dynamic> j) => SessionSummary(
        id: _str(j['id']),
        name: _str(j['name']),
        cwd: _str(j['cwd']),
        origin: _enumByName(SessionOrigin.values, j['origin'], SessionOrigin.external),
        state: _enumByName(SessionState.values, j['state'], SessionState.idle),
        model: _strOrNull(j['model']),
        startedAtMs: _int(j['startedAtMs']),
        reason: _strOrNull(j['reason']),
        openPrompts: _int(j['openPrompts']),
        live: j['live'] is bool ? j['live'] as bool : true,
        lastPromptAtMs: j['lastPromptAtMs'] is num && (j['lastPromptAtMs'] as num) > 0
            ? (j['lastPromptAtMs'] as num).toInt()
            : null,
        accountId: j['accountId'] is String && (j['accountId'] as String).isNotEmpty ? j['accountId'] as String : null,
      );
}

/// One usage window. [utilization] is 0..1; [resetsAt] is Unix seconds.
class UsageWindow {
  final double utilization;
  final int resetsAt;
  final String status;

  const UsageWindow({required this.utilization, required this.resetsAt, required this.status});

  Map<String, dynamic> toJson() => {'utilization': utilization, 'resetsAt': resetsAt, 'status': status};

  factory UsageWindow.fromJson(Map<String, dynamic> j) => UsageWindow(
        utilization: _double(j['utilization']),
        resetsAt: _int(j['resetsAt']),
        status: _str(j['status']),
      );
}

class UsageSnapshot {
  final UsageWindow? fiveHour;
  final UsageWindow? sevenDay;

  /// The account this usage belongs to (the session that reported it ran on it); null:
  /// not known (older hosts).
  final String? accountId;

  const UsageSnapshot({this.fiveHour, this.sevenDay, this.accountId});

  UsageSnapshot withAccount(String? id) => UsageSnapshot(fiveHour: fiveHour, sevenDay: sevenDay, accountId: id);

  Map<String, dynamic> toJson() => {
        'fiveHour': fiveHour?.toJson(),
        'sevenDay': sevenDay?.toJson(),
        'accountId': ?accountId,
      };

  factory UsageSnapshot.fromJson(Map<String, dynamic> j) => UsageSnapshot(
        fiveHour: j['fiveHour'] is Map ? UsageWindow.fromJson(_map(j['fiveHour'])) : null,
        sevenDay: j['sevenDay'] is Map ? UsageWindow.fromJson(_map(j['sevenDay'])) : null,
        accountId: _strOrNull(j['accountId']),
      );
}

/// One item of a session's conversation. [seq] and [atMs] are stamped by the host's
/// session manager; [parentToolUseId] is non-null for events from a subagent.
sealed class ConversationEvent {
  int seq;
  int atMs;
  String? parentToolUseId;

  ConversationEvent({this.seq = 0, this.atMs = 0, this.parentToolUseId});

  String get kind;

  Map<String, dynamic> _fields();

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'seq': seq,
        'atMs': atMs,
        'parentToolUseId': parentToolUseId,
        ..._fields(),
      };

  /// Throws [FormatException] for an unknown kind; see [tryFromJson].
  factory ConversationEvent.fromJson(Map<String, dynamic> j) {
    final e = tryFromJson(j);
    if (e == null) throw FormatException('Unknown event kind: ${j['kind']}');
    return e;
  }

  static ConversationEvent? tryFromJson(Map<String, dynamic> j) {
    final seq = _int(j['seq']);
    final atMs = _int(j['atMs']);
    final parent = _strOrNull(j['parentToolUseId']);
    switch (j['kind']) {
      case 'userMessage':
        return UserMessage(_str(j['text']), seq: seq, atMs: atMs, parentToolUseId: parent);
      case 'assistantText':
        return AssistantText(_str(j['text']), seq: seq, atMs: atMs, parentToolUseId: parent);
      case 'toolCall':
        return ToolCall(_str(j['toolUseId']), _str(j['name']), _map(j['input']),
            seq: seq, atMs: atMs, parentToolUseId: parent);
      case 'toolResult':
        return ToolResult(_str(j['toolUseId']), _str(j['text']),
            isError: j['isError'] == true,
            truncated: j['truncated'] == true,
            seq: seq,
            atMs: atMs,
            parentToolUseId: parent);
      case 'subagentStarted':
        return SubagentStarted(
            _str(j['taskId']), _str(j['toolUseId']), _str(j['description']), _str(j['subagentType']),
            seq: seq, atMs: atMs, parentToolUseId: parent);
      case 'subagentFinished':
        return SubagentFinished(_str(j['taskId']), _str(j['status']),
            seq: seq, atMs: atMs, parentToolUseId: parent);
      case 'turnEnded':
        return TurnEnded(
            isError: j['isError'] == true, text: _str(j['text']), seq: seq, atMs: atMs, parentToolUseId: parent);
      case 'notice':
        return Notice(_str(j['text']), seq: seq, atMs: atMs, parentToolUseId: parent);
      case 'slashCommand':
        return SlashCommand(_str(j['name']), _str(j['args']), seq: seq, atMs: atMs, parentToolUseId: parent);
      case 'commandOutput':
        return CommandOutput(_str(j['text']), isError: j['isError'] == true, seq: seq, atMs: atMs, parentToolUseId: parent);
    }
    return null;
  }
}

class UserMessage extends ConversationEvent {
  final String text;
  UserMessage(this.text, {super.seq, super.atMs, super.parentToolUseId});
  @override
  String get kind => 'userMessage';
  @override
  Map<String, dynamic> _fields() => {'text': text};
}

class AssistantText extends ConversationEvent {
  final String text;
  AssistantText(this.text, {super.seq, super.atMs, super.parentToolUseId});
  @override
  String get kind => 'assistantText';
  @override
  Map<String, dynamic> _fields() => {'text': text};
}

class ToolCall extends ConversationEvent {
  final String toolUseId;
  final String name;
  final Map<String, dynamic> input;
  ToolCall(this.toolUseId, this.name, this.input, {super.seq, super.atMs, super.parentToolUseId});
  @override
  String get kind => 'toolCall';
  @override
  Map<String, dynamic> _fields() => {'toolUseId': toolUseId, 'name': name, 'input': input};
}

class ToolResult extends ConversationEvent {
  final String toolUseId;
  final String text;
  final bool isError;
  final bool truncated;
  ToolResult(this.toolUseId, this.text,
      {this.isError = false, this.truncated = false, super.seq, super.atMs, super.parentToolUseId});
  @override
  String get kind => 'toolResult';
  @override
  Map<String, dynamic> _fields() =>
      {'toolUseId': toolUseId, 'text': text, 'isError': isError, 'truncated': truncated};
}

class SubagentStarted extends ConversationEvent {
  final String taskId;
  final String toolUseId;
  final String description;
  final String subagentType;
  SubagentStarted(this.taskId, this.toolUseId, this.description, this.subagentType,
      {super.seq, super.atMs, super.parentToolUseId});
  @override
  String get kind => 'subagentStarted';
  @override
  Map<String, dynamic> _fields() =>
      {'taskId': taskId, 'toolUseId': toolUseId, 'description': description, 'subagentType': subagentType};
}

class SubagentFinished extends ConversationEvent {
  final String taskId;
  final String status;
  SubagentFinished(this.taskId, this.status, {super.seq, super.atMs, super.parentToolUseId});
  @override
  String get kind => 'subagentFinished';
  @override
  Map<String, dynamic> _fields() => {'taskId': taskId, 'status': status};
}

class TurnEnded extends ConversationEvent {
  final bool isError;
  final String text;
  TurnEnded({required this.isError, required this.text, super.seq, super.atMs, super.parentToolUseId});
  @override
  String get kind => 'turnEnded';
  @override
  Map<String, dynamic> _fields() => {'isError': isError, 'text': text};
}

class Notice extends ConversationEvent {
  final String text;
  Notice(this.text, {super.seq, super.atMs, super.parentToolUseId});
  @override
  String get kind => 'notice';
  @override
  Map<String, dynamic> _fields() => {'text': text};
}

/// A slash command the owner ran in the session (`/context`, `/model haiku`): Claude Code
/// writes it to the transcript as `<command-name>`. [name] has its slash.
class SlashCommand extends ConversationEvent {
  final String name;
  final String args;
  SlashCommand(this.name, this.args, {super.seq, super.atMs, super.parentToolUseId});

  /// As typed: `/model haiku`.
  String get line => args.trim().isEmpty ? name : '$name ${args.trim()}';
  @override
  String get kind => 'slashCommand';
  @override
  Map<String, dynamic> _fields() => {'name': name, 'args': args};
}

/// What a local slash command printed (`<local-command-stdout>`, or `-stderr` with
/// [isError]), terminal colours removed.
class CommandOutput extends ConversationEvent {
  final String text;
  final bool isError;
  CommandOutput(this.text, {this.isError = false, super.seq, super.atMs, super.parentToolUseId});
  @override
  String get kind => 'commandOutput';
  @override
  Map<String, dynamic> _fields() => {'text': text, 'isError': isError};
}

/// One command the session's composer offers after `/`: its name (with the slash), what it
/// does, and where it comes from (`built-in`, `user`, `project`, `skill`, a plugin's name).
class SlashCommandInfo {
  final String name;
  final String description;
  final String source;

  /// What follows the name, if it takes something (`[model]`).
  final String argumentHint;
  const SlashCommandInfo({required this.name, this.description = '', this.source = 'built-in', this.argumentHint = ''});
  Map<String, dynamic> toJson() => {
        'name': name,
        if (description.isNotEmpty) 'description': description,
        'source': source,
        if (argumentHint.isNotEmpty) 'argumentHint': argumentHint,
      };
  static SlashCommandInfo? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final n = j['name'];
    if (n is! String || !n.startsWith('/') || n.length < 2) return null;
    String s(Object? v) => v is String ? v : '';
    return SlashCommandInfo(
        name: n, description: s(j['description']), source: s(j['source']).isEmpty ? 'built-in' : s(j['source']), argumentHint: s(j['argumentHint']));
  }
}

/// The commands that match what is typed after `/`: names starting with it first, then names
/// and descriptions containing it; [typed] includes the slash ("/con").
List<SlashCommandInfo> matchCommands(List<SlashCommandInfo> all, String typed) {
  final q = typed.trim().toLowerCase();
  if (!q.startsWith('/')) return const [];
  final word = q.substring(1);
  if (word.isEmpty) return [...all]..sort((a, b) => a.name.compareTo(b.name));
  int rank(SlashCommandInfo c) {
    final n = c.name.substring(1).toLowerCase();
    if (n == word) return 0;
    if (n.startsWith(word)) return 1;
    if (n.split(RegExp(r'[:\-_]')).any((p) => p.startsWith(word))) return 2;
    if (n.contains(word)) return 3;
    if (c.description.toLowerCase().contains(word)) return 4;
    return 9;
  }

  final hits = [for (final c in all) if (rank(c) < 9) c];
  hits.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : a.name.compareTo(b.name);
  });
  return hits;
}

/// A file or folder of a session's folder the composer offers after `@`: its [path] relative
/// to that folder, with `/` between parts on every machine.
class FileMention {
  final String path;
  final bool dir;
  const FileMention({required this.path, this.dir = false});

  /// The last part of the path.
  String get name => path.substring(path.lastIndexOf('/') + 1);

  /// What goes into the message: `@path` (folders end in `/`; a path with a space is quoted,
  /// as Claude Code writes it).
  String get mention {
    final p = dir ? '$path/' : path;
    return p.contains(' ') ? '@"$p"' : '@$p';
  }

  Map<String, dynamic> toJson() => {'path': path, if (dir) 'dir': true};
  static FileMention? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final p = j['path'];
    if (p is! String || p.isEmpty || p.startsWith('/') || p.split('/').contains('..')) return null;
    return FileMention(path: p, dir: j['dir'] == true);
  }
}

/// The `@` mention being typed in [text] with the cursor at [cursor]: where its `@` is and
/// what follows it; null when the cursor is not in one (an `@` inside a word, as in an
/// address, is not a mention).
({int start, String query})? mentionAt(String text, int cursor) {
  if (cursor < 1 || cursor > text.length) return null;
  for (var i = cursor - 1; i >= 0; i--) {
    final ch = text[i];
    if (ch == '@') {
      if (i > 0 && text[i - 1].trim().isNotEmpty) return null;
      return (start: i, query: text.substring(i + 1, cursor));
    }
    if (ch.trim().isEmpty) return null;
  }
  return null;
}

/// The files and folders that match what is typed after `@`, best first, at most [limit]:
/// with nothing typed the top of the folder; a name matches the last part of a path (whole,
/// then its start, then anywhere), then the whole path, then its letters in order; a query
/// with a `/` matches paths. Ties: nearer the top, then by name.
List<FileMention> matchFiles(List<FileMention> all, String query, {int limit = 50}) {
  final q = query.trim().toLowerCase().replaceAll('\\', '/');
  int depth(FileMention f) => '/'.allMatches(f.path).length;
  bool inOrder(String s) {
    var k = 0;
    for (var i = 0; i < s.length && k < q.length; i++) {
      if (s.codeUnitAt(i) == q.codeUnitAt(k)) k++;
    }
    return k == q.length;
  }

  int rank(FileMention f) {
    if (q.isEmpty) return depth(f);
    final p = f.path.toLowerCase();
    final n = f.name.toLowerCase();
    final stem = n.contains('.') ? n.substring(0, n.lastIndexOf('.')) : n;
    if (q.contains('/')) {
      if ('$p/' == q) return -1; // the folder already typed: its contents follow
      if (p == q) return 0;
      if (p.startsWith(q)) return 1;
      if (p.contains(q)) return 3;
      return inOrder(p) ? 5 : -1;
    }
    if (n == q || stem == q) return 0;
    if (n.startsWith(q)) return 1;
    if (n.contains(q)) return 2;
    if (p.contains(q)) return 3;
    if (inOrder(n)) return 4;
    return inOrder(p) ? 5 : -1;
  }

  final hits = <(int, FileMention)>[
    for (final f in all)
      if (rank(f) case final r when r >= 0) (r, f),
  ];
  hits.sort((a, b) {
    final r = a.$1.compareTo(b.$1);
    if (r != 0) return r;
    final d = depth(a.$2).compareTo(depth(b.$2));
    if (d != 0) return d;
    return a.$2.path.toLowerCase().compareTo(b.$2.path.toLowerCase());
  });
  return [for (final h in hits.take(limit)) h.$2];
}

/// Whether this Perch host still understands the installed Claude Code.
/// untested: Claude Code is newer than any version this Perch was checked with.
/// drifted: Perch saw Claude Code show or send something in a format it cannot read.
enum CompatibilityStatus { ok, untested, drifted }

class Compatibility {
  final CompatibilityStatus status;
  final String? claudeVersion;

  /// drifted: a short human reason.
  final String? reason;

  /// drifted: what Perch saw (session, what it expected, the screen, the version).
  final String? evidence;

  /// untested: what Claude Code's release notes say since the newest checked version
  /// (null while they are being read, or from an older host).
  final ReleaseNotesFindings? releaseNotes;

  /// untested: the [WorkingKinds] already seen working on this version in real use.
  final List<String> seenWorking;

  /// The self-test setting and its last result (null from an older host).
  final SelfTestStatus? selfTest;

  const Compatibility(
      {required this.status,
      this.claudeVersion,
      this.reason,
      this.evidence,
      this.releaseNotes,
      this.seenWorking = const [],
      this.selfTest});

  Map<String, dynamic> toJson() => {
        'status': status.name,
        'claudeVersion': claudeVersion,
        'reason': reason,
        'evidence': evidence,
        if (releaseNotes != null) 'releaseNotes': releaseNotes!.toJson(),
        if (seenWorking.isNotEmpty) 'seenWorking': seenWorking,
        if (selfTest != null) 'selfTest': selfTest!.toJson(),
      };

  factory Compatibility.fromJson(Map<String, dynamic> j) => Compatibility(
        status: _enumByName(CompatibilityStatus.values, j['status'], CompatibilityStatus.ok),
        claudeVersion: _strOrNull(j['claudeVersion']),
        reason: _strOrNull(j['reason']),
        evidence: _strOrNull(j['evidence']),
        releaseNotes: j['releaseNotes'] is Map ? ReleaseNotesFindings.fromJson(_map(j['releaseNotes'])) : null,
        seenWorking: _strings(j['seenWorking']),
        selfTest: j['selfTest'] is Map ? SelfTestStatus.fromJson(_map(j['selfTest'])) : null,
      );
}

List<String> _strings(Object? v) => [
      for (final x in (v is List ? v : const []))
        if (x is String) x
    ];

/// Kinds of real interaction that show Perch still works with a Claude Code version.
abstract final class WorkingKinds {
  static const question = 'question';
  static const permission = 'permission';
  static const plan = 'plan';
  static const transcript = 'transcript';

  /// Each must have worked once for an unchecked version to count as checked.
  static const required = [question, permission, plan];
}

/// What Claude Code's release notes say about the versions since the newest checked one.
class ReleaseNotesFindings {
  /// False when the notes could not be read ([error] says why).
  final bool checked;

  /// The versions whose notes were read, oldest first.
  final List<String> versions;

  /// Lines that mention something Perch relies on, as written.
  final List<String> relevantLines;

  /// What those lines are about, in words ("prompt", "hook", …).
  final List<String> topics;
  final String? error;

  const ReleaseNotesFindings(
      {required this.checked,
      this.versions = const [],
      this.relevantLines = const [],
      this.topics = const [],
      this.error});

  Map<String, dynamic> toJson() => {
        'checked': checked,
        'versions': versions,
        'relevantLines': relevantLines,
        'topics': topics,
        if (error != null) 'error': error,
      };

  factory ReleaseNotesFindings.fromJson(Map<String, dynamic> j) => ReleaseNotesFindings(
        checked: j['checked'] == true,
        versions: _strings(j['versions']),
        relevantLines: _strings(j['relevantLines']),
        topics: _strings(j['topics']),
        error: _strOrNull(j['error']),
      );
}

String _joinWords(List<String> words) => words.length <= 1
    ? words.join()
    : '${words.sublist(0, words.length - 1).join(', ')} and ${words.last}';

/// What the release notes say, in a few words: `release notes: nothing affecting Perch`,
/// `release notes mention prompt changes`, `release notes could not be read`; null while
/// they are being read.
String? releaseNotesPhrase(ReleaseNotesFindings? f) {
  if (f == null) return null;
  if (!f.checked) return 'release notes could not be read';
  if (f.relevantLines.isEmpty) return 'release notes: nothing affecting Perch';
  final topics = f.topics.isEmpty ? ['possibly relevant'] : f.topics;
  return 'release notes mention ${_joinWords(topics)} changes';
}

/// The amber line for an unchecked version.
String untestedLine(Compatibility c) {
  final phrase = releaseNotesPhrase(c.releaseNotes);
  return "Claude Code ${c.claudeVersion ?? ''} hasn't been checked yet${phrase == null ? '' : ' · $phrase'}";
}

/// `Seen working on 2.1.325: questions ✓, permissions ✓, plans —`
String seenWorkingLine(Compatibility c) {
  String mark(String kind) => c.seenWorking.contains(kind) ? '✓' : '—';
  return 'Seen working on ${c.claudeVersion ?? 'this version'}: questions ${mark(WorkingKinds.question)}, '
      'permissions ${mark(WorkingKinds.permission)}, plans ${mark(WorkingKinds.plan)}';
}

/// idle: not run for this version. unsupported: this machine cannot run it.
enum SelfTestState { idle, running, passed, failed, unsupported }

class SelfTestStatus {
  /// Whether the host runs the self-test by itself on a new Claude Code version.
  final bool enabled;
  final SelfTestState state;

  /// The Claude Code version the last run was for.
  final String? version;

  /// failed / unsupported: why.
  final String? reason;

  /// When the last run ended (or started, while running).
  final int? atMs;

  const SelfTestStatus({required this.enabled, this.state = SelfTestState.idle, this.version, this.reason, this.atMs});

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'state': state.name,
        if (version != null) 'version': version,
        if (reason != null) 'reason': reason,
        if (atMs != null) 'atMs': atMs,
      };

  factory SelfTestStatus.fromJson(Map<String, dynamic> j) => SelfTestStatus(
        enabled: j['enabled'] == true,
        state: _enumByName(SelfTestState.values, j['state'], SelfTestState.idle),
        version: _strOrNull(j['version']),
        reason: _strOrNull(j['reason']),
        atMs: j['atMs'] is num ? (j['atMs'] as num).toInt() : null,
      );
}

enum PromptKind { question, permission, plan }

class PromptRequest {
  /// Claude's request_id.
  final String promptId;

  /// AskUserQuestion -> question, ExitPlanMode -> plan, else permission.
  final PromptKind kind;
  final String toolName;

  /// Exactly as Claude sent it.
  final Map<String, dynamic> input;

  /// Claude's permission_suggestions; may be empty.
  final List<dynamic> suggestions;
  final String? parentToolUseId;

  const PromptRequest({
    required this.promptId,
    required this.kind,
    required this.toolName,
    required this.input,
    this.suggestions = const [],
    this.parentToolUseId,
  });

  static PromptKind kindForTool(String toolName) => switch (toolName) {
        'AskUserQuestion' => PromptKind.question,
        'ExitPlanMode' => PromptKind.plan,
        _ => PromptKind.permission,
      };

  Map<String, dynamic> toJson() => {
        'promptId': promptId,
        'kind': kind.name,
        'toolName': toolName,
        'input': input,
        'suggestions': suggestions,
        'parentToolUseId': parentToolUseId,
      };

  factory PromptRequest.fromJson(Map<String, dynamic> j) {
    final tool = _str(j['toolName']);
    return PromptRequest(
      promptId: _str(j['promptId']),
      kind: _enumByName(PromptKind.values, j['kind'], kindForTool(tool)),
      toolName: tool,
      input: _map(j['input']),
      suggestions: j['suggestions'] is List ? List<dynamic>.from(j['suggestions'] as List) : const [],
      parentToolUseId: _strOrNull(j['parentToolUseId']),
    );
  }
}

sealed class PromptAnswer {
  const PromptAnswer();
  Map<String, dynamic> toJson();

  factory PromptAnswer.fromJson(Map<String, dynamic> j) {
    switch (j['kind']) {
      case 'question':
        return QuestionAnswer(_map(j['answers']).map((k, v) => MapEntry(k, v is String ? v : '$v')));
      case 'permission':
        return PermissionAnswer(
            allow: j['allow'] == true, always: j['always'] == true, message: _strOrNull(j['message']));
      case 'plan':
        return PlanAnswer(approve: j['approve'] == true, feedback: _strOrNull(j['feedback']));
    }
    throw FormatException('Unknown answer kind: ${j['kind']}');
  }
}

/// Question text -> chosen label(s); multi-select labels joined with ", ".
class QuestionAnswer extends PromptAnswer {
  final Map<String, String> answers;
  const QuestionAnswer(this.answers);
  @override
  Map<String, dynamic> toJson() => {'kind': 'question', 'answers': answers};
}

class PermissionAnswer extends PromptAnswer {
  final bool allow;
  final bool always;
  final String? message;
  const PermissionAnswer({required this.allow, this.always = false, this.message});
  @override
  Map<String, dynamic> toJson() => {'kind': 'permission', 'allow': allow, 'always': always, 'message': message};
}

class PlanAnswer extends PromptAnswer {
  final bool approve;
  final String? feedback;
  const PlanAnswer({required this.approve, this.feedback});
  @override
  Map<String, dynamic> toJson() => {'kind': 'plan', 'approve': approve, 'feedback': feedback};
}

// ---------------------------------------------------------------- usage limits

/// What the owner chose for a usage limit (wire names).
abstract final class LimitChoices {
  /// The session resumes on its own at the reset; Perch sends `please continue` when
  /// Claude does not pick the work up by itself.
  static const continueWhenAvailable = 'continue';

  /// Nothing is sent on the owner's behalf; Claude Code's own automatic continue is
  /// cancelled.
  static const wait = 'wait';

  /// Not a lasting choice: send `please continue` now to every session still paused (the
  /// "Usage is back" card's and notification's Continue).
  static const continueNow = 'continueNow';

  /// Not a lasting choice: move the paused sessions to another account (end each and
  /// resume its conversation under that account's token) and continue them.
  static const switchAccount = 'switch';

  static const lasting = [continueWhenAvailable, wait];
}

/// Which usage window ran out, when it is known.
abstract final class LimitWindows {
  static const fiveHour = 'fiveHour';
  static const sevenDay = 'sevenDay';
  static const opus = 'opus';
  static const sonnet = 'sonnet';
}

/// One session paused by a usage limit.
class LimitedSession {
  final String id;
  final String name;

  /// Whether Claude Code itself waits to continue at the reset (its `Continuing
  /// automatically` line); null when Perch cannot tell (no screen to read).
  final bool? claudeWaiting;

  /// This session's own choice (one of [LimitChoices.lasting]); null: the machine's.
  final String? override;

  const LimitedSession({required this.id, required this.name, this.claudeWaiting, this.override});

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (claudeWaiting != null) 'claudeWaiting': claudeWaiting,
        if (override != null) 'override': override,
      };

  factory LimitedSession.fromJson(Map<String, dynamic> j) => LimitedSession(
        id: _str(j['id']),
        name: _str(j['name']),
        claudeWaiting: j['claudeWaiting'] is bool ? j['claudeWaiting'] as bool : null,
        override: LimitChoices.lasting.contains(j['override']) ? j['override'] as String : null,
      );
}

/// A machine's usage limit: one per machine, as every session on it shares the account.
class UsageLimit {
  /// When usage is available again (milliseconds since the epoch, UTC); null: unknown.
  final int? resetsAtMs;

  /// One of [LimitWindows]; null when Claude Code did not say.
  final String? window;

  /// The machine's choice, one of [LimitChoices.lasting].
  final String choice;

  /// The reset has passed: usage is back (the card says so).
  final bool back;

  /// The sessions still paused by it.
  final List<LimitedSession> sessions;

  /// Something Perch could not do for the owner ("Couldn't stop Claude Code from
  /// continuing on Desk"); null when all is well.
  final String? problem;

  const UsageLimit({
    this.resetsAtMs,
    this.window,
    this.choice = LimitChoices.continueWhenAvailable,
    this.back = false,
    this.sessions = const [],
    this.problem,
  });

  LimitedSession? session(String id) {
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// The choice that applies to session [id].
  String choiceFor(String id) => session(id)?.override ?? choice;

  Map<String, dynamic> toJson() => {
        if (resetsAtMs != null) 'resetsAtMs': resetsAtMs,
        if (window != null) 'window': window,
        'choice': choice,
        'back': back,
        'sessions': [for (final s in sessions) s.toJson()],
        if (problem != null) 'problem': problem,
      };

  factory UsageLimit.fromJson(Map<String, dynamic> j) => UsageLimit(
        resetsAtMs: j['resetsAtMs'] is num && (j['resetsAtMs'] as num) > 0 ? (j['resetsAtMs'] as num).toInt() : null,
        window: _strOrNull(j['window']),
        choice: LimitChoices.lasting.contains(j['choice']) ? j['choice'] as String : LimitChoices.continueWhenAvailable,
        back: j['back'] == true,
        sessions: [
          for (final s in (j['sessions'] is List ? j['sessions'] as List : const []))
            if (s is Map) LimitedSession.fromJson(s.cast<String, dynamic>())
        ],
        problem: _strOrNull(j['problem']),
      );
}
