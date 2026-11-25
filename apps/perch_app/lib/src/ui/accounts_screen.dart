// Accounts (docs/superpowers/specs/2026-11-15-accounts-design.md): the owner's Claude
// accounts on this phone, each machine's own login and which account it uses, adding an
// account (sign in on the phone, or at the machine), signing in again before a token
// expires, and the per-session setting. Also the account picker every switch uses.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';
import 'package:url_launcher/url_launcher.dart';

import '../connection/account_store.dart';
import '../connection/host_connection.dart';
import '../state/providers.dart';
import 'app_theme.dart' show openGlass;
import 'glass/dots.dart';
import 'glass/mosaic.dart';
import 'glass/palette.dart';
import 'glass/settings.dart';
import 'glass/widgets.dart';
import 'labels.dart';
import 'glass/click.dart';

/// Opens a link in the phone's browser (replaced in tests).
typedef UrlOpener = Future<bool> Function(Uri url);

Future<bool> openInBrowser(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);

final urlOpenerProvider = Provider<UrlOpener>((ref) => openInBrowser);

void openAccounts(BuildContext context) => openGlass<void>(context, const AccountsScreen());

/// What a machine's account is called: `Work`, or `This machine's login`.
String machineAccountName(AccountsMessage m, String id) =>
    id == machineLoginAccountId ? "This machine's login" : (m.accounts.where((a) => a.id == id).firstOrNull?.label ?? 'Another account');

/// `Work · work@example.com · Max`, or `This machine's login · me@example.com · Max`.
String machineAccountLine(AccountsMessage m, String id) {
  if (id == machineLoginAccountId) {
    final l = m.machineLogin;
    if (!l.loggedIn) return "This machine's login · signed out";
    return ["This machine's login", ?l.email, if (planLabel(l.plan).isNotEmpty) planLabel(l.plan)].join(' · ');
  }
  final a = m.accounts.where((a) => a.id == id).firstOrNull;
  return a == null ? 'Another account' : a.describe();
}

/// A session's account in a few words, when the machine knows accounts: `on Work`.
String? sessionAccountLine(HostConnection c, SessionSummary s) {
  final m = c.accounts.value;
  final id = s.accountId;
  if (m == null || id == null) return null;
  if (m.accounts.isEmpty && id == machineLoginAccountId) return null; // only one account: nothing to tell apart
  return 'on ${machineAccountName(m, id)}';
}

/// The machine's accounts to choose from: its own login, then those it holds.
List<String> machineAccountIds(AccountsMessage m) => [machineLoginAccountId, for (final a in m.accounts) a.id];

/// Asks which of [connection]'s accounts to use; null when cancelled. [current] is ticked;
/// [exclude] are left out (the account a limit hit).
Future<String?> showAccountPicker(BuildContext context, HostConnection connection,
    {required String title, String? body, String? current, Set<String> exclude = const {}}) {
  final m = connection.accounts.value;
  if (m == null) {
    say(context, olderHostAccountsMessage);
    return Future.value();
  }
  final now = DateTime.now();
  final ids = [for (final id in machineAccountIds(m)) if (!exclude.contains(id)) id];
  return showGlassSheet<String>(
    context,
    (ctx) => GlassSheet(children: [
      ...sheetTitle(title, body),
      const SizedBox(height: 12),
      if (ids.isEmpty)
        Text('No other account on ${machineTitle(connection)}. Add one in Accounts.',
            style: gSans(14, FontWeight.w600, color: G.muted)),
      for (final id in ids)
        () {
          final a = m.accounts.where((x) => x.id == id).firstOrNull;
          final expired = a != null && a.expiry(now) == AccountExpiry.expired;
          return Opacity(
            opacity: expired ? 0.5 : 1,
            child: MenuRow(
              key: ValueKey('pick-account-$id'),
              label: machineAccountLine(m, id),
              icon: id == machineLoginAccountId ? Icons.computer_rounded : Icons.person_rounded,
              selected: id == current,
              onTap: expired ? () => say(ctx, 'This sign-in has expired: sign in again in Accounts.') : () => Navigator.of(ctx).pop(id),
            ),
          );
        }(),
      const SizedBox(height: 8),
      GlassButton(label: 'Cancel', onTap: () => Navigator.of(ctx).pop()),
    ]),
  );
}

/// Machine card's Switch: new sessions on the machine start on the chosen account.
Future<void> switchMachineAccount(BuildContext context, HostConnection connection) async {
  final m = connection.accounts.value;
  final id = await showAccountPicker(context, connection,
      title: 'Account for ${machineTitle(connection)}',
      body: 'New sessions on this machine start on it. Running sessions keep theirs.',
      current: m?.activeAccountId);
  if (id == null || !context.mounted || id == m?.activeAccountId) return;
  try {
    await connection.setActiveAccount(id);
    if (context.mounted) say(context, 'New sessions on ${machineTitle(connection)} use ${machineAccountName(connection.accounts.value!, id)}');
  } on SessionActionFailed catch (e) {
    if (context.mounted) say(context, e.message);
  }
}

/// The accounts that warn: expiring within two weeks, or expired.
List<AccountInfo> accountsNeedingSignIn(PhoneAccounts a, DateTime now) =>
    [for (final x in a.accounts) if (x.expiry(now) != AccountExpiry.ok) x];

/// The first screen's note about an account whose sign-in expires soon or has expired.
class AccountsNotice extends ConsumerWidget {
  final DateTime Function() clock;
  const AccountsNotice({super.key, this.clock = DateTime.now});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(phoneAccountsProvider);
    return ListenableBuilder(
      listenable: accounts,
      builder: (context, _) {
        final now = clock();
        final due = accountsNeedingSignIn(accounts, now);
        if (due.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: ClickDetector(
            key: const ValueKey('accounts-notice'),
            behavior: HitTestBehavior.opaque,
            onTap: () => openAccounts(context),
            child: Frost(
              tone: G.deep,
              tint: 0.6,
              rim: true,
              radius: 22,
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Row(children: [
                const Icon(Icons.key_rounded, size: 18, color: G.glow),
                const SizedBox(width: 10),
                Expanded(
                  child: Text([for (final a in due) '${a.label}: ${expiryLine(a, now)}'].join('\n'),
                      style: gSans(13.5, FontWeight.w700, color: G.glow)),
                ),
                Text('Sign in again', style: gSans(13, FontWeight.w800)),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class AccountsScreen extends ConsumerWidget {
  final DateTime Function() clock;
  const AccountsScreen({super.key, this.clock = DateTime.now});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(phoneAccountsProvider);
    final machines = ref.watch(machinesProvider);
    final registry = ref.watch(connectionsProvider);
    final connections = [for (final m in machines) registry.of(m)];
    return GlassScaffold(
      background: MosaicBackdrop(seed: 11, fade: G.deep, fadeFrom: 0.3, pixel: 0.6),
      child: ListenableBuilder(
        listenable: Listenable.merge([accounts, for (final c in connections) ...[c.accounts, c.link, c.displayName]]),
        builder: (context, _) {
          final now = clock();
          return ListView(
            key: const ValueKey('accounts-list'),
            padding: screenPadding(context),
            children: [
              Row(children: [
                GlassOrb(
                    key: const ValueKey('back'),
                    icon: Icons.arrow_back_rounded,
                    label: 'Back',
                    onTap: () => Navigator.of(context).maybePop()),
                const Spacer(),
              ]),
              const SizedBox(height: 30),
              Text('Accounts', style: gSerif(38, w: FontWeight.w500, height: 1.05).copyWith(shadows: lift)),
              const SizedBox(height: 6),
              Text('Your Claude accounts, on every paired machine. Sessions keep their history on the machine '
                  'whichever account they ran on.',
                  style: gSans(13.5, FontWeight.w600).copyWith(shadows: lift)),
              const SizedBox(height: 18),
              Frost(
                rim: true,
                tone: G.deep,
                tint: 0.5,
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('ON THIS PHONE', style: gCaps(11)),
                  const SizedBox(height: 6),
                  if (accounts.accounts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text("None yet. Each machine uses its own Claude Code login until you add an account.",
                          style: gSans(14, FontWeight.w500, color: G.muted)),
                    ),
                  for (final a in accounts.accounts) _AccountRow(account: a, now: now, connections: connections),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GlassButton(
                      key: const ValueKey('add-account'),
                      label: 'Add account',
                      icon: Icons.person_add_alt_1_rounded,
                      warm: true,
                      onTap: () => showAddAccountSheet(context),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 18),
              Frost(
                rim: true,
                tone: G.deep,
                tint: 0.5,
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('MACHINES', style: gCaps(11)),
                  const SizedBox(height: 6),
                  if (connections.isEmpty)
                    Text('No machines yet.', style: gSans(14, FontWeight.w500, color: G.muted)),
                  for (final c in connections) _MachineAccountRow(connection: c),
                ]),
              ),
              const SizedBox(height: 18),
              Frost(
                tone: G.deep,
                tint: 0.5,
                padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Choose account per session', style: gSans(15, FontWeight.w700)),
                      Text("New session asks which account; Switch on a machine is then each session's choice.",
                          style: gSans(12.5, FontWeight.w500, color: G.muted)),
                    ]),
                  ),
                  const SizedBox(width: 10),
                  GlassToggle(
                    key: const ValueKey('per-session'),
                    value: accounts.perSession,
                    onChanged: (v) => accounts.setPerSession(v),
                  ),
                ]),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AccountRow extends ConsumerWidget {
  final AccountInfo account;
  final DateTime now;
  final List<HostConnection> connections;
  const _AccountRow({required this.account, required this.now, required this.connections});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = account;
    final expiry = a.expiry(now);
    final line = expiryLine(a, now);
    final missing = [
      for (final c in connections)
        if (c.accounts.value != null && !c.accounts.value!.accounts.any((x) => x.id == a.id)) machineTitle(c)
    ];
    return Padding(
      key: ValueKey('account-${a.id}'),
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MosaicThumb(seed: seedOf(a.id), size: 40, radius: 12),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a.label, style: gSans(16, FontWeight.w700)),
            if (a.email != null || a.plan != null)
              Text([?a.email, if (planLabel(a.plan).isNotEmpty) planLabel(a.plan)].join(' · '),
                  style: gSans(13, FontWeight.w500, color: G.muted)),
            if (line.isNotEmpty)
              Text(line,
                  key: ValueKey('expiry-${a.id}'),
                  style: gSans(12.5, expiry == AccountExpiry.ok ? FontWeight.w500 : FontWeight.w800,
                      color: expiry == AccountExpiry.ok ? G.muted : G.glow)),
            if (missing.isNotEmpty)
              Text('Not on ${missing.join(', ')} yet', style: gSans(12.5, FontWeight.w500, color: G.muted)),
            if (expiry != AccountExpiry.ok)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: GlassButton(
                  key: ValueKey('sign-in-again-${a.id}'),
                  label: 'Sign in again',
                  compact: true,
                  warm: true,
                  onTap: () => showAddAccountSheet(context, renewing: a),
                ),
              ),
          ]),
        ),
        ClickDetector(
          key: ValueKey('account-menu-${a.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _menu(context, ref),
          child: Semantics(
            button: true,
            label: 'Account menu',
            excludeSemantics: true,
            child: const Padding(padding: EdgeInsets.only(left: 6, top: 4), child: ValuePill('Manage')),
          ),
        ),
      ]),
    );
  }

  Future<void> _menu(BuildContext context, WidgetRef ref) async {
    final choice = await showGlassSheet<String>(
      context,
      (ctx) => GlassSheet(children: [
        menuHeader(seedOf(account.id), account.label, Text(account.describe(), style: gSans(13, FontWeight.w500, color: G.muted))),
        const SizedBox(height: 14),
        MenuRow(label: 'Sign in again…', icon: Icons.key_rounded, onTap: () => Navigator.of(ctx).pop('renew')),
        MenuRow(label: 'Remove…', icon: Icons.delete_outline_rounded, danger: true, onTap: () => Navigator.of(ctx).pop('remove')),
      ]),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'renew') {
      await showAddAccountSheet(context, renewing: account);
      return;
    }
    if (!await confirmSheet(context,
        title: 'Remove ${account.label}?',
        body: 'This phone and every machine forget it and its sign-in. Running sessions keep going; machines that '
            'used it start new sessions on their own login.',
        yes: 'Remove')) {
      return;
    }
    await ref.read(phoneAccountsProvider).remove(account.id);
    ref.read(connectionsProvider).removeAccount(account.id);
  }
}

class _MachineAccountRow extends StatelessWidget {
  final HostConnection connection;
  const _MachineAccountRow({required this.connection});
  @override
  Widget build(BuildContext context) {
    final c = connection;
    final m = c.accounts.value;
    final online = c.link.value == LinkState.online;
    return Padding(
      key: ValueKey('machine-accounts-${c.machine.id}'),
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        MosaicThumb(seed: seedOf(c.machine.id), size: 40, radius: 12),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(machineTitle(c), style: gSans(16, FontWeight.w700)),
            Text(
              !online
                  ? linkLabel(c.link.value)
                  : m == null
                      ? 'Update Perch on this machine to use accounts'
                      : 'New sessions: ${machineAccountLine(m, m.activeAccountId)}',
              style: gSans(13, FontWeight.w500, color: G.muted),
            ),
            if (m != null && online && m.activeAccountId != machineLoginAccountId)
              Text(machineAccountLine(m, machineLoginAccountId), style: gSans(12.5, FontWeight.w500, color: G.muted)),
          ]),
        ),
        if (online && m != null)
          ClickDetector(
            key: ValueKey('switch-machine-${c.machine.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => switchMachineAccount(context, c),
            child: Semantics(
              button: true,
              label: 'Switch',
              excludeSemantics: true,
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                ValuePill('Switch'),
                Icon(Icons.chevron_right_rounded, color: G.glow, size: 22),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Adds an account, or signs one in again ([renewing]).
Future<void> showAddAccountSheet(BuildContext context, {AccountInfo? renewing}) =>
    showGlassSheet<void>(context, (_) => AddAccountSheet(renewing: renewing));

class AddAccountSheet extends ConsumerStatefulWidget {
  final AccountInfo? renewing;
  const AddAccountSheet({super.key, this.renewing});
  @override
  ConsumerState<AddAccountSheet> createState() => _AddAccountSheetState();
}

class _AddAccountSheetState extends ConsumerState<AddAccountSheet> {
  late final _label = TextEditingController(text: widget.renewing?.label ?? '');
  late final _email = TextEditingController(text: widget.renewing?.email ?? '');
  late final _plan = TextEditingController(text: widget.renewing?.plan ?? '');
  final _code = TextEditingController();
  late final String _flowId = widget.renewing?.id ?? newAccountId();

  HostConnection? _machine;
  String? _labelError;
  String? _codeError;

  /// The last step the machine reported; null before Start.
  AccountSignInUpdate? _step;
  String? _error;
  bool _busy = false;
  StreamSubscription<AccountSignInUpdate>? _steps;
  StreamSubscription<ErrorMessage>? _errors;

  List<HostConnection> get _candidates {
    final registry = ref.read(connectionsProvider);
    return [
      for (final m in ref.read(machinesProvider))
        if (registry.of(m) case final c when c.link.value == LinkState.online && c.supportsAccounts) c
    ];
  }

  @override
  void initState() {
    super.initState();
    final all = _candidates;
    if (all.isNotEmpty) _use(all.first);
  }

  void _use(HostConnection c) {
    _steps?.cancel();
    _errors?.cancel();
    _machine = c;
    _steps = c.signIns.where((u) => u.flowId == _flowId).listen(_onStep);
    _errors = c.errors.listen((e) {
      if (!mounted || !_busy) return;
      setState(() {
        _busy = false;
        _error = isUnknownMessageError(e) ? olderHostAccountsMessage : e.message;
      });
    });
  }

  Future<void> _onStep(AccountSignInUpdate u) async {
    if (!mounted) return;
    // (the connection registry keeps the account and gives it to every machine)
    if (u.state == AccountSignInStates.done && u.account != null) {
      say(context, '${u.account!.label} added: every paired machine can use it');
    }
    setState(() {
      _step = u;
      _busy = u.state == AccountSignInStates.checking;
      _error = u.state == AccountSignInStates.failed ? u.message : null;
      if (u.state == AccountSignInStates.url) _code.clear();
    });
  }

  @override
  void dispose() {
    // Closing the sheet abandons a phone sign-in; a sign-in at the machine goes on (the
    // owner may be at it), and its account still reaches the phone.
    final s = _step?.state;
    if (s == AccountSignInStates.url || s == AccountSignInStates.checking) {
      _machine?.accountSignIn(AccountSignIn(flowId: _flowId, action: AccountSignInActions.cancel));
    }
    _steps?.cancel();
    _errors?.cancel();
    _label.dispose();
    _email.dispose();
    _plan.dispose();
    _code.dispose();
    super.dispose();
  }

  String? _checkedLabel() {
    final l = _label.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final e = l.isEmpty ? 'Give it a name, such as Personal or Work' : (l.length > maxAccountLabelLength ? 'At most $maxAccountLabelLength characters' : null);
    setState(() => _labelError = e);
    return e == null ? l : null;
  }

  void _start({bool atMachine = false}) {
    final c = _machine;
    final label = _checkedLabel();
    if (c == null || label == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    c.accountSignIn(AccountSignIn(
      flowId: _flowId,
      action: atMachine ? AccountSignInActions.atMachine : AccountSignInActions.start,
      label: label,
      email: _email.text.trim().isEmpty ? null : _email.text.trim(),
      plan: _plan.text.trim().isEmpty ? null : _plan.text.trim(),
    ));
  }

  void _sendCode() {
    final code = _code.text.replaceAll(RegExp(r'\s+'), '');
    if (code.isEmpty) {
      setState(() => _codeError = 'Paste the code the sign-in page showed');
      return;
    }
    setState(() {
      _codeError = null;
      _busy = true;
    });
    _machine?.accountSignIn(AccountSignIn(flowId: _flowId, action: AccountSignInActions.code, code: code));
  }

  Future<void> _openLink(String url) async {
    final ok = await ref.read(urlOpenerProvider)(Uri.parse(url));
    if (!ok && mounted) say(context, "Couldn't open the browser on this phone.");
  }

  @override
  Widget build(BuildContext context) {
    final step = _step;
    final machines = _candidates;
    final renewing = widget.renewing;
    final title = renewing == null ? 'Add account' : 'Sign in again: ${renewing.label}';
    if (_machine == null) {
      return GlassSheet(children: [
        ...sheetTitle(title, 'Connect to a machine running this version of Perch first: it runs the sign-in.'),
        const SizedBox(height: 14),
        GlassButton(label: 'Close', onTap: () => Navigator.of(context).pop()),
      ]);
    }
    final where = machineTitle(_machine!);
    final children = <Widget>[...sheetTitle(title)];
    final state = step?.state;
    if (state == null || state == AccountSignInStates.cancelled) {
      children.addAll([
        const SizedBox(height: 6),
        Text('Perch runs claude setup-token on $where. You sign in on this phone and paste the code back; '
            'the account then works on every paired machine for about a year.',
            style: gSans(14, FontWeight.w500, color: G.muted)),
        if (machines.length > 1) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final c in machines)
              GlassChip(
                key: ValueKey('sign-in-on-${c.machine.id}'),
                label: machineTitle(c),
                icon: identical(c, _machine) ? Icons.check_rounded : Icons.computer_rounded,
                onTap: () => setState(() => _use(c)),
              ),
          ]),
        ],
        const SizedBox(height: 14),
        GlassField(
            key: const ValueKey('account-label'),
            controller: _label,
            label: 'Name',
            hint: 'Personal, Work…',
            maxLength: maxAccountLabelLength,
            error: _labelError),
        const SizedBox(height: 12),
        GlassField(key: const ValueKey('account-email'), controller: _email, label: 'Email (optional)'),
        const SizedBox(height: 12),
        GlassField(key: const ValueKey('account-plan'), controller: _plan, label: 'Plan (optional)', hint: 'Pro, Max…'),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: GlassButton(label: 'Cancel', onTap: () => Navigator.of(context).pop())),
          const SizedBox(width: 10),
          Expanded(
            child: GlassButton(
                key: const ValueKey('start-sign-in'),
                label: 'Sign in',
                warm: true,
                onTap: _busy ? null : () => _start()),
          ),
        ]),
      ]);
    } else if (state == AccountSignInStates.url || state == AccountSignInStates.checking) {
      final url = step!.url ?? _lastUrl;
      _lastUrl = url;
      children.addAll([
        const SizedBox(height: 6),
        Text('1. Open the sign-in page and sign in to the account.\n2. Copy the code it shows and paste it here.',
            style: gSans(14, FontWeight.w600)),
        if (step.message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(step.message!, style: gSans(13.5, FontWeight.w700, color: G.glow)),
          ),
        const SizedBox(height: 12),
        GlassButton(
          key: const ValueKey('open-sign-in'),
          label: 'Open sign-in page',
          icon: Icons.open_in_new_rounded,
          onTap: url == null ? null : () => _openLink(url),
        ),
        const SizedBox(height: 12),
        GlassField(
          key: const ValueKey('sign-in-code'),
          controller: _code,
          label: 'Code',
          hint: 'Paste the code',
          error: _codeError,
          onSubmitted: (_) => _sendCode(),
        ),
        const SizedBox(height: 14),
        Row(children: [
          if (_busy) ...[const WorkingWave(width: 40, height: 18, bars: 8), const SizedBox(width: 14)],
          Expanded(
            child: GlassButton(
                key: const ValueKey('send-code'), label: 'Send code', warm: true, onTap: _busy ? null : _sendCode),
          ),
        ]),
        const SizedBox(height: 8),
        _atMachineLink(where),
      ]);
    } else if (state == AccountSignInStates.atMachine) {
      children.addAll([
        const SizedBox(height: 6),
        Text(step!.message ?? 'Sign in in the terminal window on $where.', style: gSans(14, FontWeight.w600)),
        const SizedBox(height: 14),
        const Center(child: WorkingWave(width: 60, height: 22, bars: 9)),
        const SizedBox(height: 6),
        Text('You can close this: the account is added when you finish at the machine.',
            style: gSans(12.5, FontWeight.w500, color: G.muted)),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: GlassButton(
                key: const ValueKey('cancel-at-machine'),
                label: 'Cancel sign-in',
                onTap: () {
                  _machine?.accountSignIn(AccountSignIn(flowId: _flowId, action: AccountSignInActions.cancel));
                  Navigator.of(context).pop();
                }),
          ),
          const SizedBox(width: 10),
          Expanded(child: GlassButton(label: 'Close', onTap: () => Navigator.of(context).pop())),
        ]),
      ]);
    } else if (state == AccountSignInStates.done) {
      final a = step!.account;
      children.addAll([
        const SizedBox(height: 6),
        Text('${a?.label ?? 'The account'} is ready on every paired machine.', style: gSans(15, FontWeight.w700)),
        if (a != null && expiryLine(a, DateTime.now()).isNotEmpty)
          Text(expiryLine(a, DateTime.now()), style: gSans(13, FontWeight.w500, color: G.muted)),
        const SizedBox(height: 14),
        GlassButton(key: const ValueKey('sign-in-done'), label: 'Done', warm: true, onTap: () => Navigator.of(context).pop()),
      ]);
    } else {
      // failed
      children.addAll([
        const SizedBox(height: 6),
        Text(_error ?? step!.message ?? 'The sign-in did not work.', style: gSans(14, FontWeight.w700, color: G.glow)),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: GlassButton(label: 'Try again', onTap: () => _start())),
          const SizedBox(width: 10),
          Expanded(
            child: GlassButton(
                key: const ValueKey('sign-in-at-machine'),
                label: 'Sign in at the machine',
                warm: true,
                onTap: () => _start(atMachine: true)),
          ),
        ]),
      ]);
    }
    if (_error != null && state != AccountSignInStates.failed) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(_error!, style: gSans(13.5, FontWeight.w700, color: G.glow)),
      ));
    }
    return GlassSheet(children: children);
  }

  String? _lastUrl;

  Widget _atMachineLink(String where) => Align(
        alignment: Alignment.centerLeft,
        child: ClickDetector(
          key: const ValueKey('use-machine-instead'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _start(atMachine: true),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Text('Sign in at $where instead', style: gSans(14, FontWeight.w700, color: Perch.orange)),
          ),
        ),
      );
}
