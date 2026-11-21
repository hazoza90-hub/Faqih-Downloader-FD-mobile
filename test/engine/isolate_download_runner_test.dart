import 'dart:async';
import 'dart:io';

import 'package:faqih_downloader_mobile/core/models/download_status.dart';
import 'package:faqih_downloader_mobile/engine/chunk_persistence.dart';
import 'package:faqih_downloader_mobile/engine/engine_callbacks.dart';
import 'package:faqih_downloader_mobile/engine/isolate_download_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'mock_range_server.dart';

void main() {
  late Directory tempDir;
  late MockRangeServer server;
  final payload = generateTestPayload(384 * 1024, seed: 9001);
  final expectedSha = sha256HexOf(payload);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fd_isolate_test_');
    server = await MockRangeServer.start(payload);
  });

  tearDown(() async {
    await server.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('IsolateDownloadRunner', () {
    test('downloads file in background Isolate with throttled progress and SHA-256 check', () async {
      final destPath = p.join(tempDir.path, 'iso_full.bin');
      final snapshots = <EngineProgressSnapshot>[];
      var completedBytes = 0;

      final runner = IsolateDownloadRunner(
        url: server.fileUrl('/iso_full.bin'),
        destinationPath: destPath,
        maxConnections: 4,
        minSplitThreshold: 32 * 1024,
        expectedSha256: expectedSha,
        progressThrottleMs: 50,
        callbacks: EngineCallbacks(
          onProgress: snapshots.add,
          onComplete: (_, bytes, _) => completedBytes = bytes,
        ),
      );

      await runner.start();
      await runner.completion;
      await runner.dispose();

      expect(snapshots, isNotEmpty);
      expect(snapshots.last.status, DownloadStatus.completed);
      expect(completedBytes, payload.length);
      expect(sha256HexOf(File(destPath).readAsBytesSync()), expectedSha);
    });

    test('supports live setSpeedLimit, pause, and resume across Isolate IPC', () async {
      server.streamSliceSize = 16 * 1024;
      server.chunkDelay = const Duration(milliseconds: 25);
      final destPath = p.join(tempDir.path, 'iso_pause.bin');

      final hasProgress = Completer<void>();
      final pausedConfirmed = Completer<void>();

      final runner = IsolateDownloadRunner(
        url: server.fileUrl('/iso_pause.bin'),
        destinationPath: destPath,
        maxConnections: 2,
        minSplitThreshold: 64 * 1024,
        speedLimitBytesPerSec: 256 * 1024,
        expectedSha256: expectedSha,
        progressThrottleMs: 40,
        callbacks: EngineCallbacks(
          onProgress: (snap) {
            if (snap.status == DownloadStatus.downloading &&
                snap.downloadedBytes > 0 &&
                !hasProgress.isCompleted) {
              hasProgress.complete();
            }
            if (snap.status == DownloadStatus.paused &&
                !pausedConfirmed.isCompleted) {
              pausedConfirmed.complete();
            }
          },
        ),
      );

      await runner.start();
      await hasProgress.future;
      runner.pause();
      await pausedConfirmed.future;

      expect(File(ChunkPersistence.stateFilePathFor(destPath)).existsSync(), isTrue);

      server.chunkDelay = Duration.zero;
      runner.setSpeedLimit(0);
      runner.resume();
      await runner.completion;
      await runner.dispose();

      expect(sha256HexOf(File(destPath).readAsBytesSync()), expectedSha);
    });

    test('cancels cleanly and removes .sd_parts directory', () async {
      server.streamSliceSize = 16 * 1024;
      server.chunkDelay = const Duration(milliseconds: 30);
      final destPath = p.join(tempDir.path, 'iso_cancel.bin');
      final hasProgress = Completer<void>();

      final runner = IsolateDownloadRunner(
        url: server.fileUrl('/iso_cancel.bin'),
        destinationPath: destPath,
        maxConnections: 2,
        progressThrottleMs: 40,
        callbacks: EngineCallbacks(
          onProgress: (snap) {
            if (snap.status == DownloadStatus.downloading &&
                snap.downloadedBytes > 0 &&
                !hasProgress.isCompleted) {
              hasProgress.complete();
            }
          },
        ),
      );

      await runner.start();
      await hasProgress.future;
      runner.cancel();
      await runner.completion;
      await runner.dispose();

      expect(File(destPath).existsSync(), isFalse);
      expect(Directory(ChunkPersistence.tempDirFor(destPath)).existsSync(), isFalse);
    });

    test('delivers HTTP 403 failure to onError and lastError without unhandled async exception', () async {
      server.rejectHeadWith405 = true;
      server.forceErrorStatus = 403;
      final destPath = p.join(tempDir.path, 'iso_expired.bin');

      Object? capturedError;
      bool? capturedExpired;
      int? capturedStatus;

      final runner = IsolateDownloadRunner(
        url: server.fileUrl('/iso_expired.bin'),
        destinationPath: destPath,
        callbacks: EngineCallbacks(
          onError: (err, {linkExpired = false, httpStatus}) {
            capturedError = err;
            capturedExpired = linkExpired;
            capturedStatus = httpStatus;
          },
        ),
      );

      await runner.start();
      await runner.completion;
      await runner.dispose();

      expect(capturedError, isNotNull);
      expect(capturedExpired, isTrue);
      expect(capturedStatus, 403);
      expect(runner.lastError, isNotNull);
    });
  });
}
