import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/models/download_status.dart';
import '../../core/models/history_entry.dart';
import '../../core/utils/category_classifier.dart';
import '../../core/utils/filename_sanitizer.dart';
import '../../engine/engine_callbacks.dart';
import '../../engine/isolate_download_runner.dart';
import '../../engine/server_prober.dart';
import '../history/history_manager.dart';
import '../media/media_exceptions.dart';
import '../resolver/html_download_resolver.dart';
import 'download_job_models.dart';

class ExportPlan {
  const ExportPlan({
    required this.sourcePath,
    required this.displayName,
    required this.ext,
    required this.category,
  });

  final String sourcePath;
  final String displayName;
  final String ext;
  final String category;
}

/// Shared coordinator helpers for MIME lookup, category resolution, cleanup, and history writes.
abstract final class CoordinatorHelpers {
  static Future<void> cleanupDirectory(String? dirPath) async {
    if (dirPath == null) return;
    final dir = Directory(dirPath);
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!dir.existsSync()) return;
      try {
        await dir.delete(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }
  }
  static IsolateDownloadRunner defaultRunnerFactory({
    required String url,
    required String destinationPath,
    Map<String, String> headers = const <String, String>{},
    int maxConnections = 6,
    double speedLimitBytesPerSec = 0.0,
    EngineCallbacks? callbacks,
  }) =>
      IsolateDownloadRunner(
        url: url,
        destinationPath: destinationPath,
        headers: headers,
        maxConnections: maxConnections,
        speedLimitBytesPerSec: speedLimitBytesPerSec,
        callbacks: callbacks,
      );

  static Future<void> upsertHistory(
    DownloadHistoryManager? history, {
    required DownloadJobRequest request,
    required DownloadJobState state,
    required DownloadStatus status,
    String? filename,
    String? filePath,
    String? contentUri,
    String? category,
    int? totalSize,
    int? downloadedBytes,
    DateTime? completedAt,
  }) async {
    if (history == null) return;
    await history.upsert(
      HistoryEntry(
        id: request.id,
        url: request.url,
        filename: filename ?? state.title,
        filePath: filePath ?? state.exportedDisplayPath ?? '',
        category: category ?? state.category,
        totalSize: totalSize ?? state.totalBytes,
        downloadedBytes: downloadedBytes ?? state.downloadedBytes,
        status: status,
        createdAt: state.createdAt,
        completedAt: completedAt,
        platform: request.platform,
        resolution: state.resolution,
        contentUri: contentUri ?? state.exportedUri,
        errorMessage: state.errorMessage,
      ),
    );
  }

  static String resolveCategory(DownloadJobRequest request, String filename) {
    final custom = request.categorySubFolder?.trim() ?? '';
    return custom.isNotEmpty ? custom : classifyCategory(filename);
  }

  static bool isCancelledError(Object err) =>
      (err is MediaExtractionException &&
          err.kind == MediaErrorKind.cancelled) ||
      (err is MediaProcessingException && err.kind == MediaErrorKind.cancelled);

  static Future<ResolvedDownloadResult?> resolveDirectTarget(
    HtmlDownloadResolver resolver, {
    required String url,
    required Map<String, String> headers,
  }) async {
    ResolvedDownloadResult? resolved;
    try {
      resolved = await resolver.resolve(url, headers: headers);
    } on StateError {
      rethrow;
    } catch (_) {}
    if (resolved != null && resolved.isHtmlLanding) {
      throw const ProbeException(
        'Server returned an HTML web page instead of a binary file',
        isHtmlResponse: true,
      );
    }
    return resolved;
  }

  static String extractUrlExtension(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    return ext.isEmpty || ext.length > 6 ? 'bin' : ext;
  }

  static String resolveDirectDisplayName({
    required String requestTitle,
    required String requestUrl,
    required String effectiveUrl,
    ResolvedDownloadResult? resolved,
  }) {
    final resolvedName = resolved?.filename?.trim() ?? '';
    final resolvedExt = p.extension(resolvedName).replaceFirst('.', '').toLowerCase();
    final titleExt = p.extension(requestTitle.trim()).replaceFirst('.', '').toLowerCase();
    final urlExt = extractUrlExtension(effectiveUrl);
    final mimeExt = resolved != null ? extForMimeType(resolved.contentType) : null;

    var ext = 'bin';
    if (titleExt.isNotEmpty && titleExt != 'bin') {
      ext = titleExt;
    } else if (resolvedExt.isNotEmpty && resolvedExt != 'bin') {
      ext = resolvedExt;
    } else if (urlExt != 'bin') {
      ext = urlExt;
    } else if (mimeExt != null && mimeExt.isNotEmpty) {
      ext = mimeExt;
    }

    final reqSeg = Uri.tryParse(requestUrl)?.pathSegments.lastOrNull?.trim() ?? '';
    final cleanTitle = requestTitle.trim();
    final titleLooksGeneric = cleanTitle.isEmpty ||
        cleanTitle.toLowerCase() == 'download' ||
        cleanTitle.toLowerCase() == 'download.bin' ||
        (titleExt.isEmpty && (resolved?.resolvedFromHtml == true || cleanTitle == reqSeg));

    if (resolvedName.isNotEmpty &&
        ((resolved?.fromContentDisposition == true && (titleLooksGeneric || titleExt.isEmpty)) ||
            (resolved?.resolvedFromHtml == true && titleLooksGeneric))) {
      final hasGoodResolvedExt = resolvedExt.isNotEmpty && resolvedExt != 'bin';
      if (hasGoodResolvedExt) return sanitizeFilename(resolvedName, fallback: 'download.$ext');
      return '${sanitizeFilename(resolvedName, fallback: 'download')}.$ext';
    }

    return titleExt.isNotEmpty
        ? sanitizeFilename(cleanTitle, fallback: 'download.$ext')
        : '${sanitizeFilename(cleanTitle, fallback: 'download')}.$ext';
  }

  static String mimeTypeForExt(String ext) {
    const map = <String, String>{
      'mp4': 'video/mp4',
      'mkv': 'video/x-matroska',
      'webm': 'video/webm',
      'avi': 'video/x-msvideo',
      'mov': 'video/quicktime',
      'mp3': 'audio/mpeg',
      'm4a': 'audio/mp4',
      'aac': 'audio/aac',
      'wav': 'audio/wav',
      'flac': 'audio/flac',
      'ogg': 'audio/ogg',
      'opus': 'audio/opus',
      'apk': 'application/vnd.android.package-archive',
      'xapk': 'application/octet-stream',
      'zip': 'application/zip',
      'rar': 'application/vnd.rar',
      '7z': 'application/x-7z-compressed',
      'gz': 'application/gzip',
      'tar': 'application/x-tar',
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'txt': 'text/plain',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
      'gif': 'image/gif',
    };
    return map[ext.toLowerCase()] ?? 'application/octet-stream';
  }

  static String? extForMimeType(String mimeType) {
    final normalized = mimeType.split(';').first.trim().toLowerCase();
    const map = <String, String>{
      'application/vnd.android.package-archive': 'apk',
      'application/zip': 'zip',
      'application/x-zip-compressed': 'zip',
      'application/vnd.rar': 'rar',
      'application/x-rar-compressed': 'rar',
      'application/x-7z-compressed': '7z',
      'application/gzip': 'gz',
      'application/x-tar': 'tar',
      'application/pdf': 'pdf',
      'application/msword': 'doc',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
      'application/vnd.ms-excel': 'xls',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
      'text/plain': 'txt',
      'video/mp4': 'mp4',
      'video/x-matroska': 'mkv',
      'video/webm': 'webm',
      'video/x-msvideo': 'avi',
      'video/quicktime': 'mov',
      'audio/mpeg': 'mp3',
      'audio/mp4': 'm4a',
      'audio/aac': 'aac',
      'audio/wav': 'wav',
      'audio/flac': 'flac',
      'audio/ogg': 'ogg',
      'audio/opus': 'opus',
      'image/jpeg': 'jpg',
      'image/png': 'png',
      'image/webp': 'webp',
      'image/gif': 'gif',
    };
    return map[normalized];
  }
}
