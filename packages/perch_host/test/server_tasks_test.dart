// The task board over the wire: tasks and the model table on connect, a change reaching
// every device, Run with the model table's model, the model table sync (newer wins),
// git remotes, switching a session's model, and the board's web page served on loopback
// only (with the machine's pairing for the page, never to another address or site).
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/host_state.dart';
import 'package:perch_host/src/host_board.dart';
import 'package:perch_host/src/server.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/task_board.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'server_accounts_test.dart' show Phone;

final sep = Platform.pathSeparator;

void main() {
  late Directory tmp;
  late HostState state;
  late SessionManager manager;
  late TaskBoard board;
  late PerchServer server;
  late int port;
  late String argsFile;
  late Directory web;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('perch_srv_tasks_');
    state = HostState.load('${tmp.path}${sep}state');
    argsFile = '${tmp.path}${sep}args.txt';
    manager = SessionManager(launcher: fakeLauncher(env: {'FAKE_CLAUDE_ARGS_FILE': argsFile}), external: FakeExternalSessions());
    board = TaskBoard(
        board: HostBoard(stateDir: state.directory, machineId: state.machineId, remoteOf: (_) => null),
        sessions: ManagerTaskSessions(manager),
        modelTable: () => state.models,
        settle: const Duration(milliseconds: 100),
        poll: const Duration(milliseconds: 100))
      ..start();
    web = Directory('${tmp.path}${sep}web')..createSync();
    File('${web.path}${sep}index.html').writeAsStringSync('<html><title>Perch</title></html>');
    File('${web.path}${sep}main.dart.js').writeAsStringSync('console.log(1)');
    server = PerchServer(
        manager: manager, state: state, machineName: 'Desk', bindAddress: '0.0.0.0', port: 0, board: board, boardDir: web.path);
    port = await server.start();
  });

  tearDown(() async {
    await server.close();
    await board.dispose();
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Phone> phone() async {
    final p = Phone(server, state);
    await p.hello();
    return p;
  }

  BoardTask task(String title, {String? type}) =>
      BoardTask(id: 'id-$title', title: title, cwd: tmp.path, taskType: type, column: TaskColumn.ready);

  test('tasks_and_the_model_table_arrive_on_connect_and_changes_reach_every_device', () async {
    final a = await phone();
    final b = await phone();
    expect((await a.next<TasksMessage>()).tasks, isEmpty);
    expect((await a.next<ModelTableMessage>()).table.rows, hasLength(7));
    final from = b.received.length;
    a.send(SaveTask(task: task('Add footer')));
    final seen = await b.next<TasksMessage>(where: (m) => m.tasks.isNotEmpty, from: from);
    expect(seen.tasks.single.title, 'Add footer');
    a.send(const MoveTask(taskId: 'id-Add footer', column: TaskColumn.done));
    await b.next<TasksMessage>(where: (m) => m.tasks.any((t) => t.column == TaskColumn.done), from: from);
    a.send(const DeleteTask(taskId: 'id-Add footer'));
    await b.next<TasksMessage>(where: (m) => m.tasks.isEmpty, from: b.received.length - 1);
    // A bad task is answered with an error.
    a.send(SaveTask(task: task('x').copyWith(cwd: '${tmp.path}${sep}missing')));
    expect((await a.next<ErrorMessage>()).message, contains('does not exist'));
  });

  test('run_uses_the_model_table_and_the_card_reaches_review', () async {
    final a = await phone();
    final table = ModelTable.starting.withRow(ModelTable.starting.row('chores')!.copyWith(model: 'haiku'), atMs: 50);
    a.send(SyncModelTable(table: table));
    await a.next<ModelTableMessage>(where: (m) => m.table.updatedAtMs == 50);
    expect(HostState.load(state.directory).models.modelFor('chores'), 'haiku', reason: 'saved in host.json');
    a.send(SaveTask(task: task('Tidy', type: 'chores')));
    await a.next<TasksMessage>(where: (m) => m.tasks.isNotEmpty);
    a.send(const RunTask(taskId: 'id-Tidy'));
    final done = await a.next<TasksMessage>(where: (m) => m.tasks.any((t) => t.column == TaskColumn.review));
    expect(done.tasks.single.report!.text, startsWith('echo: Tidy'));
    expect(File(argsFile).readAsLinesSync(), containsAllInOrder(['--model', 'haiku']));
  });

  test('projects_arrive_on_connect_are_kept_and_the_newer_list_wins', () async {
    final a = await phone();
    expect((await a.next<ProjectsMessage>()).projects.projects, isEmpty);
    final b = await phone();
    await b.next<ProjectsMessage>();
    final list = const ProjectList()
        .withProject(Project(id: 'p1', name: 'Perch', folders: {state.machineId: tmp.path}), atMs: 50);
    final from = b.received.length;
    a.send(SyncProjects(projects: list));
    final seen = await b.next<ProjectsMessage>(where: (m) => m.projects.updatedAtMs == 50, from: from);
    expect(seen.projects.byId('p1')!.name, 'Perch');
    expect(HostState.load(state.directory).projects.byId('p1')!.folderOn(state.machineId), tmp.path,
        reason: 'saved in host.json');
    final at = a.received.length;
    a.send(SyncProjects(projects: const ProjectList(updatedAtMs: 10)));
    final answer = await a.next<ProjectsMessage>(from: at);
    expect(answer.projects.updatedAtMs, 50, reason: 'an older list does not replace a newer one');
  });

  test('an_older_model_table_does_not_replace_a_newer_one', () async {
    final a = await phone();
    final newer = ModelTable.starting.withRow(ModelTable.starting.row('review')!.copyWith(model: 'opus'), atMs: 200);
    a.send(SyncModelTable(table: newer));
    await a.next<ModelTableMessage>(where: (m) => m.table.updatedAtMs == 200);
    final from = a.received.length;
    a.send(SyncModelTable(table: ModelTable.starting.withRow(ModelTable.starting.row('review')!, atMs: 100)));
    final answer = await a.next<ModelTableMessage>(from: from);
    expect(answer.table.updatedAtMs, 200);
    expect(state.models.modelFor('review'), 'opus');
  });

  test('git_remotes_of_known_folders', () async {
    final a = await phone();
    a.send(const ListGitRemotes());
    expect((await a.next<GitRemotesMessage>()).folders, isA<List<GitFolder>>());
  });

  test('set_session_model_is_answered', () async {
    final a = await phone();
    final s = await manager.start(cwd: tmp.path, prompt: 'echo hi');
    await waitUntil(() => manager.summaryOf(s.id)!.state == SessionState.idle);
    a.send(SetSessionModel(sessionId: s.id, model: 'sonnet'));
    final d = await a.next<SessionActionDone>(where: (d) => d.action == SessionActions.model);
    expect(d.message, 'Model: sonnet');
  });

  test('the_files_of_a_session_folder_are_listed_for_at_mentions', () async {
    final a = await phone();
    final s = await manager.start(cwd: tmp.path, prompt: 'echo hi');
    File('${tmp.path}${sep}notes.txt').writeAsStringSync('n');
    Directory('${tmp.path}${sep}docs').createSync();
    File('${tmp.path}${sep}docs${sep}plan.md').writeAsStringSync('p');
    a.send(ListFiles(sessionId: s.id, query: 'note'));
    final m = await a.next<FilesMessage>();
    expect(m.sessionId, s.id);
    expect(m.query, 'note');
    expect(m.files.first.path, 'notes.txt');
    a.send(ListFiles(sessionId: s.id, query: 'docs/'));
    final d = await a.next<FilesMessage>(where: (m) => m.query == 'docs/');
    expect(d.files.map((f) => f.path), contains('docs/plan.md'));
    a.send(const ListFiles(sessionId: 'nope', query: ''));
    final none = await a.next<FilesMessage>(where: (m) => m.sessionId == 'nope');
    expect(none.files, isEmpty);
  });

  test('the_slash_commands_of_a_session_folder_are_listed', () async {
    final a = await phone();
    final s = await manager.start(cwd: tmp.path, prompt: 'echo hi');
    Directory('${tmp.path}$sep.claude${sep}commands').createSync(recursive: true);
    File('${tmp.path}$sep.claude${sep}commands${sep}ship.md').writeAsStringSync('---\ndescription: Ship it\n---\n');
    a.send(ListCommands(sessionId: s.id));
    final m = await a.next<CommandsMessage>();
    expect(m.sessionId, s.id);
    expect(m.commands.map((c) => c.name), containsAll(['/context', '/ship']));
    expect(m.commands.firstWhere((c) => c.name == '/ship').source, 'project');
  });

  group('board page', () {
    Future<({int status, String body, Map<String, String> headers})> get(String host, String path,
        {String? hostHeader, String? origin}) async {
      final c = HttpClient();
      try {
        final req = await c.get(host, port, path);
        if (hostHeader != null) req.headers.host = hostHeader;
        if (origin != null) req.headers.set('origin', origin);
        final res = await req.close();
        final headers = <String, String>{};
        res.headers.forEach((k, v) => headers[k] = v.join(','));
        return (status: res.statusCode, body: await res.transform(utf8.decoder).join(), headers: headers);
      } finally {
        c.close(force: true);
      }
    }

    test('loopback_gets_the_page_and_its_files_with_types', () async {
      final r = await get('127.0.0.1', '/');
      expect(r.status, 200);
      expect(r.body, contains('<title>Perch</title>'));
      expect(r.headers['content-type'], contains('text/html'));
      final js = await get('localhost', '/main.dart.js');
      expect(js.status, 200);
      expect(js.headers['content-type'], contains('javascript'));
      expect((await get('127.0.0.1', '/nope.js')).status, 404);
      expect((await get('127.0.0.1', '/../state/host.json')).status, anyOf(400, 403, 404));
    });

    test('the_page_learns_the_pairing_from_loopback_only', () async {
      final r = await get('127.0.0.1', '/local/pairing', hostHeader: 'localhost');
      expect(r.status, 200);
      expect(r.headers['cache-control'], contains('no-store'));
      final j = jsonDecode(r.body) as Map;
      expect(j['machineId'], state.machineId);
      expect(j['name'], 'Desk');
      expect(base64UrlDecodeNoPad(j['secret'] as String), state.secret);
      // Another site's page (a DNS name pointing here, or a cross-site request) gets nothing.
      expect((await get('127.0.0.1', '/local/pairing', hostHeader: 'evil.example')).status, 403);
      expect((await get('127.0.0.1', '/local/pairing', origin: 'https://evil.example')).status, 403);
      expect((await get('127.0.0.1', '/local/pairing', origin: 'http://localhost:$port')).status, 200);
      expect((await get('127.0.0.1', '/', hostHeader: 'evil.example')).status, 403);
    });

    test('another_address_gets_neither_the_page_nor_the_pairing', () async {
      expect(PerchServer.localPageAllowed(InternetAddress('192.168.1.20'), Uri.parse('http://localhost:1/'), null), isFalse);
      expect(PerchServer.localPageAllowed(InternetAddress.loopbackIPv4, Uri.parse('http://localhost:1/'), null), isTrue);
      expect(PerchServer.localPageAllowed(InternetAddress.loopbackIPv6, Uri.parse('http://[::1]:1/'), null), isTrue);
      final addresses = [
        for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
          for (final a in i.addresses)
            if (!a.isLoopback) a.address
      ];
      if (addresses.isEmpty) return;
      expect((await get(addresses.first, '/')).status, 403);
      expect((await get(addresses.first, '/local/pairing')).status, 403);
    });

    test('without_a_built_page_it_says_how_to_build_it', () async {
      web.deleteSync(recursive: true);
      final r = await get('127.0.0.1', '/');
      expect(r.status, 200);
      expect(r.body, contains('flutter build web'));
    });
  });
}
