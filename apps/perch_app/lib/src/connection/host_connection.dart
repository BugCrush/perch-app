// Client for one host: picks a route, runs the encrypted channel, reconnects and catches up.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'board_file.dart';
import 'machine_store.dart';

/// refused = the host runs an older Perch; stopped =
/// remoteAccessStopped; needsPairing = no valid pairing (saved by phase 1, or the host
/// forgot its devices); awaitingApproval = this device asked to pair and waits until it is
/// allowed at the machine; denied = the machine did not allow it (denied, or nobody
/// decided in time); removed = the machine removed this device.
enum LinkState { connecting, online, offline, refused, stopped, needsPairing, awaitingApproval, denied, removed }

/// How an online connection reaches the host.
enum LinkRoute { lan, relay }

/// Shown when a watch-only device tries to act (the host would refuse it anyway).
const watchOnlyMessage = 'This device can only watch on this machine.';

/// Shown when a phase 1 host answers in the clear.
const olderHostMessage = 'This machine runs an older Perch host. Update it, then pair again.';

/// Shown when the host does not know a session menu action (it runs an older Perch).
const olderHostActionMessage =
    'This machine runs an older Perch host: update Perch on it to rename, delete or resume sessions.';

/// Shown when the host does not know the usage-limit choice (it runs an older Perch).
const olderHostLimitMessage = 'This machine runs an older Perch host: update Perch on it to choose what happens at a usage limit.';

/// Shown when the host does not know accounts (it runs an older Perch).
const olderHostAccountsMessage = 'This machine runs an older Perch host: update Perch on it to use accounts.';

/// Shown when the host does not know the task board (it runs an older Perch).
const olderHostTasksMessage = 'This machine runs an older Perch host: update Perch on it to use the task board.';

/// What the search screen says for a machine whose host cannot search ({machine}: its name).
String olderHostSearchMessage(String machine) => '$machine runs an older Perch host: update Perch on it to search.';

/// The phone's model table, as a connection syncs it with its host (the newer one wins).
abstract interface class ModelTableSource {
  ModelTable get table;

  /// The host had a newer table (another phone or the board page changed it).
  void adopt(ModelTable table);
}

/// The owner's projects as the phone keeps them (synced with every host; the newer list
/// wins).
abstract interface class ProjectSource {
  ProjectList get projects;

  /// A host had a newer list: keep it.
  void adoptProjects(ProjectList projects);
}

/// What a connection gives its host about the owner's accounts (the phone's store).
abstract interface class AccountSource {
  /// Every account with its token.
  List<AccountWithToken> get withTokens;

  /// Accounts the owner removed (a machine that still has one is told to forget it).
  Set<String> get removed;
}

/// A session menu action (rename, delete, resume) the host refused or did not answer.
class SessionActionFailed implements Exception {
  final String message;
  const SessionActionFailed(this.message);
  @override
  String toString() => message;
}

/// One WebSocket being tried, or in use, with its handshake.
class _Attempt {
  final LinkRoute route;
  final WebSocketChannel channel;
  final ClientHandshake handshake;
  StreamSubscription<dynamic>? sub;
  SecureSession? session;
  bool closed = false;

  /// A quiet LAN try while on the relay.
  bool probe = false;
  _Attempt(this.route, this.channel, this.handshake);

  void add(Object frame) {
    if (closed) return;
    try {
      channel.sink.add(frame);
    } catch (_) {}
  }

  void close() {
    if (closed) return;
    closed = true;
    sub?.cancel();
    try {
      channel.sink.close();
    } catch (_) {}
  }
}

typedef ChannelFactory = WebSocketChannel Function(Uri uri);

WebSocketChannel defaultChannelFactory(Uri uri) => WebSocketChannel.connect(uri);

/// One session's conversation as seen by this device.
class SessionFeed {
  final String sessionId;
  SessionFeed(this.sessionId);

  final ValueNotifier<List<ConversationEvent>> _events = ValueNotifier(const []);
  final ValueNotifier<List<PromptRequest>> _prompts = ValueNotifier(const []);
  int _lastSeq = 0;

  /// Ordered by seq, no duplicates.
  ValueListenable<List<ConversationEvent>> get events => _events;
  ValueListenable<List<PromptRequest>> get openPrompts => _prompts;
  int get lastSeq => _lastSeq;

  void _add(Iterable<ConversationEvent> incoming) {
    final fresh = <ConversationEvent>[];
    for (final e in incoming) {
      if (e.seq <= _lastSeq) continue;
      fresh.add(e);
      _lastSeq = e.seq;
    }
    if (fresh.isNotEmpty) _events.value = [..._events.value, ...fresh];
  }

  final ValueNotifier<bool> _hasEarlier = ValueNotifier(false);
  bool _loadingEarlier = false;

  /// Whether the host holds older events than the first one here.
  ValueListenable<bool> get hasEarlier => _hasEarlier;

  /// The first page arrived: remember whether there is more before it.
  void _addFirst(Iterable<ConversationEvent> incoming, bool hasEarlier) {
    final first = _events.value.isEmpty;
    _add(incoming);
    if (first) _hasEarlier.value = hasEarlier;
  }

  void _prepend(List<ConversationEvent> incoming, bool hasEarlier) {
    _loadingEarlier = false;
    final firstSeq = _events.value.isEmpty ? null : _events.value.first.seq;
    final older = [for (final e in incoming) if (firstSeq == null || e.seq < firstSeq) e]
      ..sort((a, b) => a.seq.compareTo(b.seq));
    _hasEarlier.value = hasEarlier;
    if (older.isEmpty) return;
    if (_lastSeq == 0) _lastSeq = older.last.seq;
    _events.value = [...older, ..._events.value];
  }

  void _setPrompts(List<PromptRequest> prompts) => _prompts.value = List.unmodifiable(prompts);

  void _openPrompt(PromptRequest p) {
    if (_prompts.value.any((x) => x.promptId == p.promptId)) return;
    _prompts.value = [..._prompts.value, p];
  }

  void _closePrompt(String promptId) {
    if (!_prompts.value.any((x) => x.promptId == promptId)) return;
    _prompts.value = _prompts.value.where((x) => x.promptId != promptId).toList();
  }

  void _dispose() {
    _events.dispose();
    _prompts.dispose();
    _hasEarlier.dispose();
  }
}

class HostConnection {
  /// The machine; updated when the host reports a new name, relay URL or LAN addresses,
  /// and when this device renames it.
  Machine get machine => _machine;
  set machine(Machine m) {
    _machine = m;
    _updateDisplayName();
  }

  Machine _machine;
  final ChannelFactory _factory;
  final String deviceName;
  final String deviceId;

  /// How long the LAN addresses get before the relay is tried.
  final Duration lanTimeout;

  /// How long the relay gets to answer the handshake.
  final Duration relayTimeout;

  /// How often the LAN is tried again while connected through the relay.
  final Duration lanRetryInterval;

  /// Called when the host's `welcome` changed the machine's relay URL or LAN addresses.
  final void Function(Machine updated)? onMachineUpdated;

  /// The owner's accounts, given to the host when it connects (null: none).
  AccountSource? accountSource;

  /// The owner's model table, synced with the host (null: none).
  ModelTableSource? modelSource;

  /// The owner's projects, synced with the host (null: none; default: [modelSource] when
  /// it keeps projects too, as the app's board store does).
  ProjectSource? projectSource;

  /// The board this device keeps (null: none, as in older tests). A host that keeps the
  /// board too ([Welcome.boardSync]) exchanges records with it.
  final BoardFile? boardFile;
  final List<StreamSubscription<dynamic>> _boardSubs = [];

  HostConnection(Machine machine,
      {ChannelFactory? channelFactory,
      this.deviceName = 'Android',
      this.deviceId = 'device',
      this.lanTimeout = const Duration(milliseconds: 1500),
      this.relayTimeout = const Duration(seconds: 10),
      this.lanRetryInterval = const Duration(seconds: 60),
      this.onMachineUpdated,
      this.accountSource,
      this.modelSource,
      ProjectSource? projectSource,
      this.boardFile})
      : projectSource = projectSource ?? (modelSource is ProjectSource ? modelSource as ProjectSource : null),
        _machine = machine,
        _factory = channelFactory ?? defaultChannelFactory,
        _displayName = ValueNotifier(machine.displayName) {
    final f = boardFile;
    if (f != null) {
      _boardSubs
        ..add(f.changes.listen((c) {
          if (!identical(c.origin, this)) _sendRecords(c.records);
        }))
        ..add(f.keyChanges.listen((origin) {
          if (!identical(origin, this)) _sendKey();
        }));
    }
  }

  // ------------------------------------------------------------ board sync

  bool _boardSync = false;

  /// The host keeps the whole board and syncs it (its welcome said so).
  bool get boardSync => _boardSync;

  // ------------------------------------------------------------ attachments

  final ValueNotifier<bool> _attachments = ValueNotifier(false);

  /// The host takes attachments (its welcome said so; older hosts: no attach button).
  bool get attachments => _attachments.value;

  /// [attachments], to rebuild when a welcome changes it.
  ValueListenable<bool> get attachmentsListenable => _attachments;

  final _attachEvents = StreamController<HostMessage>.broadcast();
  final _welcomes = StreamController<Welcome>.broadcast();

  /// Every welcome: a new connection on the host (a relay-to-LAN switch, a permission change),
  /// which drops the uploads of the one before.
  Stream<Welcome> get welcomes => _welcomes.stream;

  /// The host's answers to uploads: [AttachAccepted], [AttachProgress], [AttachDone],
  /// [AttachFailed].
  Stream<HostMessage> get attachmentEvents => _attachEvents.stream;

  /// Sends one of the upload messages ([AttachStart], [AttachChunk], [AttachEnd],
  /// [AttachCancel]); false when there is no link to send it on.
  bool sendAttach(ClientMessage m) {
    assert(m is AttachStart || m is AttachChunk || m is AttachEnd || m is AttachCancel);
    if (_link.value != LinkState.online) return false;
    _send(m);
    return true;
  }

  /// The host sent its board key on this connection.
  bool _hostKeySeen = false;

  /// Waiting for the host's answer to this device's summary.
  bool _awaitingBoardAnswer = false;

  bool get _boardWritable => _link.value == LinkState.online && _boardSync && canControl && boardFile != null;

  void _sendRecords(List<BoardRecord> records) {
    if (!_boardWritable || records.isEmpty) return;
    _send(BoardRecordsFromApp(records: records));
    boardFile!.markSynced();
  }

  void _sendKey() {
    final k = boardFile?.boardKey;
    if (!_boardWritable || k == null) return;
    _send(BoardKeyFromApp(boardId: k.boardId, key: k.keyText, keyVersion: k.keyVersion));
  }

  void _onBoardSummary(Map<String, Map<String, String>> summary) {
    final f = boardFile;
    if (f == null || !_boardWritable) return;
    final out = f.board.newerThan(summary);
    if (out.isNotEmpty) _send(BoardRecordsFromApp(records: out));
    f.markSynced();
  }

  Future<void> _onBoardRecords(List<BoardRecord> records) async {
    final f = boardFile;
    if (f == null) return;
    f.mergeAll(records, origin: this);
    if (!_awaitingBoardAnswer) return;
    _awaitingBoardAnswer = false;
    if (!_boardWritable) return;
    // The host sends its key (when it has one) before this answer.
    if (!_hostKeySeen) {
      if (f.boardKey == null) {
        await f.ensureBoardKey(); // made here: every machine is given it
      } else {
        _sendKey();
      }
    }
  }

  Future<void> _onBoardKey(String boardId, String key, String keyVersion) async {
    _hostKeySeen = true;
    final f = boardFile;
    if (f == null) return;
    final k = BoardKey.tryFromJson({'boardId': boardId, 'key': key, 'keyVersion': keyVersion});
    if (k == null) return;
    final taken = await f.takeBoardKey(k, origin: this);
    if (!taken && f.boardKey != null && f.boardKey!.keyVersion != keyVersion) _sendKey(); // the host's is older
  }

  /// An older host (no board sync): its tasks join the board as records assigned to it (at
  /// their own time), and a task gone from it is deleted from the board.
  void _mergeLegacyTasks(List<BoardTask> tasks) {
    final f = boardFile;
    if (f == null || _boardSync) return;
    final mid = machine.id;
    final writer = 'legacy_${mid.replaceAll('-', '_')}';
    final ids = {for (final t in tasks) t.id};
    final now = DateTime.now().millisecondsSinceEpoch;
    f.mergeAll([
      for (final t in tasks)
        BoardRecord(RecordKinds.task, t.id, {
          for (final g in taskGroupValues(t.copyWith(machineId: mid)).entries)
            g.key: BoardGroup(g.value, Hlc(t.updatedAtMs > 0 ? t.updatedAtMs : 1, 0, writer)),
        }),
      for (final r in f.board.records)
        if (r.kind == RecordKinds.task &&
            !r.deleted &&
            !ids.contains(r.id) &&
            r.groups['content']?.value['machineId'] == mid &&
            r.groups['content']!.version.writer == writer)
          BoardRecord(RecordKinds.task, r.id, {
            'life': BoardGroup({'deleted': true, 'deletedAtMs': now}, Hlc(now, 0, writer))
          }),
    ], origin: this);
  }

  final ValueNotifier<String> _displayName;

  /// What the app calls this machine everywhere: this device's alias, else the name the
  /// host gives itself.
  ValueListenable<String> get displayName => _displayName;

  /// The name the host gives itself (the last one it said, else the saved one).
  String get ownName => _machineName.value ?? _machine.label;

  void _updateDisplayName() => _displayName.value = _machine.alias ?? ownName;

  final ValueNotifier<LinkState> _link = ValueNotifier(LinkState.offline);
  final ValueNotifier<LinkRoute?> _route = ValueNotifier(null);
  final ValueNotifier<List<SessionSummary>> _sessions = ValueNotifier(const []);
  final ValueNotifier<UsageSnapshot?> _usage = ValueNotifier(null);
  final ValueNotifier<String?> _machineName = ValueNotifier(null);
  final ValueNotifier<String?> _lastError = ValueNotifier(null);
  final ValueNotifier<DirListing?> _dirListing = ValueNotifier(null);
  final ValueNotifier<bool> _hooksInstalled = ValueNotifier(true);
  final ValueNotifier<Compatibility?> _compatibility = ValueNotifier(null);
  final ValueNotifier<UsageLimit?> _usageLimit = ValueNotifier(null);
  final _resumeReports = StreamController<ResumeReport>.broadcast();

  /// This machine's usage limit now (null: none, or an older host).
  ValueListenable<UsageLimit?> get usageLimit => _usageLimit;

  final ValueNotifier<AccountsMessage?> _accounts = ValueNotifier(null);
  final _signIns = StreamController<AccountSignInUpdate>.broadcast();
  final _accountReplies = StreamController<void>.broadcast();
  bool _accountsSynced = false;

  /// The machine's accounts: its own login, the accounts it holds and the active one (null:
  /// not known yet, or an older host without accounts).
  ValueListenable<AccountsMessage?> get accounts => _accounts;

  /// The steps of account sign-ins this device started on the machine.
  Stream<AccountSignInUpdate> get signIns => _signIns.stream;

  /// Whether the host knows accounts (it sent its accounts message).
  bool get supportsAccounts => _accounts.value != null;

  /// Gives the host every account of [accountSource] (and has it forget removed ones).
  void syncAccounts() {
    final src = accountSource;
    final host = _accounts.value;
    if (src == null || host == null || _link.value != LinkState.online || !canControl) return;
    final all = src.withTokens;
    if (all.isNotEmpty) _send(SyncAccounts(accounts: all));
    for (final a in host.accounts) {
      if (src.removed.contains(a.id)) _send(RemoveAccount(accountId: a.id));
    }
  }

  /// The machine forgets [accountId] (its token too).
  void removeAccount(String accountId) {
    if (supportsAccounts && _link.value == LinkState.online) _send(RemoveAccount(accountId: accountId));
  }

  /// New sessions on this machine start on [accountId] ([machineLoginAccountId]: the
  /// machine's own login). Completes when the host has it.
  Future<void> setActiveAccount(String accountId) =>
      _awaitAccounts(SetActiveAccount(accountId: accountId), (m) => m.activeAccountId == accountId);

  Future<void> _awaitAccounts(ClientMessage m, bool Function(AccountsMessage m) done) async {
    if (_link.value != LinkState.online) throw const SessionActionFailed('Not connected to this machine.');
    if (!supportsAccounts) throw const SessionActionFailed(olderHostAccountsMessage);
    final finished = Completer<void>();
    final subs = <StreamSubscription<dynamic>>[
      _accountReplies.stream.listen((_) {
        final now = _accounts.value;
        if (now != null && done(now) && !finished.isCompleted) finished.complete();
      }),
      _errors.stream.listen((e) {
        if (finished.isCompleted) return;
        finished.completeError(SessionActionFailed(isUnknownMessageError(e) ? olderHostAccountsMessage : e.message));
      }),
    ];
    try {
      _send(m);
      await finished.future.timeout(actionTimeout,
          onTimeout: () => throw const SessionActionFailed('The machine did not answer. Try again.'));
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
    }
  }

  /// One step of adding an account (the answers arrive on [signIns]; a refusal on [errors]).
  void accountSignIn(AccountSignIn step) => _send(step);

  /// Ends [sessionId] and resumes its conversation on [accountId] in a new terminal window.
  Future<String> switchSessionAccount(String sessionId, String accountId) =>
      _act(SwitchSessionAccount(sessionId: sessionId, accountId: accountId), SessionActions.switchAccount);

  /// Sessions that resumed after a usage limit (a toast for those that changed).
  Stream<ResumeReport> get resumeReports => _resumeReports.stream;

  /// The owner's usage-limit choice ([choice] one of [LimitChoices]): for the machine, or
  /// with [sessionId] for that session only. Completes when the host has it; throws
  /// [SessionActionFailed] with what to tell the owner.
  Future<void> chooseLimit(String choice, {String? sessionId, String? accountId, bool makeDefault = false}) async {
    if (_link.value != LinkState.online) throw const SessionActionFailed('Not connected to this machine.');
    final done = Completer<void>();
    final subs = <StreamSubscription<dynamic>>[
      _limitReplies.stream.listen((_) {
        if (!done.isCompleted) done.complete();
      }),
      _errors.stream.listen((e) {
        if (done.isCompleted) return;
        done.completeError(SessionActionFailed(isUnknownMessageError(e) ? olderHostLimitMessage : e.message));
      }),
    ];
    try {
      _send(UsageLimitChoice(choice: choice, sessionId: sessionId, accountId: accountId, makeDefault: makeDefault));
      await done.future.timeout(actionTimeout,
          onTimeout: () => throw const SessionActionFailed('The machine did not answer. Try again.'));
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
    }
  }

  final _limitReplies = StreamController<void>.broadcast();

  // ------------------------------------------------------------ task board

  final ValueNotifier<List<BoardTask>?> _tasks = ValueNotifier(null);
  final ValueNotifier<ModelTable?> _hostModels = ValueNotifier(null);
  final ValueNotifier<ProjectList?> _hostProjects = ValueNotifier(null);

  /// The project list the host has (null: not known yet, or an older host).
  ValueListenable<ProjectList?> get hostProjects => _hostProjects;
  final _taskReplies = StreamController<void>.broadcast();
  final _remotes = StreamController<List<GitFolder>>.broadcast();

  /// The machine's tasks (null: not known yet, or an older host without a board).
  ValueListenable<List<BoardTask>?> get tasks => _tasks;

  /// The model table the host has (null: not known yet, or an older host).
  ValueListenable<ModelTable?> get hostModelTable => _hostModels;

  /// Whether the host has a task board (it sent its tasks).
  bool get supportsTasks => _tasks.value != null;

  /// When the host last said `welcome` (null: not online yet).
  DateTime? onlineSince;

  /// How long after `welcome` a host without tasks counts as an older one.
  Duration boardGrace = const Duration(seconds: 4);

  /// The host has been online a while without sending tasks: it runs an older Perch.
  bool get boardMissing {
    final since = onlineSince;
    return _link.value == LinkState.online &&
        _tasks.value == null &&
        since != null &&
        DateTime.now().difference(since) >= boardGrace;
  }

  /// Sends [m] and completes when the host's tasks satisfy [done]; throws
  /// [SessionActionFailed] with what to tell the owner.
  Future<void> _taskAct(ClientMessage m, bool Function(List<BoardTask> tasks) done) async {
    if (_link.value != LinkState.online) throw const SessionActionFailed('Not connected to this machine.');
    if (!canControl) throw const SessionActionFailed(watchOnlyMessage);
    final finished = Completer<void>();
    final subs = <StreamSubscription<dynamic>>[
      _taskReplies.stream.listen((_) {
        final now = _tasks.value;
        if (now != null && done(now) && !finished.isCompleted) finished.complete();
      }),
      _errors.stream.listen((e) {
        if (finished.isCompleted) return;
        finished.completeError(SessionActionFailed(isUnknownMessageError(e) ? olderHostTasksMessage : e.message));
      }),
    ];
    try {
      _send(m);
      await finished.future.timeout(actionTimeout,
          onTimeout: () => throw const SessionActionFailed('The machine did not answer. Try again.'));
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
    }
  }

  BoardTask? _task(List<BoardTask> tasks, String id) => tasks.where((t) => t.id == id).firstOrNull;

  /// Creates or edits a task on this machine; completes when the machine has it.
  Future<void> saveTask(BoardTask task) {
    final before = _tasks.value == null ? null : _task(_tasks.value!, task.id)?.updatedAtMs;
    return _taskAct(SaveTask(task: task), (all) {
      final t = _task(all, task.id);
      return t != null && (before == null || t.updatedAtMs > before) && t.title == task.title.trim();
    });
  }

  Future<void> moveTask(String id, TaskColumn column) =>
      _taskAct(MoveTask(taskId: id, column: column), (all) => _task(all, id)?.column == column);

  Future<void> deleteTask(String id) => _taskAct(DeleteTask(taskId: id), (all) => _task(all, id) == null);

  /// Sends the task to Claude (a new session, or [sessionId]); completes when the card is
  /// in progress.
  Future<void> runTask(String id, {String? sessionId}) {
    final before = _tasks.value == null ? null : _task(_tasks.value!, id)?.sentAtMs;
    return _taskAct(RunTask(taskId: id, sessionId: sessionId), (all) {
      final t = _task(all, id);
      return t != null && t.column == TaskColumn.inProgress && t.sentAtMs != null && t.sentAtMs != before;
    });
  }

  Future<void> sendTaskNotes(String id, String notes) {
    final before = _tasks.value == null ? null : _task(_tasks.value!, id)?.sentAtMs;
    return _taskAct(TaskNotes(taskId: id, notes: notes), (all) {
      final t = _task(all, id);
      return t != null && t.column == TaskColumn.inProgress && t.sentAtMs != before;
    });
  }

  /// The git remotes of the machine's known folders.
  Future<List<GitFolder>> gitRemotes() async {
    if (_link.value != LinkState.online) throw const SessionActionFailed('Not connected to this machine.');
    final done = Completer<List<GitFolder>>();
    final subs = <StreamSubscription<dynamic>>[
      _remotes.stream.listen((f) {
        if (!done.isCompleted) done.complete(f);
      }),
      _errors.stream.listen((e) {
        if (done.isCompleted) return;
        done.completeError(SessionActionFailed(isUnknownMessageError(e) ? olderHostTasksMessage : e.message));
      }),
    ];
    try {
      _send(const ListGitRemotes());
      return await done.future.timeout(actionTimeout,
          onTimeout: () => throw const SessionActionFailed('The machine did not answer. Try again.'));
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
    }
  }

  /// Gives the host the phone's model table (it keeps the newer one). A host with board
  /// sync gets it as a record instead.
  void syncModelTable() {
    final src = modelSource;
    if (src == null || _boardSync || _link.value != LinkState.online || _hostModels.value == null || !canControl) return;
    _send(SyncModelTable(table: src.table));
  }

  void _onHostModels(ModelTable table) {
    _hostModels.value = table;
    final src = modelSource;
    if (src == null || _boardSync) return;
    if (table.updatedAtMs > src.table.updatedAtMs) {
      src.adopt(table);
    } else if (table.updatedAtMs < src.table.updatedAtMs && canControl) {
      _send(SyncModelTable(table: src.table));
    }
  }

  final _commands = StreamController<CommandsMessage>.broadcast();
  final Map<String, List<SlashCommandInfo>> _commandCache = {};

  /// The slash commands [sessionId] can run (Claude Code's own, the owner's, the project's,
  /// plugins'), asked once per session while connected; empty when the host cannot say (an
  /// older host).
  Future<List<SlashCommandInfo>> listCommands(String sessionId) async {
    final hit = _commandCache[sessionId];
    if (hit != null) return hit;
    if (_link.value != LinkState.online) return const [];
    final done = Completer<List<SlashCommandInfo>>();
    final subs = <StreamSubscription<dynamic>>[
      _commands.stream.listen((m) {
        if (m.sessionId == sessionId && !done.isCompleted) done.complete(m.commands);
      }),
      _errors.stream.listen((e) {
        if (!done.isCompleted && isUnknownMessageError(e)) done.complete(const []);
      }),
    ];
    try {
      _send(ListCommands(sessionId: sessionId));
      final list = await done.future.timeout(actionTimeout, onTimeout: () => const []);
      if (list.isNotEmpty) _commandCache[sessionId] = list;
      return list;
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
    }
  }

  final _files = StreamController<FilesMessage>.broadcast();

  /// The files and folders of [sessionId]'s folder matching [query] (what follows `@`), best
  /// first; empty when offline or the host is slow, null when the host cannot list them (an
  /// older host).
  Future<List<FileMention>?> listFiles(String sessionId, String query) async {
    if (_link.value != LinkState.online) return const [];
    final done = Completer<List<FileMention>?>();
    final subs = <StreamSubscription<dynamic>>[
      _files.stream.listen((m) {
        if (m.sessionId == sessionId && m.query == query && !done.isCompleted) done.complete(m.files);
      }),
      _errors.stream.listen((e) {
        if (!done.isCompleted && isUnknownMessageError(e)) done.complete(null);
      }),
    ];
    try {
      _send(ListFiles(sessionId: sessionId, query: query));
      return await done.future.timeout(actionTimeout, onTimeout: () => const []);
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
    }
  }

  final _searches = StreamController<SearchResults>.broadcast();

  /// Searches every conversation on this machine for [query]. Null when the host cannot
  /// search (an older host: [olderHostSearchMessage]); an empty result when offline or the
  /// host does not answer in time.
  Future<SearchResults?> searchSessions(String query) async {
    if (_link.value != LinkState.online) return SearchResults(query: query, hits: const []);
    final done = Completer<SearchResults?>();
    final subs = <StreamSubscription<dynamic>>[
      _searches.stream.listen((m) {
        if (m.query == query && !done.isCompleted) done.complete(m);
      }),
      _errors.stream.listen((e) {
        if (!done.isCompleted && isUnknownMessageError(e)) done.complete(null);
      }),
    ];
    try {
      _send(SearchSessions(query: query));
      return await done.future
          .timeout(const Duration(seconds: 15), onTimeout: () => SearchResults(query: query, hits: const []));
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
    }
  }

  /// Gives the host the phone's project list (it keeps the newer one).
  void syncProjects() {
    final src = projectSource;
    if (src == null || _boardSync || _link.value != LinkState.online || _hostProjects.value == null || !canControl) return;
    _send(SyncProjects(projects: src.projects));
  }

  void _onHostProjects(ProjectList list) {
    _hostProjects.value = list;
    final src = projectSource;
    if (src == null || _boardSync) return;
    if (list.updatedAtMs > src.projects.updatedAtMs) {
      src.adoptProjects(list);
    } else if (list.updatedAtMs < src.projects.updatedAtMs && canControl) {
      _send(SyncProjects(projects: src.projects));
    }
  }

  /// Switches a running session's model ([model] null: the default).
  Future<String> setSessionModel(String sessionId, String? model) =>
      _act(SetSessionModel(sessionId: sessionId, model: model), SessionActions.model);

  /// Sends [m] once the connection is online (now, or when it gets there within
  /// [within]); false when it did not.
  Future<bool> sendWhenOnline(ClientMessage m, {Duration within = const Duration(seconds: 20)}) async {
    if (_link.value != LinkState.online) {
      final online = Completer<void>();
      void check() {
        if (_link.value == LinkState.online && !online.isCompleted) online.complete();
      }

      _link.addListener(check);
      try {
        if (_link.value == LinkState.offline && !_disposed) connect();
        await online.future.timeout(within);
      } on TimeoutException {
        return false;
      } finally {
        _link.removeListener(check);
      }
    }
    _send(m);
    return true;
  }

  /// The owner closed the "instant updates are off" note for this machine.
  final ValueNotifier<bool> hooksNoteDismissed = ValueNotifier(false);
  final _errors = StreamController<ErrorMessage>.broadcast();
  final Map<String, SessionFeed> _feeds = {};

  /// The connection in use (handshake done), and the ones still being tried.
  _Attempt? _active;
  final List<_Attempt> _pending = [];
  int _generation = 0;

  /// A relay socket told `hostOffline`, waiting for `hostOnline`.
  _Attempt? _waiting;

  /// LAN tries while on the relay.
  final List<_Attempt> _probes = [];
  Timer? _lanTimer;
  Timer? _relayTimer;
  Timer? _probeTimer;
  Timer? _probeTimeout;
  bool _relayTried = false;
  bool _badKey = false;
  String? _olderHost;
  Timer? _retry;
  Duration _backoff = const Duration(seconds: 1);
  bool _disposed = false;

  ValueListenable<LinkState> get link => _link;

  final ValueNotifier<String> _permission = ValueNotifier(DevicePermissions.full);
  final ValueNotifier<DevicesMessage?> _devices = ValueNotifier(null);

  /// What this device may do on the machine ([DevicePermissions]; an older host: full).
  ValueListenable<String> get permission => _permission;

  /// Whether this device may act (not only watch). The host refuses anyway.
  bool get canControl => _permission.value == DevicePermissions.full;

  /// The machine's devices and pending requests (full-control devices; null: not known).
  ValueListenable<DevicesMessage?> get devices => _devices;

  void listDevices() => _send(const ListDevices());
  void decideDevice(String deviceId, String decision) => _send(DecideDevice(deviceId: deviceId, decision: decision));
  void setDevicePermission(String deviceId, String permission) =>
      _send(SetDevicePermission(deviceId: deviceId, permission: permission));
  void renameDevice(String deviceId, String name) => _send(RenameDevice(deviceId: deviceId, name: name));
  void removeDevice(String deviceId) => _send(RemoveDevice(deviceId: deviceId));

  /// After the machine removed this device (or forgot its key): drops the key and asks to
  /// pair again with the pairing secret (the machine must allow it).
  void askToPairAgain() {
    if (machine.deviceKey != null) _changed(machine.copyWith(clearDeviceKey: true));
    connect();
  }

  /// How the connection reaches the host (null while not connected).
  ValueListenable<LinkRoute?> get route => _route;
  ValueListenable<List<SessionSummary>> get sessions => _sessions;
  ValueListenable<UsageSnapshot?> get usage => _usage;
  ValueListenable<String?> get machineName => _machineName;

  /// Whether the host has Perch's Claude Code hooks (cards and states arrive at once).
  ValueListenable<bool> get hooksInstalled => _hooksInstalled;

  /// Whether the host still understands its Claude Code (null: an older host).
  ValueListenable<Compatibility?> get compatibility => _compatibility;

  /// The answer to the last [listDir]; null while it is on its way.
  ValueListenable<DirListing?> get dirListing => _dirListing;

  /// The last `error` message from the host.
  ValueListenable<String?> get lastError => _lastError;

  /// Every `error` message from the host, as it arrives.
  Stream<ErrorMessage> get errors => _errors.stream;
  final _actionsDone = StreamController<SessionActionDone>.broadcast();

  /// Renames a session for Claude Code too; completes with the host's line, or throws
  /// [SessionActionFailed] with what to tell the owner.
  Future<String> renameSession(String sessionId, String name) =>
      _act(RenameSession(sessionId: sessionId, name: name), SessionActions.rename);

  /// Deletes a session for Claude Code too (ends it first if it runs).
  Future<String> deleteSession(String sessionId) => _act(DeleteSession(sessionId: sessionId), SessionActions.delete);

  /// Resumes a session that is not running in a terminal window on the machine.
  Future<String> resumeSession(String sessionId) => _act(ResumeSession(sessionId: sessionId), SessionActions.resume);

  /// How long a session menu action may take (a resume waits for the terminal window).
  Duration actionTimeout = const Duration(seconds: 90);

  Future<String> _act(ClientMessage m, String action) async {
    if (_link.value != LinkState.online) throw const SessionActionFailed('Not connected to this machine.');
    if (!canControl) throw const SessionActionFailed(watchOnlyMessage);
    final done = Completer<String>();
    final subs = <StreamSubscription<dynamic>>[
      _actionsDone.stream.listen((d) {
        if (d.action == action && !done.isCompleted) done.complete(d.message);
      }),
      _errors.stream.listen((e) {
        if (done.isCompleted) return;
        done.completeError(SessionActionFailed(isUnknownMessageError(e) ? olderHostActionMessage : e.message));
      }),
    ];
    try {
      _send(m);
      return await done.future.timeout(actionTimeout,
          onTimeout: () => throw const SessionActionFailed('The machine did not answer. Try again.'));
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
    }
  }

  /// The LAN WebSocket URIs, in the order of the pairing link.
  List<Uri> get lanUris => [
        for (final a in machine.lan)
          if (_hostPort(a) case final hp?) Uri(scheme: 'ws', host: hp.$1, port: hp.$2, path: '/ws')
      ];

  static (String, int)? _hostPort(String a) {
    final i = a.lastIndexOf(':');
    if (i <= 0) return null;
    final p = int.tryParse(a.substring(i + 1));
    return p == null ? null : (a.substring(0, i), p);
  }

  /// The relay WebSocket URI for this device, or null without a relay.
  Uri? get relayUri {
    final url = machine.relayUrl;
    final secret = machine.secretBytes;
    if (url == null || secret == null) return null;
    return relaySocketUri(url, machine.id, 'device', {'d': deviceId, 't': relayDeviceToken(secret)});
  }

  /// Connects now: every LAN address at once (the first to finish the handshake wins);
  /// with no answer within [lanTimeout], the relay. While on the relay it tries the LAN
  /// again every [lanRetryInterval] and moves over quietly when it answers. Afterwards it
  /// reconnects by itself with 1s, 2s, 4s … max 15s backoff, but never when pairing is
  /// needed, the host is too old, or it stopped remote access.
  void connect() {
    if (_disposed) return;
    _retry?.cancel();
    _closeAll();
    if (machine.needsPairing) {
      _link.value = LinkState.needsPairing;
      return;
    }
    _link.value = LinkState.connecting;
    final gen = ++_generation;
    _badKey = false;
    _olderHost = null;
    _relayTried = false;
    for (final uri in lanUris) {
      _start(LinkRoute.lan, uri, gen);
    }
    if (_pending.isEmpty) {
      _lanFailed(gen);
      return;
    }
    _lanTimer = Timer(lanTimeout, () {
      if (gen != _generation || _active != null) return;
      for (final a in _pending.toList()) {
        a.close();
      }
      _pending.clear();
      _lanFailed(gen);
    });
  }

  void _start(LinkRoute route, Uri uri, int gen, {bool probe = false}) {
    final secret = machine.channelSecret;
    if (secret == null) return;
    final WebSocketChannel ch;
    try {
      ch = _factory(uri);
    } catch (e) {
      _lastError.value = '$e';
      return;
    }
    final a = _Attempt(route, ch, ClientHandshake(secret: secret, machineId: machine.id, deviceId: deviceId))
      ..probe = probe;
    (probe ? _probes : _pending).add(a);
    ch.ready.catchError((Object _) {});
    a.sub = ch.stream.listen(
      (frame) => _onRaw(a, frame, gen),
      onDone: () => _attemptEnded(a, gen),
      onError: (Object _) => _attemptEnded(a, gen),
      cancelOnError: true,
    );
    a.add(a.handshake.hello);
  }

  void _onRaw(_Attempt a, dynamic frame, int gen) {
    if (gen != _generation || a.closed) return;
    if (frame is String) {
      if (a.route == LinkRoute.relay) {
        _onRelayControl(a, frame);
      } else if (!identical(a, _active) && !a.probe) {
        // A phase 1 host answering in the clear.
        if (decodeHost(frame) is ErrorMessage) _olderHost = olderHostMessage;
        _dropAttempt(a, gen);
      }
      return;
    }
    final bytes = frame is Uint8List ? frame : Uint8List.fromList((frame as List).cast<int>());
    if (identical(a, _active)) {
      final String? text;
      try {
        text = a.session!.open(bytes);
      } on ChannelError catch (e) {
        a.close();
        _active = null;
        _route.value = null;
        _stopProbing();
        if (e.reason == ChannelErrors.badKey) {
          _setNeedsPairing();
        } else if (e.reason == ErrorCodes.deviceRemoved) {
          _setRemoved();
        } else {
          _onDisconnected();
        }
        return;
      }
      if (text != null) _onFrame(text);
      return;
    }
    if (identical(a, _waiting)) return;
    try {
      a.session = a.handshake.finish(bytes);
    } on ChannelError catch (e) {
      if (a.probe) {
        a.close();
        _probes.remove(a);
        return;
      }
      if (e.reason == ChannelErrors.badKey) _badKey = true;
      _dropAttempt(a, gen);
      return;
    }
    if (a.probe) {
      _switchToLan(a);
      return;
    }
    if (_active != null) {
      _dropAttempt(a, gen);
      return;
    }
    _adopt(a);
  }

  /// `hostOffline` / `hostOnline` from the relay.
  void _onRelayControl(_Attempt a, String text) {
    Object? m;
    try {
      m = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (m is! Map) return;
    switch (m['t']) {
      case 'hostOffline':
        if (identical(a, _active)) {
          _active = null;
          _route.value = null;
        }
        _pending.remove(a);
        _relayTimer?.cancel();
        if (_waiting != null && !identical(_waiting, a)) _waiting!.close();
        _waiting = a;
        _lastError.value = 'The machine is not connected to the relay.';
        _link.value = LinkState.offline;
        _startProbing();
      case 'hostOnline':
        if (identical(a, _waiting)) connect();
    }
  }

  void _adopt(_Attempt a) {
    _pending.remove(a);
    for (final other in _pending) {
      other.close();
    }
    _pending.clear();
    _lanTimer?.cancel();
    _relayTimer?.cancel();
    if (_waiting != null && !identical(_waiting, a)) _waiting!.close();
    _waiting = null;
    _active = a;
    _route.value = a.route;
    if (a.route == LinkRoute.relay) {
      _startProbing();
    } else {
      _stopProbing();
    }
    _send(Hello(deviceName: deviceName, pairing: 2));
  }

  void _dropAttempt(_Attempt a, int gen) {
    a.close();
    _pending.remove(a);
    if (_pending.isEmpty && _active == null && _waiting == null) _lanFailed(gen);
  }

  void _attemptEnded(_Attempt a, int gen) {
    if (gen != _generation) return;
    if (a.probe) {
      a.closed = true;
      _probes.remove(a);
      return;
    }
    if (identical(a, _active) || identical(a, _waiting)) {
      a.closed = true;
      if (identical(a, _active)) _active = null;
      if (identical(a, _waiting)) _waiting = null;
      _route.value = null;
      _stopProbing();
      _onDisconnected();
      return;
    }
    if (a.closed) return;
    _dropAttempt(a, gen);
  }

  /// No LAN address answered (or every answer was a refusal): the relay, if there is one.
  void _lanFailed(int gen) {
    if (gen != _generation || _active != null || _waiting != null) return;
    _lanTimer?.cancel();
    if (_badKey) {
      _setNeedsPairing();
      return;
    }
    if (_olderHost != null) {
      _lastError.value = _olderHost;
      _link.value = LinkState.refused;
      return;
    }
    final uri = relayUri;
    if (uri != null && !_relayTried) {
      _relayTried = true;
      _start(LinkRoute.relay, uri, gen);
      if (_pending.isEmpty) {
        _onDisconnected();
        return;
      }
      _relayTimer?.cancel();
      _relayTimer = Timer(relayTimeout, () {
        if (gen != _generation || _active != null || _waiting != null) return;
        for (final a in _pending.toList()) {
          a.close();
        }
        _pending.clear();
        _onDisconnected();
      });
      return;
    }
    _onDisconnected();
  }

  void _startProbing() {
    if (_probeTimer != null || lanUris.isEmpty) return;
    _probeTimer = Timer.periodic(lanRetryInterval, (_) => _probeLan());
  }

  void _stopProbing() {
    _probeTimer?.cancel();
    _probeTimer = null;
    _probeTimeout?.cancel();
    for (final p in _probes) {
      p.close();
    }
    _probes.clear();
  }

  /// One quiet try of the LAN addresses while on the relay.
  void _probeLan() {
    if (_active?.route == LinkRoute.lan) {
      _stopProbing();
      return;
    }
    for (final p in _probes) {
      p.close();
    }
    _probes.clear();
    for (final uri in lanUris) {
      _start(LinkRoute.lan, uri, _generation, probe: true);
    }
    _probeTimeout?.cancel();
    _probeTimeout = Timer(lanTimeout, () {
      for (final p in _probes) {
        p.close();
      }
      _probes.clear();
    });
  }

  /// The LAN answered while on the relay: move over (welcome then resubscribes the feeds).
  void _switchToLan(_Attempt a) {
    _probes.remove(a);
    _stopProbing();
    final old = _active ?? _waiting;
    _active = null;
    _waiting = null;
    old?.close();
    _relayTimer?.cancel();
    _active = a;
    _route.value = LinkRoute.lan;
    _send(Hello(deviceName: deviceName, pairing: 2));
  }

  void _setNeedsPairing() {
    if (machine.deviceKey != null) {
      // Its own key does not open the channel: the machine removed it (the pairing secret
      // may still be good: asking again needs no QR).
      _setRemoved();
      return;
    }
    _retry?.cancel();
    _lastError.value = 'This machine no longer knows this device. Pair again by scanning its QR code.';
    _link.value = LinkState.needsPairing;
  }

  void _setRemoved([String? message]) {
    _retry?.cancel();
    _lastError.value = message ?? '$ownName removed this device.';
    _link.value = LinkState.removed;
  }

  void _closeAll() {
    _lanTimer?.cancel();
    _relayTimer?.cancel();
    _stopProbing();
    for (final a in _pending) {
      a.close();
    }
    _pending.clear();
    _active?.close();
    _active = null;
    _waiting?.close();
    _waiting = null;
    _route.value = null;
  }

  void _onDisconnected() {
    if (_disposed) return;
    final s = _link.value;
    if (s == LinkState.refused ||
        s == LinkState.stopped ||
        s == LinkState.needsPairing ||
        s == LinkState.denied ||
        s == LinkState.removed) {
      return;
    }
    _link.value = LinkState.offline;
    _retry?.cancel();
    _retry = Timer(_backoff, connect);
    final next = _backoff * 2;
    _backoff = next > const Duration(seconds: 15) ? const Duration(seconds: 15) : next;
  }

  void _send(ClientMessage m) {
    final a = _active;
    final s = a?.session;
    if (a == null || s == null) return;
    try {
      for (final f in s.seal(encodeClient(m))) {
        a.add(f);
      }
    } catch (_) {}
  }

  void _updateRouteInfo(String? relayUrl, List<String> lan) {
    // The board page stays on the address it was opened from (localhost): the host lets
    // it in without approval only over loopback.
    if (deviceId == boardPageDeviceId) return;
    var m = machine;
    if (relayUrl != m.relayUrl) m = relayUrl == null ? m.copyWith(clearRelay: true) : m.copyWith(relayUrl: relayUrl);
    if (lan.isNotEmpty && !listEquals(lan, m.lan)) m = m.copyWith(lan: List.unmodifiable(lan));
    _changed(m);
  }

  /// The host told its own name (welcome or machineRenamed): it is saved as the
  /// machine's label, so cards and notifications have it while offline.
  void _setOwnName(String name) {
    _machineName.value = name;
    if (name.isNotEmpty && name != machine.label) {
      _changed(machine.copyWith(label: name));
    } else {
      _updateDisplayName();
    }
  }

  void _changed(Machine m) {
    if (identical(m, machine)) return;
    machine = m;
    onMachineUpdated?.call(m);
  }

  void _onFrame(String frame) {
    final m = decodeHost(frame);
    if (m == null) return; // unknown types are ignored
    switch (m) {
      case Welcome(
          :final machineName,
          :final hooksInstalled,
          :final compatibility,
          :final relayUrl,
          :final lanAddresses,
          :final permission,
          :final boardSync,
          :final attachments
        ):
        _permission.value = permission ?? DevicePermissions.full;
        _boardSync = boardSync;
        _attachments.value = attachments;
        if (!_welcomes.isClosed) _welcomes.add(m);
        _hostKeySeen = false;
        _awaitingBoardAnswer = false;
        if (_permission.value != DevicePermissions.full) _devices.value = null;
        _updateRouteInfo(relayUrl, lanAddresses);
        _setOwnName(machineName);
        _hooksInstalled.value = hooksInstalled;
        _compatibility.value = compatibility;
        // The host tells the limit right after (only when there is one).
        _usageLimit.value = null;
        // And its accounts (a host without accounts never does).
        _accounts.value = null;
        _accountsSynced = false;
        // And its tasks and model table (a host without a board never does).
        _tasks.value = null;
        _hostModels.value = null;
        _hostProjects.value = null;
        _commandCache.clear();
        onlineSince = DateTime.now();
        _link.value = LinkState.online;
        _backoff = const Duration(seconds: 1);
        if (focusedSession != null) _sendFocus();
        for (final f in _feeds.values) {
          f._loadingEarlier = false; // a request lost with the old link
          _send(Subscribe(sessionId: f.sessionId, afterSeq: f.lastSeq));
        }
        final bf = boardFile;
        if (boardSync && bf != null) {
          _awaitingBoardAnswer = true;
          _send(BoardSummaryFromApp(summary: bf.board.summary()));
        }
      case Sessions(:final sessions, :final usage):
        _sessions.value = List.unmodifiable(sessions);
        if (usage != null) _usage.value = usage;
      case SessionUpdated(:final session):
        final list = [..._sessions.value];
        final i = list.indexWhere((s) => s.id == session.id);
        if (i >= 0) {
          list[i] = session;
        } else {
          list.add(session);
        }
        _sessions.value = List.unmodifiable(list);
      case Events(:final sessionId, :final events, :final openPrompts, :final hasEarlier):
        final f = _feeds[sessionId];
        if (f != null) {
          f._addFirst(events, hasEarlier);
          f._setPrompts(openPrompts);
        }
      case EarlierEvents(:final sessionId, :final events, :final hasEarlier):
        _feeds[sessionId]?._prepend(events, hasEarlier);
      case EventMessage(:final sessionId, :final event):
        _feeds[sessionId]?._add([event]);
      case PromptOpened(:final sessionId, :final prompt):
        _feeds[sessionId]?._openPrompt(prompt);
      case PromptClosed(:final sessionId, :final promptId):
        _feeds[sessionId]?._closePrompt(promptId);
      case UsageMessage(:final usage):
        _usage.value = usage;
      case CompatibilityMessage(:final compatibility):
        _compatibility.value = compatibility;
      case ErrorMessage(:final code, :final message):
        _lastError.value = message;
        if (code == ErrorCodes.badCode || code == ErrorCodes.tooManyAttempts) {
          _link.value = LinkState.refused;
          _retry?.cancel();
        } else if (code == ErrorCodes.pairingDenied || code == ErrorCodes.pairingExpired) {
          _link.value = LinkState.denied;
          _retry?.cancel();
        } else if (code == ErrorCodes.deviceRemoved) {
          _setRemoved(message);
        } else if (code == ErrorCodes.awaitingApproval) {
          _link.value = LinkState.awaitingApproval;
        }
        if (!_errors.isClosed) _errors.add(m);
      case DirListing():
        _dirListing.value = m;
      case RemoteAccessStopped():
        _link.value = LinkState.stopped;
        _retry?.cancel();
      case MachineRenamed(:final machineName):
        _setOwnName(machineName);
      case SessionActionDone():
        if (!_actionsDone.isClosed) _actionsDone.add(m);
      case UsageLimitMessage(:final limit):
        _usageLimit.value = limit;
        if (!_limitReplies.isClosed) _limitReplies.add(null);
      case ResumeReport():
        if (!_resumeReports.isClosed) _resumeReports.add(m);
      case AccountsMessage():
        _accounts.value = m;
        if (!_accountsSynced) {
          _accountsSynced = true;
          syncAccounts();
        }
        if (!_accountReplies.isClosed) _accountReplies.add(null);
      case AccountSignInUpdate():
        if (!_signIns.isClosed) _signIns.add(m);
      case TasksMessage(:final tasks):
        _tasks.value = List.unmodifiable(tasks);
        _mergeLegacyTasks(tasks);
        if (!_taskReplies.isClosed) _taskReplies.add(null);
      case GitRemotesMessage(:final folders):
        if (!_remotes.isClosed) _remotes.add(folders);
      case ModelTableMessage(:final table):
        _onHostModels(table);
      case ProjectsMessage(:final projects):
        _onHostProjects(projects);
      case CommandsMessage():
        if (!_commands.isClosed) _commands.add(m);
      case FilesMessage():
        if (!_files.isClosed) _files.add(m);
      case SearchResults():
        if (!_searches.isClosed) _searches.add(m);
      case PairingPending(:final machineName):
        if (machineName.isNotEmpty) _setOwnName(machineName);
        _lastError.value = 'Waiting for approval on $ownName. Allow this device there.';
        _link.value = LinkState.awaitingApproval;
        _backoff = const Duration(seconds: 1);
      case DeviceKey(:final key, :final permission):
        _permission.value = permission;
        if (key != machine.deviceKey) _changed(machine.copyWith(deviceKey: key));
      case DevicesMessage(:final devices):
        _devices.value = m;
        final me = devices.where((d) => d.thisDevice).firstOrNull;
        if (me != null) _permission.value = me.permission;
      case BoardSummaryFromHost(:final summary):
        _onBoardSummary(summary);
      case BoardRecordsFromHost(:final records):
        unawaited(_onBoardRecords(records));
      case BoardKeyFromHost(:final boardId, :final key, :final keyVersion):
        unawaited(_onBoardKey(boardId, key, keyVersion));
      case AttachAccepted() || AttachProgress() || AttachDone() || AttachFailed():
        if (!_attachEvents.isClosed) _attachEvents.add(m);
    }
  }

  /// The feed for a session (cached). Subscribes from its last seen event.
  SessionFeed feed(String sessionId) {
    final existing = _feeds[sessionId];
    if (existing != null) return existing;
    final f = SessionFeed(sessionId);
    _feeds[sessionId] = f;
    if (_link.value == LinkState.online) _send(Subscribe(sessionId: sessionId, afterSeq: f.lastSeq));
    return f;
  }

  /// Asks for the page of events before the first one this device has (once at a time).
  void loadEarlier(String sessionId) {
    final f = _feeds[sessionId];
    if (f == null || !f._hasEarlier.value || f._loadingEarlier || f._events.value.isEmpty) return;
    if (_link.value != LinkState.online) return;
    f._loadingEarlier = true;
    _send(LoadEarlier(sessionId: sessionId, beforeSeq: f._events.value.first.seq));
  }

  void startSession({required String cwd, required String prompt, String? name, String? model, String? accountId}) =>
      _send(StartSession(
          cwd: cwd,
          prompt: prompt,
          name: (name == null || name.trim().isEmpty) ? null : name.trim(),
          model: (model == null || model.trim().isEmpty) ? null : model.trim(),
          accountId: accountId));
  void send(String sessionId, String text) => _send(SendMessage(sessionId: sessionId, text: text));
  void answer(String sessionId, String promptId, PromptAnswer answer) =>
      _send(AnswerPrompt(sessionId: sessionId, promptId: promptId, answer: answer));
  void interrupt(String sessionId) => _send(Interrupt(sessionId: sessionId));
  void stopSession(String sessionId) => _send(StopSession(sessionId: sessionId));
  void takeOver(String sessionId, {bool force = false}) => _send(TakeOver(sessionId: sessionId, force: force));
  void killAll() => _send(const KillAll());

  /// Turns the host's self-test of new Claude Code versions on or off.
  void setSelfTest(bool enabled) => _send(SetSelfTest(enabled: enabled));

  /// Runs the host's self-test now.
  void runSelfTest() => _send(const RunSelfTest());
  void listSessions() => _send(const ListSessions());

  /// Asks for the sub-folders of [path] on the host (null: the roots and suggestions).
  void listDir(String? path) {
    _dirListing.value = null;
    _send(ListDir(path: path));
  }

  String? _focus;
  bool _foreground = true;

  /// The session this device shows now, as the host is told it (none in the background).
  String? get focusedSession => _foreground ? _focus : null;

  /// A session screen opened: the host sends this device no notification for it.
  void focusSession(String sessionId) {
    if (_focus == sessionId) return;
    _focus = sessionId;
    _sendFocus();
  }

  /// That session screen closed.
  void unfocusSession(String sessionId) {
    if (_focus != sessionId) return;
    _focus = null;
    _sendFocus();
  }

  /// The app went to the background (false) or came back (true).
  set appInForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    _sendFocus();
  }

  void _sendFocus() {
    if (_link.value == LinkState.online) _send(FocusSession(sessionId: focusedSession));
  }

  /// Removes a prompt locally (after the host said it was already answered elsewhere).
  void dropPrompt(String sessionId, String promptId) => _feeds[sessionId]?._closePrompt(promptId);

  void dispose() {
    _disposed = true;
    for (final s in _boardSubs) {
      s.cancel();
    }
    _retry?.cancel();
    _closeAll();
    for (final f in _feeds.values) {
      f._dispose();
    }
    _feeds.clear();
    _errors.close();
    _actionsDone.close();
    _permission.dispose();
    _devices.dispose();
    _resumeReports.close();
    _limitReplies.close();
    _signIns.close();
    _accountReplies.close();
    _taskReplies.close();
    _remotes.close();
    _commands.close();
    _files.close();
    _searches.close();
    _attachEvents.close();
    _welcomes.close();
    _attachments.dispose();
  }
}
