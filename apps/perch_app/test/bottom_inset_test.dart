// Android draws the app edge to edge: the navigation bar (gesture bar or three buttons) sits
// over the bottom of every screen. Each scrolling screen ends above it, and floating buttons
// and the composer sit above it (the owner's S24: the last items and half a button were
// hidden behind the bar).
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/account_store.dart';
import 'package:perch_app/src/connection/board_file.dart';
import 'package:perch_app/src/connection/board_store.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/connection/machine_store.dart';
import 'package:perch_app/src/state/providers.dart';
import 'package:perch_app/src/ui/board_screen.dart';
import 'package:perch_app/src/ui/glass/widgets.dart';
import 'package:perch_app/src/ui/home_screen.dart';
import 'package:perch_app/src/ui/model_table_screen.dart';
import 'package:perch_app/src/ui/session_screen.dart';
import 'package:perch_app/src/ui/sessions_screen.dart';
import 'package:perch_app/src/ui/task_detail.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'glass_harness.dart';

const _dpr = 2.625;
const _height = 2340 / _dpr;

/// The navigation bars to check, in logical pixels: the gesture bar and the three buttons.
const bars = {'gesture bar': 24.0, 'three-button bar': 48.0};

/// A phone (S24-like: 1080 x 2340) with the status bar and [bar] at the bottom.
void phoneWithBar(WidgetTester tester, double bar) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = _dpr;
  tester.view.padding = FakeViewPadding(top: 40 * _dpr, bottom: bar * _dpr);
  tester.view.viewPadding = FakeViewPadding(top: 40 * _dpr, bottom: bar * _dpr);
  addTearDown(tester.view.reset);
}

/// [f] is on screen and wholly above the navigation bar.
void expectAboveBar(WidgetTester tester, Finder f, double bar, {String? reason}) {
  expect(f, findsWidgets, reason: reason);
  final r = tester.getRect(f.last);
  expect(r.bottom, lessThanOrEqualTo(_height - bar), reason: '${reason ?? f} ends at ${r.bottom}, the bar starts at ${_height - bar}');
  expect(r.top, greaterThanOrEqualTo(0), reason: reason);
}

Finder composerField() => find.descendant(of: find.byKey(const ValueKey('composer')), matching: find.byType(TextField));

/// [f] ends above the composer (not covered by it).
void expectAboveComposer(WidgetTester tester, Finder f) {
  expect(f, findsWidgets);
  final top = tester.getRect(find.byKey(const ValueKey('composer'))).top;
  expect(tester.getRect(f.last).bottom, lessThanOrEqualTo(top), reason: '$f ends at ${tester.getRect(f.last).bottom}, the composer starts at $top');
}

/// Scrolls [list] to its end.
Future<void> toEnd(WidgetTester tester, Finder list) async {
  for (var i = 0; i < 6; i++) {
    await tester.drag(list.first, const Offset(0, -1200));
    await tester.pumpAndSettle();
  }
}

BoardTask _task(String id, String title, {TaskColumn column = TaskColumn.backlog, TaskReport? report}) =>
    BoardTask(id: id, title: title, description: 'Do $title', cwd: r'D:\projects\perch', column: column, report: report, createdAtMs: int.tryParse(id.substring(1)) ?? 0);

void main() {
  late FakeChannels channels;
  final conns = <HostConnection>[];
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    channels = FakeChannels();
  });
  tearDown(() {
    for (final c in conns) {
      c.dispose();
    }
    conns.clear();
  });

  Future<HostConnection> online(WidgetTester tester,
      {List<SessionSummary> sessions = const [], List<BoardTask> tasks = const [], BoardStore? store}) async {
    if (store != null && store.file == null) {
      final f = BoardFile(dir: null, writer: 'phone', keyBox: MemorySecretBox());
      await tester.runAsync(f.load);
      store.attach(f);
    }
    final c = HostConnection(testMachine(id: 'm1', label: 'Desk', lan: ['10.0.0.1:8787']),
        channelFactory: channels.factory, modelSource: store, boardFile: store?.file);
    conns.add(c);
    c.connect();
    channels.last.send(welcome);
    channels.last.send(Sessions(sessions: sessions));
    channels.last.send(TasksMessage(tasks: tasks));
    channels.last.send(ModelTableMessage(table: ModelTable.starting));
    await tester.runAsync(() => eventually(() => c.link.value == LinkState.online && c.tasks.value != null));
    return c;
  }

  /// Session s1's conversation with 40 messages, scrolled to the newest.
  Future<HostConnection> conversation(WidgetTester tester, {SessionState state = SessionState.idle}) async {
    final c = await online(tester, sessions: [summary('s1', name: 'Fix login', state: state)]);
    await tester.pumpWidget(glassApp(SessionScreen(connection: c, sessionId: 's1')));
    await tester.runAsync(() => eventually(() => channels.last.messages.whereType<Subscribe>().isNotEmpty));
    channels.last.send(Events(sessionId: 's1', events: [for (var i = 1; i <= 40; i++) UserMessage('msg $i', seq: i)]));
    await tester.runAsync(() => pump(50));
    await tester.pumpAndSettle();
    return c;
  }

  final many = [
    for (var i = 0; i < 14; i++) summary('s$i', name: 'Session number $i', startedAtMs: 100 + i),
  ];

  for (final MapEntry(key: name, value: bar) in bars.entries) {
    group(name, () {
      testWidgets('home: the last item (Stop all) ends above the bar', (tester) async {
        phoneWithBar(tester, bar);
        SharedPreferences.setMockInitialValues({
          MachineStore.key: jsonEncode([
            for (var i = 0; i < 7; i++) testMachine(id: 'm$i', label: 'Machine $i', lan: const []).toJson(),
          ])
        });
        await tester.pumpWidget(ProviderScope(
          overrides: [channelFactoryProvider.overrideWithValue(channels.factory)],
          child: glassApp(const HomeScreen()),
        ));
        await tester.runAsync(() => pump(50));
        await tester.pumpAndSettle();
        await toEnd(tester, find.byKey(const ValueKey('home-list')));
        expectAboveBar(tester, find.byKey(const ValueKey('stop-all')), bar);
      });

      testWidgets("a machine's sessions: the last item ends above the bar", (tester) async {
        phoneWithBar(tester, bar);
        final c = await online(tester, sessions: many);
        await tester.pumpWidget(ProviderScope(child: glassApp(SessionsScreen(connection: c))));
        await tester.pumpAndSettle();
        await toEnd(tester, find.byKey(const ValueKey('sessions-list')));
        expectAboveBar(tester, find.byKey(const ValueKey('stop-all')), bar);
      });

      testWidgets('board: the last card ends above the add button, which sits above the bar', (tester) async {
        phoneWithBar(tester, bar);
        final store = BoardStore(persist: false);
        final c = await online(tester, tasks: [for (var i = 0; i < 12; i++) _task('t$i', 'Task number $i')], store: store);
        await tester.pumpWidget(glassApp(BoardView(connections: [c], store: store)));
        await tester.pumpAndSettle();
        expectAboveBar(tester, find.byKey(const ValueKey('board-add')), bar);
        await toEnd(tester, find.byKey(const ValueKey('column-backlog')));
        final last = find.byKey(const ValueKey('card-t11'));
        expectAboveBar(tester, last, bar);
        expect(tester.getRect(last).bottom, lessThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('board-add'))).top),
            reason: 'the add button does not cover the last card');
      });

      testWidgets("a sheet's buttons sit above the bar", (tester) async {
        phoneWithBar(tester, bar);
        await tester.pumpWidget(glassApp(Builder(
            builder: (context) => Center(
                child: GestureDetector(
                    onTap: () => confirmSheet(context, title: 'Sure?', body: 'Body', yes: 'Yes'), child: const Text('open'))))));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expectAboveBar(tester, button('Yes'), bar);
      });

      testWidgets('task detail: the last section ends above the bar', (tester) async {
        phoneWithBar(tester, bar);
        final store = BoardStore(persist: false);
        final report = TaskReport(
            text: List.filled(30, 'A long report line.').join('\n\n'), files: const ['a.dart', 'b.dart'], changes: const [' a.dart | 2 +-'], atMs: 1);
        final c = await online(tester, tasks: [_task('t1', 'Long one', column: TaskColumn.review, report: report)], store: store);
        await tester.pumpWidget(glassApp(TaskDetailScreen(taskId: 't1', all: [c], store: store)));
        await tester.pumpAndSettle();
        await toEnd(tester, find.byType(Scrollable));
        expectAboveBar(tester, find.byKey(const ValueKey('detail-changes')), bar);
      });

      testWidgets('model table: the last row ends above the bar', (tester) async {
        phoneWithBar(tester, bar);
        await tester.pumpWidget(glassApp(ModelTableScreen(store: BoardStore(persist: false))));
        await tester.pumpAndSettle();
        await toEnd(tester, find.byType(Scrollable));
        expectAboveBar(tester, find.text('Search and chores'), bar);
      });

      testWidgets('conversation: the composer and Send sit above the bar, the last message above them', (tester) async {
        phoneWithBar(tester, bar);
        await conversation(tester);
        expectAboveBar(tester, find.byKey(const ValueKey('send')), bar);
        expectAboveBar(tester, find.byKey(const ValueKey('composer')), bar);
        expectAboveComposer(tester, find.text('msg 40'));
        // Scrolled as far as it goes: still the same.
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
        await tester.pumpAndSettle();
        expectAboveComposer(tester, find.text('msg 40'));
      });

      testWidgets("conversation: a card sits above the composer and the bar, the last message above it", (tester) async {
        phoneWithBar(tester, bar);
        await conversation(tester, state: SessionState.waitingPermission);
        channels.last.send(const PromptOpened(
            sessionId: 's1',
            prompt: PromptRequest(promptId: 'r1', kind: PromptKind.permission, toolName: 'Bash', input: {'command': 'ls'})));
        await tester.runAsync(() => pump(50));
        await tester.pumpAndSettle();
        expectAboveBar(tester, find.text('Allow'), bar);
        expectAboveComposer(tester, find.text('Allow'));
        final cardTop = tester.getRect(find.text('Claude wants to use Bash')).top;
        expect(tester.getRect(find.text('msg 40')).bottom, lessThanOrEqualTo(cardTop), reason: 'the card does not cover the last message');
      });

      testWidgets('conversation: the / list sits above the composer and the bar', (tester) async {
        phoneWithBar(tester, bar);
        await conversation(tester);
        await tester.enterText(composerField(), '/');
        await tester.runAsync(() => eventually(() => channels.last.messages.whereType<ListCommands>().isNotEmpty));
        channels.last.send(const CommandsMessage(
            sessionId: 's1', commands: [SlashCommandInfo(name: '/compact', description: 'Free up context by summarizing')]));
        await tester.runAsync(() => pump(50));
        await tester.pumpAndSettle();
        expectAboveBar(tester, find.byKey(const ValueKey('command-list')), bar);
        expectAboveComposer(tester, find.byKey(const ValueKey('command-list')));
      });

      testWidgets('conversation: a bar that grows keeps the newest message above the composer', (tester) async {
        phoneWithBar(tester, 0);
        await conversation(tester);
        tester.view.padding = FakeViewPadding(top: 40 * _dpr, bottom: bar * _dpr);
        tester.view.viewPadding = FakeViewPadding(top: 40 * _dpr, bottom: bar * _dpr);
        await tester.pumpAndSettle();
        expectAboveComposer(tester, find.text('msg 40'));
      });

      testWidgets('conversation with the keyboard open: the composer sits right on the keyboard', (tester) async {
        phoneWithBar(tester, bar);
        await conversation(tester);
        // The keyboard covers the bar: Android reports it as a view inset, the padding drops to 0.
        const keyboard = 300.0;
        tester.view.viewInsets = const FakeViewPadding(bottom: keyboard * _dpr);
        tester.view.padding = const FakeViewPadding(top: 40 * _dpr);
        await tester.pumpAndSettle();
        final field = tester.getRect(find.byKey(const ValueKey('composer')));
        expect(field.bottom, lessThanOrEqualTo(_height - keyboard), reason: 'not under the keyboard');
        expect(field.bottom, greaterThan(_height - keyboard - 24), reason: 'right on the keyboard, no gap the size of the bar');
        expectAboveComposer(tester, find.text('msg 40'));
      });
    });
  }
}
