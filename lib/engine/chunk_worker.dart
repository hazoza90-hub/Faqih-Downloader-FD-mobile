import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../core/models/download_chunk.dart';
import 'server_prober.dart';
import 'token_bucket_rate_limiter.dart';

class ChunkWorkerException implements Exception {
  const ChunkWorkerException(
    this.message, {
    this.linkExpired = false,
    this.httpStatus,
  });

  final String message;
  final bool linkExpired;
  final int? httpStatus;

  @override
  String toString() => 'ChunkWorkerException($message, status=$httpStatus)';
}

/// Streams a single byte-range chunk (or unknown-length stream) to `.part_<id>`.
class ChunkWorker {
  static const int googleVideoWindowBytes = 10 * 1024 * 1024;

  static bool isGoogleVideoUrl(String url) =>
      (Uri.tryParse(url)?.host.toLowerCase() ?? '').contains('googlevideo.com');

  static String buildGoogleVideoWindowUrl(String url, int startByte, int endByte) {
    var cleaned = url
        .replaceAll(RegExp(r'&(range|rn)=[^&]*', caseSensitive: false), '')
        .replaceAll(RegExp(r'\?(range|rn)=[^&]*&', caseSensitive: false), '?')
        .replaceAll(RegExp(r'\?(range|rn)=[^&]*$', caseSensitive: false), '');
    final sep = cleaned.contains('?') ? '&' : '?';
    return '$cleaned${sep}range=$startByte-$endByte';
  }

  Future<void> run({
    required HttpClient httpClient,
    required String url,
    required Map<String, String> headers,
    required bool supportsRanges,
    required DownloadChunk Function() readChunk,
    required void Function(DownloadChunk Function(DownloadChunk current) updater)
        updateChunk,
    required TokenBucketRateLimiter rateLimiter,
    required void Function(int deltaBytes) onBytesWritten,
    required bool Function() isPaused,
    required bool Function() isCancelled,
    required void Function(void Function() abortCallback) registerAborter,
    required void Function(void Function() abortCallback) unregisterAborter,
    Duration requestTimeout = const Duration(seconds: 20),
    int maxRetries = 4,
  }) async {
    var chunk = readChunk();
    if (chunk.isCompleted) return;

    final partFile = File(chunk.partFilepath);
    await partFile.parent.create(recursive: true);
    final raf = await partFile.open(mode: FileMode.append);

    void resetNonRangeStream() {
      chunk = readChunk();
      final isRanged = supportsRanges && chunk.endByte >= 0;
      if (!isRanged && (chunk.downloadedBytes > 0 || raf.lengthSync() > 0)) {
        raf.truncateSync(0);
        raf.setPositionSync(0);
        updateChunk(
          (c) => c.copyWith(
            downloadedBytes: 0,
            status: ChunkStatus.active,
            errorMsg: '',
          ),
        );
        chunk = readChunk();
      }
    }

    try {
      chunk = readChunk();
      if (chunk.isCompleted) return;
      final initiallyRanged = supportsRanges && chunk.endByte >= 0;
      if (!initiallyRanged) {
        resetNonRangeStream();
      } else {
        if (raf.lengthSync() != chunk.downloadedBytes) {
          raf.truncateSync(chunk.downloadedBytes);
        }
        raf.setPositionSync(chunk.downloadedBytes);
      }
      updateChunk((c) => c.copyWith(status: ChunkStatus.active, errorMsg: ''));

      final isGoogleVideo = isGoogleVideoUrl(url);
      var retries = 0;

      while (!isPaused() && !isCancelled()) {
        resetNonRangeStream();
        if (chunk.endByte >= 0 && chunk.currentByte > chunk.endByte) {
          updateChunk((c) => c.copyWith(status: ChunkStatus.completed));
          break;
        }
        try {
          await _streamOnce(
            httpClient: httpClient,
            url: url,
            headers: headers,
            supportsRanges: supportsRanges,
            isGoogleVideo: isGoogleVideo,
            raf: raf,
            readChunk: readChunk,
            updateChunk: updateChunk,
            rateLimiter: rateLimiter,
            onBytesWritten: onBytesWritten,
            isPaused: isPaused,
            isCancelled: isCancelled,
            registerAborter: registerAborter,
            unregisterAborter: unregisterAborter,
            requestTimeout: requestTimeout,
          );
          chunk = readChunk();
          if (isPaused() || isCancelled()) break;
          if (chunk.endByte == -1 || chunk.currentByte > chunk.endByte) {
            updateChunk((c) => c.copyWith(status: ChunkStatus.completed));
            break;
          }
          if (!(supportsRanges && chunk.endByte >= 0)) {
            throw HttpException(
              'Premature EOF at byte ${chunk.currentByte} of ${chunk.endByte + 1}',
            );
          }
          retries = 0;
        } on ChunkWorkerException {
          rethrow;
        } catch (error) {
          if (isPaused() || isCancelled()) break;
          retries++;
          if (retries > maxRetries) {
            updateChunk(
              (c) => c.copyWith(
                status: ChunkStatus.failed,
                errorMsg: error.toString(),
              ),
            );
            final failed = readChunk();
            throw ChunkWorkerException(
              'Chunk #${failed.chunkId} failed after $maxRetries retries: $error',
            );
          }
          final backoffMs = math.min(1500, 150 * (1 << (retries - 1)));
          await Future<void>.delayed(Duration(milliseconds: backoffMs));
        }
      }

      if (isPaused() && !isCancelled()) {
        updateChunk(
          (c) => c.isCompleted ? c : c.copyWith(status: ChunkStatus.pending),
        );
      }
    } finally {
      try {
        raf.flushSync();
      } catch (_) {}
      try {
        raf.closeSync();
      } catch (_) {}
    }
  }

  Future<void> _streamOnce({
    required HttpClient httpClient,
    required String url,
    required Map<String, String> headers,
    required bool supportsRanges,
    required bool isGoogleVideo,
    required RandomAccessFile raf,
    required DownloadChunk Function() readChunk,
    required void Function(DownloadChunk Function(DownloadChunk current) updater)
        updateChunk,
    required TokenBucketRateLimiter rateLimiter,
    required void Function(int deltaBytes) onBytesWritten,
    required bool Function() isPaused,
    required bool Function() isCancelled,
    required void Function(void Function() abortCallback) registerAborter,
    required void Function(void Function() abortCallback) unregisterAborter,
    required Duration requestTimeout,
  }) async {
    final snapshot = readChunk();
    final isRanged = supportsRanges && snapshot.endByte >= 0;
    final rangeStart = snapshot.currentByte;
    final targetUrl = (isRanged && isGoogleVideo)
        ? buildGoogleVideoWindowUrl(
            url,
            rangeStart,
            math.min(snapshot.endByte, rangeStart + googleVideoWindowBytes - 1),
          )
        : url;

    HttpClientRequest? activeReq;
    StreamSubscription<List<int>>? activeSub;
    final done = Completer<void>();

    void abort() {
      activeSub?.cancel();
      try {
        activeReq?.abort();
      } catch (_) {}
      if (!done.isCompleted) done.complete();
    }

    registerAborter(abort);
    try {
      final req = await httpClient.getUrl(Uri.parse(targetUrl)).timeout(requestTimeout);
      activeReq = req;
      req.followRedirects = true;
      req.maxRedirects = 8;
      req.headers.set(HttpHeaders.userAgentHeader, ServerProber.defaultUserAgent);
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      headers.forEach(req.headers.set);
      if (isRanged && !isGoogleVideo) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$rangeStart-${snapshot.endByte}');
      }
      if (isPaused() || isCancelled()) {
        req.abort();
        return;
      }

      final resp = await req.close().timeout(requestTimeout);
      await _validateResponse(resp, isRanged, isGoogleVideo, rangeStart);

      activeSub = resp.listen(
        (data) async {
          activeSub?.pause();
          try {
            final keepReading = await _handlePacket(
              data: data,
              raf: raf,
              readChunk: readChunk,
              updateChunk: updateChunk,
              rateLimiter: rateLimiter,
              onBytesWritten: onBytesWritten,
              isPaused: isPaused,
              isCancelled: isCancelled,
            );
            if (!keepReading) {
              await activeSub?.cancel();
              if (!done.isCompleted) done.complete();
            } else {
              activeSub?.resume();
            }
          } catch (err, st) {
            await activeSub?.cancel();
            if (!done.isCompleted) done.completeError(err, st);
          }
        },
        onError: (Object err, StackTrace st) {
          if (!done.isCompleted) done.completeError(err, st);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await done.future;
    } finally {
      unregisterAborter(abort);
      await activeSub?.cancel();
    }
  }

  Future<void> _validateResponse(
    HttpClientResponse resp,
    bool isRanged,
    bool isGoogleVideo,
    int rangeStart,
  ) async {
    final status = resp.statusCode;
    if (status == 401 || status == 403 || status == 410) {
      await resp.drain<void>();
      throw ChunkWorkerException(
        'Download link expired (HTTP $status)',
        linkExpired: true,
        httpStatus: status,
      );
    }
    if (status < 200 || status >= 300) {
      await resp.drain<void>();
      final msg = 'HTTP $status during chunk transfer';
      if (status >= 400 && status < 500 && status != 408 && status != 429) {
        throw ChunkWorkerException(msg, httpStatus: status);
      }
      throw HttpException(msg);
    }
    if (isRanged && !isGoogleVideo && rangeStart > 0 && status == HttpStatus.ok) {
      await resp.drain<void>();
      throw ChunkWorkerException(
        'Server ignored Range header (HTTP 200 for non-zero offset)',
        httpStatus: status,
      );
    }
  }

  Future<bool> _handlePacket({
    required List<int> data,
    required RandomAccessFile raf,
    required DownloadChunk Function() readChunk,
    required void Function(DownloadChunk Function(DownloadChunk current) updater)
        updateChunk,
    required TokenBucketRateLimiter rateLimiter,
    required void Function(int deltaBytes) onBytesWritten,
    required bool Function() isPaused,
    required bool Function() isCancelled,
  }) async {
    if (isPaused() || isCancelled()) return false;
    var latest = readChunk();
    if (latest.endByte >= 0 && latest.currentByte > latest.endByte) return false;

    if (rateLimiter.limitBytesPerSec > 0) {
      final preAllowed = latest.endByte >= 0
          ? math.min(data.length, latest.endByte - latest.currentByte + 1)
          : data.length;
      await rateLimiter.consume(
        preAllowed,
        shouldAbort: () => isPaused() || isCancelled(),
      );
    }
    if (isPaused() || isCancelled()) return false;

    latest = readChunk();
    final allowed = latest.endByte >= 0
        ? (latest.endByte - latest.currentByte + 1)
        : data.length;
    if (allowed <= 0) {
      updateChunk((c) => c.copyWith(status: ChunkStatus.completed));
      return false;
    }

    final toWrite = data.length > allowed ? data.sublist(0, allowed) : data;
    if (toWrite.isNotEmpty) {
      raf.writeFromSync(toWrite);
      final newDownloaded = latest.downloadedBytes + toWrite.length;
      final finished = latest.endByte >= 0 &&
          (latest.startByte + newDownloaded - 1) >= latest.endByte;
      updateChunk(
        (c) => c.copyWith(
          downloadedBytes: newDownloaded,
          status: finished ? ChunkStatus.completed : ChunkStatus.active,
          errorMsg: '',
        ),
      );
      onBytesWritten(toWrite.length);
      if (finished) return false;
    }
    return true;
  }
}
