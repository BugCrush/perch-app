// Scripted stand-in for `claude -p --input-format stream-json --output-format stream-json`.
// The script is chosen by the first user message's text:
//   question   -> AskUserQuestion prompt, echoes the answers, result
//   permission -> Write permission prompt, result text "allowed" / "denied"
//   crash      -> "boom" on stderr, exit 3
//   slow       -> init, then nothing until an interrupt control request
//   flood N    -> N assistant texts, then a result
//   todo-task  -> a TodoWrite to-do list, a Write of notes.txt in its folder (the file is
//                 written), the list again with every item ticked, an answer ending in a
//                 "## Report" section, result
//   a set_model control request (Perch's Model…) is answered with success at any time
//   malformed  -> a permission request without tool_name, then echoes
//   anything else (and "echo") -> "echo: <text>" + result for every user message
// Also `auth status --json` and `setup-token` (see authStatus, setupToken).
// Environment:
//   FAKE_CLAUDE_ARGS_FILE  - write the command-line arguments there, one per line
//   FAKE_CLAUDE_STDIN_LOG  - append every stdin line there
//   FAKE_CLAUDE_ENV_FILE   - write the token (SYNTHETIC in tests) / BROWSER it ran with
//   FAKE_CLAUDE_AUTH_EMAIL - `auth status`: signed in with this email (plan max)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

final _rand = Random();
String _id() => List.generate(16, (_) => _rand.nextInt(16).toRadixString(16)).join();

late final String sessionId;
var _toolCounter = 0;

void emit(Map<String, dynamic> m) => stdout.writeln(jsonEncode(m));

void init() => emit({
      'type': 'system',
      'subtype': 'init',
      'session_id': sessionId,
      'model': 'fake-model',
      'claude_code_version': '2.1.322',
      'cwd': Directory.current.path,
    });

void usage() => emit({
      'type': 'rate_limit_event',
      'rate_limit_info': {
        'status': 'allowed',
        'unifiedWindows': {
          'five_hour': {'utilization': 0.5, 'resetsAt': 1794424800, 'status': 'allowed'},
          'seven_day': {'utilization': 0.1, 'resetsAt': 1794906000, 'status': 'allowed'},
        },
      },
      'session_id': sessionId,
    });

void say(String text) => emit({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': text}
        ]
      },
      'parent_tool_use_id': null,
      'session_id': sessionId,
    });

void toolUse(String id, String name, Map<String, dynamic> input) => emit({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'tool_use', 'id': id, 'name': name, 'input': input}
        ]
      },
      'parent_tool_use_id': null,
      'session_id': sessionId,
    });

void toolResult(String id, String text) => emit({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': id, 'content': text}
        ]
      },
      'parent_tool_use_id': null,
      'session_id': sessionId,
    });

void result(String text, {bool error = false, String subtype = 'success'}) => emit({
      'type': 'result',
      'subtype': subtype,
      'is_error': error,
      'result': text,
      'session_id': sessionId,
    });

String request(String tool, Map<String, dynamic> input, {List<dynamic> suggestions = const []}) {
  final rid = 'req-${_id()}';
  emit({
    'type': 'control_request',
    'request_id': rid,
    'request': {
      'subtype': 'can_use_tool',
      'tool_name': tool,
      'input': input,
      'permission_suggestions': suggestions,
      'tool_use_id': 'toolu_${++_toolCounter}',
    },
  });
  return rid;
}

/// `claude auth status --json`: a token in the environment wins (no email or plan, as
/// Claude Code 2.1.325 reports it); else the stored login FAKE_CLAUDE_AUTH_EMAIL (plan
/// max), else signed out (exit 1).
void authStatus(Map<String, String> env) {
  final email = env['FAKE_CLAUDE_AUTH_EMAIL'];
  final Map<String, dynamic> j;
  if ((env['CLAUDE_CODE_OAUTH_TOKEN'] ?? '').isNotEmpty) {
    j = {'loggedIn': true, 'authMethod': 'oauth_token', 'apiProvider': 'firstParty'};
  } else if (email != null) {
    j = {
      'loggedIn': true,
      'authMethod': 'claude.ai',
      'apiProvider': 'firstParty',
      'email': email,
      'orgName': "$email's Organization",
      'subscriptionType': 'max',
    };
  } else {
    j = {'loggedIn': false, 'authMethod': 'none', 'apiProvider': 'firstParty'};
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(j));
  exitCode = j['loggedIn'] == true ? 0 : 1;
}

/// `claude setup-token`, as plain text (the real one draws with Ink): the sign-in link,
/// the code prompt; the code `good#code` prints a SYNTHETIC token and exits, anything else
/// the OAuth error and "Press Enter to retry" (Enter shows a new link). FAKE_CLAUDE_ENV_FILE
/// gets `BROWSER=<value>` and whether a token was in the environment.
Future<void> setupToken(Map<String, String> env) async {
  final envFile = env['FAKE_CLAUDE_ENV_FILE'];
  if (envFile != null) {
    File(envFile).writeAsStringSync('BROWSER=${env['BROWSER'] ?? ''}\nTOKEN=${env.containsKey('CLAUDE_CODE_OAUTH_TOKEN')}\n');
  }
  var round = 0;
  void link() {
    round++;
    stdout.writeln(" Browser didn't open? Use the url below to sign in (c to copy)");
    stdout.writeln('https://claude.com/cai/oauth/authorize?code=true&client_id=00000000-0000-4000-8000-000000000000'
        '&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback'
        '&scope=user%3Ainference&code_challenge=FAKEchallenge$round&code_challenge_method=S256&state=FAKEstate$round');
    stdout.write(' Paste code here if prompted > ');
  }

  stdout.writeln(' This will guide you through long-lived (1-year) auth token setup for your Claude account.');
  link();
  while (true) {
    final line = stdin.readLineSync();
    if (line == null) return;
    if (line.trim() == 'good#code') {
      stdout.writeln();
      stdout.writeln(' ✓ Long-lived authentication token created successfully!');
      stdout.writeln();
      stdout.writeln(' Your OAuth token (valid for 1 year):');
      stdout.writeln();
      stdout.writeln(' sk-ant-oat01-FAKEtoken-0000000000000000000000000000000000000000000000000000000000000000000000AA');
      stdout.writeln();
      stdout.writeln(" Store this token securely. You won't be able to see it again.");
      return;
    }
    stdout.writeln();
    stdout.writeln(" OAuth error: That code wasn't accepted. It may be incomplete, expired, already used, or from an");
    stdout.writeln(' earlier sign-in attempt. Sign in again to get a new code.');
    stdout.writeln(' Press Enter to retry.');
    stdin.readLineSync();
    link();
  }
}

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final argsFile = env['FAKE_CLAUDE_ARGS_FILE'];
  if (argsFile != null) File(argsFile).writeAsStringSync('${args.join('\n')}\n');
  if (args.length >= 2 && args[0] == 'auth' && args[1] == 'status') return authStatus(env);
  if (args.isNotEmpty && args.first == 'setup-token') return setupToken(env);
  // Which token (SYNTHETIC in tests) the session runs with.
  final envFile = env['FAKE_CLAUDE_ENV_FILE'];
  if (envFile != null) File(envFile).writeAsStringSync('TOKEN=${env['CLAUDE_CODE_OAUTH_TOKEN'] ?? ''}\n');
  final r = args.indexOf('--resume');
  sessionId = r >= 0 && r + 1 < args.length ? args[r + 1] : 'fake-${_id()}';
  final stdinLog = env['FAKE_CLAUDE_STDIN_LOG'];

  final lines = StreamIterator(stdin.transform(utf8.decoder).transform(const LineSplitter()));
  Future<Map<String, dynamic>?> next() async {
    while (await lines.moveNext()) {
      final l = lines.current;
      if (stdinLog != null) File(stdinLog).writeAsStringSync('$l\n', mode: FileMode.append, flush: true);
      try {
        final j = jsonDecode(l);
        if (j is Map<String, dynamic>) {
          if (j['type'] == 'control_request' && j['request']?['subtype'] == 'set_model') {
            emit({
              'type': 'control_response',
              'response': {'subtype': 'success', 'request_id': j['request_id']}
            });
            continue;
          }
          return j;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<Map<String, dynamic>?> nextUser() async {
    while (true) {
      final m = await next();
      if (m == null || m['type'] == 'user') return m;
    }
  }

  Future<Map<String, dynamic>?> responseFor(String rid) async {
    while (true) {
      final m = await next();
      if (m == null) return null;
      if (m['type'] == 'control_response' && m['response']?['request_id'] == rid) return m;
    }
  }

  String textOf(Map<String, dynamic> m) {
    final c = m['message']?['content'];
    if (c is String) return c;
    if (c is List) return c.whereType<Map>().map((b) => '${b['text'] ?? ''}').join();
    return '';
  }

  final first = await nextUser();
  if (first == null) exit(0);
  final text = textOf(first);
  init();
  usage();

  if (text.contains('malformed')) {
    // A permission request in a shape Perch does not know (no tool_name).
    emit({
      'type': 'control_request',
      'request_id': 'req-${_id()}',
      'request': {'subtype': 'can_use_tool', 'input': <String, dynamic>{}},
    });
    result('done');
  }

  if (text.contains('crash')) {
    stderr.write('something went wrong: boom');
    await stderr.flush();
    exit(3);
  }

  if (text.contains('question')) {
    final rid = request('AskUserQuestion', {
      'questions': [
        {
          'question': 'Which color?',
          'header': 'Color',
          'multiSelect': false,
          'options': [
            {'label': 'Red', 'description': 'Choose red'},
            {'label': 'Blue', 'description': 'Choose blue'},
          ],
        }
      ]
    });
    final resp = await responseFor(rid);
    if (resp == null) exit(0);
    final answers = resp['response']?['response']?['updatedInput']?['answers'];
    say('You chose: ${answers is Map ? answers.entries.map((e) => '${e.key}=${e.value}').join(', ') : 'nothing'}');
    result('done');
  } else if (text.contains('permission')) {
    final rid = request('Write', {'file_path': 'notes.txt', 'content': 'hello'}, suggestions: [
      {
        'type': 'addRules',
        'rules': [
          {'toolName': 'Write'}
        ],
        'behavior': 'allow',
        'destination': 'localSettings'
      }
    ]);
    final resp = await responseFor(rid);
    if (resp == null) exit(0);
    final behavior = resp['response']?['response']?['behavior'];
    result(behavior == 'allow' ? 'allowed' : 'denied');
  } else if (text.startsWith('limit')) {
    // `limit <seconds>`: the five-hour window runs out, resetting in that many seconds
    // (the shape `claude -p` reports a rejected window in; synthetic values).
    final secs = int.tryParse(text.substring(5).trim()) ?? 3600;
    final reset = DateTime.now().millisecondsSinceEpoch ~/ 1000 + secs;
    emit({
      'type': 'rate_limit_event',
      'rate_limit_info': {
        'status': 'rejected',
        'resetsAt': reset,
        'rateLimitType': 'five_hour',
        'unifiedWindows': {
          'five_hour': {'utilization': 1.0, 'resetsAt': reset, 'status': 'rejected'},
          'seven_day': {'utilization': 0.4, 'resetsAt': reset + 86400, 'status': 'allowed'},
        },
      },
      'session_id': sessionId,
    });
    result("You've hit your session limit", error: true);
  } else if (text.contains('todo-task')) {
    final sep = Platform.pathSeparator;
    final file = '${Directory.current.path}${sep}notes.txt';
    toolUse('todo_1', 'TodoWrite', {
      'todos': [
        {'content': 'Create notes.txt', 'status': 'in_progress', 'activeForm': 'Creating notes.txt'},
        {'content': 'Check its contents', 'status': 'pending', 'activeForm': 'Checking its contents'},
      ]
    });
    toolResult('todo_1', 'Todos have been modified successfully.');
    say('Creating the file.');
    toolUse('write_1', 'Write', {'file_path': file, 'content': 'hello\n'});
    File(file).writeAsStringSync('hello\n');
    toolResult('write_1', 'File created successfully at: $file');
    toolUse('todo_2', 'TodoWrite', {
      'todos': [
        {'content': 'Create notes.txt', 'status': 'completed', 'activeForm': 'Creating notes.txt'},
        {'content': 'Check its contents', 'status': 'completed', 'activeForm': 'Checking its contents'},
      ]
    });
    toolResult('todo_2', 'Todos have been modified successfully.');
    say('Created notes.txt.\n\n## Report\n- Changed: created notes.txt containing hello\n- Tested: read it back\n'
        '- Left: nothing');
    result('done');
  } else if (text.startsWith('flood ')) {
    final n = int.parse(text.substring(6).trim());
    for (var i = 1; i <= n; i++) {
      say('line $i');
    }
    result('flooded');
  } else if (text.contains('slow')) {
    while (true) {
      final m = await next();
      if (m == null) exit(0);
      if (m['type'] == 'control_request' && m['request']?['subtype'] == 'interrupt') {
        emit({
          'type': 'control_response',
          'response': {'subtype': 'success', 'request_id': m['request_id']}
        });
        result('', error: true, subtype: 'error_during_execution');
        break;
      }
    }
  } else {
    say('echo: $text');
    result('echo: $text');
  }

  // Afterwards: echo every further user message.
  while (true) {
    final m = await nextUser();
    if (m == null) break;
    final t = textOf(m);
    say('echo: $t');
    result('echo: $t');
  }
  exit(0);
}
