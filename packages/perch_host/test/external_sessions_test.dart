import 'dart:io';

import 'package:perch_host/src/external_sessions.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

const sample = r'''
[{"id":"e739e53a","cwd":"D:\\projects\\x","kind":"background","startedAt":1791059963001,"sessionId":"e739e53a-c8b0-4536-8c1f-e00df5024b81","name":"NFSMW visuals work","state":"blocked"},
 {"pid":7792,"cwd":"D:\\projects\\perch","kind":"interactive","startedAt":1794410986545,"sessionId":"b835a490-2ed9-4971-a4eb-35f6e10febbc","name":"perch-14","status":"busy"}]
''';

void main() {
  test('parses_real_output', () {
    final s = ExternalSessions.parse(sample);
    expect(s.length, 2);
    // An old background session with no process: listed, but not running.
    expect(s[0].state, SessionState.idle);
    expect(s[0].reason, 'Not running');
    expect(s[0].live, isFalse);
    expect(s[0].name, 'NFSMW visuals work');
    expect(s[1].live, isTrue);
    expect(s[0].origin, SessionOrigin.external);
    expect(s[1].id, 'b835a490-2ed9-4971-a4eb-35f6e10febbc');
    expect(s[1].state, SessionState.working);
    expect(s[1].startedAtMs, 1794410986545);
    expect(ExternalSessions.parse('garbage'), isEmpty);
  });

  test('state_mapping_and_defaults', () {
    final s = ExternalSessions.parse(r'''[
      {"pid":1,"cwd":"D:\\a\\proj","kind":"interactive","status":"waiting","waitingFor":"permission prompt"},
      {"pid":2,"cwd":"D:\\a","kind":"interactive","status":"waiting","waitingFor":"input needed"},
      {"pid":3,"cwd":"/home/me/p","kind":"interactive","status":"idle"},
      {"id":"b1","cwd":"x","kind":"background","state":"done"},
      {"id":"b2","cwd":"x","kind":"background","state":"failed"},
      {"id":"b3","cwd":"x","kind":"background","state":"stopped"},
      {"id":"b4","cwd":"x","kind":"background","state":"working"},
      "not an object"
    ]''');
    expect(s.map((e) => e.state).toList(), [
      SessionState.waitingPermission,
      SessionState.waitingQuestion,
      SessionState.idle,
      SessionState.idle,
      SessionState.finished,
      SessionState.stopped,
      SessionState.working,
    ]);
    expect(s[0].id, 'pid:1');
    expect(s[0].name, 'proj');
    expect(s[2].name, 'p');
    expect(s[3].id, 'b1');
    final entries = ExternalSessions.parseEntries('[{"pid":9,"cwd":"x","sessionId":"abc","kind":"interactive"}]');
    expect(entries.single.pid, 9);
    expect(entries.single.claudeSessionId, 'abc');
    expect(entries.single.interactive, isTrue);
  });

  test('stale_blocked_background_session_is_not_running', () {
    final s = ExternalSessions.parse(r'''[
      {"id":"old1","cwd":"x","kind":"background","startedAt":1,"sessionId":"aaaa-1","name":"Old","state":"blocked"},
      {"id":"bg2","cwd":"x","kind":"background","state":"working"},
      {"id":"bg3","cwd":"x","kind":"background","state":"done"},
      {"pid":5,"cwd":"x","kind":"interactive","status":"idle","state":"blocked"},
      {"pid":6,"cwd":"x","kind":"background","state":"blocked"}
    ]''');
    expect(s[0].state, SessionState.idle);
    expect(s[0].reason, 'Not running');
    expect(s[0].live, isFalse);
    expect(s[1].state, SessionState.working);
    expect(s[1].live, isTrue);
    expect(s[2].live, isFalse);
    expect(s[3].live, isTrue);
    expect(s[3].state, SessionState.blocked); // a running process that is blocked still needs the owner
    expect(s[4].live, isTrue);
    expect(s[4].state, SessionState.blocked);
  });

  test('busy_with_only_background_shells_is_idle', () {
    // Claude Code lists a session as "busy" while background shells it started still run,
    // although its turn ended; its own registry (sessions/<pid>.json) says "shell".
    final tmp = Directory.systemTemp.createTempSync('perch_registry_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final sessions = Directory('${tmp.path}${Platform.pathSeparator}sessions')..createSync();
    File('${sessions.path}${Platform.pathSeparator}11.json').writeAsStringSync('{"pid":11,"status":"shell"}');
    File('${sessions.path}${Platform.pathSeparator}12.json').writeAsStringSync('{"pid":12,"status":"busy"}');
    final entries = ExternalSessions.parseEntries('''[
      {"pid":11,"cwd":"/w/mirror","kind":"interactive","sessionId":"s11","status":"busy"},
      {"pid":12,"cwd":"/w/other","kind":"interactive","sessionId":"s12","status":"busy"},
      {"pid":13,"cwd":"/w/none","kind":"interactive","sessionId":"s13","status":"busy"}
    ]''');
    final fixed = ExternalSessions.withRegistryStatus(entries, configDir: tmp.path);
    expect(fixed.map((e) => e.summary.state).toList(), [SessionState.idle, SessionState.working, SessionState.working]);
    expect(fixed[0].summary.reason, 'Background shells running');
  });
}
