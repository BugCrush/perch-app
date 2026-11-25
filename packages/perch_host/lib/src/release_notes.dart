// Reads Claude Code's published release notes for the versions newer than the newest one
// this Perch was checked with, and picks out the lines about things Perch relies on.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

import 'compatibility.dart' show compareVersions;
import 'version_store.dart';

const changelogUrl = 'https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md';

/// What Perch relies on, as words that may appear in a release-notes line, each with the
/// topic it belongs to. Matched case-insensitively as whole words (a trailing `s` is
/// allowed). The one place to add to when Perch starts relying on something new.
///
/// Kept narrow on purpose: Claude Code's notes run to a hundred lines a release, and bare
/// words such as "hooks", "dialog", "resume" or "-p" matched most of them (checked against
/// the notes for 2.1.325), which would make the amber line say "changes" every time.
const perchKeywords = <({String phrase, String topic})>[
  // Question, permission and plan dialogs, and how the terminal draws them.
  (phrase: 'AskUserQuestion', topic: 'prompt'),
  (phrase: 'question dialog', topic: 'prompt'),
  (phrase: 'question prompt', topic: 'prompt'),
  (phrase: 'multiSelect', topic: 'prompt'),
  (phrase: 'multi-select', topic: 'prompt'),
  (phrase: 'permission prompt', topic: 'prompt'),
  (phrase: 'permission dialog', topic: 'prompt'),
  (phrase: 'permission request', topic: 'prompt'),
  (phrase: 'permission mode', topic: 'prompt'),
  (phrase: 'plan mode', topic: 'prompt'),
  (phrase: 'plan approval', topic: 'prompt'),
  (phrase: 'ExitPlanMode', topic: 'prompt'),
  (phrase: 'EnterPlanMode', topic: 'prompt'),
  (phrase: 'trust dialog', topic: 'prompt'),
  (phrase: 'trusted folder', topic: 'prompt'),
  (phrase: 'folder trust', topic: 'prompt'),
  (phrase: 'trust this folder', topic: 'prompt'),
  // Hooks: the events Perch installs, and how hooks get their input.
  (phrase: 'hook input', topic: 'hook'),
  (phrase: 'hook event', topic: 'hook'),
  (phrase: 'command hook', topic: 'hook'),
  (phrase: 'async hook', topic: 'hook'),
  (phrase: 'PreToolUse', topic: 'hook'),
  (phrase: 'PermissionRequest', topic: 'hook'),
  (phrase: 'PostToolUse', topic: 'hook'),
  (phrase: 'UserPromptSubmit', topic: 'hook'),
  (phrase: 'SubagentStart', topic: 'hook'),
  (phrase: 'SubagentStop', topic: 'hook'),
  (phrase: 'SessionStart', topic: 'hook'),
  (phrase: 'SessionEnd', topic: 'hook'),
  // Transcripts and resuming.
  (phrase: 'transcript', topic: 'transcript'),
  (phrase: '.jsonl', topic: 'transcript'),
  (phrase: 'session file', topic: 'transcript'),
  (phrase: '--resume', topic: 'transcript'),
  // The session list.
  (phrase: 'claude agents', topic: 'session list'),
  (phrase: 'agent view', topic: 'session list'),
  (phrase: 'agents view', topic: 'session list'),
  // Sessions Perch runs itself.
  (phrase: 'stream-json', topic: 'headless mode'),
  (phrase: '--print', topic: 'headless mode'),
  (phrase: '--input-format', topic: 'headless mode'),
  (phrase: '--output-format', topic: 'headless mode'),
  // Usage limits.
  (phrase: 'usage limit', topic: 'usage limit'),
  (phrase: 'rate limit', topic: 'usage limit'),
  (phrase: 'automatic continue', topic: 'usage limit'),
  (phrase: 'auto-continue', topic: 'usage limit'),
];

final List<({RegExp re, String topic, String phrase})> _patterns = [
  for (final k in perchKeywords)
    (
      re: RegExp(
          // Not inside a longer word or option name ("plan-mode model" is not plan mode).
          '(?<![\\w-])${RegExp.escape(k.phrase).replaceAll(' ', r'\s+')}s?(?![\\w-])',
          caseSensitive: false),
      topic: k.topic,
      phrase: k.phrase,
    )
];

/// The keywords [line] mentions (empty: nothing Perch relies on).
List<({String phrase, String topic})> relevantKeywords(String line) => [
      for (final p in _patterns)
        if (p.re.hasMatch(line)) (phrase: p.phrase, topic: p.topic)
    ];

typedef ChangelogSection = ({String version, List<String> bullets});

final _heading = RegExp(r'^##\s+v?(\d+(?:\.\d+)+)\b');
final _bullet = RegExp(r'^\s{0,3}[-*+]\s+(.*)$');

/// The `## <version>` sections of a changelog, in file order (newest first), each with its
/// bullet lines (a bullet continued on the next lines is one line).
List<ChangelogSection> parseChangelog(String text) {
  final out = <ChangelogSection>[];
  String? version;
  var bullets = <String>[];
  void flush() {
    final v = version;
    if (v != null) out.add((version: v, bullets: bullets));
  }

  for (final raw in const LineSplitter().convert(text)) {
    final h = _heading.firstMatch(raw);
    if (h != null) {
      flush();
      version = h.group(1);
      bullets = <String>[];
      continue;
    }
    if (raw.startsWith('#')) {
      flush();
      version = null;
      continue;
    }
    if (version == null) continue;
    final b = _bullet.firstMatch(raw);
    if (b != null) {
      bullets.add(b.group(1)!.trim());
    } else if (raw.trim().isNotEmpty && bullets.isNotEmpty && raw.startsWith(' ')) {
      bullets[bullets.length - 1] = '${bullets.last} ${raw.trim()}';
    }
  }
  flush();
  return out;
}

/// The sections newer than [after] up to and including [upTo], oldest first.
List<ChangelogSection> sectionsBetween(List<ChangelogSection> sections, {required String after, required String upTo}) {
  final picked = [
    for (final s in sections)
      if (compareVersions(s.version, after) > 0 && compareVersions(s.version, upTo) <= 0) s
  ];
  picked.sort((a, b) => compareVersions(a.version, b.version));
  return picked;
}

/// A line written for another product (`[VSCode] …`, `[SDK] …`).
bool _forAnotherProduct(String line) => RegExp(r'^\[[^\]]+\]').hasMatch(line.trim());

/// What the notes between [after] and [upTo] say. Not a check when the installed version
/// has no notes yet.
ReleaseNotesFindings findingsFor(List<ChangelogSection> sections, {required String after, required String upTo}) {
  final slice = sectionsBetween(sections, after: after, upTo: upTo);
  final lines = <String>[];
  final topics = <String>[];
  for (final s in slice) {
    for (final b in s.bullets) {
      if (_forAnotherProduct(b)) continue;
      final k = relevantKeywords(b);
      if (k.isEmpty) continue;
      lines.add(b);
      for (final x in k) {
        if (!topics.contains(x.topic)) topics.add(x.topic);
      }
    }
  }
  final versions = [for (final s in slice) s.version];
  final complete = versions.contains(upTo);
  return ReleaseNotesFindings(
    checked: complete,
    versions: versions,
    relevantLines: lines,
    topics: topics,
    error: complete ? null : 'The release notes have no entry for $upTo yet.',
  );
}

typedef ChangelogFetcher = Future<String> Function(Uri uri);

Future<String> defaultChangelogFetcher(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(uri);
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: uri);
    return body;
  } finally {
    client.close(force: true);
  }
}

class ReleaseNotesScanner {
  final VersionStore store;
  final ChangelogFetcher fetch;
  final Duration timeout;

  ReleaseNotesScanner({required this.store, ChangelogFetcher? fetch, this.timeout = const Duration(seconds: 10)})
      : fetch = fetch ?? defaultChangelogFetcher;

  /// The findings for [installed] since [newestChecked]: from the cache in the host state, or
  /// read now. A result that is not a check (the notes could not be read, or have no entry
  /// for [installed] yet) is not cached, so the next scan tries again.
  Future<ReleaseNotesFindings> scan({required String installed, required String newestChecked}) async {
    final key = cacheKey(installed);
    final cached = store.releaseNotes(key);
    if (cached != null && cached.checked) return cached;
    final String text;
    try {
      text = await fetch(Uri.parse(changelogUrl)).timeout(timeout);
    } on TimeoutException {
      return ReleaseNotesFindings(checked: false, error: 'Reading the release notes timed out after ${timeout.inSeconds} s.');
    } catch (e) {
      return ReleaseNotesFindings(checked: false, error: 'The release notes could not be read ($e).');
    }
    final sections = parseChangelog(text);
    if (sections.isEmpty) {
      return const ReleaseNotesFindings(checked: false, error: 'The release notes could not be read (no versions in them).');
    }
    final f = findingsFor(sections, after: newestChecked, upTo: installed);
    if (f.checked) store.setReleaseNotes(key, f);
    return f;
  }

  /// The cache entry for [installed]: a changed keyword list reads the notes again.
  static String cacheKey(String installed) {
    var h = 0x811c9dc5; // FNV-1a over the phrases
    for (final unit in perchKeywords.map((k) => k.phrase).join('|').codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0xffffffff;
    }
    return '$installed#${h.toRadixString(16)}';
  }
}
