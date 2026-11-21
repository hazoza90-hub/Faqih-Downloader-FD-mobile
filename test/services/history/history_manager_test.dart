import 'dart:io';

import 'package:faqih_downloader_mobile/core/models/download_status.dart';
import 'package:faqih_downloader_mobile/core/models/history_entry.dart';
import 'package:faqih_downloader_mobile/core/utils/unique_path_resolver.dart';
import 'package:faqih_downloader_mobile/services/history/history_manager.dart';
import 'package:faqih_downloader_mobile/services/history/history_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late String storagePath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fd_history_test_');
    storagePath = p.join(tempDir.path, 'download_history.json');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  HistoryEntry makeEntry({
    required String id,
    required String filename,
    required String filePath,
    required DownloadStatus status,
    String category = 'Video',
    String platform = 'YouTube',
  }) {
    return HistoryEntry(
      id: id,
      url: 'https://example.com/$filename',
      filename: filename,
      filePath: filePath,
      category: category,
      totalSize: 1024,
      downloadedBytes: status == DownloadStatus.completed ? 1024 : 256,
      status: status,
      createdAt: DateTime.utc(2026, 11, 21, 12, 0),
      completedAt: status == DownloadStatus.completed
          ? DateTime.utc(2026, 11, 21, 12, 1)
          : null,
      platform: platform,
    );
  }

  group('DownloadHistoryManager & HistoryStorage', () {
    test('upserts, deduplicates active file paths, and persists atomically', () async {
      final manager = DownloadHistoryManager(storage: HistoryStorage(storagePath));
      await manager.load();

      await manager.upsert(
        makeEntry(
          id: 'dl_1',
          filename: 'lecture.mp4',
          filePath: '/downloads/Video/lecture.mp4',
          status: DownloadStatus.downloading,
        ),
      );

      // Same path with different ID while active replaces rather than duplicates.
      await manager.upsert(
        makeEntry(
          id: 'dl_2',
          filename: 'lecture.mp4',
          filePath: '/downloads/Video/lecture.mp4',
          status: DownloadStatus.paused,
        ),
      );

      expect(manager.entries.length, 1);
      expect(manager.entries.first.id, 'dl_2');
      expect(manager.entries.first.status, DownloadStatus.paused);

      // Reloading from disk into a fresh manager restores the exact entry.
      final reloaded = DownloadHistoryManager(storage: HistoryStorage(storagePath));
      await reloaded.load();
      expect(reloaded.entries, equals(manager.entries));
    });

    test('handles missing and corrupted JSON gracefully', () async {
      await File(storagePath).writeAsString('{corrupt-json!!!');
      final manager = DownloadHistoryManager(storage: HistoryStorage(storagePath));
      await manager.load();
      expect(manager.entries, isEmpty);
    });

    test('filters by KanbanBucket, category, and searchQuery, and reserves active paths', () async {
      final manager = DownloadHistoryManager(storage: HistoryStorage(storagePath));

      await manager.upsert(
        makeEntry(
          id: 's1',
          filename: 'course.zip',
          filePath: '/downloads/Compressed/course.zip',
          status: DownloadStatus.staged,
          category: 'Compressed',
          platform: 'Direct',
        ),
      );
      await manager.upsert(
        makeEntry(
          id: 'a1',
          filename: 'flutter_talk.mp4',
          filePath: '/downloads/Video/flutter_talk.mp4',
          status: DownloadStatus.downloading,
          category: 'Video',
          platform: 'YouTube',
        ),
      );
      await manager.upsert(
        makeEntry(
          id: 'v1',
          filename: 'nasheed.mp3',
          filePath: '/downloads/Music/nasheed.mp3',
          status: DownloadStatus.completed,
          category: 'Audio',
          platform: 'Direct',
        ),
      );

      expect(manager.query(bucket: KanbanBucket.staged).map((e) => e.id), ['s1']);
      expect(manager.query(bucket: KanbanBucket.active).map((e) => e.id), ['a1']);
      expect(manager.query(bucket: KanbanBucket.vault).map((e) => e.id), ['v1']);
      expect(manager.query(category: 'Audio').map((e) => e.id), ['v1']);
      expect(manager.query(searchQuery: 'flutter').map((e) => e.id), ['a1']);

      final reserved = manager.getActiveOrQueuedPaths();
      expect(reserved, contains('/downloads/Compressed/course.zip'));
      expect(reserved, contains('/downloads/Video/flutter_talk.mp4'));
      expect(reserved, isNot(contains('/downloads/Music/nasheed.mp3')));

      final unique = generateUniquePath(
        '/downloads/Video/flutter_talk.mp4',
        existsCheck: (_) => false,
        reservedPaths: reserved,
      );
      expect(unique, '/downloads/Video/flutter_talk (1).mp4');

      await manager.updateStatus(
        'a1',
        DownloadStatus.completed,
        downloadedBytes: 1024,
        completedAt: DateTime.utc(2026, 11, 21, 13, 0),
      );
      expect(manager.query(bucket: KanbanBucket.vault).length, 2);

      await manager.clear(bucket: KanbanBucket.staged);
      expect(manager.query(bucket: KanbanBucket.staged), isEmpty);
      expect(manager.entries.length, 2);
    });
  });
}
