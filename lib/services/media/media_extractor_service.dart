import '../../core/models/youtube_stream_info.dart';
import '../../core/utils/url_detector.dart';
import '../../platform/native_models.dart';
import '../../platform/youtube_dl_channel.dart';
import 'format_ranker.dart';
import 'media_exceptions.dart';
import 'tiktok_fallback_extractor.dart';
import 'youtube_innertube_extractor.dart';

/// Extracts ranked video, dubbing, and subtitle metadata via InnerTube and [YoutubeDlChannel].
class MediaExtractorService {
  MediaExtractorService({
    YoutubeDlChannel? channel,
    FormatRanker ranker = const FormatRanker(),
    TikTokFallbackExtractor? tiktokFallback,
    YouTubeInnerTubeExtractor? innerTubeExtractor,
    DateTime Function()? clock,
  })  : _channel = channel ?? YoutubeDlChannel(),
        _ranker = ranker,
        _tiktokFallback = tiktokFallback ?? TikTokFallbackExtractor(ranker: ranker),
        _innerTube = innerTubeExtractor ?? YouTubeInnerTubeExtractor(ranker: ranker),
        _clock = clock ?? DateTime.now;

  static const Duration cacheTtl = Duration(minutes: 3);
  static const int maxCacheEntries = 25;

  final YoutubeDlChannel _channel;
  final FormatRanker _ranker;
  final TikTokFallbackExtractor _tiktokFallback;
  final YouTubeInnerTubeExtractor _innerTube;
  final DateTime Function() _clock;
  final Set<String> _cancelledIds = <String>{};
  final Map<String, void Function()> _activeAborters = <String, void Function()>{};
  final Map<String, ({YouTubeStreamInfo info, DateTime cachedAt})> _cache =
      <String, ({YouTubeStreamInfo info, DateTime cachedAt})>{};
  bool _autoUpdatedThisSession = false;
  Future<bool>? _inFlightAutoUpdate;

  static const List<String> _ytFallbackStrategies = <String>[
    'youtube:player_client=ios,mweb',
    '',
  ];

  void _throwIfCancelled(String processId) {
    if (_cancelledIds.contains(processId)) {
      throw const MediaExtractionException(
        kind: MediaErrorKind.cancelled,
        message: 'Extraction cancelled',
      );
    }
  }

  YouTubeStreamInfo? _readCache(String key) {
    final entry = _cache.remove(key);
    if (entry == null) return null;
    if (_clock().difference(entry.cachedAt) > cacheTtl) return null;
    _cache[key] = entry;
    return entry.info;
  }

  void _writeCache(String key, YouTubeStreamInfo info) {
    if (!_hasUsableStreams(info)) return;
    _cache.remove(key);
    while (_cache.length >= maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = (info: info, cachedAt: _clock());
  }

  Future<YouTubeStreamInfo> extractInfo(
    String url, {
    String? cookiesFile,
    String? userAgent,
    Map<String, String>? headers,
    String? playlistItems,
    String? processId,
    int timeoutSeconds = 15,
  }) async {
    final cleanUrl = url.trim();
    if (!UrlDetector.isHttpUrl(cleanUrl)) {
      throw const MediaExtractionException(
        kind: MediaErrorKind.unsupportedUrl,
        message: 'Invalid or unsupported URL',
      );
    }

    final effectiveId =
        processId ?? 'extract_${DateTime.now().microsecondsSinceEpoch}';
    final trimmedPlaylist = playlistItems?.trim() ?? '';
    final cacheKey = '$cleanUrl|$trimmedPlaylist|${cookiesFile?.trim() ?? ''}';

    try {
      _throwIfCancelled(effectiveId);
      final cached = _readCache(cacheKey);
      if (cached != null) return cached;

      final isSingleYouTube = UrlDetector.extractYouTubeId(cleanUrl) != null &&
          !cleanUrl.toLowerCase().contains('/playlist?') &&
          trimmedPlaylist.isEmpty;
      if (isSingleYouTube) {
        final fast = await _innerTube.extract(
          cleanUrl,
          onRegisterAbort: (aborter) => _activeAborters[effectiveId] = aborter,
        );
        _activeAborters.remove(effectiveId);
        _throwIfCancelled(effectiveId);
        if (fast != null && _hasUsableStreams(fast)) {
          _writeCache(cacheKey, fast);
          return fast;
        }
      }

      if (UrlDetector.isTikTokUrl(cleanUrl)) {
        final fastTikTok = await _tiktokFallback.extract(cleanUrl);
        _throwIfCancelled(effectiveId);
        if (fastTikTok != null && _hasUsableStreams(fastTikTok)) {
          _writeCache(cacheKey, fastTikTok);
          return fastTikTok;
        }
      }

      final trimmedCookies = cookiesFile?.trim() ?? '';
      final firstPass = await _extractWithStrategies(
        cleanUrl: cleanUrl,
        processId: effectiveId,
        cookiesFile: trimmedCookies,
        userAgent: userAgent,
        headers: headers,
        playlistItems: playlistItems,
        timeoutSeconds: timeoutSeconds,
      );
      if (firstPass.usable != null) {
        _writeCache(cacheKey, firstPass.usable!);
        return firstPass.usable!;
      }
      _throwIfCancelled(effectiveId);

      final skipAutoUpdate = !UrlDetector.isMediaUrl(cleanUrl) &&
          firstPass.lastError?.kind == MediaErrorKind.unsupportedUrl;
      if (!skipAutoUpdate && await _tryAutoUpdateOnce()) {
        _throwIfCancelled(effectiveId);
        final retryPass = await _extractWithStrategies(
          cleanUrl: cleanUrl,
          processId: effectiveId,
          cookiesFile: trimmedCookies,
          userAgent: userAgent,
          headers: headers,
          playlistItems: playlistItems,
          timeoutSeconds: timeoutSeconds,
        );
        if (retryPass.usable != null) {
          _writeCache(cacheKey, retryPass.usable!);
          return retryPass.usable!;
        }
        if (retryPass.bestPartial != null) return retryPass.bestPartial!;
        if (retryPass.lastError != null) throw retryPass.lastError!;
      }

      if (firstPass.bestPartial != null) return firstPass.bestPartial!;
      throw firstPass.lastError!;
    } finally {
      _activeAborters.remove(effectiveId);
      _cancelledIds.remove(effectiveId);
    }
  }

  Future<({YouTubeStreamInfo? usable, YouTubeStreamInfo? bestPartial, MediaExtractionException? lastError})>
      _extractWithStrategies({
    required String cleanUrl,
    required String processId,
    required String cookiesFile,
    required String? userAgent,
    required Map<String, String>? headers,
    required String? playlistItems,
    required int timeoutSeconds,
  }) async {
    final isYouTube = UrlDetector.isYouTubeUrl(cleanUrl);
    final strategies = isYouTube ? <String?>[null, ..._ytFallbackStrategies] : const <String?>[null];

    MediaExtractionException? lastError;
    YouTubeStreamInfo? bestResult;

    if (isYouTube) {
      for (final strategy in strategies) {
        _throwIfCancelled(processId);
        try {
          final info = await _runSingleExtract(
            cleanUrl: cleanUrl,
            processId: processId,
            cookiesFile: null,
            userAgent: userAgent,
            headers: headers,
            playlistItems: playlistItems,
            timeoutSeconds: timeoutSeconds,
            extractorArgs: strategy,
          );
          if (_hasUsableStreams(info)) {
            return (usable: info, bestPartial: bestResult, lastError: lastError);
          }
          bestResult = info;
        } on MediaExtractionException catch (e) {
          if (e.kind == MediaErrorKind.cancelled) rethrow;
          lastError = e;
          if (e.kind == MediaErrorKind.loginRequired && cookiesFile.isNotEmpty) {
            break;
          }
        }
      }

      final shouldTryCookieOnce = cookiesFile.isNotEmpty &&
          (lastError == null ||
              lastError.kind == MediaErrorKind.loginRequired ||
              lastError.kind == MediaErrorKind.linkExpired ||
              lastError.kind == MediaErrorKind.unknown);
      if (shouldTryCookieOnce) {
        _throwIfCancelled(processId);
        try {
          final info = await _runSingleExtract(
            cleanUrl: cleanUrl,
            processId: processId,
            cookiesFile: cookiesFile,
            userAgent: userAgent,
            headers: headers,
            playlistItems: playlistItems,
            timeoutSeconds: timeoutSeconds,
            extractorArgs: 'youtube:player_client=mweb,web',
          );
          if (_hasUsableStreams(info)) {
            return (usable: info, bestPartial: bestResult, lastError: lastError);
          }
          bestResult = info;
        } on MediaExtractionException catch (e) {
          if (e.kind == MediaErrorKind.cancelled) rethrow;
          lastError = e;
        }
      }
      return (usable: null, bestPartial: bestResult, lastError: lastError);
    }

    final cookieAttempts = cookiesFile.isEmpty ? const <String?>[null] : <String?>[cookiesFile, null];
    for (final attemptCookie in cookieAttempts) {
      _throwIfCancelled(processId);
      try {
        final info = await _runSingleExtract(
          cleanUrl: cleanUrl,
          processId: processId,
          cookiesFile: attemptCookie,
          userAgent: userAgent,
          headers: headers,
          playlistItems: playlistItems,
          timeoutSeconds: timeoutSeconds,
          extractorArgs: null,
        );
        if (_hasUsableStreams(info)) {
          return (usable: info, bestPartial: bestResult, lastError: lastError);
        }
        bestResult = info;
      } on MediaExtractionException catch (e) {
        if (e.kind == MediaErrorKind.cancelled) rethrow;
        lastError = e;
      }
    }
    return (usable: null, bestPartial: bestResult, lastError: lastError);
  }

  Future<bool> _tryAutoUpdateOnce() async {
    if (_autoUpdatedThisSession) return false;
    final inFlight = _inFlightAutoUpdate;
    if (inFlight != null) return inFlight;

    _autoUpdatedThisSession = true;
    final fut = () async {
      try {
        final res = await _channel.updateYoutubeDL();
        return res.status.toUpperCase() == 'DONE';
      } catch (_) {
        return false;
      } finally {
        _inFlightAutoUpdate = null;
      }
    }();
    _inFlightAutoUpdate = fut;
    return fut;
  }

  Future<YouTubeStreamInfo> _runSingleExtract({
    required String cleanUrl,
    required String processId,
    required String? cookiesFile,
    required String? userAgent,
    required Map<String, String>? headers,
    required String? playlistItems,
    required int timeoutSeconds,
    String? extractorArgs,
  }) async {
    try {
      final rawJson = await _channel.extractInfo(
        url: cleanUrl,
        processId: processId,
        cookiesFile: cookiesFile,
        userAgent: userAgent,
        headers: headers,
        playlistItems: playlistItems,
        timeoutSeconds: timeoutSeconds,
        extractorArgs: extractorArgs,
      );
      if (rawJson.trim().isEmpty) {
        throw const MediaExtractionException(
          kind: MediaErrorKind.unknown,
          message: 'Extractor returned empty metadata',
        );
      }
      return _ranker.parseJsonString(rawJson, fallbackUrl: cleanUrl);
    } on NativeBridgeException catch (e) {
      final details = '${e.code}: ${e.message}';
      throw MediaExtractionException(
        kind: classifyError(details),
        message: e.message.isNotEmpty ? e.message : e.code,
        rawDetails: details,
      );
    } on FormatException catch (e) {
      throw MediaExtractionException(
        kind: MediaErrorKind.unknown,
        message: 'Failed to parse extractor JSON: ${e.message}',
        rawDetails: e.toString(),
      );
    }
  }

  static bool _hasUsableStreams(YouTubeStreamInfo info) =>
      info.isPlaylist ||
      info.videoFormats.isNotEmpty ||
      info.audioTracks.isNotEmpty ||
      info.videoUrl.isNotEmpty;

  Future<bool> cancelExtraction(String processId) {
    _cancelledIds.add(processId);
    _activeAborters.remove(processId)?.call();
    return _channel.cancelProcess(processId);
  }

  static MediaErrorKind classifyError(String rawError) {
    final lower = rawError.toLowerCase();
    if (lower.contains('cancel') || lower.contains('destroyed')) {
      return MediaErrorKind.cancelled;
    }
    if (lower.contains('unsupported url') ||
        lower.contains('no video formats found')) {
      return MediaErrorKind.unsupportedUrl;
    }
    if (lower.contains('sign in to confirm') ||
        lower.contains('sign in required') ||
        lower.contains('private video') ||
        lower.contains('login required') ||
        lower.contains('members-only') ||
        lower.contains('age-restricted')) {
      return MediaErrorKind.loginRequired;
    }
    if (lower.contains('not available in your country') ||
        lower.contains('geo') && lower.contains('block')) {
      return MediaErrorKind.geoBlocked;
    }
    if (lower.contains('http error 403') ||
        lower.contains('http error 410') ||
        lower.contains('403 forbidden') ||
        lower.contains('410 gone')) {
      return MediaErrorKind.linkExpired;
    }
    if (lower.contains('timed out') ||
        lower.contains('unable to download webpage') ||
        lower.contains('connection') ||
        lower.contains('network') ||
        lower.contains('socket')) {
      return MediaErrorKind.networkError;
    }
    return MediaErrorKind.unknown;
  }
}
