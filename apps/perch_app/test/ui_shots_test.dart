// Renders the app's real screens to PNG files, light and dark, over a fake connection with
// made-up data (nothing here comes from a real machine or conversation).
// Skipped unless UI_SHOTS names an output folder:
//   UI_SHOTS=../../.scratch/shots flutter test test/ui_shots_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perch_app/src/connection/host_connection.dart';
import 'package:perch_app/src/connection/machine_store.dart';
import 'package:perch_app/src/state/providers.dart';
import 'package:perch_app/src/state/session_prefs.dart';
import 'package:perch_app/src/ui/add_machine_screen.dart';
import 'package:perch_app/src/ui/app_menu.dart';
import 'package:perch_app/src/ui/board_screen.dart';
import 'package:perch_app/src/ui/intro.dart';
import 'package:perch_app/src/ui/model_table_screen.dart';
import 'package:perch_app/src/ui/projects_screen.dart';
import 'package:perch_app/src/ui/task_detail.dart';
import 'package:perch_app/src/ui/task_sheets.dart';
import 'package:perch_app/src/ui/board_logic.dart' show BoardItem;
import 'package:perch_app/src/ui/app_theme.dart';
import 'package:perch_app/src/ui/compatibility.dart';
import 'package:perch_app/src/ui/glass/mosaic.dart';
import 'package:perch_app/src/ui/glass/palette.dart';
import 'package:perch_app/src/ui/glass/theme.dart';
import 'package:perch_app/src/ui/glass/widgets.dart';
import 'package:perch_app/src/ui/home_screen.dart';
import 'package:perch_app/src/ui/machine_menu.dart';
import 'package:perch_app/src/ui/new_session_sheet.dart';
import 'package:perch_app/src/ui/resumed_toast.dart';
import 'package:perch_app/src/ui/session_menu.dart';
import 'package:perch_app/src/ui/session_screen.dart';
import 'package:perch_app/src/ui/sessions_screen.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

final _out = Platform.environment['UI_SHOTS'];

Future<void> _loadFonts() async {
  Future<void> font(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(File(f).readAsBytes().then((b) => ByteData.sublistView(b)));
    }
    await loader.load();
  }

  const dir = 'assets/ui/fonts';
  await font(GlassFonts.serif, ['$dir/Newsreader.ttf']);
  await font(GlassFonts.sans, ['$dir/Manrope.ttf']);
  await font(GlassFonts.mono, ['$dir/JetBrainsMono.ttf']);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
  final mf = '$flutterRoot/bin/cache/artifacts/material_fonts';
  await font('MaterialIcons', ['$mf/materialicons-regular.otf']);
  await font('Roboto', ['$mf/roboto-regular.ttf', '$mf/roboto-medium.ttf', '$mf/roboto-bold.ttf']);
}

/// A fake camera view for the pairing screen: dark glass with corner marks.
Widget _fakeCamera(BuildContext context, void Function(String) onCode) => Container(
      color: const Color(0xFF15110F),
      child: CustomPaint(painter: _Corners()),
    );

class _Corners extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Perch.cream
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final r = Rect.fromCenter(center: size.center(Offset.zero), width: size.width * 0.6, height: size.width * 0.6);
    const l = 34.0;
    for (final (c, dx, dy) in [(r.topLeft, 1, 1), (r.topRight, -1, 1), (r.bottomLeft, 1, -1), (r.bottomRight, -1, -1)]) {
      canvas.drawLine(c, c + Offset(l * dx, 0), p);
      canvas.drawLine(c, c + Offset(0, l * dy), p);
    }
  }

  @override
  bool shouldRepaint(_Corners old) => false;
}

int _ago(Duration d) => DateTime.now().subtract(d).millisecondsSinceEpoch;

SessionSummary _s(String id, String name, String cwd, SessionState state,
        {SessionOrigin origin = SessionOrigin.perch, int open = 0, bool live = true, Duration? last, int startedMin = 60}) =>
    SessionSummary(
        id: id,
        name: name,
        cwd: cwd,
        origin: origin,
        state: state,
        startedAtMs: _ago(Duration(minutes: startedMin)),
        openPrompts: open,
        live: live,
        lastPromptAtMs: last == null ? null : _ago(last));

final _studio = [
  _s('s-release', 'Release checklist', r'D:\demo\perch-demo\docs', SessionState.idle, last: const Duration(hours: 3), startedMin: 400),
  _s('s-billing', 'Refactor billing export', r'D:\demo\billing-api', SessionState.waitingQuestion,
      open: 1, last: const Duration(minutes: 12), startedMin: 50),
  _s('s-upload', 'Fix flaky upload test', r'D:\demo\photo-app', SessionState.waitingPermission,
      origin: SessionOrigin.external, open: 1, last: const Duration(minutes: 25), startedMin: 90),
  _s('s-dark', 'Dark mode for settings', r'D:\demo\photo-app', SessionState.waitingPlan,
      open: 1, last: const Duration(minutes: 37), startedMin: 120),
  _s('s-docs', 'Write API docs', r'D:\demo\billing-api\docs', SessionState.working,
      last: const Duration(minutes: 4), startedMin: 30),
  _s('s-cache', 'Spike: image cache', r'D:\demo\photo-app', SessionState.finished, last: const Duration(hours: 5), startedMin: 500),
  _s('s-old', 'Old prototype', r'D:\demo\sketches', SessionState.idle, live: false, origin: SessionOrigin.external, startedMin: 3000),
];

final _mac = [
  _s('m-readme', 'Tidy the README', '/Users/demo/site', SessionState.working, last: const Duration(minutes: 2), startedMin: 20),
  _s('m-router', 'Try the new router', '/Users/demo/site/app', SessionState.idle,
      origin: SessionOrigin.external, last: const Duration(hours: 1), startedMin: 70),
];

UsageSnapshot _usage(double five, double week) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return UsageSnapshot(
    fiveHour: UsageWindow(utilization: five, resetsAt: now + 2 * 3600 + 1200, status: 'allowed'),
    sevenDay: UsageWindow(utilization: week, resetsAt: now + 4 * 86400, status: 'allowed'),
  );
}

const _untested = Compatibility(
  status: CompatibilityStatus.untested,
  claudeVersion: '2.1.330',
  releaseNotes: ReleaseNotesFindings(
      checked: true,
      versions: ['2.1.326', '2.1.330'],
      relevantLines: ['Improved how permission prompts wrap long commands'],
      topics: ['prompt']),
  seenWorking: ['question', 'permission'],
  selfTest: SelfTestStatus(enabled: false),
);

const _drifted = Compatibility(
  status: CompatibilityStatus.drifted,
  claudeVersion: '2.1.331',
  reason: 'Claude Code shows a dialog Perch cannot recognise.',
  evidence: 'Session: Tidy the README\nExpected: a permission request\nScreen (last 2 lines):\n> 1. Maybe\n  2. Later',
);

List<ConversationEvent> _docsEvents() => [
      UserMessage('Write the API docs for the billing endpoints, one page per resource.', seq: 1),
      AssistantText("I'll start from the route table and keep each page short: what it does, its fields, an example.",
          seq: 2),
      ToolCall('t1', 'Read', {'file_path': r'D:\demo\billing-api\lib\routes.dart'}, seq: 3),
      ToolResult('t1', "final routes = [\n  Route('/invoices', InvoicesHandler()),\n  Route('/exports', ExportsHandler()),\n];",
          seq: 4),
      ToolCall('t2', 'Agent', {'description': 'List every endpoint and its fields'}, seq: 5),
      SubagentStarted('task1', 't2', 'List every endpoint and its fields', 'general-purpose', seq: 6),
      ToolCall('t3', 'Grep', {'pattern': 'Route\\('}, seq: 7, parentToolUseId: 't2'),
      AssistantText('Found **4 resources**: invoices, exports, customers and plans.', seq: 8, parentToolUseId: 't2'),
      SubagentFinished('task1', 'completed', seq: 9),
      AssistantText('The first page, `invoices.md`:\n\n```markdown\n# Invoices\n\nGET /invoices lists the account\'s invoices,\nnewest first.\n```\n\nNext I write **exports** and link the pages from the index.',
          seq: 10),
      Notice('Message sent from Perch', seq: 11),
      UserMessage('Keep the examples in curl, please.', seq: 12),
      AssistantText('Will do: every example is a `curl` call with the test key.', seq: 13),
    ];

List<ConversationEvent> _billingEvents() => [
      UserMessage("Split the CSV export into a streaming writer so big months don't time out.", seq: 1),
      AssistantText("I'll stream rows instead of building the whole file in memory. The core of it:\n\n"
          '```dart\nStream<List<int>> exportRows(Query q) async* {\n  yield utf8.encode(header);\n  await for (final row in q.stream()) {\n    yield utf8.encode(row.toCsv());\n  }\n}\n```',
          seq: 2),
      ToolCall('b1', 'Bash', {'command': 'dart test test/export_test.dart'}, seq: 3),
      ToolResult('b1', '00:02 +6: All tests passed!', seq: 4),
      AssistantText('Before I touch the admin page, two questions.', seq: 5),
    ];

const _question = PromptRequest(promptId: 'q1', kind: PromptKind.question, toolName: 'AskUserQuestion', input: {
  'questions': [
    {
      'question': 'What should happen to the old admin export page?',
      'header': 'Admin page',
      'multiSelect': false,
      'options': [
        {'label': 'Stream it too', 'description': 'Use the new writer there as well'},
        {'label': 'Remove it', 'description': 'It had no visits in the last 90 days'},
        {'label': 'Leave it', 'description': 'Keep the in-memory version for now'},
      ],
    },
    {
      'question': 'Which formats should the streaming writer support?',
      'header': 'Formats',
      'multiSelect': true,
      'options': [
        {'label': 'CSV', 'description': ''},
        {'label': 'TSV', 'description': ''},
      ],
    },
  ]
});

const _permission = PromptRequest(
  promptId: 'p1',
  kind: PromptKind.permission,
  toolName: 'Bash',
  input: {'command': 'flutter test test/upload_test.dart --repeat 20', 'description': 'Run the upload test 20 times'},
  suggestions: [
    {'type': 'addRules', 'behavior': 'allow'}
  ],
);

const _plan = PromptRequest(promptId: 'pl1', kind: PromptKind.plan, toolName: 'ExitPlanMode', input: {
  'plan': '## Dark mode for settings\n\n1. Add a `ThemeMode` setting stored with the other preferences.\n'
      '2. Read it in `SettingsStore` and rebuild the app theme.\n3. Add a three-way switch: System, Light, Dark.\n'
      '4. Test that the choice survives a restart.'
});

const _trust = PromptRequest(
    promptId: 'trust:s-new', kind: PromptKind.permission, toolName: 'TrustFolder', input: {'path': r'D:\demo\new-site'});

const _projects = ProjectList(updatedAtMs: 5, projects: [
  Project(id: 'p-billing', name: 'Billing API', folders: {'m-studio': r'D:\demo\billing-api', 'm-mac': '/Users/demo/billing-api'}),
  Project(id: 'p-photo', name: 'Photo app', folders: {'m-studio': r'D:\demo\photo-app'}),
  Project(id: 'p-site', name: 'Website', folders: {'m-mac': '/Users/demo/site'}),
]);

List<BoardTask> _studioTasks() => [
      BoardTask(
          id: 't-export',
          title: 'Stream the CSV export',
          description: 'Big months time out: write rows as they are read instead of building the file in memory.',
          cwd: r'D:\demo\billing-api',
          projectId: 'p-billing',
          acceptance: const ['A 2 GB month exports without a timeout', 'The existing export tests pass', 'Memory stays under 200 MB'],
          taskType: 'feature',
          priority: TaskPriority.high,
          column: TaskColumn.review,
          sessionId: 's-billing',
          sessionName: 'Stream the CSV export',
          createdAtMs: 1,
          report: const TaskReport(
            text: '## Report\n- Rows are written as they are read (`exportRows`).\n- Tested with a generated 2 GB month.\n\n'
                '- [x] A 2 GB month exports without a timeout\n- [x] The existing export tests pass\n- [ ] Memory stays under 200 MB (peaks at 260 MB)',
            criteria: [
              CriterionCheck('A 2 GB month exports without a timeout', met: true),
              CriterionCheck('The existing export tests pass', met: true),
              CriterionCheck('Memory stays under 200 MB', met: false),
            ],
            todos: [TodoItem('Write the streaming writer', done: true), TodoItem('Profile memory', done: false)],
            files: [r'D:\demo\billing-api\lib\export.dart', r'D:\demo\billing-api\test\export_test.dart'],
            changes: [' lib/export.dart       | 48 ++++++++++++------', ' test/export_test.dart | 12 ++++', ' 2 files changed, 44 insertions(+), 16 deletions(-)'],
            atMs: 2,
          )),
      const BoardTask(
          id: 't-dark',
          title: 'Dark mode for settings',
          cwd: r'D:\demo\photo-app',
          projectId: 'p-photo',
          taskType: 'feature',
          column: TaskColumn.backlog,
          createdAtMs: 2),
      const BoardTask(
          id: 't-flaky',
          title: 'Fix the flaky upload test',
          cwd: r'D:\demo\photo-app',
          projectId: 'p-photo',
          taskType: 'bugfix',
          priority: TaskPriority.high,
          column: TaskColumn.backlog,
          createdAtMs: 3),
      const BoardTask(
          id: 't-docs',
          title: 'Write the API docs',
          cwd: r'D:\demo\billing-api',
          projectId: 'p-billing',
          taskType: 'tests',
          column: TaskColumn.backlog,
          createdAtMs: 4),
    ];

List<ConversationEvent> _commandEvents() => [
      UserMessage('How full is the context now?', seq: 1),
      AssistantText('Run /context and I can tell you what takes the room.', seq: 2),
      SlashCommand('/context', '', seq: 3),
      CommandOutput(
          '## Context Usage\n\n**Model:** claude-sonnet · 41k / 200k tokens (21%)\n\n| Category | Tokens | Share |\n|---|---|---|\n'
          '| System prompt | 3.1k | 1.6% |\n| Tools | 12.4k | 6.2% |\n| Messages | 25.5k | 12.8% |\n| Free space | 159k | 79.4% |',
          seq: 4),
      SlashCommand('/model', 'haiku', seq: 5),
      CommandOutput('Set model to haiku', seq: 6),
    ];

void main() {
  final boundary = GlobalKey();
  final nav = GlobalKey<NavigatorState>();

  setUpAll(() async {
    if (_out == null) return;
    Directory(_out!).createSync(recursive: true);
    await _loadFonts();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 600));
    }
  }

  testWidgets('screenshots', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    tester.view.padding = const FakeViewPadding(top: 110, bottom: 60);
    tester.view.viewPadding = const FakeViewPadding(top: 110, bottom: 60);
    addTearDown(tester.view.reset);
    GlassTheme.reset();

    SharedPreferences.setMockInitialValues({
      MachineStore.key: jsonEncode([
        testMachine(id: 'm-studio', label: 'Studio PC', lan: const ['10.0.0.1:8787']).toJson(),
        testMachine(id: 'm-mac', label: 'MacBook Air', lan: const [], relayUrl: 'https://relay.example').toJson(),
      ])
    });
    final prefs = SessionPrefs(persist: false);
    await prefs.pin('m-studio', 's-release');
    await prefs.mute('m-studio', 's-cache');
    final channels = FakeChannels();

    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: ProviderScope(
        overrides: [
          channelFactoryProvider.overrideWithValue(channels.factory),
          sessionPrefsProvider.overrideWithValue(prefs),
          qrScannerProvider.overrideWithValue(_fakeCamera),
        ],
        child: MaterialApp(
          navigatorKey: nav,
          debugShowCheckedModeBanner: false,
          theme: perchTheme(),
          builder: glassAppBuilder,
          home: const HomeScreen(),
        ),
      ),
    ));
    await tester.runAsync(() => pump(80));
    await tester.pumpAndSettle();
    await tester.runAsync(() => eventually(() => channels.hosts.length >= 2));
    final studio = channels.lastTo('ws://10.0.0.1');
    final mac = channels.lastTo('wss://');
    studio.send(const Welcome(machineName: 'Studio PC', os: 'windows', hostVersion: '0.3.0', compatibility: _untested));
    studio.send(Sessions(sessions: _studio, usage: _usage(0.42, 0.18)));
    mac.send(const Welcome(
        machineName: 'MacBook Air',
        os: 'macos',
        hostVersion: '0.3.0',
        relayUrl: 'https://relay.example',
        compatibility: Compatibility(status: CompatibilityStatus.ok, claudeVersion: '2.1.325')));
    mac.send(Sessions(sessions: _mac, usage: _usage(0.12, 0.31)));
    await tester.runAsync(() => pump(80));
    await tester.pumpAndSettle();

    var prefix = '';
    Future<void> shot(String name) async {
      await settle(tester);
      final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await ro.toImage(pixelRatio: 2.625);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$_out/$prefix$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    Future<void> back() async {
      nav.currentState!.pop();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    }

    HostConnection conn(String id) =>
        ProviderScope.containerOf(tester.element(find.byType(HomeScreen, skipOffstage: false)), listen: false).read(connectionsProvider).byId(id)!;
    BuildContext top<T>() => tester.element(find.byType(T).last);

    Future<void> session(String id, FakeHostSide host, List<ConversationEvent> events, List<PromptRequest> prompts,
        String name) async {
      nav.currentState!.push(glassRoute<void>(SessionScreen(connection: conn(host == studio ? 'm-studio' : 'm-mac'), sessionId: id)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => pump(60));
      host.send(Events(sessionId: id, events: events, openPrompts: prompts));
      await tester.runAsync(() => pump(60));
      await tester.pumpAndSettle();
      await shot(name);
      await back();
    }

    for (final mode in [GlassMode.light, GlassMode.dark]) {
      GlassTheme.mode.value = mode;
      prefix = mode == GlassMode.dark ? 'dark-' : 'light-';
      await tester.pumpAndSettle();

      await shot('home');
      await tester.drag(find.byKey(const ValueKey('home-list')), const Offset(0, -700));
      await tester.pumpAndSettle();
      await shot('home-waiting');
      await tester.drag(find.byKey(const ValueKey('home-list')), const Offset(0, 700));
      await tester.pumpAndSettle();

      unawaitedSheet(showMachineMenu(top<HomeScreen>(), conn('m-studio')));
      await shot('machine-menu');
      await back();

      unawaitedSheet(showMachineRenameSheet(top<HomeScreen>(), current: 'Studio PC', own: 'Studio PC', hasAlias: false));
      await shot('rename-machine');
      await back();

      nav.currentState!.push(glassRoute<void>(const AddMachineScreen()));
      await shot('add-machine');
      await back();

      nav.currentState!.push(glassRoute<void>(SessionsScreen(connection: conn('m-studio'))));
      await shot('sessions');
      unawaitedSheet(showSessionMenu(top<SessionsScreen>(),
          connection: conn('m-studio'), session: _studio.firstWhere((s) => s.id == 's-docs'), prefs: prefs));
      await shot('session-menu');
      await back();
      unawaitedSheet(confirmStopAll(top<SessionsScreen>(), count: 4, where: 'Studio PC'));
      await shot('stop-all');
      await back();
      say(top<SessionsScreen>(), 'Hidden until it runs again', action: 'Undo', onAction: () {});
      await shot('note');
      ScaffoldMessenger.of(top<SessionsScreen>()).hideCurrentSnackBar();
      await tester.pumpAndSettle();
      unawaitedSheet(showNewSessionSheet(top<SessionsScreen>(), conn('m-studio'), folder: r'D:\demo\billing-api'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => pump(60));
      studio.send(const DirListing(
        path: r'D:\demo\billing-api',
        parent: r'D:\demo',
        entries: [
          DirEntry(name: 'docs', path: r'D:\demo\billing-api\docs'),
          DirEntry(name: 'lib', path: r'D:\demo\billing-api\lib'),
          DirEntry(name: 'test', path: r'D:\demo\billing-api\test'),
        ],
        suggested: [
          DirEntry(name: 'photo-app', path: r'D:\demo\photo-app'),
          DirEntry(name: 'Home', path: r'C:\Users\demo'),
        ],
      ));
      await tester.runAsync(() => pump(60));
      await tester.pumpAndSettle();
      await shot('new-session');
      await back();
      await back();

      nav.currentState!.push(glassRoute<void>(SessionsScreen(connection: conn('m-mac'))));
      await shot('sessions-relay');
      await back();

      await session('s-docs', studio, _docsEvents(), const [], 'conversation');
      await session('s-billing', studio, _billingEvents(), const [_question], 'question');
      await session('s-upload', studio, _billingEvents().take(2).toList(), const [_permission], 'permission');
      await session('s-dark', studio, _billingEvents().take(1).toList(), const [_plan], 'plan');

      // A terminal session waiting with no card: the banner.
      mac.send(SessionUpdated(
          session: _mac.last.copyWith(state: SessionState.waitingPermission, openPrompts: 0)));
      await tester.runAsync(() => pump(60));
      await session('m-router', mac, _billingEvents().take(2).toList(), const [], 'terminal-waiting');
      mac.send(SessionUpdated(session: _mac.last));
      studio.send(SessionUpdated(
          session: _s('s-new', 'New site', r'D:\demo\new-site', SessionState.blocked,
              origin: SessionOrigin.external, open: 1, startedMin: 1)));
      await tester.runAsync(() => pump(60));
      await session('s-new', studio, const [], const [_trust], 'trust');

      nav.currentState!.push(glassRoute<void>(CompatibilityScreen(connection: conn('m-studio'))));
      await shot('checks');
      await back();

      // The menu, the board with projects, a task, the projects and the destructive confirmations.
      unawaitedSheet(showAppMenu(top<HomeScreen>()));
      await shot('menu');
      await back();
      final store = ProviderScope.containerOf(tester.element(find.byType(HomeScreen, skipOffstage: false)), listen: false)
          .read(boardStoreProvider);
      await tester.runAsync(() => store.setProjects(_projects));
      studio.send(ProjectsMessage(projects: _projects));
      studio.send(TasksMessage(tasks: _studioTasks()));
      studio.send(ModelTableMessage(table: ModelTable.starting));
      mac.send(ProjectsMessage(projects: _projects));
      mac.send(TasksMessage(tasks: [
        const BoardTask(id: 't-hero', title: 'New hero section', cwd: '/Users/demo/site', projectId: 'p-site', column: TaskColumn.ready),
      ]));
      mac.send(ModelTableMessage(table: ModelTable.starting));
      await tester.runAsync(() => pump(80));
      nav.currentState!.push(glassRoute<void>(const BoardScreen()));
      await shot('board');
      await tester.tap(find.byKey(const ValueKey('chip-review')));
      await tester.pumpAndSettle();
      await shot('board-review');
      final review = _studioTasks().first;
      unawaitedSheet(showTaskEditor(top<BoardScreen>(),
          all: [conn('m-studio'), conn('m-mac')], store: store, editing: BoardItem(review.copyWith(machineId: 'm-studio'), conn('m-studio'))));
      await shot('task-editor');
      await back();
      nav.currentState!.push(glassRoute<void>(
          TaskDetailScreen(taskId: review.id, all: [conn('m-studio'), conn('m-mac')], store: store)));
      await shot('task-detail');
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -900));
      await tester.pumpAndSettle();
      await shot('task-detail-report');
      await back();
      await back();
      nav.currentState!.push(glassRoute<void>(const ProjectsScreen()));
      await shot('projects');
      await back();
      await session('s-cmd', studio, _commandEvents(), const [], 'commands');
      // The composer's / list.
      nav.currentState!.push(glassRoute<void>(SessionScreen(connection: conn('m-studio'), sessionId: 's-docs')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => pump(60));
      studio.send(Events(sessionId: 's-docs', events: _docsEvents()));
      await tester.runAsync(() => pump(60));
      await tester.pumpAndSettle();
      await tester.enterText(find.descendant(of: find.byKey(const ValueKey('composer')), matching: find.byType(TextField)), '/co');
      await tester.runAsync(() => pump(60));
      studio.send(const CommandsMessage(sessionId: 's-docs', commands: [
        SlashCommandInfo(name: '/compact', description: 'Free up context by summarizing the conversation so far'),
        SlashCommandInfo(name: '/config', description: 'Open settings'),
        SlashCommandInfo(name: '/context', description: 'Visualize current context usage as a colored grid', argumentHint: '[all]'),
        SlashCommandInfo(name: '/code-review', description: 'Review the current diff for correctness bugs'),
        SlashCommandInfo(name: '/copy-docs', description: 'Copy the API docs to the site', source: 'project'),
      ]));
      await tester.runAsync(() => pump(60));
      await tester.pumpAndSettle();
      await shot('command-list');
      // The composer's @ list.
      await tester.enterText(find.descendant(of: find.byKey(const ValueKey('composer')), matching: find.byType(TextField)), 'Summarise @do');
      await tester.runAsync(() => pump(60));
      studio.send(const FilesMessage(sessionId: 's-docs', query: 'do', files: [
        FileMention(path: 'docs', dir: true),
        FileMention(path: 'docs/api.md'),
        FileMention(path: 'docs/getting-started.md'),
        FileMention(path: 'src/docs_builder.dart'),
      ]));
      await tester.runAsync(() => pump(60));
      await tester.pumpAndSettle();
      await shot('mention-list');
      await tester.enterText(find.descendant(of: find.byKey(const ValueKey('composer')), matching: find.byType(TextField)), '');
      await tester.pumpAndSettle();
      // The end of the conversation over Android's three-button bar.
      tester.view.padding = const FakeViewPadding(top: 110, bottom: 126);
      tester.view.viewPadding = const FakeViewPadding(top: 110, bottom: 126);
      await tester.pumpAndSettle();
      await shot('conversation-button-bar');
      tester.view.padding = const FakeViewPadding(top: 110, bottom: 60);
      tester.view.viewPadding = const FakeViewPadding(top: 110, bottom: 60);
      await tester.pumpAndSettle();
      await back();
      nav.currentState!.push(glassRoute<void>(ModelTableScreen(store: store)));
      await shot('models');
      await back();

      mac.send(const CompatibilityMessage(compatibility: _drifted));
      await tester.runAsync(() => pump(60));
      await tester.pumpAndSettle();
      await shot('drift');
      // A usage limit: the card on the machine's page, then usage is back.
      UsageLimit limit({bool back = false}) => UsageLimit(
            resetsAtMs: DateTime.now().add(const Duration(hours: 1, minutes: 42)).millisecondsSinceEpoch,
            window: LimitWindows.fiveHour,
            back: back,
            sessions: const [
              LimitedSession(id: 's-docs', name: 'Write API docs', claudeWaiting: true),
              LimitedSession(
                  id: 's-billing', name: 'Refactor billing export', claudeWaiting: false, override: LimitChoices.wait),
            ],
          );
      studio.send(UsageLimitMessage(limit: limit()));
      await tester.runAsync(() => pump(60));
      nav.currentState!.push(glassRoute<void>(SessionsScreen(connection: conn('m-studio'))));
      await shot('usage-limit');
      studio.send(UsageLimitMessage(limit: limit(back: true)));
      await tester.runAsync(() => pump(60));
      await shot('usage-back');
      await back();
      await shot('home-limit');
      studio.send(const UsageLimitMessage());
      await tester.runAsync(() => pump(60));
      // Resumed without the subagent: the toast over the conversation, and its lasting note.
      nav.currentState!.push(glassRoute<void>(SessionScreen(connection: conn('m-studio'), sessionId: 's-docs')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => pump(60));
      studio.send(Events(sessionId: 's-docs', events: [
        ..._docsEvents(),
        Notice('Resumed without the subagent', seq: 90, atMs: DateTime.now().millisecondsSinceEpoch),
        ToolCall('t9', 'Write', {'file_path': r'D:\demoilling-api\docs\exports.md'}, seq: 91),
      ]));
      await tester.runAsync(() => pump(60));
      await tester.pumpAndSettle();
      showResumedToast(nav.currentState!.overlay!,
          text: resumedToastText('Write API docs', 'Resumed without the subagent'), onStop: () {}, onOpen: () {});
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 4));
      await shot('resumed-toast');
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      await back();

      mac.send(const CompatibilityMessage(compatibility: Compatibility(status: CompatibilityStatus.ok)));
      studio.send(Sessions(sessions: _studio, usage: _usage(0.42, 0.18)));
      await tester.runAsync(() => pump(60));
      await tester.pumpAndSettle();
    }

    // The bird: its flap and its wink, on the first screen (light).
    GlassTheme.mode.value = GlassMode.light;
    prefix = '';
    // The intro's moments: the first frame (empty), flying in, sitting on the branch with the
    // name, taking off.
    for (final (i, t) in [0.0, 0.10, 0.5, 0.68].indexed) {
      nav.currentState!.push(PageRouteBuilder<void>(pageBuilder: (_, _, _) => IntroFrame(t: t), transitionDuration: Duration.zero));
      await tester.pumpAndSettle();
      await shot('intro-${i + 1}');
      nav.currentState!.pop();
      await tester.pumpAndSettle();
    }

    for (final (i, pose) in [0, 2, 4, 3].indexed) {
      debugFlapPose.value = pose;
      await shot('flap-${i + 1}');
    }
    debugFlapPose.value = null;
    for (final (i, eye) in [eyeOpen, eyeHalf, eyeShut].indexed) {
      debugEyePose.value = eye;
      await shot('wink-${i + 1}');
    }
    debugEyePose.value = null;
    GlassTheme.reset();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }, skip: _out == null);
}

/// Sheets open while the screenshot is taken; their result is not needed.
void unawaitedSheet(Future<Object?> f) {}
