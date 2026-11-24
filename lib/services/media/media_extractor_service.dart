import '../../core/models/youtube_stream_info.dart';
import '../../core/utils/url_detector.dart';
import '../../platform/native_models.dart';
import '../../platform/youtube_dl_channel.dart';
import 'format_ranker.dart';
import 'media_exceptions.dart';
import 'tiktok_fallback_extractor.dart';

/// Extracts ranked video, dubbing, and subtitle metadata via [YoutubeDlChannel].
class MediaExtractorService {
  MediaExtractorService({
    YoutubeDlChannel? channel,
    FormatRanker ranker = const FormatRanker(),
    TikTokFallbackExtractor? tiktokFallback,
  })  : _channel = channel ?? YoutubeDlChannel(),
        _ranker = ranker,
        _tiktokFallback = tiktokFallback ?? TikTokFallbackExtractor(ranker: ranker);

  final YoutubeDlChannel _channel;
  final FormatRanker _ranker;
  final TikTokFallbackExtractor _tiktokFallback;
  bool _autoUpdatedThisSession = false;
  Future<bool>? _inFlightAutoUpdate;

  static const List<String> _ytFallbackStrategies = <String>[
    '',
    'youtube:player_client=mweb,web_safari,ios',
  ];

  Future<YouTubeStreamInfo> extractInfo(
    String url, {
    String? cookiesFile,
    String? userAgent,
    Map<String, String>? headers,
    String? playlistItems,
    String? processId,
    int timeoutSeconds = 30,
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
    final cookieAttempts = _buildCookieAttempts(cleanUrl, cookiesFile);

    final firstPass = await _extractWithStrategies(
      cleanUrl: cleanUrl,
      processId: effectiveId,
      cookieAttempts: cookieAttempts,
      userAgent: userAgent,
      headers: headers,
      playlistItems: playlistItems,
      timeoutSeconds: timeoutSeconds,
    );
    if (firstPass.usable != null) return firstPass.usable!;

    if (UrlDetector.isTikTokUrl(cleanUrl)) {
      final fallback = await _tiktokFallback.extract(cleanUrl);
      if (fallback != null && _hasUsableStreams(fallback)) return fallback;
    }

    if (await _tryAutoUpdateOnce()) {
      final retryPass = await _extractWithStrategies(
        cleanUrl: cleanUrl,
        processId: effectiveId,
        cookieAttempts: cookieAttempts,
        userAgent: userAgent,
        headers: headers,
        playlistItems: playlistItems,
        timeoutSeconds: timeoutSeconds,
      );
      if (retryPass.usable != null) return retryPass.usable!;
      if (retryPass.bestPartial != null) return retryPass.bestPartial!;
      if (retryPass.lastError != null) throw retryPass.lastError!;
    }

    if (firstPass.bestPartial != null) return firstPass.bestPartial!;
    throw firstPass.lastError!;
  }

  Future<({YouTubeStreamInfo? usable, YouTubeStreamInfo? bestPartial, MediaExtractionException? lastError})>
      _extractWithStrategies({
    required String cleanUrl,
    required String processId,
    required List<String?> cookieAttempts,
    required String? userAgent,
    required Map<String, String>? headers,
    required String? playlistItems,
    required int timeoutSeconds,
  }) async {
    final strategies = UrlDetector.isYouTubeUrl(cleanUrl)
        ? <String?>[null, ..._ytFallbackStrategies]
        : const <String?>[null];

    MediaExtractionException? lastError;
    YouTubeStreamInfo? bestResult;
    for (final strategy in strategies) {
      for (final attemptCookie in cookieAttempts) {
        try {
          final info = await _runSingleExtract(
            cleanUrl: cleanUrl,
            processId: processId,
            cookiesFile: attemptCookie,
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
        }
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

  List<String?> _buildCookieAttempts(String cleanUrl, String? cookiesFile) {
    final trimmed = cookiesFile?.trim() ?? '';
    if (trimmed.isEmpty) return const <String?>[null];
    if (UrlDetector.isYouTubeUrl(cleanUrl)) return <String?>[null, trimmed];
    return <String?>[trimmed, null];
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
