import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/config/app_constants.dart';
import '../../core/utils/filename_sanitizer.dart';
import '../../engine/engine_callbacks.dart';
import '../../platform/media_store_channel.dart';
import '../coordinator/job_export_helper.dart';
import '../coordinator/media_stream_acquirer.dart';

/// Parsed metadata for the latest GitHub release APK update check.
@immutable
class ReleaseUpdateInfo {
  const ReleaseUpdateInfo({
    required this.hasUpdate,
    required this.currentVersion,
    required this.latestVersion,
    this.releaseNotes = '',
    this.apkUrl = '',
    this.apkName = '',
    this.apkSizeBytes = 0,
    this.publishedAt,
  });

  final bool hasUpdate;
  final String currentVersion;
  final String latestVersion;
  final String releaseNotes;
  final String apkUrl;
  final String apkName;
  final int apkSizeBytes;
  final DateTime? publishedAt;
}

/// Checks GitHub Releases API and installs newer APK builds via [MediaStoreChannel].
class GitHubReleaseUpdater {
  GitHubReleaseUpdater({
    HttpClient Function()? httpClientFactory,
    MediaStoreChannel? mediaStoreChannel,
    DownloadRunnerFactory? runnerFactory,
    this.repoSlug = AppConstants.githubRepoSlug,
    this.currentVersion = AppConstants.appVersion,
  })  : _httpClientFactory = httpClientFactory,
        _mediaStore = mediaStoreChannel ?? MediaStoreChannel(),
        _runnerFactory =
            runnerFactory ?? CoordinatorHelpers.defaultRunnerFactory;

  final HttpClient Function()? _httpClientFactory;
  final MediaStoreChannel _mediaStore;
  final DownloadRunnerFactory _runnerFactory;
  final String repoSlug;
  final String currentVersion;

  Future<ReleaseUpdateInfo> checkForUpdate({String? preferredAbi}) async {
    final uri = Uri.parse(
      'https://api.github.com/repos/$repoSlug/releases/latest',
    );
    final client = (_httpClientFactory ?? HttpClient.new)();
    try {
      client.connectionTimeout = const Duration(seconds: 12);
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set(HttpHeaders.userAgentHeader, 'FaqihDownloaderMobile');
      final res = await req.close();
      final body = await utf8.decodeStream(res);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException(
          'GitHub Releases HTTP ${res.statusCode}',
          uri: uri,
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const FormatException('Invalid GitHub release payload');
      }
      return parseReleaseJson(
        Map<String, dynamic>.from(decoded),
        preferredAbi: preferredAbi,
      );
    } finally {
      client.close(force: true);
    }
  }

  ReleaseUpdateInfo parseReleaseJson(
    Map<String, dynamic> raw, {
    String? preferredAbi,
  }) {
    final latest = normalizeVersionTag(raw['tag_name']?.toString() ?? '');
    final assets = raw['assets'];
    final asset = assets is List
        ? selectBestApkAsset(assets, preferredAbi: preferredAbi)
        : null;

    return ReleaseUpdateInfo(
      hasUpdate: latest.isNotEmpty && isNewerVersion(latest, currentVersion),
      currentVersion: normalizeVersionTag(currentVersion),
      latestVersion: latest,
      releaseNotes: (raw['body']?.toString() ?? '').trim(),
      apkUrl: asset?['browser_download_url']?.toString() ?? '',
      apkName: asset?['name']?.toString() ?? '',
      apkSizeBytes: _toInt(asset?['size']),
      publishedAt: DateTime.tryParse(raw['published_at']?.toString() ?? ''),
    );
  }

  Future<bool> downloadAndInstallUpdate(
    ReleaseUpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    if (info.apkUrl.trim().isEmpty) return false;
    final workDir = await _mediaStore.getAppWorkDir();
    final safeName = sanitizeFilename(
      info.apkName.trim().isEmpty ? 'FaqihDownloader-update.apk' : info.apkName,
      fallback: 'FaqihDownloader-update.apk',
    );
    final updatesDir = Directory(p.join(workDir, 'updates'));
    if (!updatesDir.existsSync()) {
      await updatesDir.create(recursive: true);
    }
    final apkPath = p.join(updatesDir.path, safeName);

    Object? capturedError;
    final runner = _runnerFactory(
      url: info.apkUrl,
      destinationPath: apkPath,
      headers: const <String, String>{'User-Agent': 'FaqihDownloaderMobile'},
      maxConnections: 4,
      callbacks: EngineCallbacks(
        onProgress: (snap) => onProgress?.call(snap.progressRatio),
        onError: (err, {linkExpired = false, httpStatus}) => capturedError = err,
      ),
    );
    await runner.start();
    await runner.completion;
    if (capturedError != null) throw capturedError!;

    return _mediaStore.openFile(
      pathOrUri: apkPath,
      mimeType: 'application/vnd.android.package-archive',
    );
  }

  static Map<String, dynamic>? selectBestApkAsset(
    List<dynamic> assets, {
    String? preferredAbi,
  }) {
    Map<String, dynamic>? best;
    var bestScore = -1;
    final abiLower = preferredAbi?.trim().toLowerCase() ?? '';

    for (final raw in assets) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final name = item['name']?.toString() ?? '';
      final url = item['browser_download_url']?.toString() ?? '';
      if (!name.toLowerCase().endsWith('.apk') || !url.startsWith('http')) {
        continue;
      }
      final nameLower = name.toLowerCase();
      var score = 10;
      if (abiLower.isNotEmpty && nameLower.contains(abiLower)) score += 100;
      if (nameLower.contains('arm64')) score += 50;
      if (nameLower.contains('universal')) score += 40;
      if (score > bestScore) {
        bestScore = score;
        best = item;
      }
    }
    return best;
  }

  static String normalizeVersionTag(String raw) {
    var clean = raw.trim();
    if (clean.startsWith('v') || clean.startsWith('V')) {
      clean = clean.substring(1);
    }
    final plusIdx = clean.indexOf('+');
    if (plusIdx >= 0) {
      clean = clean.substring(0, plusIdx);
    }
    return clean.trim();
  }

  /// Compares normalized SemVer tags, supporting numeric parts and pre-release qualifiers.
  static bool isNewerVersion(String latest, String current) {
    final l = _ParsedSemVer.parse(normalizeVersionTag(latest));
    final c = _ParsedSemVer.parse(normalizeVersionTag(current));
    if (l == null || c == null) return false;

    final maxLen = l.nums.length > c.nums.length ? l.nums.length : c.nums.length;
    for (var i = 0; i < maxLen; i++) {
      final lv = i < l.nums.length ? l.nums[i] : 0;
      final cv = i < c.nums.length ? c.nums[i] : 0;
      if (lv != cv) return lv > cv;
    }
    if (c.isPreRelease && !l.isPreRelease) return true;
    return false;
  }

  static int _toInt(Object? raw) =>
      raw is int ? raw : (raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0);
}

class _ParsedSemVer {
  const _ParsedSemVer(this.nums, this.isPreRelease);

  final List<int> nums;
  final bool isPreRelease;

  static _ParsedSemVer? parse(String raw) {
    if (raw.isEmpty) return null;
    final dashIdx = raw.indexOf('-');
    final core = dashIdx >= 0 ? raw.substring(0, dashIdx) : raw;
    final suffix = dashIdx >= 0 ? raw.substring(dashIdx + 1).toLowerCase() : '';
    final parts = core.split('.');
    final nums = <int>[];
    for (final part in parts) {
      final n = int.tryParse(part.trim());
      if (n == null) return null;
      nums.add(n);
    }
    final isPre = suffix.contains('alpha') ||
        suffix.contains('beta') ||
        suffix.contains('rc') ||
        suffix.contains('dev') ||
        suffix.contains('pre');
    return _ParsedSemVer(nums, isPre);
  }
}
