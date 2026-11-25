// "Update available" for an app installed from an APK (Play updates its own installs): the
// app asks GitHub for the newest release of the Perch repository
// (`https://api.github.com/repos/<repo>/releases/latest`, which skips drafts and
// pre-releases), compares its tag with the app's own version and offers the release's APK.
//
// It degrades quietly: any failure (no network, a private repository answering 404, the
// rate limit, an answer it cannot read) offers nothing and says nothing. It asks at most
// once every 12 hours while the app runs. The repository is PERCH_RELEASE_REPO at build
// time (`--dart-define`), else BugCrush/perch-app.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Whether this build looks for updates (`--dart-define=PERCH_UPDATE_CHECK=false` for a build
/// that a store updates).
const updateCheckOn = bool.fromEnvironment('PERCH_UPDATE_CHECK', defaultValue: true);

/// The GitHub repository whose releases hold Perch's APK.
const releaseRepo = String.fromEnvironment('PERCH_RELEASE_REPO', defaultValue: 'BugCrush/perch-app');

/// [a] compared with [b] by their numbers (`0.10.0` > `0.9.9`); a suffix (`-rc1`) is left
/// out and missing parts count as 0.
int compareVersions(String a, String b) {
  List<int> parts(String v) =>
      [for (final p in v.split('-').first.split('.')) int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

/// A published release: its version, its page and its APK (when it has one).
class ReleaseInfo {
  final String version;
  final String pageUrl;
  final String? apkUrl;
  const ReleaseInfo({required this.version, required this.pageUrl, this.apkUrl});

  /// What Download opens: the APK, else the release's page.
  String get downloadUrl => apkUrl ?? pageUrl;
}

/// The release in GitHub's `releases/latest` answer; null for a draft, a pre-release or
/// anything else.
ReleaseInfo? parseLatestRelease(Object? json) {
  if (json is! Map) return null;
  final tag = json['tag_name'];
  if (tag is! String || !RegExp(r'^v?\d+(\.\d+)*').hasMatch(tag)) return null;
  if (json['draft'] == true || json['prerelease'] == true) return null;
  final version = tag.startsWith('v') ? tag.substring(1) : tag;
  String? apk;
  for (final a in json['assets'] is List ? json['assets'] as List : const []) {
    if (a is Map && a['name'] is String && (a['name'] as String).endsWith('.apk') && a['browser_download_url'] is String) {
      apk = a['browser_download_url'] as String;
      break;
    }
  }
  final page = json['html_url'] is String ? json['html_url'] as String : 'https://github.com/$releaseRepo/releases';
  return ReleaseInfo(version: version, pageUrl: page, apkUrl: apk);
}

/// Body of a GET that answered 200, else null.
typedef ReleaseFetch = Future<String?> Function(Uri url);

Future<String?> _get(Uri url) async {
  final r = await http.get(url, headers: {
    'accept': 'application/vnd.github+json',
    'user-agent': 'perch-app',
  }).timeout(const Duration(seconds: 10));
  return r.statusCode == 200 ? r.body : null;
}

class UpdateChecker extends ChangeNotifier {
  final String current;
  final String repo;
  final bool enabled;
  final ReleaseFetch fetch;

  /// Keeps the version the owner put off with Later (the app stores it).
  final Future<void> Function(String version)? saveDismissed;
  String? dismissed;
  ReleaseInfo? _latest;
  DateTime? _checkedAt;

  UpdateChecker({
    required this.current,
    this.repo = releaseRepo,
    this.enabled = true,
    ReleaseFetch? fetch,
    this.saveDismissed,
    this.dismissed,
  }) : fetch = fetch ?? _get;

  /// Never asks (tests, the board page, builds from a store).
  UpdateChecker.disabled({String current = '0.0.0'}) : this(current: current, enabled: false);

  /// A newer release than this app that the owner has not put off; null when there is none
  /// or the check could not tell.
  ReleaseInfo? get available {
    final l = _latest;
    if (l == null || compareVersions(l.version, current) <= 0) return null;
    if (dismissed != null && compareVersions(l.version, dismissed!) <= 0) return null;
    return l;
  }

  /// Asks GitHub (at most every 12 hours unless [force]); never throws.
  Future<void> check({bool force = false}) async {
    if (!enabled) return;
    final at = _checkedAt;
    if (!force && at != null && DateTime.now().difference(at) < const Duration(hours: 12)) return;
    _checkedAt = DateTime.now();
    try {
      final body = await fetch(Uri.parse('https://api.github.com/repos/$repo/releases/latest'));
      final info = body == null ? null : parseLatestRelease(jsonDecode(body));
      if (info == null) return;
      _latest = info;
      notifyListeners();
    } catch (_) {
      // Quietly nothing: the next start asks again.
    }
  }

  /// Later: this version is not offered again (a newer one is).
  void dismiss() {
    final a = available;
    if (a == null) return;
    dismissed = a.version;
    notifyListeners();
    saveDismissed?.call(a.version).catchError((_) {});
  }
}
