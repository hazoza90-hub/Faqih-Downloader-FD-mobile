import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/config/app_settings.dart';
import '../core/models/history_entry.dart';
import '../core/models/subtitle_track.dart';
import '../core/models/youtube_stream_info.dart';
import '../core/utils/filename_sanitizer.dart';
import '../core/utils/url_detector.dart';
import '../platform/cookies_channel.dart';
import '../platform/foreground_service_channel.dart';
import '../platform/media_store_channel.dart';
import '../platform/youtube_dl_channel.dart';
import '../services/coordinator/download_job_models.dart';
import '../services/coordinator/download_queue_manager.dart';
import '../services/coordinator/job_export_helper.dart';
import '../services/coordinator/stream_download_coordinator.dart';
import '../services/history/history_manager.dart';
import '../services/media/ffmpeg_media_processor.dart';

/// Result returned when analyzing a user URL (either direct HTTP or rich media info).
@immutable
class UrlAnalysisResult {
  const UrlAnalysisResult({
    required this.url,
    this.mediaInfo,
    this.resolvedFilename,
    this.resolvedHeaders = const <String, String>{},
  });

  final String url;
  final YouTubeStreamInfo? mediaInfo;
  final String? resolvedFilename;
  final Map<String, String> resolvedHeaders;
  bool get isMedia => mediaInfo != null;
}

/// Encapsulates vault open/share/delete, SAF directory selection, cookies, external subtitles, and permissions.
class VaultStorageActions {
  VaultStorageActions({
    required MediaStoreChannel mediaStore,
    required CookiesChannel cookies,
    required DownloadHistoryManager? Function() historyProvider,
    required AppSettings Function() settingsProvider,
    required Future<void> Function(AppSettings next) saveSettings,
  })  : _mediaStore = mediaStore,
        _cookies = cookies,
        _historyProvider = historyProvider,
        _settingsProvider = settingsProvider,
        _saveSettings = saveSettings;

  final MediaStoreChannel _mediaStore;
  final CookiesChannel _cookies;
  final DownloadHistoryManager? Function() _historyProvider;
  final AppSettings Function() _settingsProvider;
  final Future<void> Function(AppSettings next) _saveSettings;
  bool _notifRequested = false;

  Future<int> saveWebViewCookies(List<String> urls) async {
    final workDir = await _mediaStore.getAppWorkDir();
    final cookiesPath = p.join(workDir, 'cookies.txt');
    final count = await _cookies.exportCookiesForUrls(urls: urls, outputPath: cookiesPath);
    if (count > 0) {
      await _saveSettings(_settingsProvider().copyWith(cookiesFilePath: cookiesPath));
    }
    return count;
  }

  Future<void> clearCookies() async {
    final path = _settingsProvider().cookiesFilePath;
    await _cookies.clearAllCookies(cookiesFilePath: path.isEmpty ? null : path);
    await _saveSettings(_settingsProvider().copyWith(cookiesFilePath: ''));
  }

  String resolveTarget(HistoryEntry entry) =>
      (entry.contentUri != null && entry.contentUri!.trim().isNotEmpty)
          ? entry.contentUri!
          : entry.filePath;

  String resolveMime(HistoryEntry entry) => CoordinatorHelpers.mimeTypeForExt(
        p.extension(entry.filename).replaceFirst('.', ''),
      );

  Future<bool> openEntry(HistoryEntry entry) =>
      _mediaStore.openFile(pathOrUri: resolveTarget(entry), mimeType: resolveMime(entry));

  Future<bool> shareEntry(HistoryEntry entry) =>
      _mediaStore.shareFile(pathOrUri: resolveTarget(entry), mimeType: resolveMime(entry));

  Future<void> deleteEntry(HistoryEntry entry, {required bool deleteFile}) async {
    if (deleteFile) {
      await _mediaStore.deleteExportedFile(pathOrUri: resolveTarget(entry));
    }
    await _historyProvider()?.remove(entry.id, deleteFile: deleteFile);
  }

  Future<bool> pickCustomSaveDirectory() async {
    final picked = await _mediaStore.pickSaveDirectory();
    if (picked == null) return false;
    await _saveSettings(
      _settingsProvider().copyWith(
        customSaveTreeUri: picked.treeUri,
        customSaveDisplayLabel: picked.displayName,
      ),
    );
    return true;
  }

  Future<void> resetSaveDirectory() => _saveSettings(
        _settingsProvider().copyWith(customSaveTreeUri: '', customSaveDisplayLabel: ''),
      );

  Future<SubtitleTrack?> pickExternalSubtitleFile() async {
    final picked = await _mediaStore.pickSubtitleFile();
    if (picked == null) return null;
    final ext = p.extension(picked.name).replaceFirst('.', '').toLowerCase();
    final isAr = RegExp(
      r'(?:^|[._\-\s])(ar|ara|arabic)(?:$|[._\-\s])',
      caseSensitive: false,
    ).hasMatch(picked.name);
    final lang = isAr ? 'ar' : 'und';
    return SubtitleTrack(
      subId: 'ext_${DateTime.now().millisecondsSinceEpoch}',
      language: lang,
      label: picked.name,
      url: picked.path,
      ext: ext == 'vtt' ? 'vtt' : 'srt',
      isExternal: true,
      localPath: picked.path,
    );
  }

  Future<void> requestNotificationPermissionOnce() async {
    if (_notifRequested) return;
    _notifRequested = true;
    await _mediaStore.requestNotificationPermission();
  }

  static DownloadJobRequest buildBasicRequest({
    required String id,
    required String url,
    required AppSettings settings,
    String? customTitle,
    int durationSec = 0,
    bool forceMediaPipeline = false,
    int preferredVideoHeight = 0,
    bool skipHtmlResolve = false,
    Map<String, String> headers = const <String, String>{},
    String? cookiesFile,
  }) {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    final rawName = (customTitle?.trim().isNotEmpty ?? false)
        ? customTitle!.trim()
        : (uri != null && uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'download');
    return DownloadJobRequest(
      id: id,
      url: trimmed,
      title: sanitizeFilename(rawName, fallback: 'download'),
      headers: headers,
      maxConnections: settings.maxConnections,
      speedLimitBytesPerSec: settings.speedLimitBytesPerSec,
      cookiesFile: cookiesFile,
      platform: UrlDetector.extractMediaPlatform(trimmed) ?? (forceMediaPipeline ? 'Media' : 'Direct'),
      durationSec: durationSec,
      customSaveTreeUri: settings.customSaveTreeUri,
      autoCategorizeFolders: settings.autoCategorizeFolders,
      subtitlePosition: settings.subtitlePosition,
      subtitleFontSize: settings.subtitleFontSize,
      forceMediaPipeline: forceMediaPipeline,
      preferredVideoHeight: preferredVideoHeight,
      skipHtmlResolve: skipHtmlResolve,
    );
  }

  static DownloadJobRequest buildMediaRequest({
    required String id,
    required DownloadJobRequest request,
    required AppSettings settings,
    String? effectiveCookiesFile,
  }) =>
      DownloadJobRequest(
        id: id,
        url: request.url,
        title: request.title,
        selectedVideoFormat: request.selectedVideoFormat,
        selectedAudioTrack: request.selectedAudioTrack,
        selectedSubtitle: request.selectedSubtitle,
        subtitleMode: request.subtitleMode,
        audioOnly: request.audioOnly,
        audioFormat: request.audioFormat,
        clipRange: request.clipRange,
        headers: request.headers,
        cookiesFile: request.cookiesFile ?? effectiveCookiesFile,
        maxConnections: settings.maxConnections,
        speedLimitBytesPerSec: settings.speedLimitBytesPerSec,
        categorySubFolder: request.categorySubFolder,
        platform: request.platform,
        durationSec: request.durationSec,
        customSaveTreeUri: settings.customSaveTreeUri,
        autoCategorizeFolders: settings.autoCategorizeFolders,
        subtitlePosition: settings.subtitlePosition,
        subtitleFontSize: settings.subtitleFontSize,
      );

  static DownloadQueueManager createDefaultQueue({
    required AppSettings settings,
    required ForegroundServiceChannel foregroundService,
    required YoutubeDlChannel youtubeDl,
    required MediaStoreChannel mediaStore,
    required DownloadHistoryManager? Function() historyProvider,
    required String pauseLabel,
    required String cancelLabel,
  }) =>
      DownloadQueueManager(
        settings: settings,
        foregroundService: foregroundService,
        pauseLabel: pauseLabel,
        cancelLabel: cancelLabel,
        coordinatorFactory: (req, {required onStateChanged}) =>
            StreamDownloadCoordinator(
          request: req,
          youtubeDlChannel: youtubeDl,
          mediaStoreChannel: mediaStore,
          ffmpegProcessor: FfmpegMediaProcessor(channel: youtubeDl),
          historyManager: historyProvider(),
          onStateChanged: onStateChanged,
        ),
      );
}
