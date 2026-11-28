import '../../app/vault_storage_actions.dart';
import '../../core/utils/url_detector.dart';
import '../media/media_exceptions.dart';
import '../media/media_extractor_service.dart';
import 'html_candidate_parser.dart';
import 'html_download_resolver.dart';

/// Analyzes an arbitrary URL via media regex fast-path, HTML/APK resolver, and yt-dlp fallback.
class SmartUrlAnalyzer {
  SmartUrlAnalyzer({
    required MediaExtractorService extractor,
    HtmlDownloadResolver? htmlResolver,
  })  : _extractor = extractor,
        _htmlResolver = htmlResolver ?? HtmlDownloadResolver();

  final MediaExtractorService _extractor;
  final HtmlDownloadResolver _htmlResolver;

  Future<UrlAnalysisResult> analyze(
    String rawUrl, {
    String? cookiesFile,
    required String processId,
  }) async {
    final url = rawUrl.trim();
    if (UrlDetector.isMediaUrl(url)) {
      final info = await _extractor.extractInfo(
        url,
        cookiesFile: cookiesFile,
        processId: processId,
      );
      return UrlAnalysisResult(url: url, mediaInfo: info);
    }

    final effectiveUrl = HtmlCandidateParser.normalizeDirectUrl(url);
    if (UrlDetector.isDirectDownloadUrl(effectiveUrl)) {
      return UrlAnalysisResult(url: effectiveUrl);
    }

    ResolvedDownloadResult? resolved;
    Object? resolverError;
    try {
      resolved = await _htmlResolver.resolve(effectiveUrl);
      if (!resolved.isHtmlLanding) {
        return UrlAnalysisResult(
          url: resolved.url,
          resolvedFilename: resolved.filename,
          resolvedHeaders: resolved.headers,
        );
      }
    } catch (e) {
      resolverError = e;
    }

    // Fallback for video platforms outside regex list (VK, Kick, Bilibili, SoundCloud, etc.)
    try {
      final info = await _extractor.extractInfo(
        url,
        cookiesFile: cookiesFile,
        processId: processId,
      );
      return UrlAnalysisResult(url: url, mediaInfo: info);
    } on MediaExtractionException catch (e) {
      if (e.kind == MediaErrorKind.cancelled) rethrow;
      if (e.kind == MediaErrorKind.unsupportedUrl && resolverError != null) {
        throw resolverError;
      }
      if (resolved != null && resolved.isHtmlLanding) {
        throw MediaExtractionException(
          kind: e.kind,
          message: e.message,
          rawDetails: e.rawDetails.isNotEmpty
              ? e.rawDetails
              : (resolverError?.toString() ?? ''),
        );
      }
      if (resolverError != null) rethrow;
      rethrow;
    }
  }
}
