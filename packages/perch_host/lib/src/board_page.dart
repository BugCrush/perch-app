// The board on the host machine: the Memory Glass app built for the web
// (`flutter build web` in apps/perch_app), served by the host at http://localhost:<port>/
// to a browser on this machine only. The page learns the machine's pairing from
// `/local/pairing` (loopback, asked for by this host's own name) and then talks to the host
// over the same encrypted channel as the phone.
import 'dart:convert' show HtmlEscape;
import 'dart:io';

import 'package:shelf/shelf.dart';

import 'autostart.dart' show findPerchRepo;

/// Where the built page is looked for: `PERCH_BOARD_DIR`, else the repo's
/// `apps/perch_app/build/web` (the repo from `PERCH_REPO`, which autostart's launcher sets
/// for the compiled host, else the one this script runs from).
String? defaultBoardDir({Map<String, String>? environment, Uri? script, String? executable}) {
  final env = environment ?? Platform.environment;
  final own = env['PERCH_BOARD_DIR'];
  if (own != null && own.isNotEmpty) return own;
  final sep = Platform.pathSeparator;
  // A release build: the page ships in `board/` next to the compiled host.
  final besideExe = '${File(executable ?? Platform.resolvedExecutable).parent.path}${sep}board';
  if (File('$besideExe${sep}index.html').existsSync()) return besideExe;
  String? repo = env['PERCH_REPO'];
  if (repo == null || repo.isEmpty) {
    final s = script ?? Platform.script;
    repo = s.scheme == 'file' ? findPerchRepo(s.toFilePath()) : null;
    repo ??= findPerchRepo(Directory.current.path);
  }
  return repo == null ? null : '$repo${sep}apps${sep}perch_app${sep}build${sep}web';
}

const _types = {
  'html': 'text/html; charset=utf-8',
  'js': 'text/javascript; charset=utf-8',
  'mjs': 'text/javascript; charset=utf-8',
  'json': 'application/json',
  'wasm': 'application/wasm',
  'css': 'text/css; charset=utf-8',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'svg': 'image/svg+xml',
  'ico': 'image/x-icon',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'txt': 'text/plain; charset=utf-8',
  'frag': 'application/octet-stream',
  'bin': 'application/octet-stream',
  'symbols': 'text/plain; charset=utf-8',
};

/// What `/` shows when the page has not been built on this machine.
String notBuiltPage(String? dir) => '''<!doctype html><html><head><meta charset="utf-8"><title>Perch board</title></head>
<body style="font-family:sans-serif;background:#161310;color:#fce6d1;padding:32px">
<h1>Perch board</h1>
<p>The board page is not built on this machine yet. In the Perch repo run:</p>
<pre>cd apps/perch_app
flutter build web --no-web-resources-cdn</pre>
<p>then reload this page.${dir == null ? '' : ' (Looked in ${const HtmlEscape().convert(dir)}.)'}</p>
</body></html>''';

/// Serves a file of the built page from [dir], or the "not built" page.
Future<Response> serveBoardFile(String? dir, String path) async {
  final sep = Platform.pathSeparator;
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  if (parts.any((p) => p == '..' || p == '.' || p.contains('\\') || p.contains(':'))) {
    return Response.forbidden('Not allowed.');
  }
  if (dir == null || !File('$dir${sep}index.html').existsSync()) {
    if (parts.isEmpty || parts.last == 'index.html') {
      return Response.ok(notBuiltPage(dir), headers: {'content-type': _types['html']!, 'cache-control': 'no-store'});
    }
    return Response.notFound('Not found.');
  }
  final rel = parts.isEmpty ? 'index.html' : parts.join(sep);
  final file = File('$dir$sep$rel');
  if (!file.existsSync()) return Response.notFound('Not found.');
  final ext = rel.contains('.') ? rel.substring(rel.lastIndexOf('.') + 1).toLowerCase() : '';
  return Response.ok(file.openRead(), headers: {
    'content-type': _types[ext] ?? 'application/octet-stream',
    // The page changes with each build: always ask again (the host is on this machine).
    'cache-control': 'no-cache',
    'content-length': '${file.lengthSync()}',
  });
}
