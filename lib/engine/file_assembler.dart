import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../core/models/download_chunk.dart';
import 'chunk_persistence.dart';

class _SingleDigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}

@immutable
class AssemblyResult {
  const AssemblyResult({
    required this.filePath,
    required this.totalBytes,
    required this.sha256Hex,
  });

  final String filePath;
  final int totalBytes;
  final String sha256Hex;
}

/// Verifies chunk integrity, merges `.part_*` sequentially, checks SHA-256, and cleans temp files.
class FileAssembler {
  const FileAssembler({
    this.persistence = const ChunkPersistence(),
  });

  final ChunkPersistence persistence;

  Future<AssemblyResult> assemble({
    required String destinationPath,
    required List<DownloadChunk> chunks,
    required int expectedTotalSize,
    required bool supportsRanges,
    String? expectedSha256,
    int bufferBytes = 256 * 1024,
  }) async {
    if (chunks.isEmpty) {
      throw StateError('No download chunks available for assembly.');
    }

    final sorted = List<DownloadChunk>.from(chunks)
      ..sort((a, b) => a.startByte.compareTo(b.startByte));

    for (final chunk in sorted) {
      if (!chunk.isCompleted) {
        throw StateError('Chunk #${chunk.chunkId} is not completed.');
      }
      final partFile = File(chunk.partFilepath);
      if (!partFile.existsSync()) {
        throw FileSystemException(
          'Missing chunk part file',
          chunk.partFilepath,
        );
      }
      if (chunk.endByte >= chunk.startByte) {
        final actualLen = partFile.lengthSync();
        if (actualLen != chunk.totalBytes) {
          throw StateError(
            'Chunk #${chunk.chunkId} size mismatch: '
            'disk=$actualLen != expected=${chunk.totalBytes}',
          );
        }
      }
    }

    if (supportsRanges && expectedTotalSize > 0) {
      if (sorted.first.startByte != 0) {
        throw StateError(
          'Chunk 0 starts at ${sorted.first.startByte}, expected 0.',
        );
      }
      for (var i = 0; i < sorted.length - 1; i++) {
        final cur = sorted[i];
        final next = sorted[i + 1];
        if (cur.endByte + 1 != next.startByte) {
          throw StateError(
            'Gap or overlap between chunk #${cur.chunkId} (${cur.endByte}) '
            'and #${next.chunkId} (${next.startByte}).',
          );
        }
      }
      if (sorted.last.endByte != expectedTotalSize - 1) {
        throw StateError(
          'Final chunk ends at ${sorted.last.endByte}, '
          'expected ${expectedTotalSize - 1}.',
        );
      }
    }

    final destFile = File(destinationPath);
    await destFile.parent.create(recursive: true);
    final tmpFile = File('$destinationPath.assembling.tmp');
    if (tmpFile.existsSync()) {
      await tmpFile.delete();
    }

    final digestSink = _SingleDigestSink();
    final hashInput = sha256.startChunkedConversion(digestSink);
    var totalWritten = 0;

    final outRaf = await tmpFile.open(mode: FileMode.writeOnly);
    try {
      final buffer = List<int>.filled(bufferBytes, 0);
      for (final chunk in sorted) {
        final inRaf = await File(chunk.partFilepath).open(mode: FileMode.read);
        try {
          while (true) {
            final readCount = inRaf.readIntoSync(buffer);
            if (readCount <= 0) {
              break;
            }
            final slice = readCount == buffer.length
                ? buffer
                : buffer.sublist(0, readCount);
            outRaf.writeFromSync(slice);
            hashInput.add(slice);
            totalWritten += readCount;
          }
        } finally {
          inRaf.closeSync();
        }
      }
      outRaf.flushSync();
    } finally {
      outRaf.closeSync();
    }

    hashInput.close();
    final sha256Hex = digestSink.digest.toString();

    if (expectedTotalSize > 0 && totalWritten != expectedTotalSize) {
      if (tmpFile.existsSync()) {
        await tmpFile.delete();
      }
      throw StateError(
        'Assembled file size mismatch: '
        'written=$totalWritten != expected=$expectedTotalSize',
      );
    }

    if (expectedSha256 != null && expectedSha256.trim().isNotEmpty) {
      final normalizedExpected = expectedSha256.trim().toLowerCase();
      if (sha256Hex.toLowerCase() != normalizedExpected) {
        if (tmpFile.existsSync()) {
          await tmpFile.delete();
        }
        throw StateError(
          'SHA-256 verification failed: '
          'actual=$sha256Hex != expected=$normalizedExpected',
        );
      }
    }

    try {
      await tmpFile.rename(destFile.path);
    } on FileSystemException {
      if (destFile.existsSync()) {
        await destFile.delete();
      }
      await tmpFile.rename(destFile.path);
    }

    await persistence.cleanupTempDir(destinationPath);

    return AssemblyResult(
      filePath: destFile.path,
      totalBytes: totalWritten,
      sha256Hex: sha256Hex,
    );
  }
}
