// WebSocket wire messages: one JSON object per text frame, discriminated by "type".
import 'dart:convert';

import 'accounts.dart';
import 'board.dart';
import 'hlc.dart';
import 'models.dart';
import 'tasks.dart';

abstract final class ErrorCodes {
  static const badCode = 'badCode';
  static const tooManyAttempts = 'tooManyAttempts';
  static const noSuchSession = 'noSuchSession';
  static const readOnlySession = 'readOnlySession';
  static const promptAlreadyAnswered = 'promptAlreadyAnswered';
  static const spawnFailed = 'spawnFailed';
  static const sessionBusy = 'sessionBusy';
  static const takeoverFailed = 'takeoverFailed';

  /// The host could not type into a terminal session; the app may offer a take-over.
  static const cannotType = 'cannotType';

  /// The host could not answer a card in a terminal session (the screen was not what it
  /// expected); the owner answers it at the machine. The card stays open.
  static const cannotAnswerInTerminal = 'cannotAnswerInTerminal';
  static const badRequest = 'badRequest';

  /// An older app asked to pair: the device waits until it is allowed at the machine,
  /// then connects by itself (the host closes the connection after this message).
  static const awaitingApproval = 'awaitingApproval';

  /// An app too old to take its own device key: the machine no longer lets it in (keyless
  /// access was removed on 2026-11-19); the message says to update Perch.
  static const updateApp = 'updateApp';

  /// The machine refused this device's request to pair.
  static const pairingDenied = 'pairingDenied';

  /// Nobody decided the request in time.
  static const pairingExpired = 'pairingExpired';

  /// The machine removed this device (its key no longer opens the channel).
  static const deviceRemoved = 'deviceRemoved';

  /// This device may only watch on this machine.
  static const watchOnly = 'watchOnly';
}

/// What a device may do on a machine.
abstract final class DevicePermissions {
  static const full = 'full';
  static const watch = 'watch';
  static const all = [full, watch];
}

/// The answers to a device's request to pair.
abstract final class DeviceDecisions {
  static const full = 'full';
  static const watch = 'watch';
  static const deny = 'deny';
  static const all = [full, watch, deny];
}

/// The device id of the board page in a browser on the machine itself: the host lets it in
/// over a loopback connection without approval and keeps no record of it.
const boardPageDeviceId = 'board-page';

/// Longest device name a host accepts.
const maxDeviceNameLength = 40;

/// What every host answers a message type it does not know (older hosts included).
const unknownMessageText = 'Unknown or malformed message.';

/// Whether [e] is a host's answer to a message type it does not know: the host runs an
/// older Perch.
bool isUnknownMessageError(ErrorMessage e) => e.code == ErrorCodes.badRequest && e.message == unknownMessageText;

/// The session actions a [SessionActionDone] reports.
abstract final class SessionActions {
  static const rename = 'rename';
  static const delete = 'delete';
  static const resume = 'resume';
  static const switchAccount = 'switchAccount';

  /// The session's model was switched ([SetSessionModel]).
  static const model = 'model';
}

String _str(Object? v, [String fallback = '']) => v is String ? v : fallback;
String? _strOrNull(Object? v) => v is String ? v : null;
int _int(Object? v) => v is num ? v.toInt() : 0;
Map<String, dynamic> _map(Object? v) {
  if (v is Map) return v.cast<String, dynamic>();
  throw const FormatException('expected an object');
}

// ---------------------------------------------------------------- app -> host

sealed class ClientMessage {
  const ClientMessage();
  String get type;
  Map<String, dynamic> fields() => const {};
  Map<String, dynamic> toJson() => {'type': type, ...fields()};
}

/// The first message inside the encrypted channel. [code] is the retired phase 1 pairing
/// code: kept on the wire, sent empty, ignored by the host.
class Hello extends ClientMessage {
  final String code;
  final String deviceName;

  /// The pairing scheme the app speaks: 2 = it waits for approval and takes its own
  /// device key. Null from older apps.
  final int? pairing;
  const Hello({this.code = '', required this.deviceName, this.pairing});
  @override
  String get type => 'hello';
  @override
  Map<String, dynamic> fields() => {'code': code, 'deviceName': deviceName, 'pairing': ?pairing};
}

class ListSessions extends ClientMessage {
  const ListSessions();
  @override
  String get type => 'listSessions';
}

class StartSession extends ClientMessage {
  final String cwd;
  final String prompt;
  final String? name;
  final String? model;

  /// The account to start it on; null: the machine's active account. Older hosts ignore it.
  final String? accountId;
  const StartSession({required this.cwd, required this.prompt, this.name, this.model, this.accountId});
  @override
  String get type => 'startSession';
  @override
  Map<String, dynamic> fields() =>
      {'cwd': cwd, 'prompt': prompt, 'name': name, 'model': model, 'accountId': ?accountId};
}

class Subscribe extends ClientMessage {
  final String sessionId;
  final int afterSeq;
  const Subscribe({required this.sessionId, this.afterSeq = 0});
  @override
  String get type => 'subscribe';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId, 'afterSeq': afterSeq};
}

/// Asks for the page of events just before [beforeSeq] (answered with `earlierEvents`).
class LoadEarlier extends ClientMessage {
  final String sessionId;
  final int beforeSeq;
  const LoadEarlier({required this.sessionId, required this.beforeSeq});
  @override
  String get type => 'loadEarlier';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId, 'beforeSeq': beforeSeq};
}

class SendMessage extends ClientMessage {
  final String sessionId;
  final String text;
  const SendMessage({required this.sessionId, required this.text});
  @override
  String get type => 'sendMessage';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId, 'text': text};
}

class AnswerPrompt extends ClientMessage {
  final String sessionId;
  final String promptId;
  final PromptAnswer answer;
  const AnswerPrompt({required this.sessionId, required this.promptId, required this.answer});
  @override
  String get type => 'answerPrompt';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId, 'promptId': promptId, 'answer': answer.toJson()};
}

class Interrupt extends ClientMessage {
  final String sessionId;
  const Interrupt({required this.sessionId});
  @override
  String get type => 'interrupt';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId};
}

class StopSession extends ClientMessage {
  final String sessionId;
  const StopSession({required this.sessionId});
  @override
  String get type => 'stopSession';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId};
}

class KillAll extends ClientMessage {
  const KillAll();
  @override
  String get type => 'killAll';
}

class TakeOver extends ClientMessage {
  final String sessionId;
  final bool force;
  const TakeOver({required this.sessionId, this.force = false});
  @override
  String get type => 'takeOver';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId, 'force': force};
}

/// Asks for the sub-folders of [path] on the host; null or empty lists the roots.
class ListDir extends ClientMessage {
  final String? path;
  const ListDir({this.path});
  @override
  String get type => 'listDir';
  @override
  Map<String, dynamic> fields() => {'path': path};
}

/// Which session this device shows in the foreground now (null: none, or the app is in
/// the background). The host sends that device no notification for that session.
class FocusSession extends ClientMessage {
  final String? sessionId;
  const FocusSession({this.sessionId});
  @override
  String get type => 'focus';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId};
}

/// Turns the host's self-test of new Claude Code versions on or off (the host answers with
/// a `compatibility` message).
class SetSelfTest extends ClientMessage {
  final bool enabled;
  const SetSelfTest({required this.enabled});
  @override
  String get type => 'setSelfTest';
  @override
  Map<String, dynamic> fields() => {'enabled': enabled};
}

/// Runs the self-test now, whatever the setting (progress and result arrive as
/// `compatibility` messages).
class RunSelfTest extends ClientMessage {
  const RunSelfTest();
  @override
  String get type => 'runSelfTest';
}

/// Renames a session for Claude Code too (what `/rename` does). Answered with
/// [SessionActionDone] or an error. Older hosts answer [unknownMessageText].
class RenameSession extends ClientMessage {
  final String sessionId;
  final String name;
  const RenameSession({required this.sessionId, required this.name});
  @override
  String get type => 'renameSession';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId, 'name': name};
}

/// Deletes a session for Claude Code too: ends it if it runs, then removes its
/// conversation (so `claude --resume` no longer lists it). Cannot be undone.
class DeleteSession extends ClientMessage {
  final String sessionId;
  const DeleteSession({required this.sessionId});
  @override
  String get type => 'deleteSession';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId};
}

/// Resumes a session that is not running in a new terminal window on the machine
/// (`claude --resume <id>`).
class ResumeSession extends ClientMessage {
  final String sessionId;
  const ResumeSession({required this.sessionId});
  @override
  String get type => 'resumeSession';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId};
}

/// The owner's choice for this machine's usage limit ([choice] one of [LimitChoices]),
/// for the whole machine or, with [sessionId], for that session only.
/// [LimitChoices.continueNow] sends `please continue` now (to [sessionId], else to every
/// session still paused). Older hosts answer [unknownMessageText].
class UsageLimitChoice extends ClientMessage {
  final String choice;
  final String? sessionId;

  /// [LimitChoices.switchAccount]: the account to move the paused sessions to, and whether
  /// it also becomes the machine's account for new sessions.
  final String? accountId;
  final bool makeDefault;
  const UsageLimitChoice({required this.choice, this.sessionId, this.accountId, this.makeDefault = false});
  @override
  String get type => 'usageLimitChoice';
  @override
  Map<String, dynamic> fields() => {
        'choice': choice,
        if (sessionId != null) 'sessionId': sessionId,
        'accountId': ?accountId,
        if (makeDefault) 'makeDefault': true,
      };
}

/// The phone's accounts with their tokens (decision 6: added once, used on every paired
/// machine). The host adds or updates each one; it never removes an account it is not sent
/// ([RemoveAccount] does). Only ever inside the encrypted channel.
class SyncAccounts extends ClientMessage {
  final List<AccountWithToken> accounts;
  const SyncAccounts({required this.accounts});
  @override
  String get type => 'syncAccounts';
  @override
  Map<String, dynamic> fields() => {'accounts': [for (final a in accounts) a.toJson()]};
}

/// Forget an account (and its token) on this machine.
class RemoveAccount extends ClientMessage {
  final String accountId;
  const RemoveAccount({required this.accountId});
  @override
  String get type => 'removeAccount';
  @override
  Map<String, dynamic> fields() => {'accountId': accountId};
}

/// The account new sessions on this machine start on ([machineLoginAccountId]: the
/// machine's own login). Running sessions keep theirs.
class SetActiveAccount extends ClientMessage {
  final String accountId;
  const SetActiveAccount({required this.accountId});
  @override
  String get type => 'setActiveAccount';
  @override
  Map<String, dynamic> fields() => {'accountId': accountId};
}

/// One step of adding an account ([action] one of [AccountSignInActions]). [flowId] is
/// also the new account's id. [label], [email] and [plan] come with `start` and
/// `atMachine`; [code] with `code`.
class AccountSignIn extends ClientMessage {
  final String flowId;
  final String action;
  final String? code;
  final String? label;
  final String? email;
  final String? plan;
  const AccountSignIn({required this.flowId, required this.action, this.code, this.label, this.email, this.plan});
  @override
  String get type => 'accountSignIn';
  @override
  Map<String, dynamic> fields() => {
        'flowId': flowId,
        'action': action,
        'code': ?code,
        'label': ?label,
        'email': ?email,
        'plan': ?plan,
      };
}

/// Ends a running session and resumes its conversation under another account (decision
/// 3: the owner switches that session). Answered with [SessionActionDone]
/// ([SessionActions.switchAccount]).
class SwitchSessionAccount extends ClientMessage {
  final String sessionId;
  final String accountId;
  const SwitchSessionAccount({required this.sessionId, required this.accountId});
  @override
  String get type => 'switchSessionAccount';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId, 'accountId': accountId};
}

// ---- task board (older hosts answer [unknownMessageText])

/// Asks for the machine's tasks (answered with [TasksMessage]).
class ListTasks extends ClientMessage {
  const ListTasks();
  @override
  String get type => 'listTasks';
}

/// Creates a task (a new id) or edits one: the host keeps its own fields (the linked
/// session, the report). A task copied from another machine is a create here.
class SaveTask extends ClientMessage {
  final BoardTask task;
  const SaveTask({required this.task});
  @override
  String get type => 'saveTask';
  @override
  Map<String, dynamic> fields() => {'task': task.toJson()};
}

/// Moves a task to another column (Done is a move too).
class MoveTask extends ClientMessage {
  final String taskId;
  final TaskColumn column;
  const MoveTask({required this.taskId, required this.column});
  @override
  String get type => 'moveTask';
  @override
  Map<String, dynamic> fields() => {'taskId': taskId, 'column': column.name};
}

class DeleteTask extends ClientMessage {
  final String taskId;
  const DeleteTask({required this.taskId});
  @override
  String get type => 'deleteTask';
  @override
  Map<String, dynamic> fields() => {'taskId': taskId};
}

/// Sends a task to Claude: into [sessionId] (an existing session on the machine), or with
/// null into a new session named after the task, on its task type's model and the
/// machine's current account. The card moves to In progress.
class RunTask extends ClientMessage {
  final String taskId;
  final String? sessionId;
  const RunTask({required this.taskId, this.sessionId});
  @override
  String get type => 'runTask';
  @override
  Map<String, dynamic> fields() => {'taskId': taskId, 'sessionId': ?sessionId};
}

/// Types the owner's notes into the task's session; the card goes back to In progress.
class TaskNotes extends ClientMessage {
  final String taskId;
  final String notes;
  const TaskNotes({required this.taskId, required this.notes});
  @override
  String get type => 'taskNotes';
  @override
  Map<String, dynamic> fields() => {'taskId': taskId, 'notes': notes};
}

/// Asks for the git remotes of the machine's known folders (answered with
/// [GitRemotesMessage]).
class ListGitRemotes extends ClientMessage {
  const ListGitRemotes();
  @override
  String get type => 'listGitRemotes';
}

/// The phone's model table; the host keeps it unless its own is newer.
class SyncModelTable extends ClientMessage {
  final ModelTable table;
  const SyncModelTable({required this.table});
  @override
  String get type => 'syncModelTable';
  @override
  Map<String, dynamic> fields() => {'table': table.toJson()};
}

/// The phone's project list; the host keeps it unless its own is newer.
class SyncProjects extends ClientMessage {
  final ProjectList projects;
  const SyncProjects({required this.projects});
  @override
  String get type => 'syncProjects';
  @override
  Map<String, dynamic> fields() => {'projects': projects.toJson()};
}

/// Asks for the slash commands a session can run (answered with [CommandsMessage]).
class ListCommands extends ClientMessage {
  final String sessionId;
  const ListCommands({required this.sessionId});
  @override
  String get type => 'listCommands';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId};
}

/// Asks for the files and folders of [sessionId]'s folder that match [query] (what follows
/// `@` in the composer); answered with [FilesMessage].
class ListFiles extends ClientMessage {
  final String sessionId;
  final String query;
  const ListFiles({required this.sessionId, this.query = ''});
  @override
  String get type => 'listFiles';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId, 'query': query};
}

/// Searches the text of every conversation on the machine (the owner's messages and
/// Claude's replies, in every transcript Claude Code kept). Answered with [SearchResults].
class SearchSessions extends ClientMessage {
  final String query;
  const SearchSessions({required this.query});
  @override
  String get type => 'searchSessions';
  @override
  Map<String, dynamic> fields() => {'query': query};
}

/// Switches a running session's model ([model] null: the default). Answered with
/// [SessionActionDone] ([SessionActions.model]).
class SetSessionModel extends ClientMessage {
  final String sessionId;
  final String? model;
  const SetSessionModel({required this.sessionId, this.model});
  @override
  String get type => 'setSessionModel';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId, 'model': ?model};
}

/// Asks for the machine's devices and pending requests (full-control devices only).
class ListDevices extends ClientMessage {
  const ListDevices();
  @override
  String get type => 'listDevices';
}

/// Answers a pending request to pair: one of [DeviceDecisions].
class DecideDevice extends ClientMessage {
  final String deviceId;
  final String decision;
  const DecideDevice({required this.deviceId, required this.decision});
  @override
  String get type => 'decideDevice';
  @override
  Map<String, dynamic> fields() => {'deviceId': deviceId, 'decision': decision};
}

/// Changes an approved device's permission: one of [DevicePermissions].
class SetDevicePermission extends ClientMessage {
  final String deviceId;
  final String permission;
  const SetDevicePermission({required this.deviceId, required this.permission});
  @override
  String get type => 'setDevicePermission';
  @override
  Map<String, dynamic> fields() => {'deviceId': deviceId, 'permission': permission};
}

class RenameDevice extends ClientMessage {
  final String deviceId;
  final String name;
  const RenameDevice({required this.deviceId, required this.name});
  @override
  String get type => 'renameDevice';
  @override
  Map<String, dynamic> fields() => {'deviceId': deviceId, 'name': name};
}

/// Removes a device: its key stops working and its connection closes.
class RemoveDevice extends ClientMessage {
  final String deviceId;
  const RemoveDevice({required this.deviceId});
  @override
  String get type => 'removeDevice';
  @override
  Map<String, dynamic> fields() => {'deviceId': deviceId};
}

/// What the app's board has (record key -> group -> encoded version); the host answers with
/// the records the app lacks or has older.
class BoardSummaryFromApp extends ClientMessage {
  final Map<String, Map<String, String>> summary;
  const BoardSummaryFromApp({required this.summary});
  @override
  String get type => 'boardSummary';
  @override
  Map<String, dynamic> fields() => {'summary': summary};
}

/// Board records from the app (new or newer than the host's); full devices only.
class BoardRecordsFromApp extends ClientMessage {
  final List<BoardRecord> records;
  const BoardRecordsFromApp({required this.records});
  @override
  String get type => 'boardRecords';
  @override
  Map<String, dynamic> fields() => {'records': [for (final r in records) r.toJson()]};
}

/// The board key (base64url) and board id; the one with the newer [keyVersion] (an encoded
/// [Hlc]) wins everywhere. Full devices only.
class BoardKeyFromApp extends ClientMessage {
  final String boardId;
  final String key;
  final String keyVersion;
  const BoardKeyFromApp({required this.boardId, required this.key, required this.keyVersion});
  @override
  String get type => 'boardKey';
  @override
  Map<String, dynamic> fields() => {'boardId': boardId, 'key': key, 'keyVersion': keyVersion};
}

// ---------------------------------------------------------------- host -> app

sealed class HostMessage {
  const HostMessage();
  String get type;
  Map<String, dynamic> fields() => const {};
  Map<String, dynamic> toJson() => {'type': type, ...fields()};
}

class Welcome extends HostMessage {
  final String machineName;
  final String os;
  final String hostVersion;
  final String? claudeVersion;

  /// Whether Perch's Claude Code hooks are installed on the host (instant updates).
  /// Missing in JSON from older hosts: true.
  final bool hooksInstalled;

  /// Whether the host still understands its Claude Code; null from older hosts.
  final Compatibility? compatibility;

  /// The host's relay URL now (null: LAN only), so devices paired before it was set learn it.
  final String? relayUrl;

  /// The host's LAN addresses now (`host:port`), so devices follow an address change.
  final List<String> lanAddresses;

  /// This device's permission ([DevicePermissions]); null from older hosts (full).
  final String? permission;

  /// The host keeps the whole board and syncs it ([BoardSummaryFromHost] follows); false from
  /// older hosts (the app then uses the task messages).
  final bool boardSync;
  const Welcome(
      {required this.machineName,
      required this.os,
      required this.hostVersion,
      this.claudeVersion,
      this.hooksInstalled = true,
      this.compatibility,
      this.relayUrl,
      this.lanAddresses = const [],
      this.permission,
      this.boardSync = false});
  @override
  String get type => 'welcome';
  @override
  Map<String, dynamic> fields() => {
        'machineName': machineName,
        'os': os,
        'hostVersion': hostVersion,
        'claudeVersion': claudeVersion,
        'hooksInstalled': hooksInstalled,
        'compatibility': compatibility?.toJson(),
        'relayUrl': relayUrl,
        'lanAddresses': lanAddresses,
        'permission': ?permission,
        if (boardSync) 'boardSync': true,
      };
}

/// The host's [Compatibility] changed.
class CompatibilityMessage extends HostMessage {
  final Compatibility compatibility;
  const CompatibilityMessage({required this.compatibility});
  @override
  String get type => 'compatibility';
  @override
  Map<String, dynamic> fields() => {'compatibility': compatibility.toJson()};
}

class Sessions extends HostMessage {
  final List<SessionSummary> sessions;
  final UsageSnapshot? usage;
  const Sessions({required this.sessions, this.usage});
  @override
  String get type => 'sessions';
  @override
  Map<String, dynamic> fields() =>
      {'sessions': [for (final s in sessions) s.toJson()], 'usage': usage?.toJson()};
}

class SessionUpdated extends HostMessage {
  final SessionSummary session;
  const SessionUpdated({required this.session});
  @override
  String get type => 'sessionUpdated';
  @override
  Map<String, dynamic> fields() => {'session': session.toJson()};
}

/// Reply to `subscribe`. A first subscribe (afterSeq 0) gets only the latest page;
/// [hasEarlier] says whether older events can be fetched with `loadEarlier`.
class Events extends HostMessage {
  final String sessionId;
  final List<ConversationEvent> events;
  final List<PromptRequest> openPrompts;
  final bool hasEarlier;
  const Events({required this.sessionId, required this.events, this.openPrompts = const [], this.hasEarlier = false});
  @override
  String get type => 'events';
  @override
  Map<String, dynamic> fields() => {
        'sessionId': sessionId,
        'events': [for (final e in events) e.toJson()],
        'openPrompts': [for (final p in openPrompts) p.toJson()],
        'hasEarlier': hasEarlier,
      };
}

/// Reply to `loadEarlier`: the events just before the asked seq, oldest first.
class EarlierEvents extends HostMessage {
  final String sessionId;
  final List<ConversationEvent> events;
  final bool hasEarlier;
  const EarlierEvents({required this.sessionId, required this.events, this.hasEarlier = false});
  @override
  String get type => 'earlierEvents';
  @override
  Map<String, dynamic> fields() => {
        'sessionId': sessionId,
        'events': [for (final e in events) e.toJson()],
        'hasEarlier': hasEarlier,
      };
}

List<ConversationEvent> _events(Object? v) => [
      for (final e in (v is List ? v : const []))
        if (e is Map) ConversationEvent.tryFromJson(e.cast<String, dynamic>())
    ].whereType<ConversationEvent>().toList();

class EventMessage extends HostMessage {
  final String sessionId;
  final ConversationEvent event;
  const EventMessage({required this.sessionId, required this.event});
  @override
  String get type => 'event';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId, 'event': event.toJson()};
}

class PromptOpened extends HostMessage {
  final String sessionId;
  final PromptRequest prompt;
  const PromptOpened({required this.sessionId, required this.prompt});
  @override
  String get type => 'promptOpened';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId, 'prompt': prompt.toJson()};
}

class PromptClosed extends HostMessage {
  final String sessionId;
  final String promptId;
  const PromptClosed({required this.sessionId, required this.promptId});
  @override
  String get type => 'promptClosed';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId, 'promptId': promptId};
}

class UsageMessage extends HostMessage {
  final UsageSnapshot usage;
  const UsageMessage({required this.usage});
  @override
  String get type => 'usage';
  @override
  Map<String, dynamic> fields() => {'usage': usage.toJson()};
}

class ErrorMessage extends HostMessage {
  /// One of [ErrorCodes].
  final String code;
  final String message;
  const ErrorMessage({required this.code, required this.message});
  @override
  String get type => 'error';
  @override
  Map<String, dynamic> fields() => {'code': code, 'message': message};
}

/// One folder in a [DirListing].
class DirEntry {
  final String name;
  final String path;
  const DirEntry({required this.name, required this.path});
  Map<String, dynamic> toJson() => {'name': name, 'path': path};
  factory DirEntry.fromJson(Map<String, dynamic> j) => DirEntry(name: _str(j['name']), path: _str(j['path']));
}

List<DirEntry> _entries(Object? v) => [
      for (final e in (v is List ? v : const []))
        if (e is Map) DirEntry.fromJson(e.cast<String, dynamic>())
    ];

/// Reply to `listDir`. [path] is the resolved absolute folder, or empty for the roots view;
/// [parent] is null at a root. [entries] are sub-folders only; [suggested] are shortcuts
/// (recent session folders, then the home folder last).
class DirListing extends HostMessage {
  final String path;
  final String? parent;
  final List<DirEntry> entries;
  final List<DirEntry> suggested;
  const DirListing({required this.path, this.parent, this.entries = const [], this.suggested = const []});
  @override
  String get type => 'dirListing';
  @override
  Map<String, dynamic> fields() => {
        'path': path,
        'parent': parent,
        'entries': [for (final e in entries) e.toJson()],
        'suggested': [for (final e in suggested) e.toJson()],
      };
}

class RemoteAccessStopped extends HostMessage {
  const RemoteAccessStopped();
  @override
  String get type => 'remoteAccessStopped';
}

/// The machine's own name changed (`perch_host name set`) while devices were connected.
/// Older apps ignore it and learn the name from the next `welcome`.
class MachineRenamed extends HostMessage {
  final String machineName;
  const MachineRenamed({required this.machineName});
  @override
  String get type => 'machineRenamed';
  @override
  Map<String, dynamic> fields() => {'machineName': machineName};
}

/// A [RenameSession], [DeleteSession] or [ResumeSession] was done ([action] is one of
/// [SessionActions]); [message] is a line for the device that asked. Failures arrive as
/// an `error`.
class SessionActionDone extends HostMessage {
  final String action;
  final String sessionId;
  final String message;
  const SessionActionDone({required this.action, required this.sessionId, this.message = ''});
  @override
  String get type => 'sessionActionDone';
  @override
  Map<String, dynamic> fields() => {'action': action, 'sessionId': sessionId, 'message': message};
}

/// This machine's usage limit now; null [limit]: none (cleared). Sent after `sessions` on
/// connect and whenever it changes. Older apps ignore it.
class UsageLimitMessage extends HostMessage {
  final UsageLimit? limit;
  const UsageLimitMessage({this.limit});
  @override
  String get type => 'usageLimit';
  @override
  Map<String, dynamic> fields() => {'limit': limit?.toJson()};
}

/// A session resumed after a usage limit. [changed]: the work did not carry on the same
/// way (it ran in a subagent and now does not); the app shows a toast. [text] is the
/// note also written into the session's conversation.
class ResumeReport extends HostMessage {
  final String sessionId;
  final String sessionName;
  final bool changed;
  final String text;
  const ResumeReport({required this.sessionId, this.sessionName = '', required this.changed, required this.text});
  @override
  String get type => 'resumeReport';
  @override
  Map<String, dynamic> fields() =>
      {'sessionId': sessionId, 'sessionName': sessionName, 'changed': changed, 'text': text};
}

/// The machine's accounts: its own login (decision 10), the token accounts it holds (no
/// tokens), and which one new sessions start on. Sent after `sessions` on connect and on
/// every change. Older apps ignore it.
class AccountsMessage extends HostMessage {
  final MachineLogin machineLogin;

  /// An account id, or [machineLoginAccountId].
  final String activeAccountId;
  final List<AccountInfo> accounts;
  const AccountsMessage(
      {required this.machineLogin, this.activeAccountId = machineLoginAccountId, required this.accounts});
  @override
  String get type => 'accounts';
  @override
  Map<String, dynamic> fields() => {
        'machineLogin': machineLogin.toJson(),
        'activeAccountId': activeAccountId,
        'accounts': [for (final a in accounts) a.toJson()],
      };
}

/// Where an account sign-in is ([state] one of [AccountSignInStates]). [token] only with
/// `done`, so the phone keeps the account and gives it to its other machines.
class AccountSignInUpdate extends HostMessage {
  final String flowId;
  final String state;
  final String? url;
  final String? message;
  final AccountInfo? account;
  final String? token;
  const AccountSignInUpdate({required this.flowId, required this.state, this.url, this.message, this.account, this.token});
  @override
  String get type => 'accountSignIn';
  @override
  Map<String, dynamic> fields() => {
        'flowId': flowId,
        'state': state,
        'url': ?url,
        'message': ?message,
        'account': ?account?.toJson(),
        'token': ?token,
      };
}

/// The machine's tasks (on connect, after `listTasks`, and after every change). Older apps
/// ignore it.
class TasksMessage extends HostMessage {
  final List<BoardTask> tasks;
  const TasksMessage({required this.tasks});
  @override
  String get type => 'tasks';
  @override
  Map<String, dynamic> fields() => {'tasks': [for (final t in tasks) t.toJson()]};
}

/// The git remotes of the machine's known folders (recent sessions' and tasks').
class GitRemotesMessage extends HostMessage {
  final List<GitFolder> folders;
  const GitRemotesMessage({required this.folders});
  @override
  String get type => 'gitRemotes';
  @override
  Map<String, dynamic> fields() => {'folders': [for (final f in folders) f.toJson()]};
}

/// The machine's model table (on connect and when it changes).
class ModelTableMessage extends HostMessage {
  final ModelTable table;
  const ModelTableMessage({required this.table});
  @override
  String get type => 'modelTable';
  @override
  Map<String, dynamic> fields() => {'table': table.toJson()};
}

/// The slash commands [sessionId] can run: Claude Code's own and the owner's and the
/// project's commands and skills (installed plugins' too).
class CommandsMessage extends HostMessage {
  final String sessionId;
  final List<SlashCommandInfo> commands;
  const CommandsMessage({required this.sessionId, required this.commands});
  @override
  String get type => 'commands';
  @override
  Map<String, dynamic> fields() => {'sessionId': sessionId, 'commands': [for (final c in commands) c.toJson()]};
}

/// The files and folders of [sessionId]'s folder matching [query], best first, a few dozen at
/// most ([truncated]: the folder had more files than the host lists).
class FilesMessage extends HostMessage {
  final String sessionId;
  final String query;
  final List<FileMention> files;
  final bool truncated;
  const FilesMessage({required this.sessionId, required this.query, required this.files, this.truncated = false});
  @override
  String get type => 'files';
  @override
  Map<String, dynamic> fields() => {
        'sessionId': sessionId,
        'query': query,
        'files': [for (final f in files) f.toJson()],
        if (truncated) 'truncated': true,
      };
}

/// One message that matches a search: the session it belongs to (open it with [Subscribe]
/// by [sessionId], also when it is not listed: the host then lists it as not running), and
/// the words around the match.
class SearchHit {
  final String sessionId;
  final String name;
  final String cwd;
  final int atMs;

  /// The owner's message (else Claude's reply).
  final bool fromUser;
  final String snippet;

  /// The session runs now.
  final bool running;
  const SearchHit({
    required this.sessionId,
    this.name = '',
    this.cwd = '',
    this.atMs = 0,
    this.fromUser = false,
    required this.snippet,
    this.running = false,
  });

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'name': name,
        'cwd': cwd,
        'atMs': atMs,
        'fromUser': fromUser,
        'snippet': snippet,
        if (running) 'running': true,
      };

  static SearchHit? tryFromJson(Object? v) {
    if (v is! Map) return null;
    final id = _str(v['sessionId']);
    if (id.isEmpty) return null;
    return SearchHit(
      sessionId: id,
      name: _str(v['name']),
      cwd: _str(v['cwd']),
      atMs: _int(v['atMs']),
      fromUser: v['fromUser'] == true,
      snippet: _str(v['snippet']),
      running: v['running'] == true,
    );
  }
}

/// The answer to [SearchSessions]: matching messages, newest sessions first, a few per
/// session ([truncated]: there were more, or the search ran out of time).
class SearchResults extends HostMessage {
  final String query;
  final List<SearchHit> hits;
  final bool truncated;
  const SearchResults({required this.query, required this.hits, this.truncated = false});
  @override
  String get type => 'searchResults';
  @override
  Map<String, dynamic> fields() => {
        'query': query,
        'hits': [for (final h in hits) h.toJson()],
        if (truncated) 'truncated': true,
      };
}

/// The project list the machine has (on connect and when it changes).
class ProjectsMessage extends HostMessage {
  final ProjectList projects;
  const ProjectsMessage({required this.projects});
  @override
  String get type => 'projects';
  @override
  Map<String, dynamic> fields() => {'projects': projects.toJson()};
}

/// The device asked to pair and waits until it is allowed at [machineName]; the
/// connection stays open until the request is decided or expires.
class PairingPending extends HostMessage {
  final String machineName;
  const PairingPending({required this.machineName});
  @override
  String get type => 'pairingPending';
  @override
  Map<String, dynamic> fields() => {'machineName': machineName};
}

/// The device's own key for this machine (base64url): it replaces the pairing secret in
/// every later handshake and opens this device's notifications.
class DeviceKey extends HostMessage {
  final String key;
  final String permission;
  const DeviceKey({required this.key, required this.permission});
  @override
  String get type => 'deviceKey';
  @override
  Map<String, dynamic> fields() => {'key': key, 'permission': permission};
}

/// What the host's board has (record key -> group -> encoded version).
class BoardSummaryFromHost extends HostMessage {
  final Map<String, Map<String, String>> summary;
  const BoardSummaryFromHost({required this.summary});
  @override
  String get type => 'boardSummary';
  @override
  Map<String, dynamic> fields() => {'summary': summary};
}

/// Board records from the host (missing or older on the device, or just changed).
class BoardRecordsFromHost extends HostMessage {
  final List<BoardRecord> records;
  const BoardRecordsFromHost({required this.records});
  @override
  String get type => 'boardRecords';
  @override
  Map<String, dynamic> fields() => {'records': [for (final r in records) r.toJson()]};
}

/// The board key (base64url) and board id the host has; the newer [keyVersion] wins.
class BoardKeyFromHost extends HostMessage {
  final String boardId;
  final String key;
  final String keyVersion;
  const BoardKeyFromHost({required this.boardId, required this.key, required this.keyVersion});
  @override
  String get type => 'boardKey';
  @override
  Map<String, dynamic> fields() => {'boardId': boardId, 'key': key, 'keyVersion': keyVersion};
}

List<BoardRecord> _records(Object? v) => [for (final r in (v is List ? v : const [])) ?BoardRecord.tryFromJson(r)];

/// (boardId, key, keyVersion) of a boardKey frame, or null when any is missing or broken.
(String, String, String)? _boardKey(Map<String, dynamic> j) {
  final id = _str(j['boardId']), key = _str(j['key']), v = _str(j['keyVersion']);
  if (id.isEmpty || key.isEmpty || Hlc.parse(v) == null) return null;
  return (id, key, v);
}

/// One approved device in a [DevicesMessage].
class DeviceInfo {
  final String id;
  final String name;
  final String permission;

  /// False: a legacy device (an older app that never took its own key).
  final bool keyed;
  final int approvedAtMs;
  final int? lastSeenAtMs;
  final bool connected;

  /// The device this message is sent to.
  final bool thisDevice;
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.permission,
    required this.keyed,
    required this.approvedAtMs,
    this.lastSeenAtMs,
    this.connected = false,
    this.thisDevice = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'permission': permission,
        'keyed': keyed,
        'approvedAtMs': approvedAtMs,
        'lastSeenAtMs': ?lastSeenAtMs,
        'connected': connected,
        'thisDevice': thisDevice,
      };

  static DeviceInfo? tryFromJson(Object? v) {
    if (v is! Map) return null;
    final id = _str(v['id']);
    if (id.isEmpty) return null;
    final p = _str(v['permission']);
    return DeviceInfo(
      id: id,
      name: _str(v['name']),
      permission: DevicePermissions.all.contains(p) ? p : DevicePermissions.full,
      keyed: v['keyed'] == true,
      approvedAtMs: _int(v['approvedAtMs']),
      lastSeenAtMs: v['lastSeenAtMs'] is num ? (v['lastSeenAtMs'] as num).toInt() : null,
      connected: v['connected'] == true,
      thisDevice: v['thisDevice'] == true,
    );
  }
}

/// A device waiting to be allowed, in a [DevicesMessage].
class PendingDevice {
  final String id;
  final String name;

  /// How it reached the machine: a LAN address or `relay`.
  final String route;
  final int requestedAtMs;
  const PendingDevice({required this.id, required this.name, required this.route, required this.requestedAtMs});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'route': route, 'requestedAtMs': requestedAtMs};

  static PendingDevice? tryFromJson(Object? v) {
    if (v is! Map) return null;
    final id = _str(v['id']);
    if (id.isEmpty) return null;
    return PendingDevice(
        id: id, name: _str(v['name']), route: _str(v['route']), requestedAtMs: _int(v['requestedAtMs']));
  }
}

/// The machine's devices and pending requests (sent to full-control devices on connect
/// and whenever the list changes).
class DevicesMessage extends HostMessage {
  final List<DeviceInfo> devices;
  final List<PendingDevice> pending;
  const DevicesMessage({required this.devices, this.pending = const []});
  @override
  String get type => 'devices';
  @override
  Map<String, dynamic> fields() => {
        'devices': [for (final d in devices) d.toJson()],
        'pending': [for (final p in pending) p.toJson()],
      };
}

// ---------------------------------------------------------------- codec

String encodeClient(ClientMessage m) => jsonEncode(m.toJson());
String encodeHost(HostMessage m) => jsonEncode(m.toJson());

Map<String, dynamic>? _object(String frame) {
  try {
    final v = jsonDecode(frame);
    return v is Map ? v.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// Null for an unknown type or malformed JSON.
ClientMessage? decodeClient(String frame) {
  final j = _object(frame);
  if (j == null) return null;
  try {
    switch (j['type']) {
      case 'hello':
        return Hello(
            code: _str(j['code']),
            deviceName: _str(j['deviceName']),
            pairing: j['pairing'] is num ? (j['pairing'] as num).toInt() : null);
      case 'listSessions':
        return const ListSessions();
      case 'startSession':
        final account = _strOrNull(j['accountId']);
        return StartSession(
            cwd: _str(j['cwd']),
            prompt: _str(j['prompt']),
            name: _strOrNull(j['name']),
            model: _strOrNull(j['model']),
            accountId: account == null || account.isEmpty ? null : account);
      case 'subscribe':
        return Subscribe(sessionId: _str(j['sessionId']), afterSeq: _int(j['afterSeq']));
      case 'loadEarlier':
        return LoadEarlier(sessionId: _str(j['sessionId']), beforeSeq: _int(j['beforeSeq']));
      case 'sendMessage':
        return SendMessage(sessionId: _str(j['sessionId']), text: _str(j['text']));
      case 'answerPrompt':
        return AnswerPrompt(
            sessionId: _str(j['sessionId']),
            promptId: _str(j['promptId']),
            answer: PromptAnswer.fromJson(_map(j['answer'])));
      case 'interrupt':
        return Interrupt(sessionId: _str(j['sessionId']));
      case 'stopSession':
        return StopSession(sessionId: _str(j['sessionId']));
      case 'killAll':
        return const KillAll();
      case 'takeOver':
        return TakeOver(sessionId: _str(j['sessionId']), force: j['force'] == true);
      case 'listDir':
        return ListDir(path: _strOrNull(j['path']));
      case 'focus':
        final id = _strOrNull(j['sessionId']);
        return FocusSession(sessionId: id == null || id.isEmpty ? null : id);
      case 'setSelfTest':
        return SetSelfTest(enabled: j['enabled'] == true);
      case 'runSelfTest':
        return const RunSelfTest();
      case 'renameSession':
        return RenameSession(sessionId: _str(j['sessionId']), name: _str(j['name']));
      case 'deleteSession':
        return DeleteSession(sessionId: _str(j['sessionId']));
      case 'resumeSession':
        return ResumeSession(sessionId: _str(j['sessionId']));
      case 'usageLimitChoice':
        final choice = _str(j['choice']);
        final account = _strOrNull(j['accountId']);
        if (choice == LimitChoices.switchAccount) {
          if (account == null || account.isEmpty) return null;
        } else if (!LimitChoices.lasting.contains(choice) && choice != LimitChoices.continueNow) {
          return null;
        }
        final sid = _strOrNull(j['sessionId']);
        return UsageLimitChoice(
            choice: choice,
            sessionId: sid == null || sid.isEmpty ? null : sid,
            accountId: account == null || account.isEmpty ? null : account,
            makeDefault: j['makeDefault'] == true);
      case 'syncAccounts':
        return SyncAccounts(accounts: [
          for (final a in (j['accounts'] is List ? j['accounts'] as List : const [])) ?AccountWithToken.tryFromJson(a)
        ]);
      case 'removeAccount':
        final id = _str(j['accountId']);
        return id.isEmpty ? null : RemoveAccount(accountId: id);
      case 'setActiveAccount':
        final id = _str(j['accountId']);
        return id.isEmpty ? null : SetActiveAccount(accountId: id);
      case 'accountSignIn':
        final flow = _str(j['flowId']);
        final action = _str(j['action']);
        if (flow.isEmpty || !AccountSignInActions.all.contains(action)) return null;
        return AccountSignIn(
            flowId: flow,
            action: action,
            code: _strOrNull(j['code']),
            label: _strOrNull(j['label']),
            email: _strOrNull(j['email']),
            plan: _strOrNull(j['plan']));
      case 'switchSessionAccount':
        final sid = _str(j['sessionId']), id = _str(j['accountId']);
        return sid.isEmpty || id.isEmpty ? null : SwitchSessionAccount(sessionId: sid, accountId: id);
      case 'listTasks':
        return const ListTasks();
      case 'saveTask':
        final t = BoardTask.tryFromJson(j['task']);
        return t == null ? null : SaveTask(task: t);
      case 'moveTask':
        final id = _str(j['taskId']);
        final col = TaskColumn.values.where((c) => c.name == j['column']).firstOrNull;
        return id.isEmpty || col == null ? null : MoveTask(taskId: id, column: col);
      case 'deleteTask':
        final id = _str(j['taskId']);
        return id.isEmpty ? null : DeleteTask(taskId: id);
      case 'runTask':
        final id = _str(j['taskId']);
        final sid = _strOrNull(j['sessionId']);
        return id.isEmpty ? null : RunTask(taskId: id, sessionId: sid == null || sid.isEmpty ? null : sid);
      case 'taskNotes':
        final id = _str(j['taskId']);
        return id.isEmpty ? null : TaskNotes(taskId: id, notes: _str(j['notes']));
      case 'listGitRemotes':
        return const ListGitRemotes();
      case 'syncModelTable':
        final t = ModelTable.tryFromJson(j['table']);
        return t == null ? null : SyncModelTable(table: t);
      case 'listCommands':
        final sid = _str(j['sessionId']);
        return sid.isEmpty ? null : ListCommands(sessionId: sid);
      case 'searchSessions':
        final q = _str(j['query']).trim();
        return q.isEmpty ? null : SearchSessions(query: q);
      case 'listFiles':
        final sid = _str(j['sessionId']);
        return sid.isEmpty ? null : ListFiles(sessionId: sid, query: _str(j['query']));
      case 'syncProjects':
        final p = ProjectList.tryFromJson(j['projects']);
        return p == null ? null : SyncProjects(projects: p);
      case 'setSessionModel':
        final sid = _str(j['sessionId']);
        final model = _strOrNull(j['model']);
        return sid.isEmpty ? null : SetSessionModel(sessionId: sid, model: model == null || model.isEmpty ? null : model);
      case 'listDevices':
        return const ListDevices();
      case 'decideDevice':
        final id = _str(j['deviceId']), decision = _str(j['decision']);
        return id.isEmpty || !DeviceDecisions.all.contains(decision)
            ? null
            : DecideDevice(deviceId: id, decision: decision);
      case 'setDevicePermission':
        final id = _str(j['deviceId']), permission = _str(j['permission']);
        return id.isEmpty || !DevicePermissions.all.contains(permission)
            ? null
            : SetDevicePermission(deviceId: id, permission: permission);
      case 'renameDevice':
        final id = _str(j['deviceId']), name = _str(j['name']).trim();
        return id.isEmpty || name.isEmpty || name.length > maxDeviceNameLength
            ? null
            : RenameDevice(deviceId: id, name: name);
      case 'removeDevice':
        final id = _str(j['deviceId']);
        return id.isEmpty ? null : RemoveDevice(deviceId: id);
      case 'boardSummary':
        return BoardSummaryFromApp(summary: summaryFromJson(j['summary']));
      case 'boardRecords':
        return BoardRecordsFromApp(records: _records(j['records']));
      case 'boardKey':
        final k = _boardKey(j);
        return k == null ? null : BoardKeyFromApp(boardId: k.$1, key: k.$2, keyVersion: k.$3);
    }
  } catch (_) {
    return null;
  }
  return null;
}

/// Null for an unknown type or malformed JSON.
HostMessage? decodeHost(String frame) {
  final j = _object(frame);
  if (j == null) return null;
  try {
    switch (j['type']) {
      case 'welcome':
        return Welcome(
            machineName: _str(j['machineName']),
            os: _str(j['os']),
            hostVersion: _str(j['hostVersion']),
            claudeVersion: _strOrNull(j['claudeVersion']),
            hooksInstalled: j['hooksInstalled'] is bool ? j['hooksInstalled'] as bool : true,
            compatibility: j['compatibility'] is Map ? Compatibility.fromJson(_map(j['compatibility'])) : null,
            relayUrl: _strOrNull(j['relayUrl']),
            lanAddresses: [
              for (final a in (j['lanAddresses'] is List ? j['lanAddresses'] as List : const []))
                if (a is String) a
            ],
            permission: _strOrNull(j['permission']),
            boardSync: j['boardSync'] == true);
      case 'compatibility':
        return CompatibilityMessage(compatibility: Compatibility.fromJson(_map(j['compatibility'])));
      case 'sessions':
        return Sessions(
            sessions: [
              for (final s in (j['sessions'] as List? ?? const []))
                if (s is Map) SessionSummary.fromJson(s.cast<String, dynamic>())
            ],
            usage: j['usage'] is Map ? UsageSnapshot.fromJson(_map(j['usage'])) : null);
      case 'sessionUpdated':
        return SessionUpdated(session: SessionSummary.fromJson(_map(j['session'])));
      case 'events':
        return Events(
          sessionId: _str(j['sessionId']),
          events: _events(j['events']),
          openPrompts: [
            for (final p in (j['openPrompts'] as List? ?? const []))
              if (p is Map) PromptRequest.fromJson(p.cast<String, dynamic>())
          ],
          hasEarlier: j['hasEarlier'] == true,
        );
      case 'earlierEvents':
        return EarlierEvents(
            sessionId: _str(j['sessionId']), events: _events(j['events']), hasEarlier: j['hasEarlier'] == true);
      case 'event':
        final e = ConversationEvent.tryFromJson(_map(j['event']));
        return e == null ? null : EventMessage(sessionId: _str(j['sessionId']), event: e);
      case 'promptOpened':
        return PromptOpened(sessionId: _str(j['sessionId']), prompt: PromptRequest.fromJson(_map(j['prompt'])));
      case 'promptClosed':
        return PromptClosed(sessionId: _str(j['sessionId']), promptId: _str(j['promptId']));
      case 'usage':
        return UsageMessage(usage: UsageSnapshot.fromJson(_map(j['usage'])));
      case 'error':
        return ErrorMessage(code: _str(j['code']), message: _str(j['message']));
      case 'dirListing':
        return DirListing(
          path: _str(j['path']),
          parent: _strOrNull(j['parent']),
          entries: _entries(j['entries']),
          suggested: _entries(j['suggested']),
        );
      case 'remoteAccessStopped':
        return const RemoteAccessStopped();
      case 'machineRenamed':
        final name = _str(j['machineName']);
        return name.isEmpty ? null : MachineRenamed(machineName: name);
      case 'sessionActionDone':
        final action = _str(j['action']);
        return action.isEmpty
            ? null
            : SessionActionDone(action: action, sessionId: _str(j['sessionId']), message: _str(j['message']));
      case 'usageLimit':
        return UsageLimitMessage(limit: j['limit'] is Map ? UsageLimit.fromJson(_map(j['limit'])) : null);
      case 'resumeReport':
        final sid = _str(j['sessionId']);
        return sid.isEmpty
            ? null
            : ResumeReport(
                sessionId: sid, sessionName: _str(j['sessionName']), changed: j['changed'] == true, text: _str(j['text']));
      case 'accounts':
        final active = _strOrNull(j['activeAccountId']);
        return AccountsMessage(
          machineLogin: MachineLogin.fromJson(j['machineLogin']),
          activeAccountId: active == null || active.isEmpty ? machineLoginAccountId : active,
          accounts: [
            for (final a in (j['accounts'] is List ? j['accounts'] as List : const [])) ?AccountInfo.tryFromJson(a)
          ],
        );
      case 'accountSignIn':
        final flow = _str(j['flowId']);
        final state = _str(j['state']);
        if (flow.isEmpty || !AccountSignInStates.all.contains(state)) return null;
        return AccountSignInUpdate(
          flowId: flow,
          state: state,
          url: _strOrNull(j['url']),
          message: _strOrNull(j['message']),
          account: AccountInfo.tryFromJson(j['account']),
          token: _strOrNull(j['token']),
        );
      case 'tasks':
        return TasksMessage(tasks: [
          for (final t in (j['tasks'] is List ? j['tasks'] as List : const [])) ?BoardTask.tryFromJson(t)
        ]);
      case 'gitRemotes':
        return GitRemotesMessage(folders: [
          for (final f in (j['folders'] is List ? j['folders'] as List : const [])) ?GitFolder.tryFromJson(f)
        ]);
      case 'modelTable':
        final t = ModelTable.tryFromJson(j['table']);
        return t == null ? null : ModelTableMessage(table: t);
      case 'commands':
        return CommandsMessage(sessionId: _str(j['sessionId']), commands: [
          for (final c in (j['commands'] is List ? j['commands'] as List : const [])) ?SlashCommandInfo.tryFromJson(c)
        ]);
      case 'searchResults':
        return SearchResults(
            query: _str(j['query']),
            hits: [for (final h in (j['hits'] is List ? j['hits'] as List : const [])) ?SearchHit.tryFromJson(h)],
            truncated: j['truncated'] == true);
      case 'files':
        return FilesMessage(
            sessionId: _str(j['sessionId']),
            query: _str(j['query']),
            files: [for (final f in (j['files'] is List ? j['files'] as List : const [])) ?FileMention.tryFromJson(f)],
            truncated: j['truncated'] == true);
      case 'projects':
        final p = ProjectList.tryFromJson(j['projects']);
        return p == null ? null : ProjectsMessage(projects: p);
      case 'pairingPending':
        return PairingPending(machineName: _str(j['machineName']));
      case 'deviceKey':
        final key = _str(j['key']);
        final permission = _str(j['permission']);
        return key.isEmpty
            ? null
            : DeviceKey(
                key: key,
                permission: DevicePermissions.all.contains(permission) ? permission : DevicePermissions.full);
      case 'devices':
        return DevicesMessage(
          devices: [for (final d in (j['devices'] is List ? j['devices'] as List : const [])) ?DeviceInfo.tryFromJson(d)],
          pending: [
            for (final p in (j['pending'] is List ? j['pending'] as List : const [])) ?PendingDevice.tryFromJson(p)
          ],
        );
      case 'boardSummary':
        return BoardSummaryFromHost(summary: summaryFromJson(j['summary']));
      case 'boardRecords':
        return BoardRecordsFromHost(records: _records(j['records']));
      case 'boardKey':
        final k = _boardKey(j);
        return k == null ? null : BoardKeyFromHost(boardId: k.$1, key: k.$2, keyVersion: k.$3);
    }
  } catch (_) {
    return null;
  }
  return null;
}
