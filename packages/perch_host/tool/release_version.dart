// The Perch version of this checkout: one version for the host (`hostVersion` in
// lib/src/server.dart), the Claude Code plugin (claude_plugin/perch/.claude-plugin/plugin.json)
// and the app (apps/perch_app/pubspec.yaml, `version: <name>+<build>`, and `appVersion` in
// lib/src/ui/app_menu.dart, which the app shows and compares with the newest release). The release workflow
// runs it first: it prints the version and fails when they differ, or when a release tag
// (`v<version>` or `v<version>-<suffix>`) does not match.
//   dart run tool/release_version.dart [--root ../..] [--tag v0.3.0]
import 'dart:convert';
import 'dart:io';

typedef Versions = ({String host, String plugin, String app, int build, String appShown});

Versions readVersions(String root) {
  final server = File('$root/packages/perch_host/lib/src/server.dart').readAsStringSync();
  final host = RegExp(r"const hostVersion = '([^']+)';").firstMatch(server)?.group(1) ?? '';
  final plugin = (jsonDecode(File('$root/packages/perch_host/claude_plugin/perch/.claude-plugin/plugin.json')
          .readAsStringSync()) as Map)['version'] as String? ??
      '';
  final pubspec = File('$root/apps/perch_app/pubspec.yaml').readAsStringSync();
  final m = RegExp(r'^version:\s*([0-9A-Za-z.\-]+)\+(\d+)\s*$', multiLine: true).firstMatch(pubspec);
  final menu = File('$root/apps/perch_app/lib/src/ui/app_menu.dart').readAsStringSync();
  final shown = RegExp(r"const appVersion = '([^']+)';").firstMatch(menu)?.group(1) ?? '';
  return (
      host: host,
      plugin: plugin,
      app: m?.group(1) ?? '',
      build: int.tryParse(m?.group(2) ?? '') ?? 0,
      appShown: shown);
}

/// What is wrong with [v] (and [tag], when given); empty when all is well.
List<String> problems(Versions v, {String? tag}) => [
      if (v.host.isEmpty) 'no hostVersion in lib/src/server.dart',
      if (v.plugin != v.host) 'the plugin says ${v.plugin}, the host ${v.host}',
      if (v.app != v.host) 'the app says ${v.app}, the host ${v.host}',
      if (v.appShown != v.host) 'the app shows ${v.appShown} (appVersion in app_menu.dart), the host ${v.host}',
      if (v.build <= 0) 'the app has no build number (version: <name>+<build>)',
      if (tag != null && tag != 'v${v.host}' && !tag.startsWith('v${v.host}-'))
        'the tag $tag does not match the version ${v.host}',
    ];

void main(List<String> args) {
  String? opt(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final v = readVersions(opt('--root') ?? '../..');
  final tag = opt('--tag');
  final wrong = problems(v, tag: (tag == null || tag.isEmpty) ? null : tag);
  if (wrong.isNotEmpty) {
    stderr.writeln(wrong.join('\n'));
    exit(1);
  }
  stdout.writeln(v.host);
}
