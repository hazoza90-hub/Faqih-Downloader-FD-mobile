import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/models/download_chunk.dart';
import 'chunk_persistence.dart';

@immutable
class SplitDecision {
  const SplitDecision({required this.updatedParent, required this.newChild});

  final DownloadChunk updatedParent;
  final DownloadChunk newChild;
}

/// Adaptive initial and mid-flight chunk partitioning without byte gaps or overlap.
class DynamicSplitter {
  const DynamicSplitter();

  List<DownloadChunk> buildInitialChunks({
    required int totalSize,
    required bool supportsRanges,
    required int maxConnections,
    required int minSplitThreshold,
    required String destinationPath,
    int? initialChunks,
  }) {
    if (!supportsRanges || totalSize <= 0) {
      return <DownloadChunk>[
        DownloadChunk(
          chunkId: 0,
          startByte: 0,
          endByte: totalSize > 0 ? totalSize - 1 : -1,
          partFilepath: ChunkPersistence.partFilePathFor(destinationPath, 0),
        ),
      ];
    }

    final requested = initialChunks != null
        ? initialChunks.clamp(1, maxConnections)
        : maxConnections;
    final maxBySize = math.max(1, totalSize ~/ minSplitThreshold);
    final chunkCount = math.min(requested, maxBySize);
    final baseSpan = totalSize ~/ chunkCount;

    final result = <DownloadChunk>[];
    var cursor = 0;
    for (var i = 0; i < chunkCount; i++) {
      final end = (i == chunkCount - 1) ? (totalSize - 1) : (cursor + baseSpan - 1);
      result.add(
        DownloadChunk(
          chunkId: i,
          startByte: cursor,
          endByte: end,
          partFilepath: ChunkPersistence.partFilePathFor(destinationPath, i),
        ),
      );
      cursor = end + 1;
    }
    return result;
  }

  SplitDecision? trySplit({
    required List<DownloadChunk> chunks,
    required int maxConnections,
    required int minSplitThreshold,
    required String destinationPath,
  }) {
    if (chunks.isEmpty || maxConnections <= 1 || minSplitThreshold <= 0) {
      return null;
    }

    final inFlight = chunks
        .where((c) => c.status == ChunkStatus.active || c.status == ChunkStatus.pending)
        .length;
    if (inFlight >= maxConnections) return null;

    final minRemaining = minSplitThreshold * 2;
    DownloadChunk? candidate;
    for (final chunk in chunks) {
      final activeOrPending =
          chunk.status == ChunkStatus.active || chunk.status == ChunkStatus.pending;
      if (!activeOrPending || chunk.endByte < chunk.startByte) continue;
      if (chunk.remainingBytes < minRemaining) continue;
      if (candidate == null || chunk.remainingBytes > candidate.remainingBytes) {
        candidate = chunk;
      }
    }
    if (candidate == null) return null;

    final half = candidate.remainingBytes ~/ 2;
    if (half < minSplitThreshold) return null;

    final splitStart = candidate.currentByte + half;
    final oldEnd = candidate.endByte;
    if (splitStart <= candidate.currentByte || splitStart > oldEnd) return null;

    final newId = chunks.fold<int>(-1, (prev, c) => math.max(prev, c.chunkId)) + 1;
    return SplitDecision(
      updatedParent: candidate.copyWith(endByte: splitStart - 1),
      newChild: DownloadChunk(
        chunkId: newId,
        startByte: splitStart,
        endByte: oldEnd,
        partFilepath: ChunkPersistence.partFilePathFor(destinationPath, newId),
      ),
    );
  }
}
