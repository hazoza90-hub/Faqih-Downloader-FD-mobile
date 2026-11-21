import 'package:faqih_downloader_mobile/core/models/download_chunk.dart';
import 'package:faqih_downloader_mobile/engine/dynamic_splitter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const splitter = DynamicSplitter();

  group('DynamicSplitter', () {
    test('builds contiguous initial chunks covering exact byte span', () {
      final chunks = splitter.buildInitialChunks(
        totalSize: 1000003,
        supportsRanges: true,
        maxConnections: 6,
        minSplitThreshold: 128 * 1024,
        destinationPath: '/tmp/movie.mp4',
      );

      expect(chunks.length, 6);
      expect(chunks.first.startByte, 0);
      expect(chunks.last.endByte, 1000002);
      for (var i = 0; i < chunks.length - 1; i++) {
        expect(chunks[i].endByte + 1, chunks[i + 1].startByte);
      }
    });

    test('splits largest active chunk cleanly with zero gaps or overlaps', () {
      final chunks = <DownloadChunk>[
        const DownloadChunk(
          chunkId: 0,
          startByte: 0,
          endByte: 199999,
          downloadedBytes: 200000,
          status: ChunkStatus.completed,
        ),
        const DownloadChunk(
          chunkId: 1,
          startByte: 200000,
          endByte: 999999,
          downloadedBytes: 100000,
          status: ChunkStatus.active,
        ),
      ];

      final decision = splitter.trySplit(
        chunks: chunks,
        maxConnections: 4,
        minSplitThreshold: 128 * 1024,
        destinationPath: '/tmp/movie.mp4',
      );

      expect(decision, isNotNull);
      expect(decision!.updatedParent.chunkId, 1);
      expect(decision.updatedParent.endByte + 1, decision.newChild.startByte);
      expect(decision.newChild.endByte, 999999);
      expect(decision.newChild.chunkId, 2);
      expect(decision.newChild.downloadedBytes, 0);
      expect(decision.newChild.status, ChunkStatus.pending);
    });

    test('respects maxConnections, threshold guard, and unknown-size streams', () {
      const activeChunk = DownloadChunk(
        chunkId: 0,
        startByte: 0,
        endByte: 200000,
        status: ChunkStatus.active,
      );

      expect(
        splitter.trySplit(
          chunks: const <DownloadChunk>[activeChunk],
          maxConnections: 1,
          minSplitThreshold: 1024,
          destinationPath: '/tmp/file.bin',
        ),
        isNull,
      );

      expect(
        splitter.trySplit(
          chunks: const <DownloadChunk>[activeChunk],
          maxConnections: 4,
          minSplitThreshold: 128 * 1024,
          destinationPath: '/tmp/file.bin',
        ),
        isNull,
      );

      expect(
        splitter.trySplit(
          chunks: const <DownloadChunk>[
            DownloadChunk(
              chunkId: 0,
              startByte: 0,
              endByte: -1,
              status: ChunkStatus.active,
            ),
          ],
          maxConnections: 4,
          minSplitThreshold: 1024,
          destinationPath: '/tmp/live.bin',
        ),
        isNull,
      );
    });
  });
}
