import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'incoming_files.dart';

/// A newer release found on GitHub.
class UpdateInfo {
  /// `1.2.3` (no leading `v`).
  final String version;
  final String notes;

  /// The release page (always set).
  final String pageUrl;
  final String apkName;
  final String apkUrl;
  final int apkSize;
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.pageUrl,
    required this.apkName,
    required this.apkUrl,
    required this.apkSize,
  });
}

enum InstallResult {
  /// The system installer is showing.
  started,

  /// The user must allow installs from this app first (settings opened).
  needsPermission,
  failed,
}

/// Checks the GitHub releases of this project for a newer version and, on
/// Android, downloads its APK and hands it to the system installer.
///
/// Releases are published as `osuEdit-<version>.apk` assets on tags like
/// `v1.2.3` (the old Java app's pre-releases have other asset names and are
/// ignored). Android only installs an update signed with the same key as the
/// installed app and with a higher version code, so the check compares the
/// release tag with the installed `versionName`.
abstract final class AppUpdater {
  static const repo = 'inix1257/osuEdit';
  static final _apkName = RegExp(r'^osuEdit.*\.apk$', caseSensitive: false);
  static const _minInterval = Duration(hours: 12);

  /// Tests: replace the network call (the releases JSON list), the installed
  /// version, the platform check and the state file.
  @visibleForTesting
  static Future<List<Object?>> Function()? debugFetch;
  @visibleForTesting
  static String? debugVersion;
  @visibleForTesting
  static bool? debugSupported;
  @visibleForTesting
  static File? debugStateFile;

  /// Whether this platform can update itself (Android; elsewhere the release
  /// page is only a link).
  static bool get supported => debugSupported ?? Platform.isAndroid;

  /// The development app (`OSUEDIT_DEV=1` build, version name `x.y.z-dev`):
  /// installed from a computer, never updated from a release.
  static bool isDevVersion(String? version) => version != null && version.endsWith('-dev');

  /// The installed `versionName`, or null when unknown.
  static Future<String?> currentVersion() async {
    if (debugVersion != null) return debugVersion;
    try {
      return await IncomingFiles.channel.invokeMethod<String>('appVersion');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// `[1, 2, 3]` from `v1.2.3` / `1.2.3+4`; null when there is no number.
  static List<int>? parseVersion(String s) {
    final m = RegExp(r'(\d+(?:\.\d+)*)').firstMatch(s);
    if (m == null) return null;
    return [for (final p in m.group(1)!.split('.')) int.parse(p)];
  }

  /// Negative / 0 / positive like `compareTo`; missing parts count as 0.
  static int compareVersions(List<int> a, List<int> b) {
    final n = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  /// The highest release (not a draft / pre-release) that has an APK asset.
  static UpdateInfo? pickLatest(List<Object?> releases) {
    UpdateInfo? best;
    List<int>? bestV;
    for (final r in releases) {
      if (r is! Map || r['draft'] == true || r['prerelease'] == true) continue;
      final v = parseVersion('${r['tag_name']}');
      if (v == null) continue;
      Map? apk;
      for (final a in (r['assets'] as List? ?? const [])) {
        if (a is Map && _apkName.hasMatch('${a['name']}') && a['browser_download_url'] is String) {
          apk = a;
          break;
        }
      }
      if (apk == null) continue;
      if (bestV != null && compareVersions(v, bestV) <= 0) continue;
      bestV = v;
      best = UpdateInfo(
        version: v.join('.'),
        notes: '${r['body'] ?? ''}'.trim(),
        pageUrl: '${r['html_url'] ?? 'https://github.com/$repo/releases'}',
        apkName: '${apk['name']}',
        apkUrl: apk['browser_download_url'] as String,
        apkSize: (apk['size'] as num?)?.toInt() ?? 0,
      );
    }
    return best;
  }

  static Future<List<Object?>> _fetchReleases() async {
    final hook = debugFetch;
    if (hook != null) return hook();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$repo/releases?per_page=20'));
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set(HttpHeaders.userAgentHeader, 'osuEdit');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw HttpException('GitHub answered ${res.statusCode}');
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
      return jsonDecode(body) as List<Object?>;
    } finally {
      client.close(force: true);
    }
  }

  // --- When to check / which version to skip (a small file in app support).

  static Future<File> _stateFile() async {
    final f = debugStateFile;
    if (f != null) return f;
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}update_state.json');
  }

  static Future<Map<String, Object?>> _readState() async {
    try {
      final f = await _stateFile();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map<String, Object?>) return j;
      }
    } catch (_) {}
    return {};
  }

  static Future<void> _writeState(Map<String, Object?> s) async {
    try {
      final f = await _stateFile();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(s), flush: true);
    } catch (_) {}
  }

  /// "Skip this version": the automatic check stays quiet about [version].
  static Future<void> skip(String version) async {
    final s = await _readState();
    s['skipped'] = version;
    await _writeState(s);
  }

  /// A newer release, or null when up to date. [manual] ignores the check
  /// interval and the skipped version. Throws when the check itself fails
  /// (offline, rate limit); the automatic caller ignores that.
  static Future<UpdateInfo?> check({bool manual = false}) async {
    final state = await _readState();
    if (!manual) {
      final last = DateTime.tryParse('${state['lastCheck']}');
      if (last != null && DateTime.now().difference(last) < _minInterval) return null;
    }
    final current = await currentVersion();
    final cur = current == null ? null : parseVersion(current);
    if (cur == null || isDevVersion(current)) return null;
    final latest = pickLatest(await _fetchReleases());
    state['lastCheck'] = DateTime.now().toIso8601String();
    await _writeState(state);
    if (latest == null || compareVersions(parseVersion(latest.version)!, cur) <= 0) return null;
    if (!manual && state['skipped'] == latest.version) return null;
    return latest;
  }

  // --- Download + install.

  /// Downloads [info]'s APK into the cache folder; [onProgress] gets 0..1.
  /// A partial or wrong-sized file is deleted and reported as an error.
  static Future<File> download(UpdateInfo info, {void Function(double)? onProgress}) async {
    final uri = Uri.parse(info.apkUrl);
    if (uri.scheme != 'https') throw const HttpException('Refusing a non-HTTPS download');
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}${info.apkName}');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'osuEdit');
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('Download failed (${res.statusCode})');
      final total = res.contentLength > 0 ? res.contentLength : info.apkSize;
      final sink = file.openWrite();
      var got = 0;
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 30))) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress?.call((got / total).clamp(0, 1).toDouble());
        }
      } finally {
        await sink.close();
      }
      if (info.apkSize > 0 && got != info.apkSize) {
        throw HttpException('Download incomplete ($got of ${info.apkSize} bytes)');
      }
      return file;
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// Hands [apk] to the Android package installer.
  static Future<InstallResult> install(File apk) async {
    try {
      final r = await IncomingFiles.channel.invokeMethod<String>('installApk', apk.path);
      return switch (r) {
        'started' => InstallResult.started,
        'permission' => InstallResult.needsPermission,
        _ => InstallResult.failed,
      };
    } on MissingPluginException {
      return InstallResult.failed;
    } on PlatformException {
      return InstallResult.failed;
    }
  }
}
