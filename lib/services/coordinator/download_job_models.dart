import 'package:flutter/foundation.dart';

import '../../core/config/app_constants.dart';
import '../../core/models/audio_track.dart';
import '../../core/models/clip_range.dart';
import '../../core/models/download_status.dart';
import '../../core/models/subtitle_track.dart';
import '../../core/models/video_format_option.dart';
import '../../core/utils/url_detector.dart';

/// Fine-grained execution phases of a unified download job.
enum DownloadPhase {
  queued,
  probing,
  downloadingDirect,
  downloadingVideo,
  downloadingAudio,
  downloadingSubtitle,
  processingFfmpeg,
  exporting,
  completed,
  paused,
  cancelled,
  failed,
}

/// Strategy for handling subtitle tracks in video downloads.
enum SubtitleMode {
  none,
  softMux,
  hardBurn,
}

/// Maps fine-grained [DownloadPhase] values into persistence/Kanban [DownloadStatus].
DownloadStatus statusForPhase(DownloadPhase phase) {
  switch (phase) {
    case DownloadPhase.queued:
      return DownloadStatus.queued;
    case DownloadPhase.probing:
      return DownloadStatus.probing;
    case DownloadPhase.downloadingDirect:
    case DownloadPhase.downloadingVideo:
    case DownloadPhase.downloadingAudio:
    case DownloadPhase.downloadingSubtitle:
      return DownloadStatus.downloading;
    case DownloadPhase.processingFfmpeg:
      return DownloadStatus.merging;
    case DownloadPhase.exporting:
      return DownloadStatus.postProcessing;
    case DownloadPhase.completed:
      return DownloadStatus.completed;
    case DownloadPhase.paused:
      return DownloadStatus.paused;
    case DownloadPhase.cancelled:
      return DownloadStatus.cancelled;
    case DownloadPhase.failed:
      return DownloadStatus.failed;
  }
}

/// Immutable request payload describing a direct or media download job.
@immutable
class DownloadJobRequest {
  const DownloadJobRequest({
    required this.id,
    required this.url,
    required this.title,
    this.selectedVideoFormat,
    this.selectedAudioTrack,
    this.selectedSubtitle,
    this.subtitleMode = SubtitleMode.none,
    this.audioOnly = false,
    this.audioFormat = 'mp3',
    this.clipRange,
    this.headers = const <String, String>{},
    this.cookiesFile,
    this.maxConnections = AppConstants.defaultMaxConnections,
    this.speedLimitBytesPerSec = 0,
    this.categorySubFolder,
    this.platform = 'Direct',
    this.durationSec = 0,
    this.customSaveTreeUri = '',
    this.autoCategorizeFolders = true,
    this.subtitlePosition = 'bottom',
    this.subtitleFontSize = 20,
    this.forceMediaPipeline = false,
    this.preferredVideoHeight = 0,
    this.skipHtmlResolve = false,
  });

  final String id;
  final String url;
  final String title;
  final VideoFormatOption? selectedVideoFormat;
  final AudioTrack? selectedAudioTrack;
  final SubtitleTrack? selectedSubtitle;
  final SubtitleMode subtitleMode;
  final bool audioOnly;
  final String audioFormat;
  final ClipRange? clipRange;
  final Map<String, String> headers;
  final String? cookiesFile;
  final int maxConnections;
  final int speedLimitBytesPerSec;
  final String? categorySubFolder;
  final String platform;
  final int durationSec;
  final String customSaveTreeUri;
  final bool autoCategorizeFolders;
  final String subtitlePosition;
  final int subtitleFontSize;
  final bool forceMediaPipeline;
  final int preferredVideoHeight;
  final bool skipHtmlResolve;

  bool get isMediaJob =>
      selectedVideoFormat != null ||
      selectedAudioTrack != null ||
      audioOnly ||
      forceMediaPipeline ||
      UrlDetector.isMediaUrl(url);

  DownloadJobRequest copyWith({
    int? speedLimitBytesPerSec,
    int? maxConnections,
    bool? forceMediaPipeline,
    int? preferredVideoHeight,
    bool? skipHtmlResolve,
  }) {
    return DownloadJobRequest(
      id: id,
      url: url,
      title: title,
      selectedVideoFormat: selectedVideoFormat,
      selectedAudioTrack: selectedAudioTrack,
      selectedSubtitle: selectedSubtitle,
      subtitleMode: subtitleMode,
      audioOnly: audioOnly,
      audioFormat: audioFormat,
      clipRange: clipRange,
      headers: headers,
      cookiesFile: cookiesFile,
      maxConnections: maxConnections ?? this.maxConnections,
      speedLimitBytesPerSec:
          speedLimitBytesPerSec ?? this.speedLimitBytesPerSec,
      categorySubFolder: categorySubFolder,
      platform: platform,
      durationSec: durationSec,
      customSaveTreeUri: customSaveTreeUri,
      autoCategorizeFolders: autoCategorizeFolders,
      subtitlePosition: subtitlePosition,
      subtitleFontSize: subtitleFontSize,
      forceMediaPipeline: forceMediaPipeline ?? this.forceMediaPipeline,
      preferredVideoHeight: preferredVideoHeight ?? this.preferredVideoHeight,
      skipHtmlResolve: skipHtmlResolve ?? this.skipHtmlResolve,
    );
  }
}

/// Immutable UI/Queue state snapshot for a single download job card.
@immutable
class DownloadJobState {
  const DownloadJobState({
    required this.id,
    required this.title,
    required this.url,
    required this.phase,
    required this.status,
    required this.progress,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.speedBytesPerSec,
    required this.etaSeconds,
    this.errorMessage,
    this.exportedUri,
    this.exportedDisplayPath,
    required this.category,
    required this.createdAt,
    this.platform = 'Direct',
    this.resolution,
  });

  factory DownloadJobState.fromRequest(
    DownloadJobRequest request, {
    DateTime? createdAt,
    String category = 'Other',
  }) {
    return DownloadJobState(
      id: request.id,
      title: request.title,
      url: request.url,
      phase: DownloadPhase.queued,
      status: DownloadStatus.queued,
      progress: 0.0,
      downloadedBytes: 0,
      totalBytes: 0,
      speedBytesPerSec: 0.0,
      etaSeconds: -1.0,
      category: request.categorySubFolder ?? category,
      createdAt: createdAt ?? DateTime.now().toUtc(),
      platform: request.platform,
      resolution: request.selectedVideoFormat?.resolutionLabel,
    );
  }

  final String id;
  final String title;
  final String url;
  final DownloadPhase phase;
  final DownloadStatus status;
  final double progress;
  final int downloadedBytes;
  final int totalBytes;
  final double speedBytesPerSec;
  final double etaSeconds;
  final String? errorMessage;
  final String? exportedUri;
  final String? exportedDisplayPath;
  final String category;
  final DateTime createdAt;
  final String platform;
  final String? resolution;

  DownloadJobState copyWith({
    String? title,
    DownloadPhase? phase,
    DownloadStatus? status,
    double? progress,
    int? downloadedBytes,
    int? totalBytes,
    double? speedBytesPerSec,
    double? etaSeconds,
    String? errorMessage,
    bool clearErrorMessage = false,
    String? exportedUri,
    String? exportedDisplayPath,
    String? category,
    String? resolution,
  }) {
    final nextPhase = phase ?? this.phase;
    return DownloadJobState(
      id: id,
      title: title ?? this.title,
      url: url,
      phase: nextPhase,
      status: status ?? statusForPhase(nextPhase),
      progress: progress ?? this.progress,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      speedBytesPerSec: speedBytesPerSec ?? this.speedBytesPerSec,
      etaSeconds: etaSeconds ?? this.etaSeconds,
      errorMessage:
          clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      exportedUri: exportedUri ?? this.exportedUri,
      exportedDisplayPath: exportedDisplayPath ?? this.exportedDisplayPath,
      category: category ?? this.category,
      createdAt: createdAt,
      platform: platform,
      resolution: resolution ?? this.resolution,
    );
  }
}
