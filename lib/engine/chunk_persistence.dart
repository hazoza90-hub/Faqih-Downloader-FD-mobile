import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/models/download_chunk.dart';

/// Serialized download checkpoint stored inside `<destinationPath>.sd_parts/state.json`.
@immutable
class PersistedDownloadState {
  const PersistedDownloadState({
    required this.url,
    required this.destinationPath,
    required this.totalSize,
    required this.supportsRanges,
    required this.filename,
    required this.headers,
    required this.accumulatedActiveSeconds,
    required this.chunks,
  });

  final String url;
  final String destinationPath;
  final int totalSize;
  final bool supportsRanges;
  final String filename;
  final Map<String, String> headers;
  final double accumulatedActiveSeconds;
  final List<DownloadChunk> chunks;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'url': url,
      'destinationPath': destinationPath,
      'totalSize': totalSize,
      'supportsRanges': supportsRanges,
      'filename': filename,
      'headers': headers,
      'accumulatedActiveSeconds': accumulatedActiveSeconds,
      'chunks': chunks.map((c) => c.toJson()).toList(growable: false),
    };
  }

  factory PersistedDownloadState.fromJson(Map<String, dynamic> json) {
    final rawChunks = json['chunks'];
    final parsedChunks = rawChunks is List
        ? rawChunks
            .whereType<Map>()
            .map((m) => DownloadChunk.fromJson(Map<String, dynamic>.from(m)))
            .toList(growable: false)
        : const <DownloadChunk>[];

    final rawHeaders = json['headers'];
    final parsedHeaders = rawHeaders is Map
        ? <String, String>{
            for (final entry in rawHeaders.entries)
              entry.key.toString(): entry.value?.toString() ?? '',
          }
        : const <String, String>{};

    return PersistedDownloadState(
      url: json['url']?.toString() ?? '',
      destinationPath: json['destinationPath']?.toString() ?? '',
      totalSize: (json['totalSize'] as num?)?.toInt() ?? 0,
      supportsRanges: json['supportsRanges'] == true,
      filename: json['filename']?.toString() ?? '',
      headers: Map<String, String>.unmodifiable(parsedHeaders),
      accumulatedActiveSeconds:
          (json['accumulatedActiveSeconds'] as num?)?.toDouble() ?? 0.0,
      chunks: List<DownloadChunk>.unmodifiable(parsedChunks),
    );
  }
}

/// Atomic checkpoint manager reconciling chunk offsets with `.part_<id>` files on disk.
class ChunkPersistence {
  const ChunkPersistence();

  static int _saveSeq = 0;

  static String tempDirFor(String destinationPath) => '$destinationPath.sd_parts';

  static String stateFilePathFor(String destinationPath) =>
      p.join(tempDirFor(destinationPath), 'state.json');

  static String partFilePathFor(String destinationPath, int chunkId) => p.join(
        tempDirFor(destinationPath),
        '${p.basename(destinationPath)}.part_$chunkId',
      );

  Future<bool> saveState(PersistedDownloadState state) async {
    File? tmpFile;
    try {
      final tempDir = Directory(tempDirFor(state.destinationPath));
      if (!tempDir.existsSync()) {
        await tempDir.create(recursive: true);
      }

      final targetFile = File(stateFilePathFor(state.destinationPath));
      final uniqueName =
          'state.${DateTime.now().microsecondsSinceEpoch}.${_saveSeq++}.tmp';
      tmpFile = File(p.join(tempDir.path, uniqueName));
      final encoded = const JsonEncoder.withIndent('  ').convert(state.toJson());

      await tmpFile.writeAsString(encoded, flush: true);
      await _atomicReplace(tmpFile, targetFile);
      return true;
    } catch (_) {
      if (tmpFile != null && tmpFile.existsSync()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      return false;
    }
  }

  Future<PersistedDownloadState?> loadState(String destinationPath) async {
    try {
      final file = File(stateFilePathFor(destinationPath));
      if (!file.existsSync()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final parsed = PersistedDownloadState.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      if (parsed.chunks.isEmpty) return null;

      final reconciled = <DownloadChunk>[];
      for (final chunk in parsed.chunks) {
        final partPath = chunk.partFilepath.isNotEmpty
            ? chunk.partFilepath
            : partFilePathFor(destinationPath, chunk.chunkId);
        final partFile = File(partPath);

        var diskBytes = 0;
        var status = chunk.status;

        if (partFile.existsSync()) {
          final actualSize = partFile.lengthSync();
          if (chunk.endByte >= chunk.startByte) {
            diskBytes = math.min(actualSize, chunk.totalBytes);
            if (chunk.totalBytes > 0 && diskBytes >= chunk.totalBytes) {
              status = ChunkStatus.completed;
            } else if (status != ChunkStatus.pending) {
              status = ChunkStatus.pending;
            }
          } else {
            diskBytes = actualSize;
            if (status != ChunkStatus.completed) {
              status = ChunkStatus.pending;
            }
          }
        } else {
          diskBytes = 0;
          status = ChunkStatus.pending;
        }

        if (!parsed.supportsRanges && status != ChunkStatus.completed) {
          diskBytes = 0;
          status = ChunkStatus.pending;
          if (partFile.existsSync()) {
            try {
              await partFile.delete();
            } catch (_) {
              try {
                partFile.writeAsBytesSync(const <int>[], flush: true);
              } catch (_) {}
            }
          }
        }

        reconciled.add(
          chunk.copyWith(
            downloadedBytes: diskBytes,
            status: status,
            partFilepath: partPath,
          ),
        );
      }

      return PersistedDownloadState(
        url: parsed.url,
        destinationPath: parsed.destinationPath,
        totalSize: parsed.totalSize,
        supportsRanges: parsed.supportsRanges,
        filename: parsed.filename,
        headers: parsed.headers,
        accumulatedActiveSeconds: parsed.accumulatedActiveSeconds,
        chunks: List<DownloadChunk>.unmodifiable(reconciled),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> cleanupTempDir(String destinationPath) async {
    final dir = Directory(tempDirFor(destinationPath));
    if (!dir.existsSync()) return;
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // Best-effort cleanup; ignore transient lock errors.
    }
  }

  static Future<void> _atomicReplace(File source, File target) async {
    try {
      await source.rename(target.path);
    } on FileSystemException {
      if (target.existsSync()) {
        await target.delete();
      }
      await source.rename(target.path);
    }
  }
}
