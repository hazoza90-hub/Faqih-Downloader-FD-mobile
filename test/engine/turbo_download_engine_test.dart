import 'dart:async';
import 'dart:io';

import 'package:faqih_downloader_mobile/core/models/download_status.dart';
import 'package:faqih_downloader_mobile/engine/chunk_persistence.dart';
import 'package:faqih_downloader_mobile/engine/engine_callbacks.dart';
import 'package:faqih_downloader_mobile/engine/turbo_download_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'mock_range_server.dart';

void main() {
  late Directory tempDir;
  late MockRangeServer server;
  final payload = generateTestPayload(512 * 1024, seed: 2026);
  final expectedSha = sha256HexOf(payload);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fd_engine_test_');
    server = await MockRangeServer.start(payload);
  });

  tearDown(() async {
    await server.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('TurboDownloadEngine', () {
    test('downloads multi-connection HTTP 206 with exact SHA-256 and cleanup', () async {
      final destPath = p.join(tempDir.path, 'multi.bin');
      String? completedPath;
      int? completedBytes;

      final engine = TurboDownloadEngine(
        url: server.fileUrl('/multi.bin'),
        destinationPath: destPath,
        maxConnections: 4,
        minSplitThreshold: 64 * 1024,
        expectedSha256: expectedSha,
        callbacks: EngineCallbacks(
          onComplete: (filePath, totalBytes, _) {
            completedPath = filePath;
            completedBytes = totalBytes;
          },
        ),
      );

      await engine.start();

      expect(engine.status, DownloadStatus.completed);
      expect(completedPath, destPath);
      expect(completedBytes, payload.length);
      expect(server.rangeGetCount, greaterThanOrEqualTo(4));
      expect(sha256HexOf(File(destPath).readAsBytesSync()), expectedSha);
      expect(Directory(ChunkPersistence.tempDirFor(destPath)).existsSync(), isFalse);
    });

    test('falls back to single-stream when ranges unsupported and length unknown', () async {
      server.supportRanges = false;
      server.unknownContentLength = true;
      final destPath = p.join(tempDir.path, 'stream.bin');

      final engine = TurboDownloadEngine(
        url: server.fileUrl('/stream.bin'),
        destinationPath: destPath,
        maxConnections: 6,
        expectedSha256: expectedSha,
      );

      await engine.start();

      expect(engine.status, DownloadStatus.completed);
      expect(engine.chunks.length, 1);
      expect(sha256HexOf(File(destPath).readAsBytesSync()), expectedSha);
    });

    test('persists checkpoint on pause and resumes accurately from a new engine', () async {
      server.streamSliceSize = 16 * 1024;
      server.chunkDelay = const Duration(milliseconds: 25);
      final destPath = p.join(tempDir.path, 'resumable.bin');

      final triggerPause = Completer<void>();
      final engine1 = TurboDownloadEngine(
        url: server.fileUrl('/resumable.bin'),
        destinationPath: destPath,
        maxConnections: 2,
        minSplitThreshold: 64 * 1024,
        callbacks: EngineCallbacks(
          onProgress: (snap) {
            if (snap.status == DownloadStatus.downloading &&
                snap.downloadedBytes >= 64 * 1024 &&
                !triggerPause.isCompleted) {
              triggerPause.complete();
            }
          },
        ),
      );

      final startFuture = engine1.start();
      await triggerPause.future;
      await engine1.pause();
      await startFuture;

      expect(engine1.status, DownloadStatus.paused);
      expect(File(ChunkPersistence.stateFilePathFor(destPath)).existsSync(), isTrue);
      expect(File(destPath).existsSync(), isFalse);

      // Resume using a brand-new TurboDownloadEngine instance with zero server delay.
      server.chunkDelay = Duration.zero;
      final engine2 = TurboDownloadEngine(
        url: server.fileUrl('/resumable.bin'),
        destinationPath: destPath,
        maxConnections: 2,
        minSplitThreshold: 64 * 1024,
        expectedSha256: expectedSha,
      );

      await engine2.start();

      expect(engine2.status, DownloadStatus.completed);
      expect(sha256HexOf(File(destPath).readAsBytesSync()), expectedSha);
      expect(Directory(ChunkPersistence.tempDirFor(destPath)).existsSync(), isFalse);
    });

    test('dynamically splits active chunks mid-flight without byte corruption', () async {
      server.streamSliceSize = 16 * 1024;
      server.chunkDelay = const Duration(milliseconds: 25);
      final destPath = p.join(tempDir.path, 'split.bin');

      final engine = TurboDownloadEngine(
        url: server.fileUrl('/split.bin'),
        destinationPath: destPath,
        maxConnections: 4,
        initialChunks: 1,
        minSplitThreshold: 32 * 1024,
        allowDynamicSplit: true,
        expectedSha256: expectedSha,
      );

      await engine.start();

      expect(engine.status, DownloadStatus.completed);
      expect(engine.chunks.length, greaterThan(1));
      expect(sha256HexOf(File(destPath).readAsBytesSync()), expectedSha);
    });

    test('cleans up temporary .sd_parts directory on cancel', () async {
      server.streamSliceSize = 16 * 1024;
      server.chunkDelay = const Duration(milliseconds: 30);
      final destPath = p.join(tempDir.path, 'cancelled.bin');

      final startedTransfer = Completer<void>();
      final engine = TurboDownloadEngine(
        url: server.fileUrl('/cancelled.bin'),
        destinationPath: destPath,
        maxConnections: 2,
        callbacks: EngineCallbacks(
          onProgress: (snap) {
            if (snap.status == DownloadStatus.downloading &&
                snap.downloadedBytes > 0 &&
                !startedTransfer.isCompleted) {
              startedTransfer.complete();
            }
          },
        ),
      );

      final startFuture = engine.start();
      await startedTransfer.future;
      await engine.cancel();
      await startFuture;

      expect(engine.status, DownloadStatus.cancelled);
      expect(File(destPath).existsSync(), isFalse);
      expect(Directory(ChunkPersistence.tempDirFor(destPath)).existsSync(), isFalse);
    });
  });
}
