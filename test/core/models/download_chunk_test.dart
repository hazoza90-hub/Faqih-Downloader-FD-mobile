import 'package:faqih_downloader_mobile/core/models/download_chunk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadChunk', () {
    test('computes byte ranges, remaining bytes, and progress accurately', () {
      const chunk = DownloadChunk(
        chunkId: 0,
        startByte: 0,
        endByte: 999,
        downloadedBytes: 250,
        status: ChunkStatus.active,
        partFilepath: '/tmp/file.part0',
      );

      expect(chunk.totalBytes, 1000);
      expect(chunk.currentByte, 250);
      expect(chunk.remainingBytes, 750);
      expect(chunk.isCompleted, isFalse);
      expect(chunk.progressPct, closeTo(25.0, 0.001));
    });

    test('handles completed chunk and clamps over-downloaded progress', () {
      const chunk = DownloadChunk(
        chunkId: 2,
        startByte: 1000,
        endByte: 1999,
        downloadedBytes: 1200,
        status: ChunkStatus.completed,
      );

      expect(chunk.totalBytes, 1000);
      expect(chunk.currentByte, 2200);
      expect(chunk.remainingBytes, 0);
      expect(chunk.isCompleted, isTrue);
      expect(chunk.progressPct, 100.0);
    });

    test('handles zero or invalid bounds safely', () {
      const singleByte = DownloadChunk(
        chunkId: 1,
        startByte: 50,
        endByte: 50,
      );
      expect(singleByte.totalBytes, 1);
      expect(singleByte.remainingBytes, 1);
      expect(singleByte.progressPct, 0.0);

      const invalidRange = DownloadChunk(
        chunkId: 3,
        startByte: 500,
        endByte: 100,
      );
      expect(invalidRange.totalBytes, 0);
      expect(invalidRange.remainingBytes, 0);
      expect(invalidRange.progressPct, 100.0);
    });

    test('supports copyWith and JSON round-trip', () {
      const original = DownloadChunk(
        chunkId: 4,
        startByte: 2048,
        endByte: 4095,
        downloadedBytes: 512,
        status: ChunkStatus.failed,
        partFilepath: '/storage/emulated/0/Download/test.part4',
        errorMsg: 'Connection reset',
      );

      final json = original.toJson();
      final restored = DownloadChunk.fromJson(json);
      expect(restored, equals(original));

      final updated = restored.copyWith(
        status: ChunkStatus.completed,
        downloadedBytes: 2048,
        errorMsg: '',
      );
      expect(updated.isCompleted, isTrue);
      expect(updated.remainingBytes, 0);
      expect(updated.errorMsg, isEmpty);
    });
  });
}
