import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/models/download_status.dart';
import '../../core/models/history_entry.dart';
import '../../core/utils/category_classifier.dart';
import '../../engine/engine_callbacks.dart';
import '../../engine/isolate_download_runner.dart';
import '../history/history_manager.dart';
import '../media/media_exceptions.dart';
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

  static String extractUrlExtension(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    return ext.isEmpty || ext.length > 6 ? 'bin' : ext;
  }

  static String mimeTypeForExt(String ext) {
    const map = <String, String>{
      'mp4': 'video/mp4',
      'mkv': 'video/x-matroska',
      'webm': 'video/webm',
      'mp3': 'audio/mpeg',
      'm4a': 'audio/mp4',
      'aac': 'audio/aac',
      'pdf': 'application/pdf',
      'zip': 'application/zip',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
    };
    return map[ext.toLowerCase()] ?? 'application/octet-stream';
  }
}
