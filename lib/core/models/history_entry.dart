import 'package:flutter/foundation.dart';

import 'download_status.dart';

/// Persistent record of a staged, active, or completed download in history.
@immutable
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.url,
    required this.filename,
    required this.filePath,
    required this.category,
    required this.totalSize,
    required this.downloadedBytes,
    required this.status,
    required this.createdAt,
    this.completedAt,
    this.platform = 'Direct',
    this.resolution,
  });

  final String id;
  final String url;
  final String filename;
  final String filePath;
  final String category;
  final int totalSize;
  final int downloadedBytes;
  final DownloadStatus status;
  final DateTime createdAt;
  final DateTime? completedAt;
  final String platform;
  final String? resolution;

  HistoryEntry copyWith({
    String? id,
    String? url,
    String? filename,
    String? filePath,
    String? category,
    int? totalSize,
    int? downloadedBytes,
    DownloadStatus? status,
    DateTime? createdAt,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    String? platform,
    String? resolution,
    bool clearResolution = false,
  }) {
    return HistoryEntry(
      id: id ?? this.id,
      url: url ?? this.url,
      filename: filename ?? this.filename,
      filePath: filePath ?? this.filePath,
      category: category ?? this.category,
      totalSize: totalSize ?? this.totalSize,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
      platform: platform ?? this.platform,
      resolution: clearResolution ? null : (resolution ?? this.resolution),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'url': url,
      'filename': filename,
      'filePath': filePath,
      'category': category,
      'totalSize': totalSize,
      'downloadedBytes': downloadedBytes,
      'status': status.name,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'completedAt': completedAt?.toUtc().toIso8601String(),
      'platform': platform,
      'resolution': resolution,
    };
  }

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    final completedRaw = json['completedAt']?.toString();
    return HistoryEntry(
      id: json['id']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      filename: json['filename']?.toString() ?? '',
      filePath: json['filePath']?.toString() ?? '',
      category: json['category']?.toString() ?? 'Other',
      totalSize: _toInt(json['totalSize']),
      downloadedBytes: _toInt(json['downloadedBytes']),
      status: parseDownloadStatus(json['status']?.toString()),
      createdAt: _parseDate(json['createdAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      completedAt: _parseDate(completedRaw),
      platform: json['platform']?.toString() ?? 'Direct',
      resolution: json['resolution']?.toString(),
    );
  }

  static int _toInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? 0;
    return 0;
  }

  static DateTime? _parseDate(Object? raw) {
    if (raw == null) return null;
    final str = raw.toString().trim();
    if (str.isEmpty) return null;
    return DateTime.tryParse(str);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is HistoryEntry &&
        other.id == id &&
        other.url == url &&
        other.filename == filename &&
        other.filePath == filePath &&
        other.category == category &&
        other.totalSize == totalSize &&
        other.downloadedBytes == downloadedBytes &&
        other.status == status &&
        other.createdAt == createdAt &&
        other.completedAt == completedAt &&
        other.platform == platform &&
        other.resolution == resolution;
  }

  @override
  int get hashCode => Object.hash(
    id,
    url,
    filename,
    filePath,
    category,
    totalSize,
    downloadedBytes,
    status,
    createdAt,
    completedAt,
    platform,
    resolution,
  );
}
