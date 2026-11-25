import 'dart:async';
import 'dart:io';

import 'package:perch_host/src/release_notes.dart';
import 'package:perch_host/src/version_store.dart';
import 'package:perch_protocol/perch_protocol.dart' show ReleaseNotesFindings;
import 'package:test/test.dart';

/// Shaped like Claude Code's CHANGELOG.md (synthetic lines).
const changelog = '''
# Changelog

## 2.1.326

- Added a setting for the spinner colour
- Fixed hooks not receiving the cwd for SubagentStop events

## 2.1.325

- Fixed long options in lists and permission prompts being partly overwritten when they wrap, and first-run screens losing lines on narrow terminals
- [VSCode] Fixed the permission prompt not closing after approval
- Improved MCP server startup time when many servers are configured
- Fixed cloud sessions sometimes failing to sync on slow networks

## 2.1.324

- Added OAuth refresh for remote MCP servers
- Improved the VS Code extension's diff view
- Fixed a crash when pasting large images

## 2.1.323

- Fixed AskUserQuestion dialogs dropping the last option
''';

void main() {
  group('parsing', () {
    test('sections_come_out_newest_first_with_their_bullets', () {
      final s = parseChangelog(changelog);
      expect([for (final x in s) x.version], ['2.1.326', '2.1.325', '2.1.324', '2.1.323']);
      expect(s[1].bullets, hasLength(4));
      expect(s[1].bullets.first, startsWith('Fixed long options in lists'));
      expect(s[3].bullets.single, 'Fixed AskUserQuestion dialogs dropping the last option');
    });

    test('a_bullet_continued_on_the_next_line_is_one_line', () {
      final s = parseChangelog('# Changelog\n\n## 1.0.1\n\n- First part\n  second part\n* Star bullet\n');
      expect(s.single.bullets, ['First part second part', 'Star bullet']);
    });

    test('slicing_takes_the_versions_after_the_checked_one_up_to_the_installed_one', () {
      final s = parseChangelog(changelog);
      final slice = sectionsBetween(s, after: '2.1.323', upTo: '2.1.325');
      expect([for (final x in slice) x.version], ['2.1.324', '2.1.325']); // oldest first
      expect(sectionsBetween(s, after: '2.1.325', upTo: '2.1.325'), isEmpty);
      expect([for (final x in sectionsBetween(s, after: '2.1.300', upTo: '2.1.326')) x.version],
          ['2.1.323', '2.1.324', '2.1.325', '2.1.326']);
    });
  });

  group('keywords', () {
    test('the_lines_perch_relies_on_match', () {
      for (final line in [
        'Fixed long options in lists and permission prompts being partly overwritten when they wrap, and first-run screens losing lines on narrow terminals',
        'Fixed AskUserQuestion with multiSelect losing the typed answer',
        'Plan mode now shows the plan in a scrollable view',
        'ExitPlanMode no longer asks twice',
        'The trust dialog now remembers parent folders',
        'Added PreToolUse matcher for MCP tools',
        'Hook input now includes the permission mode',
        'Fixed Stop hook events arriving twice',
        'Transcripts are written before the first reply',
        'Fixed --resume picking the wrong session',
        'claude agents --json now lists the session name',
        'Fixed stream-json output dropping control requests',
        'Fixed --print hanging when stdin is closed',
        'Added --input-format validation',
        'Usage limit messages now show the reset time',
        'Rate limits are retried automatically',
        'Changed new sessions from the agents view to start in their folder',
        'Session files now use the .jsonl suffix everywhere',
        'Fixed the permission dialog flickering in Windows Terminal',
        'Fixed words typed with a Yes at a permission dialog or plan approval not reaching Claude',
      ]) {
        expect(relevantKeywords(line), isNotEmpty, reason: line);
      }
    });

    test('typical_lines_about_other_things_do_not_match', () {
      for (final line in [
        'Improved MCP server startup time when many servers are configured',
        'Fixed cloud sessions sometimes failing to sync on slow networks',
        'Added OAuth refresh for remote MCP servers',
        "Improved the VS Code extension's diff view",
        'Fixed a crash when pasting large images',
        'Added a setting for the spinner colour',
        'Improved performance of file search in large repositories',
        'Fixed a typo in the /doctor output',
        'Fixed the -pe flag spelling in docs', // "-p" only as a whole option
        'Stopped showing the welcome tip twice', // not the Stop hook
        'Desktop notifications now use the app icon', // not the Notification hook
        // Shaped like real lines that mention a word Perch uses in another sense.
        'Changed scheduled tasks to ask before running a skill that declares allowed tools or hooks',
        'Changed EnterWorktree to refuse a WorktreeCreate hook path through a symlink',
        'Fixed the exit dialog stopping background work twice',
        'Fixed the IDE welcome dialog showing the wrong shortcut',
        'Fixed `/resume` on Windows hiding sessions recorded with another drive-letter case',
        'Changed `claude -p` with no cached account data to wait before its first request',
        'Fixed background sessions using an API key from the shell that started them',
        'Fixed subagents with their own model being moved to the plan-mode model',
        '`claude doctor` now lists it as a skipped entry',
      ]) {
        expect(relevantKeywords(line), isEmpty, reason: line);
      }
    });

    test('matching_ignores_case_and_needs_whole_words', () {
      expect(relevantKeywords('PERMISSION PROMPTS now wrap'), isNotEmpty);
      expect(relevantKeywords('askuserquestion fixed'), isNotEmpty);
      expect(relevantKeywords('Fixed hookshot integration'), isEmpty);
      expect(relevantKeywords('Fixed prestream-jsonish thing'), isEmpty);
    });

    test('lines_for_another_product_in_brackets_are_ignored', () {
      final f = findingsFor(parseChangelog(changelog), after: '2.1.323', upTo: '2.1.325');
      expect(f.checked, isTrue);
      expect(f.versions, ['2.1.324', '2.1.325']);
      expect(f.relevantLines, [
        'Fixed long options in lists and permission prompts being partly overwritten when they wrap, and first-run screens losing lines on narrow terminals'
      ]);
      expect(f.topics, ['prompt']);
    });

    test('nothing_relevant_gives_an_empty_list', () {
      final f = findingsFor(parseChangelog(changelog), after: '2.1.323', upTo: '2.1.324');
      expect(f.checked, isTrue);
      expect(f.relevantLines, isEmpty);
      expect(f.topics, isEmpty);
    });

    test('an_installed_version_without_notes_yet_is_not_a_check', () {
      final f = findingsFor(parseChangelog(changelog), after: '2.1.323', upTo: '2.1.327');
      expect(f.checked, isFalse);
      expect(f.error, contains('2.1.327'));
      expect(f.versions, ['2.1.324', '2.1.325', '2.1.326']);
    });
  });

  group('scanner', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('perch_rn_'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('fetches_once_and_caches_by_version_in_the_state', () async {
      var fetches = 0;
      final store = VersionStore.load(tmp.path);
      final scanner = ReleaseNotesScanner(store: store, fetch: (uri) async {
        fetches++;
        expect(uri.toString(), changelogUrl);
        return changelog;
      });
      final f = await scanner.scan(installed: '2.1.325', newestChecked: '2.1.323');
      expect(f.relevantLines, hasLength(1));
      expect(fetches, 1);
      await scanner.scan(installed: '2.1.325', newestChecked: '2.1.323');
      expect(fetches, 1);
      // A new host process reads the cache from the state.
      final again = ReleaseNotesScanner(store: VersionStore.load(tmp.path), fetch: (_) async {
        fetches++;
        return changelog;
      });
      final cached = await again.scan(installed: '2.1.325', newestChecked: '2.1.323');
      expect(cached.relevantLines, f.relevantLines);
      expect(fetches, 1);
      // An entry cached under another keyword list is not used.
      final stale = VersionStore.load(tmp.path)
        ..setReleaseNotes('2.1.326#0', const ReleaseNotesFindings(checked: true, relevantLines: ['old']));
      final fresh = await ReleaseNotesScanner(store: stale, fetch: (_) async {
        fetches++;
        return changelog;
      }).scan(installed: '2.1.326', newestChecked: '2.1.323');
      expect(fresh.relevantLines, isNot(contains('old')));
      expect(fetches, 2);
    });

    test('a_failed_fetch_says_the_notes_could_not_be_read_and_is_not_cached', () async {
      var fail = true;
      final store = VersionStore.load(tmp.path);
      final scanner = ReleaseNotesScanner(store: store, fetch: (_) async {
        if (fail) throw const SocketException('offline');
        return changelog;
      });
      final f = await scanner.scan(installed: '2.1.325', newestChecked: '2.1.323');
      expect(f.checked, isFalse);
      expect(f.error, isNotNull);
      expect(store.releaseNotes(ReleaseNotesScanner.cacheKey('2.1.325')), isNull);
      fail = false;
      final g = await scanner.scan(installed: '2.1.325', newestChecked: '2.1.323');
      expect(g.checked, isTrue);
    });

    test('a_slow_fetch_times_out', () async {
      final scanner = ReleaseNotesScanner(
          store: VersionStore.load(tmp.path),
          timeout: const Duration(milliseconds: 50),
          fetch: (_) => Completer<String>().future);
      final f = await scanner.scan(installed: '2.1.325', newestChecked: '2.1.323');
      expect(f.checked, isFalse);
      expect(f.error, contains('time'));
    });

    test('something_that_is_not_a_changelog_is_not_a_check', () async {
      final scanner =
          ReleaseNotesScanner(store: VersionStore.load(tmp.path), fetch: (_) async => '<html>rate limited</html>');
      final f = await scanner.scan(installed: '2.1.325', newestChecked: '2.1.323');
      expect(f.checked, isFalse);
    });
  });
}
