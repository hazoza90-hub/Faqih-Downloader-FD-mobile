import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/models/download_chunk.dart';
import 'chunk_persistence.dart';
import 'dynamic_splitter.dart';
import 'server_prober.dart';

class EngineInitResult {
  const EngineInitResult({
    required this.resolvedUrl,
    required this.filename,
    required this.totalSize,
    required this.supportsRanges,
    required this.initialElapsedSec,
    required this.chunks,
    required this.restoredFromCheckpoint,
  });

  final String resolvedUrl;
  final String filename;
  final int totalSize;
  final bool supportsRanges;
  final double initialElapsedSec;
  final List<DownloadChunk> chunks;
  final bool restoredFromCheckpoint;
}

/// Restores saved chunk checkpoints or probes the server to partition initial chunks.
class EngineInitializer {
  const EngineInitializer();

  Future<EngineInitResult> prepare({
    required String url,
    required String destinationPath,
    required Map<String, String> headers,
    required int maxConnections,
    required int minSplitThreshold,
    required int? initialChunks,
    required HttpClient client,
    required ChunkPersistence persistence,
    required DynamicSplitter splitter,
    required void Function() onProbing,
    void Function(String message)? onLog,
  }) async {
    final restored = await persistence.loadState(destinationPath);
    if (restored != null) {
      onLog?.call('Restored ${restored.chunks.length} chunk(s) from checkpoint.');
      return EngineInitResult(
        resolvedUrl: url.isNotEmpty ? url : restored.url,
        filename: restored.filename,
        totalSize: restored.totalSize,
        supportsRanges: restored.supportsRanges,
        initialElapsedSec: restored.accumulatedActiveSeconds,
        chunks: restored.chunks,
        restoredFromCheckpoint: true,
      );
    }

    onProbing();
    onLog?.call('Probing $url');

    final probe = await ServerProber(httpClient: client).probe(
      url,
      headers: headers,
      destinationPath: destinationPath,
    );
    if (probe.linkExpired) {
      throw ProbeException(
        'Download link expired (HTTP ${probe.httpStatus})',
        httpStatus: probe.httpStatus,
        linkExpired: true,
      );
    }

    final chunks = splitter.buildInitialChunks(
      totalSize: probe.totalSize,
      supportsRanges: probe.supportsRanges,
      maxConnections: maxConnections,
      minSplitThreshold: minSplitThreshold,
      destinationPath: destinationPath,
      initialChunks: initialChunks,
    );

    return EngineInitResult(
      resolvedUrl: probe.finalUrl,
      filename: probe.filename ?? p.basename(destinationPath),
      totalSize: probe.totalSize,
      supportsRanges: probe.supportsRanges,
      initialElapsedSec: 0.0,
      chunks: chunks,
      restoredFromCheckpoint: false,
    );
  }
}
