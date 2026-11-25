// "Update available" for APK installs: the app asks GitHub for the latest release of the
// Perch repository, compares it with its own version and offers the APK. A check that
// fails (no network, a private repository, a rate limit, a strange answer) shows nothing.
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perch_app/src/state/providers.dart';
import 'package:perch_app/src/ui/app_menu.dart' show appVersion;
import 'package:perch_app/src/ui/home_screen.dart';
import 'package:perch_app/src/ui/update_notice.dart';
import 'package:perch_app/src/update_check.dart';

import 'glass_harness.dart';

Map<String, Object?> release(String tag, {bool pre = false, bool draft = false, bool apk = true}) => {
      'tag_name': tag,
      'prerelease': pre,
      'draft': draft,
      'html_url': 'https://github.com/owner/perch/releases/tag/$tag',
      'assets': [
        {'name': 'SHA256SUMS.txt', 'browser_download_url': 'https://example.invalid/SHA256SUMS.txt'},
        if (apk)
          {
            'name': 'perch-${tag.substring(1)}.apk',
            'browser_download_url': 'https://github.com/owner/perch/releases/download/$tag/perch-${tag.substring(1)}.apk'
          },
      ],
    };

void main() {
  test('versions_compare_by_number', () {
    expect(compareVersions('0.3.1', '0.3.0'), greaterThan(0));
    expect(compareVersions('0.10.0', '0.9.9'), greaterThan(0));
    expect(compareVersions('1.0', '1.0.0'), 0);
    expect(compareVersions('0.3.0-rc1', '0.3.0'), 0, reason: 'the suffix is left out');
    expect(compareVersions('0.2.9', '0.3.0'), lessThan(0));
  });

  test('the_latest_release_names_its_version_and_apk', () {
    final r = parseLatestRelease(release('v0.3.1'))!;
    expect(r.version, '0.3.1');
    expect(r.apkUrl, endsWith('/perch-0.3.1.apk'));
    expect(r.downloadUrl, r.apkUrl);
    final noApk = parseLatestRelease(release('v0.3.1', apk: false))!;
    expect(noApk.apkUrl, isNull);
    expect(noApk.downloadUrl, contains('/releases/tag/v0.3.1'));
    expect(parseLatestRelease(release('v0.3.1', pre: true)), isNull);
    expect(parseLatestRelease(release('v0.3.1', draft: true)), isNull);
    expect(parseLatestRelease({'message': 'Not Found'}), isNull);
    expect(parseLatestRelease({'tag_name': 'nightly'}), isNull);
  });

  test('the_check_asks_github_for_the_repositorys_latest_release', () async {
    Uri? asked;
    final c = UpdateChecker(current: '0.3.0', repo: 'owner/perch', fetch: (u) async {
      asked = u;
      return jsonEncode(release('v0.3.1'));
    });
    await c.check();
    expect(asked.toString(), 'https://api.github.com/repos/owner/perch/releases/latest');
    expect(c.available?.version, '0.3.1');
  });

  test('nothing_is_offered_for_the_same_or_an_older_version_or_when_the_check_fails', () async {
    Future<UpdateChecker> run(Future<String?> Function(Uri) fetch) async {
      final c = UpdateChecker(current: '0.3.0', repo: 'owner/perch', fetch: fetch);
      await c.check();
      return c;
    }

    expect((await run((_) async => jsonEncode(release('v0.3.0')))).available, isNull);
    expect((await run((_) async => jsonEncode(release('v0.2.0')))).available, isNull);
    expect((await run((_) async => null)).available, isNull, reason: '404 of a private repository');
    expect((await run((_) async => 'not json')).available, isNull);
    expect((await run((_) async => throw Exception('offline'))).available, isNull);
  });

  test('later_hides_that_version_until_a_newer_one', () async {
    String? saved;
    var tag = 'v0.3.1';
    final c = UpdateChecker(
        current: '0.3.0',
        repo: 'owner/perch',
        fetch: (_) async => jsonEncode(release(tag)),
        saveDismissed: (v) async => saved = v);
    await c.check();
    c.dismiss();
    expect(c.available, isNull);
    expect(saved, '0.3.1');
    await c.check(force: true);
    expect(c.available, isNull, reason: 'the same version stays dismissed');
    tag = 'v0.3.2';
    await c.check(force: true);
    expect(c.available?.version, '0.3.2');
  });

  test('the_menu_shows_the_version_and_an_available_update', () {
    expect(versionLine('0.3.0', null), 'Version 0.3.0');
    expect(versionLine('0.3.0', const ReleaseInfo(version: '0.3.1', pageUrl: 'p')), 'Version 0.3.0 · 0.3.1 available');
  });

  test('a_disabled_checker_never_asks', () async {
    var asked = false;
    final c = UpdateChecker(current: '0.3.0', repo: 'owner/perch', enabled: false, fetch: (_) async {
      asked = true;
      return null;
    });
    await c.check();
    expect(asked, isFalse);
  });

  testWidgets('the_home_screen_offers_the_download_and_later', (tester) async {
    tallPhone(tester);
    final opened = <Uri>[];
    final checker = UpdateChecker(
        current: appVersion, repo: 'owner/perch', fetch: (_) async => jsonEncode(release('v99.0.0')));
    await checker.check();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        updateCheckerProvider.overrideWithValue(checker),
        updateOpenerProvider.overrideWithValue((u) async {
          opened.add(u);
          return true;
        }),
      ],
      child: glassApp(const HomeScreen()),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('update-notice')), findsOneWidget);
    expect(find.text('Perch 99.0.0 is available'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-download')));
    await tester.pump();
    expect(opened.single.toString(), endsWith('/perch-99.0.0.apk'));
    await tester.tap(find.byKey(const ValueKey('update-later')));
    await tester.pump();
    expect(find.byKey(const ValueKey('update-notice')), findsNothing);
  });

  testWidgets('no_notice_without_an_update', (tester) async {
    tallPhone(tester);
    await tester.pumpWidget(ProviderScope(child: glassApp(const HomeScreen())));
    await tester.pump();
    expect(find.byKey(const ValueKey('update-notice')), findsNothing);
  });
}
