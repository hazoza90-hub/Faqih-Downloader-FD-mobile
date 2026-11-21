import 'package:flutter/foundation.dart';

/// Execution status of an individual HTTP byte-range chunk.
enum ChunkStatus {
  pending,
  active,
  completed,
  failed,
}

ChunkStatus parseChunkStatus(
  String? raw, {
  ChunkStatus fallback = ChunkStatus.pending,
}) {
  if (raw == null || raw.trim().isEmpty) {
    return fallback;
  }
  final normalized = raw.trim().toLowerCase();
  for (final value in ChunkStatus.values) {
    if (value.name.toLowerCase() == normalized) {
      return value;
    }
  }
  return fallback;
}

/// Represents a discrete contiguous byte range of a target download file.
@immutable
class DownloadChunk {
  const DownloadChunk({
    required this.chunkId,
    required this.startByte,
    required this.endByte,
    this.downloadedBytes = 0,
    this.status = ChunkStatus.pending,
    this.partFilepath = '',
    this.errorMsg = '',
  });

  final int chunkId;
  final int startByte;
  final int endByte;
  final int downloadedBytes;
  final ChunkStatus status;
  final String partFilepath;
  final String errorMsg;

  int get totalBytes {
    if (endByte < startByte) {
      return 0;
    }
    return endByte - startByte + 1;
  }

  int get currentByte => startByte + downloadedBytes;

  int get remainingBytes {
    final remaining = endByte - currentByte + 1;
    return remaining > 0 ? remaining : 0;
  }

  bool get isCompleted => status == ChunkStatus.completed;

  double get progressPct {
    final total = totalBytes;
    if (total <= 0) {
      return 100.0;
    }
    final pct = (downloadedBytes / total) * 100.0;
    if (pct < 0.0) {
      return 0.0;
    }
    if (pct > 100.0) {
      return 100.0;
    }
    return pct;
  }

  DownloadChunk copyWith({
    int? chunkId,
    int? startByte,
    int? endByte,
    int? downloadedBytes,
    ChunkStatus? status,
    String? partFilepath,
    String? errorMsg,
  }) {
    return DownloadChunk(
      chunkId: chunkId ?? this.chunkId,
      startByte: startByte ?? this.startByte,
      endByte: endByte ?? this.endByte,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      status: status ?? this.status,
      partFilepath: partFilepath ?? this.partFilepath,
      errorMsg: errorMsg ?? this.errorMsg,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'chunkId': chunkId,
      'startByte': startByte,
      'endByte': endByte,
      'downloadedBytes': downloadedBytes,
      'status': status.name,
      'partFilepath': partFilepath,
      'errorMsg': errorMsg,
    };
  }

  factory DownloadChunk.fromJson(Map<String, dynamic> json) {
    return DownloadChunk(
      chunkId: _toInt(json['chunkId']),
      startByte: _toInt(json['startByte']),
      endByte: _toInt(json['endByte']),
      downloadedBytes: _toInt(json['downloadedBytes']),
      status: parseChunkStatus(json['status']?.toString()),
      partFilepath: json['partFilepath']?.toString() ?? '',
      errorMsg: json['errorMsg']?.toString() ?? '',
    );
  }

  static int _toInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? 0;
    return 0;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DownloadChunk &&
        other.chunkId == chunkId &&
        other.startByte == startByte &&
        other.endByte == endByte &&
        other.downloadedBytes == downloadedBytes &&
        other.status == status &&
        other.partFilepath == partFilepath &&
        other.errorMsg == errorMsg;
  }

  @override
  int get hashCode => Object.hash(
    chunkId,
    startByte,
    endByte,
    downloadedBytes,
    status,
    partFilepath,
    errorMsg,
  );
}
