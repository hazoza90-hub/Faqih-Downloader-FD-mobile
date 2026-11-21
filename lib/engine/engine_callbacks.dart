import 'package:flutter/foundation.dart';

import '../core/models/download_chunk.dart';
import '../core/models/download_status.dart';

/// Immutable snapshot of active download engine progress and chunk states.
@immutable
class EngineProgressSnapshot {
  const EngineProgressSnapshot({
    required this.downloadedBytes,
    required this.totalBytes,
    required this.speedBytesPerSec,
    required this.etaSeconds,
    required this.activeWorkers,
    required this.status,
    required this.chunks,
  });

  final int downloadedBytes;
  final int totalBytes;
  final double speedBytesPerSec;
  final double etaSeconds;
  final int activeWorkers;
  final DownloadStatus status;
  final List<DownloadChunk> chunks;

  double get progressRatio {
    if (totalBytes <= 0) {
      return status == DownloadStatus.completed ? 1.0 : 0.0;
    }
    return (downloadedBytes / totalBytes).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'downloadedBytes': downloadedBytes,
      'totalBytes': totalBytes,
      'speedBytesPerSec': speedBytesPerSec,
      'etaSeconds': etaSeconds,
      'activeWorkers': activeWorkers,
      'status': status.name,
      'chunks': chunks.map((c) => c.toJson()).toList(growable: false),
    };
  }

  factory EngineProgressSnapshot.fromMap(Map<String, dynamic> map) {
    final rawChunks = map['chunks'];
    final parsedChunks = rawChunks is List
        ? rawChunks
            .whereType<Map>()
            .map((m) => DownloadChunk.fromJson(Map<String, dynamic>.from(m)))
            .toList(growable: false)
        : const <DownloadChunk>[];

    return EngineProgressSnapshot(
      downloadedBytes: (map['downloadedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
      speedBytesPerSec: (map['speedBytesPerSec'] as num?)?.toDouble() ?? 0.0,
      etaSeconds: (map['etaSeconds'] as num?)?.toDouble() ?? -1.0,
      activeWorkers: (map['activeWorkers'] as num?)?.toInt() ?? 0,
      status: parseDownloadStatus(map['status']?.toString()),
      chunks: List<DownloadChunk>.unmodifiable(parsedChunks),
    );
  }
}

/// Callback hooks emitted by [TurboDownloadEngine] and [IsolateDownloadRunner].
class EngineCallbacks {
  const EngineCallbacks({
    this.onProgress,
    this.onLog,
    this.onComplete,
    this.onError,
  });

  final void Function(EngineProgressSnapshot snapshot)? onProgress;
  final void Function(String message)? onLog;
  final void Function(String filePath, int totalBytes, double elapsedSeconds)?
      onComplete;
  final void Function(Object error, {bool linkExpired, int? httpStatus})?
      onError;
}
