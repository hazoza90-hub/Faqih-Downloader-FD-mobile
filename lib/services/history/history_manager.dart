import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/models/download_status.dart';
import '../../core/models/history_entry.dart';
import 'history_storage.dart';

enum KanbanBucket {
  staged,
  active,
  vault,
}

/// Manages persistent download history, Kanban bucket queries, and path reservations.
class DownloadHistoryManager extends ChangeNotifier {
  DownloadHistoryManager({
    required this.storage,
    this.maxEntries = 500,
  });

  final HistoryStorage storage;
  final int maxEntries;
  final List<HistoryEntry> _entries = <HistoryEntry>[];

  List<HistoryEntry> get entries => List<HistoryEntry>.unmodifiable(_entries);

  static KanbanBucket bucketForStatus(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.staged:
        return KanbanBucket.staged;
      case DownloadStatus.queued:
      case DownloadStatus.probing:
      case DownloadStatus.downloading:
      case DownloadStatus.paused:
      case DownloadStatus.merging:
      case DownloadStatus.postProcessing:
        return KanbanBucket.active;
      case DownloadStatus.completed:
      case DownloadStatus.failed:
      case DownloadStatus.cancelled:
        return KanbanBucket.vault;
    }
  }

  Future<void> load() async {
    final loaded = await storage.load();
    _entries
      ..clear()
      ..addAll(loaded.take(maxEntries));
    notifyListeners();
  }

  Future<HistoryEntry> upsert(
    HistoryEntry entry, {
    bool persist = true,
  }) async {
    final normalizedPath = _normalizePath(entry.filePath);
    final existingIdx = _entries.indexWhere((existing) {
      if (existing.id == entry.id) return true;
      if (normalizedPath.isEmpty || existing.filePath.trim().isEmpty) {
        return false;
      }
      final existingBucket = bucketForStatus(existing.status);
      final incomingBucket = bucketForStatus(entry.status);
      if (existingBucket == KanbanBucket.vault &&
          incomingBucket == KanbanBucket.vault &&
          existing.id != entry.id) {
        return false;
      }
      return _normalizePath(existing.filePath) == normalizedPath;
    });

    if (existingIdx >= 0) {
      _entries.removeAt(existingIdx);
    }

    _entries.insert(0, entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }

    if (persist) {
      await storage.save(_entries);
    }
    notifyListeners();
    return entry;
  }

  Future<HistoryEntry?> updateStatus(
    String id,
    DownloadStatus status, {
    int? downloadedBytes,
    int? totalSize,
    DateTime? completedAt,
    bool persist = true,
  }) async {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return null;

    final updated = _entries[index].copyWith(
      status: status,
      downloadedBytes: downloadedBytes,
      totalSize: totalSize,
      completedAt: completedAt,
    );
    _entries[index] = updated;

    if (persist) {
      await storage.save(_entries);
    }
    notifyListeners();
    return updated;
  }

  Future<bool> remove(
    String id, {
    bool deleteFile = false,
    bool persist = true,
  }) async {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return false;

    final removed = _entries.removeAt(index);
    if (deleteFile && removed.filePath.trim().isNotEmpty) {
      final file = File(removed.filePath);
      if (file.existsSync()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }

    if (persist) {
      await storage.save(_entries);
    }
    notifyListeners();
    return true;
  }

  Future<void> clear({
    KanbanBucket? bucket,
    bool persist = true,
  }) async {
    if (bucket == null) {
      _entries.clear();
    } else {
      _entries.removeWhere((e) => bucketForStatus(e.status) == bucket);
    }

    if (persist) {
      await storage.save(_entries);
    }
    notifyListeners();
  }

  List<HistoryEntry> query({
    KanbanBucket? bucket,
    String? category,
    String? searchQuery,
  }) {
    final catNorm = (category ?? '').trim().toLowerCase();
    final queryNorm = (searchQuery ?? '').trim().toLowerCase();

    return _entries.where((entry) {
      if (bucket != null && bucketForStatus(entry.status) != bucket) {
        return false;
      }
      if (catNorm.isNotEmpty &&
          catNorm != 'all' &&
          entry.category.trim().toLowerCase() != catNorm) {
        return false;
      }
      if (queryNorm.isNotEmpty) {
        final haystack =
            '${entry.filename} ${entry.url} ${entry.platform}'.toLowerCase();
        if (!haystack.contains(queryNorm)) {
          return false;
        }
      }
      return true;
    }).toList(growable: false);
  }

  Set<String> getActiveOrQueuedPaths() {
    return <String>{
      for (final entry in _entries)
        if (bucketForStatus(entry.status) != KanbanBucket.vault &&
            entry.filePath.trim().isNotEmpty)
          entry.filePath,
    };
  }

  static String _normalizePath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    return p.normalize(trimmed).toLowerCase();
  }
}
