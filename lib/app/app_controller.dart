import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/config/app_settings.dart';
import '../core/config/settings_repository.dart';
import '../core/i18n/translator.dart';
import '../core/models/history_entry.dart';
import '../core/models/subtitle_track.dart';
import '../core/utils/filename_sanitizer.dart';
import '../core/utils/url_detector.dart';
import '../platform/cookies_channel.dart';
import '../platform/foreground_service_channel.dart';
import '../platform/media_store_channel.dart';
import '../platform/native_models.dart';
import '../platform/share_intent_channel.dart';
import '../platform/youtube_dl_channel.dart';
import '../services/coordinator/download_job_models.dart';
import '../services/coordinator/download_queue_manager.dart';
import '../services/coordinator/stream_download_coordinator.dart';
import '../services/history/history_manager.dart';
import '../services/history/history_storage.dart';
import '../services/media/ffmpeg_media_processor.dart';
import '../services/media/media_extractor_service.dart';
import '../services/updater/github_release_updater.dart';
import 'vault_storage_actions.dart';

export 'vault_storage_actions.dart' show UrlAnalysisResult;

/// Central controller wiring settings, history, queue manager, native bridges, and UI.
class AppController extends ChangeNotifier {
  AppController({
    required this.translator,
    SettingsRepository? settingsRepository,
    DownloadHistoryManager? historyManager,
    DownloadQueueManager? queueManager,
    MediaExtractorService? extractorService,
    YoutubeDlChannel? youtubeDlChannel,
    ShareIntentChannel? shareIntentChannel,
    MediaStoreChannel? mediaStoreChannel,
    ForegroundServiceChannel? foregroundServiceChannel,
    CookiesChannel? cookiesChannel,
    GitHubReleaseUpdater? updater,
    this.autoInitNative = true,
  })  : _settingsRepo = settingsRepository,
        _history = historyManager,
        _queue = queueManager,
        _youtubeDl = youtubeDlChannel ?? YoutubeDlChannel(),
        _extractor = extractorService ??
            MediaExtractorService(channel: youtubeDlChannel ?? YoutubeDlChannel()),
        _shareIntent = shareIntentChannel ?? ShareIntentChannel(),
        _mediaStore = mediaStoreChannel ?? MediaStoreChannel(),
        _foregroundService = foregroundServiceChannel ?? ForegroundServiceChannel(),
        _cookies = cookiesChannel ?? CookiesChannel(),
        _updater = updater ??
            GitHubReleaseUpdater(
              mediaStoreChannel: mediaStoreChannel ?? MediaStoreChannel(),
            );

  final AppTranslator translator;
  final bool autoInitNative;
  final YoutubeDlChannel _youtubeDl;
  final MediaExtractorService _extractor;
  final ShareIntentChannel _shareIntent;
  final MediaStoreChannel _mediaStore;
  final ForegroundServiceChannel _foregroundService;
  final CookiesChannel _cookies;
  final GitHubReleaseUpdater _updater;

  SettingsRepository? _settingsRepo;
  DownloadHistoryManager? _history;
  DownloadQueueManager? _queue;

  AppSettings _settings = const AppSettings();
  final List<String> _stagedUrls = <String>[];
  final StreamController<String> _incomingSharedCtrl =
      StreamController<String>.broadcast();
  StreamSubscription<List<String>>? _shareSub;

  bool _initialized = false;
  bool _nativeReady = false;
  String _ytdlpVersion = '';
  bool _isExtracting = false;
  String? _activeExtractProcessId;
  int _jobCounter = 0;

  late final VaultStorageActions _vaultActions = VaultStorageActions(
    mediaStore: _mediaStore,
    cookies: _cookies,
    historyProvider: () => _history,
    settingsProvider: () => _settings,
    saveSettings: updateSettings,
  );

  bool get isInitialized => _initialized;
  bool get nativeReady => _nativeReady;
  String get ytdlpVersion => _ytdlpVersion;
  bool get isExtracting => _isExtracting;
  AppSettings get settings => _settings;
  List<String> get stagedUrls => List<String>.unmodifiable(_stagedUrls);
  Stream<String> get sharedUrlsStream => _incomingSharedCtrl.stream;
  GitHubReleaseUpdater get updater => _updater;
  DownloadHistoryManager? get historyManager => _history;
  DownloadQueueManager? get queueManager => _queue;

  ThemeMode get themeMode => switch (_settings.themeMode) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };

  Future<void> initialize() async {
    if (_initialized) return;
    _settingsRepo ??= await SettingsRepository.create();
    _settings = _settingsRepo!.load();
    await translator.setLanguage(_settings.language);

    if (_history == null) {
      final dir = await getApplicationSupportDirectory();
      _history = DownloadHistoryManager(
        storage: HistoryStorage(p.join(dir.path, 'history.json')),
      );
      await _history!.load();
    } else if (_history!.entries.isEmpty) {
      await _history!.load();
    }
    _history!.addListener(notifyListeners);

    _queue ??= DownloadQueueManager(
      settings: _settings,
      foregroundService: _foregroundService,
      pauseLabel: translator.tr('notif_pause_all'),
      cancelLabel: translator.tr('notif_cancel_all'),
      coordinatorFactory: (req, {required onStateChanged}) =>
          StreamDownloadCoordinator(
        request: req,
        youtubeDlChannel: _youtubeDl,
        mediaStoreChannel: _mediaStore,
        ffmpegProcessor: FfmpegMediaProcessor(channel: _youtubeDl),
        historyManager: _history,
        onStateChanged: onStateChanged,
      ),
    );
    _queue!.addListener(notifyListeners);

    try {
      final initial = await _shareIntent.consumeInitialSharedUrls();
      for (final u in initial) {
        if (!_stagedUrls.contains(u)) _stagedUrls.add(u);
      }
    } catch (_) {}

    try {
      _shareSub = _shareIntent.sharedUrlsStream.listen(
        (urls) {
          for (final u in urls) {
            _incomingSharedCtrl.add(u);
          }
        },
        onError: (_) {},
      );
    } catch (_) {}

    _initialized = true;
    notifyListeners();

    if (autoInitNative) {
      unawaited(_initNativeEngineInBackground());
    }
  }

  Future<void> _initNativeEngineInBackground() async {
    try {
      final status = await _youtubeDl.initialize();
      _nativeReady = status.initialized;
      _ytdlpVersion = status.ytdlpVersion;
      notifyListeners();
    } catch (_) {}
  }

  Future<UrlAnalysisResult> analyzeUrl(String rawUrl) async {
    final url = rawUrl.trim();
    if (!UrlDetector.isMediaUrl(url)) {
      return UrlAnalysisResult(url: url);
    }
    final pid = 'extract_${DateTime.now().microsecondsSinceEpoch}';
    _activeExtractProcessId = pid;
    _isExtracting = true;
    notifyListeners();
    try {
      final cookies = _effectiveCookiesFile();
      final info = await _extractor.extractInfo(
        url,
        cookiesFile: cookies,
        processId: pid,
      );
      return UrlAnalysisResult(url: url, mediaInfo: info);
    } finally {
      if (_activeExtractProcessId == pid) _activeExtractProcessId = null;
      _isExtracting = false;
      notifyListeners();
    }
  }

  Future<void> cancelActiveExtraction() async {
    final pid = _activeExtractProcessId;
    _activeExtractProcessId = null;
    _isExtracting = false;
    notifyListeners();
    if (pid != null) {
      await _extractor.cancelExtraction(pid).catchError((_) => false);
    }
  }

  void stageUrl(String rawUrl) {
    final url = rawUrl.trim();
    if (url.isEmpty || _stagedUrls.contains(url)) return;
    _stagedUrls.insert(0, url);
    notifyListeners();
  }

  int stageUrls(Iterable<String> rawUrls) {
    var added = 0;
    for (final raw in rawUrls) {
      final url = raw.trim();
      if (url.isNotEmpty && !_stagedUrls.contains(url)) {
        _stagedUrls.insert(0, url);
        added++;
      }
    }
    if (added > 0) notifyListeners();
    return added;
  }

  void removeStagedUrl(String url) {
    if (_stagedUrls.remove(url)) notifyListeners();
  }

  Future<void> startAllStaged() async {
    final copy = List<String>.from(_stagedUrls);
    _stagedUrls.clear();
    notifyListeners();
    for (final url in copy) {
      enqueueSmartDownload(url);
    }
  }

  DownloadJobState enqueueSmartDownload(
    String url, {
    String? customTitle,
    int durationSec = 0,
  }) {
    if (!UrlDetector.isMediaUrl(url)) {
      return enqueueDirectDownload(url, customTitle: customTitle);
    }
    return _enqueueBasicRequest(
      url,
      customTitle: customTitle,
      durationSec: durationSec,
      forceMediaPipeline: true,
      preferredVideoHeight: _settings.preferredVideoHeight,
    );
  }

  DownloadJobState enqueueDirectDownload(String url, {String? customTitle}) =>
      _enqueueBasicRequest(url, customTitle: customTitle);

  DownloadJobState _enqueueBasicRequest(
    String url, {
    String? customTitle,
    int durationSec = 0,
    bool forceMediaPipeline = false,
    int preferredVideoHeight = 0,
  }) {
    final trimmed = url.trim();
    _stagedUrls.remove(trimmed);
    _stagedUrls.remove(url);
    final uri = Uri.tryParse(trimmed);
    final rawName = (customTitle?.trim().isNotEmpty ?? false)
        ? customTitle!.trim()
        : (uri != null && uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'download');
    final safeTitle = sanitizeFilename(rawName, fallback: 'download');
    final id = 'job_${DateTime.now().millisecondsSinceEpoch}_${++_jobCounter}';
    final req = DownloadJobRequest(
      id: id,
      url: trimmed,
      title: safeTitle,
      maxConnections: _settings.maxConnections,
      speedLimitBytesPerSec: _settings.speedLimitBytesPerSec,
      cookiesFile: _effectiveCookiesFile(),
      platform: UrlDetector.extractMediaPlatform(trimmed) ??
          (forceMediaPipeline ? 'Media' : 'Direct'),
      durationSec: durationSec,
      customSaveTreeUri: _settings.customSaveTreeUri,
      autoCategorizeFolders: _settings.autoCategorizeFolders,
      subtitlePosition: _settings.subtitlePosition,
      subtitleFontSize: _settings.subtitleFontSize,
      forceMediaPipeline: forceMediaPipeline,
      preferredVideoHeight: preferredVideoHeight,
    );
    return _queue!.enqueue(req);
  }

  DownloadJobState enqueueMediaJob(DownloadJobRequest request) {
    _stagedUrls.remove(request.url);
    final id = request.id.trim().isEmpty
        ? 'job_${DateTime.now().millisecondsSinceEpoch}_${++_jobCounter}'
        : request.id;
    final effective = DownloadJobRequest(
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
      cookiesFile: request.cookiesFile ?? _effectiveCookiesFile(),
      maxConnections: _settings.maxConnections,
      speedLimitBytesPerSec: _settings.speedLimitBytesPerSec,
      categorySubFolder: request.categorySubFolder,
      platform: request.platform,
      durationSec: request.durationSec,
      customSaveTreeUri: _settings.customSaveTreeUri,
      autoCategorizeFolders: _settings.autoCategorizeFolders,
      subtitlePosition: _settings.subtitlePosition,
      subtitleFontSize: _settings.subtitleFontSize,
    );
    return _queue!.enqueue(effective);
  }

  Future<void> updateSettings(AppSettings next) async {
    final langChanged = next.language != _settings.language;
    _settings = next;
    if (langChanged) {
      await translator.setLanguage(next.language);
      _queue?.updateNotificationLabels(
        pauseLabel: translator.tr('notif_pause_all'),
        cancelLabel: translator.tr('notif_cancel_all'),
      );
    }
    await _settingsRepo?.save(next);
    _queue?.updateSettings(next);
    notifyListeners();
  }

  Future<NativeUpdateResult> updateYtDlpEngine() async {
    final res = await _youtubeDl.updateYoutubeDL();
    _ytdlpVersion = res.ytdlpVersion;
    notifyListeners();
    return res;
  }

  Future<int> saveWebViewCookies(List<String> urls) => _vaultActions.saveWebViewCookies(urls);
  Future<void> clearCookies() => _vaultActions.clearCookies();

  Future<bool> openVaultEntry(HistoryEntry entry) => _vaultActions.openEntry(entry);
  Future<bool> shareVaultEntry(HistoryEntry entry) => _vaultActions.shareEntry(entry);
  Future<void> deleteVaultEntry(HistoryEntry entry, {required bool deleteFile}) =>
      _vaultActions.deleteEntry(entry, deleteFile: deleteFile);
  Future<void> removeHistoryEntry(String id, {bool deleteFile = false}) async =>
      _history?.remove(id, deleteFile: deleteFile);
  Future<bool> pickCustomSaveDirectory() => _vaultActions.pickCustomSaveDirectory();
  Future<void> resetSaveDirectory() => _vaultActions.resetSaveDirectory();
  Future<SubtitleTrack?> pickExternalSubtitleFile() => _vaultActions.pickExternalSubtitleFile();
  Future<void> requestNotificationPermissionOnce() =>
      _vaultActions.requestNotificationPermissionOnce();

  String? _effectiveCookiesFile() {
    final path = _settings.cookiesFilePath.trim();
    if (path.isEmpty || !File(path).existsSync()) return null;
    return path;
  }

  @override
  void dispose() {
    unawaited(_shareSub?.cancel());
    unawaited(_incomingSharedCtrl.close());
    _history?.removeListener(notifyListeners);
    _queue?.removeListener(notifyListeners);
    super.dispose();
  }
}
