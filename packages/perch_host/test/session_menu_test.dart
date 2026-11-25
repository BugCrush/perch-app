// Rename, delete and resume from the phone's session menu, and sessions that ended while
// the host ran. Never touches a real Claude Code folder: everything lives in a temp dir.
import 'dart:convert';
import 'dart:io';

import 'package:perch_host/src/external_sessions.dart';
import 'package:perch_host/src/session_manager.dart';
import 'package:perch_host/src/terminal_window.dart';
import 'package:perch_host/src/transcript.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final sep = Platform.pathSeparator;

String screen(String name) => File('test${sep}fixtures${sep}screens$sep$name').readAsStringSync();

const cid = 'aaaaaaaa-0000-4000-8000-000000000001';
const otherId = 'bbbbbbbb-0000-4000-8000-000000000002';

void main() {
  late Directory tmp;
  late Directory work;
  late String config;
  late FakeExternalSessions external;
  late FakeConsoleTyper console;
  late List<TerminalLaunch> launches;
  late SessionManager manager;
  late void Function(TerminalLaunch) onLaunch;

  /// Writes a transcript (and a sibling folder) for [id] in a project folder.
  File transcript(String id, {String folder = '-w-proj', List<Map<String, dynamic>> extra = const []}) {
    final dir = Directory('$config${sep}projects$sep$folder')..createSync(recursive: true);
    final f = File('${dir.path}$sep$id.jsonl');
    f.writeAsStringSync([
      jsonEncode({
        'type': 'user',
        'message': {'role': 'user', 'content': 'Say hi'},
        'timestamp': '2026-11-14T10:00:00.000Z'
      }),
      jsonEncode({
        'type': 'assistant',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'Hi'}
          ]
        },
        'timestamp': '2026-11-14T10:00:01.000Z'
      }),
      jsonEncode({'type': 'ai-title', 'aiTitle': 'Greeting', 'sessionId': id}),
      for (final e in extra) jsonEncode(e),
    ].join('\n'));
    Directory('${dir.path}$sep$id${sep}subagents').createSync(recursive: true);
    return f;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('perch_menu_');
    work = Directory('${tmp.path}${sep}work')..createSync();
    config = '${tmp.path}${sep}config';
    external = FakeExternalSessions();
    console = FakeConsoleTyper(currentScreen: screen('idle_after_deny.txt'));
    launches = [];
    onLaunch = (l) => external.entries.add(external.entry(pid: 9999, sessionId: cid, cwd: work.path));
    manager = SessionManager(
      launcher: fakeLauncher(),
      external: external,
      typer: console,
      claudeConfigDir: config,
      openWindow: (l) async {
        launches.add(l);
        onLaunch(l);
      },
      terminalStartTimeout: const Duration(milliseconds: 600),
      terminalPoll: const Duration(milliseconds: 20),
    )..endTimeout = const Duration(milliseconds: 500);
  });

  tearDown(() async {
    await manager.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A terminal session that was listed, then ended (Claude Code stops listing it).
  Future<SessionSummary> endedSession() async {
    transcript(cid);
    external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
    await manager.list();
    external.entries = [];
    final listed = await manager.list();
    return listed.single;
  }

  group('sessions that ended', () {
    test('stay listed as not running, then go when they run again', () async {
      final s = await endedSession();
      expect(s.id, cid);
      expect(s.live, isFalse);
      expect(s.state, SessionState.stopped);
      expect(s.name, 'Greeting');

      external.entries = [external.entry(pid: 5000, sessionId: cid, cwd: work.path)];
      final again = await manager.list();
      expect(again.single.live, isTrue);
    });

    test('their conversation can still be read', () async {
      await endedSession();
      final h = manager.history(cid, paged: true);
      expect(h.events.whereType<UserMessage>().single.text, 'Say hi');
      expect(h.openPrompts, isEmpty);
    });

    test('at most maxEnded are kept', () async {
      for (var i = 0; i < SessionManager.maxEnded + 3; i++) {
        final id = 'cccccccc-0000-4000-8000-${i.toString().padLeft(12, '0')}';
        external.entries = [external.entry(pid: 100 + i, sessionId: id, cwd: work.path)];
        await manager.list();
      }
      external.entries = [];
      expect(await manager.list(), hasLength(SessionManager.maxEnded));
    });
  });

  group('rename', () {
    test('a session that is not running gets what Claude Code itself writes', () async {
      await endedSession();
      final f = findTranscript(cid, configDir: config)!;
      expect(await manager.rename(cid, '  Login   fix '), 'Login fix');
      final lines = f.readAsLinesSync();
      expect(jsonDecode(lines[lines.length - 2]), {'type': 'custom-title', 'customTitle': 'Login fix', 'sessionId': cid});
      expect(jsonDecode(lines.last), {'type': 'agent-name', 'agentName': 'Login fix', 'sessionId': cid});
      expect(jsonDecode(File('${f.parent.path}$sep$cid${sep}custom-title.json').readAsStringSync()),
          {'customTitle': 'Login fix'});
      // Perch shows the new name (it wins over Claude's title).
      expect((await manager.list()).single.name, 'Login fix');
      expect(latestTitles(f).custom, 'Login fix');
    });

    test('a running session in a terminal Perch can type into gets /rename typed', () async {
      transcript(cid);
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      await manager.list();
      await manager.rename(cid, 'Login fix');
      expect(console.calls.single, (pid: 4242, text: '/rename Login fix'));
      // Nothing written to its files while it runs.
      expect(findTranscript(cid, configDir: config)!.readAsStringSync(), isNot(contains('custom-title')));
    });

    test('a running session that is busy or shows a dialog is not typed into', () async {
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      await manager.list();
      console.currentScreen = screen('question_single.txt');
      await expectLater(manager.rename(cid, 'X'), throwsA(isA<StateError>()));
      expect(console.calls, isEmpty);
    });

    test('a running session in a terminal Perch cannot type into is refused with how to do it', () async {
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      await manager.list();
      console.operable = false;
      await expectLater(
          manager.rename(cid, 'Login fix'),
          throwsA(isA<CannotType>().having((e) => e.message, 'message', contains('Type /rename Login fix there'))));
    });

    test('names are checked', () async {
      await endedSession();
      await expectLater(manager.rename(cid, '   '), throwsArgumentError);
      await expectLater(manager.rename(cid, 'x' * 101), throwsArgumentError);
      await expectLater(manager.rename('nope', 'x'), throwsA(isA<NoSuchSession>()));
    });

    test('a custom-title line wins over the ai-title in transcripts', () {
      final f = transcript(otherId, extra: [
        {'type': 'custom-title', 'customTitle': 'Mine', 'sessionId': otherId},
        {'type': 'ai-title', 'aiTitle': 'Later AI title', 'sessionId': otherId},
      ]);
      expect(latestTitles(f), (custom: 'Mine', ai: 'Later AI title'));
      expect(parseTranscriptLine(jsonEncode({'type': 'agent-name', 'agentName': 'A'})),
          isA<TranscriptTitle>().having((t) => t.custom, 'custom', isTrue));
    });
  });

  group('delete', () {
    test('removes exactly that session id, everywhere Claude Code keeps it', () async {
      await endedSession();
      transcript(cid, folder: '-w-old'); // a stale copy in another project folder
      final keep = transcript(otherId);
      for (final d in ['file-history', 'session-env', 'tasks']) {
        Directory('$config$sep$d$sep$cid').createSync(recursive: true);
        Directory('$config$sep$d$sep$otherId').createSync(recursive: true);
      }
      final n = await manager.delete(cid);
      expect(n, 7); // 2 transcripts, 2 folders beside them, 3 folders
      expect(findTranscript(cid, configDir: config), isNull);
      expect(Directory('$config${sep}projects$sep-w-proj$sep$cid').existsSync(), isFalse);
      for (final d in ['file-history', 'session-env', 'tasks']) {
        expect(Directory('$config$sep$d$sep$cid').existsSync(), isFalse);
        expect(Directory('$config$sep$d$sep$otherId').existsSync(), isTrue);
      }
      expect(keep.existsSync(), isTrue);
      expect(Directory('$config${sep}projects$sep-w-proj$sep$otherId').existsSync(), isTrue);
      expect(await manager.list(), isEmpty);
    });

    test('a running session is ended first', () async {
      transcript(cid);
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      await manager.list();
      await manager.delete(cid);
      expect(external.kills, [4242]);
      expect(findTranscript(cid, configDir: config), isNull);
      expect(await manager.list(), isEmpty);
    });

    test('a session first listed by its process finds its id in Claude Code\'s registry', () async {
      transcript(cid);
      external.entries = [ExternalSessions.unlistedEntry(4242, work.path)];
      final id = (await manager.list()).single.id;
      expect(id, 'pid:4242');
      await expectLater(manager.delete(id), throwsA(isA<StateError>()));
      expect(external.kills, isEmpty, reason: 'not ended while its id is unknown');

      Directory('$config${sep}sessions').createSync(recursive: true);
      File('$config${sep}sessions${sep}4242.json').writeAsStringSync(jsonEncode({'pid': 4242, 'sessionId': cid}));
      await manager.delete(id);
      expect(external.kills, [4242]);
      expect(findTranscript(cid, configDir: config), isNull);
    });

    test('nothing is deleted when the session does not end', () async {
      transcript(cid);
      external
        ..killRemoves = false
        ..entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      await manager.list();
      await expectLater(manager.delete(cid), throwsA(isA<StateError>()));
      expect(findTranscript(cid, configDir: config), isNotNull);
    });
  });

  group('resume', () {
    test('opens a terminal window running claude --resume <id> in its folder', () async {
      await endedSession();
      final s = await manager.resume(cid);
      final l = launches.single;
      expect(l.cwd, work.path);
      expect(l.args.skip(l.args.length - 2), ['--resume', cid]);
      expect(l.environment.keys, isNot(contains('CLAUDECODE')));
      expect(s.id, cid);
      expect(s.live, isTrue);
      final listed = await manager.list();
      expect(listed.single.live, isTrue);
    });

    test('a running session, a missing folder or no terminal is refused', () async {
      transcript(cid);
      external.entries = [external.entry(pid: 4242, sessionId: cid, cwd: work.path)];
      await manager.list();
      await expectLater(manager.resume(cid), throwsA(isA<StateError>()));

      external.entries = [];
      await manager.list();
      console.supported = false;
      await expectLater(manager.resume(cid), throwsA(isA<StateError>()));
      console.supported = true;
      work.deleteSync(recursive: true);
      await expectLater(manager.resume(cid), throwsA(isA<StateError>()));
      expect(launches, isEmpty);
    });

    test('times out when Claude Code never lists it', () async {
      await endedSession();
      onLaunch = (_) {};
      await expectLater(manager.resume(cid), throwsA(isA<StateError>()));
    });
  });

}
