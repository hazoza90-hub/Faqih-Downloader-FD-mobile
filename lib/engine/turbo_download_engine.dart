import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../core/config/app_constants.dart';
import '../core/models/download_chunk.dart';
import '../core/models/download_status.dart';
import 'chunk_persistence.dart';
import 'chunk_worker.dart';
import 'dynamic_splitter.dart';
import 'engine_callbacks.dart';
import 'engine_initializer.dart';
import 'file_assembler.dart';
import 'http_client_factory.dart';
import 'server_prober.dart';
import 'speed_tracker.dart';
import 'token_bucket_rate_limiter.dart';

/// Orchestrates multi-connection range downloads, dynamic splitting, pause/resume, and assembly.
class TurboDownloadEngine {
  TurboDownloadEngine({
    required this.url,
    required this.destinationPath,
    this.headers = const <String, String>{},
    int maxConnections = AppConstants.defaultMaxConnections,
    this.minSplitThreshold = AppConstants.defaultMinSplitBytes,
    double speedLimitBytesPerSec = 0.0,
    this.allowDynamicSplit = true,
    this.initialChunks,
    this.expectedSha256,
    this.callbacks,
    HttpClient? httpClient,
  })  : maxConnections = AppConstants.clampConnections(maxConnections),
        _injectedClient = httpClient,
        _rateLimiter = TokenBucketRateLimiter(bytesPerSec: speedLimitBytesPerSec);

  final String url;
  final String destinationPath;
  final Map<String, String> headers;
  final int maxConnections;
  final int minSplitThreshold;
  final bool allowDynamicSplit;
  final int? initialChunks;
  final String? expectedSha256;
  final EngineCallbacks? callbacks;

  final HttpClient? _injectedClient;
  final TokenBucketRateLimiter _rateLimiter;
  final SpeedTracker _speedTracker = SpeedTracker();
  final ChunkPersistence _persistence = const ChunkPersistence();
  final DynamicSplitter _splitter = const DynamicSplitter();
  final EngineInitializer _initializer = const EngineInitializer();
  final FileAssembler _assembler = const FileAssembler();
  final ChunkWorker _worker = ChunkWorker();

  final List<DownloadChunk> _chunks = <DownloadChunk>[];
  final Map<int, Future<void>> _activeWorkers = <int, Future<void>>{};
  final Set<void Function()> _aborters = <void Function()>{};

  DownloadStatus _status = DownloadStatus.staged;
  String _resolvedUrl = '';
  String _filename = '';
  int _totalSize = 0;
  bool _supportsRanges = false;
  late Map<String, String> _effectiveHeaders = headers;
  double _initialElapsedSec = 0.0;
  bool _isPaused = false;
  bool _isCancelled = false;
  bool _isResetting = false;
  Object? _fatalError;
  bool _fatalLinkExpired = false;
  int? _fatalHttpStatus;
  Future<void>? _activeRunFuture;
  Future<void> _saveQueue = Future<void>.value();

  DownloadStatus get status => _status;
  List<DownloadChunk> get chunks => List<DownloadChunk>.unmodifiable(_chunks);
  void setSpeedLimit(double bytesPerSec) => _rateLimiter.setLimit(bytesPerSec);

  EngineProgressSnapshot snapshot() {
    final downloaded = _chunks.fold<int>(0, (sum, c) => sum + c.downloadedBytes);
    final remaining = _totalSize > 0 ? math.max(0, _totalSize - downloaded) : 0;
    return EngineProgressSnapshot(
      downloadedBytes: downloaded,
      totalBytes: _totalSize,
      speedBytesPerSec: _speedTracker.currentSpeedBytesPerSec(),
      etaSeconds: _totalSize > 0
          ? _speedTracker.estimateEtaSeconds(remainingBytes: remaining)
          : -1.0,
      activeWorkers: _activeWorkers.length,
      status: _status,
      chunks: List<DownloadChunk>.unmodifiable(_chunks),
    );
  }

  Future<void> _awaitActiveRun() async {
    final active = _activeRunFuture;
    if (active == null) return;
    try {
      await active;
    } catch (_) {}
  }

  Future<void> start() {
    if (_activeRunFuture != null) return _activeRunFuture!;
    final future = _runInternal().whenComplete(() {
      _activeRunFuture = null;
    });
    _activeRunFuture = future;
    return future;
  }

  Future<void> pause() async {
    if (_status == DownloadStatus.completed || _isCancelled) return;
    _isPaused = true;
    _abortAllWorkers();
    if (_activeRunFuture != null) return await _awaitActiveRun();
    await _finalizePaused();
  }

  Future<void> resume() async {
    await _awaitActiveRun();
    if (_status == DownloadStatus.completed || _isCancelled) return;
    _isPaused = false;
    await start();
  }

  Future<void> cancel() async {
    if (_status == DownloadStatus.completed) return;
    _isCancelled = true;
    _isPaused = false;
    _abortAllWorkers();
    if (_activeRunFuture != null) return await _awaitActiveRun();
    await _finalizeCancelled();
  }

  Future<void> _runInternal() async {
    _isPaused = false;
    _isCancelled = false;
    _isResetting = false;
    _fatalError = null;
    _fatalLinkExpired = false;
    _fatalHttpStatus = null;

    final ownsClient = _injectedClient == null;
    final client = _injectedClient ?? HttpClientFactory.create(
      connectionTimeout: const Duration(seconds: 10),
      idleTimeout: const Duration(seconds: 20),
      maxConnectionsPerHost: math.max(maxConnections + 2, 8),
    );

    Timer? progressTimer;
    try {
      await _prepareChunks(client);
      if (_isCancelled) return await _finalizeCancelled();
      if (_isPaused) return await _finalizePaused();

      _status = DownloadStatus.downloading;
      _speedTracker.start(initialElapsedSeconds: _initialElapsedSec);
      _emitProgress();

      var tickCount = 0;
      progressTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
        if (_isPaused || _isCancelled || _isResetting || _fatalError != null) return;
        _emitProgress();
        if (allowDynamicSplit && _supportsRanges) _attemptDynamicSplits(client);
        if (++tickCount % 10 == 0) unawaited(_saveCurrentState());
      });

      var triedSingleStream = false;
      while (true) {
        await _runWorkerLoop(client);
        if (_isCancelled || _isPaused || _fatalError == null) break;
        if (!triedSingleStream && _supportsRanges && _shouldFallbackToSingleStream()) {
          triedSingleStream = true;
          await _resetToSingleStream();
          continue;
        }
        break;
      }
      progressTimer.cancel();
      progressTimer = null;

      if (_isCancelled) return await _finalizeCancelled();
      if (_isPaused) return await _finalizePaused();
      if (_fatalError != null) return await _handleFatalError();

      _status = DownloadStatus.merging;
      _emitProgress();
      await _saveQueue;
      final assembly = await _assembler.assemble(
        destinationPath: destinationPath,
        chunks: _chunks,
        expectedTotalSize: _supportsRanges ? _totalSize : 0,
        supportsRanges: _supportsRanges,
        expectedSha256: expectedSha256,
      );
      _speedTracker.pause();
      if (!_supportsRanges || _totalSize <= 0) _totalSize = assembly.totalBytes;
      _status = DownloadStatus.completed;
      _emitProgress();
      callbacks?.onComplete?.call(assembly.filePath, assembly.totalBytes, _speedTracker.elapsedActiveSeconds);
    } finally {
      progressTimer?.cancel();
      if (ownsClient) client.close(force: true);
    }
  }

  Future<void> _handleFatalError() async {
    _speedTracker.pause();
    await _saveCurrentState();
    _status = DownloadStatus.failed;
    _emitProgress();
    callbacks?.onError?.call(_fatalError!, linkExpired: _fatalLinkExpired, httpStatus: _fatalHttpStatus);
    throw _fatalError!;
  }

  Future<void> _prepareChunks(HttpClient client) async {
    if (_chunks.isNotEmpty) {
      if (_resolvedUrl.isEmpty) _resolvedUrl = url;
      return;
    }
    try {
      final init = await _initializer.prepare(
        url: url, destinationPath: destinationPath, headers: headers,
        maxConnections: maxConnections, minSplitThreshold: minSplitThreshold,
        initialChunks: initialChunks, client: client,
        persistence: _persistence, splitter: _splitter,
        onProbing: () { _status = DownloadStatus.probing; _emitProgress(); },
        onLog: callbacks?.onLog,
      );
      _resolvedUrl = init.resolvedUrl;
      _filename = init.filename;
      _totalSize = init.totalSize;
      _supportsRanges = init.supportsRanges;
      _initialElapsedSec = init.initialElapsedSec;
      _effectiveHeaders = HttpClientFactory.withCookieHeader(headers, init.cookieHeader);
      _chunks..clear()..addAll(init.chunks);
      if (!init.restoredFromCheckpoint) unawaited(_saveCurrentState());
    } on ProbeException catch (e) {
      _status = DownloadStatus.failed;
      _emitProgress();
      callbacks?.onError?.call(e, linkExpired: e.linkExpired, httpStatus: e.httpStatus);
      rethrow;
    }
  }

  Future<void> _runWorkerLoop(HttpClient client) async {
    while (!_isPaused && !_isCancelled && _fatalError == null) {
      _launchAvailableWorkers(client);
      if (_activeWorkers.isEmpty) break;
      await Future.any(_activeWorkers.values.toList(growable: false));
      if (!_isPaused && !_isCancelled && _fatalError == null && allowDynamicSplit && _supportsRanges) {
        _attemptDynamicSplits(client);
      }
    }
    if (_activeWorkers.isNotEmpty) {
      await Future.wait(_activeWorkers.values.toList(growable: false));
    }
  }

  void _launchAvailableWorkers(HttpClient client) {
    for (final chunk in _chunks) {
      if (_activeWorkers.length >= maxConnections || _isPaused || _isCancelled || _fatalError != null) break;
      if (chunk.status != ChunkStatus.pending || _activeWorkers.containsKey(chunk.chunkId)) continue;
      final chunkId = chunk.chunkId;
      _activeWorkers[chunkId] = _runWorker(client, chunkId).whenComplete(() {
        _activeWorkers.remove(chunkId);
      });
    }
  }

  void _attemptDynamicSplits(HttpClient client) {
    while (_activeWorkers.length < maxConnections && !_isPaused && !_isCancelled && _fatalError == null) {
      final decision = _splitter.trySplit(
        chunks: _chunks,
        maxConnections: maxConnections,
        minSplitThreshold: minSplitThreshold,
        destinationPath: destinationPath,
      );
      if (decision == null) break;
      final idx = _chunks.indexWhere((c) => c.chunkId == decision.updatedParent.chunkId);
      if (idx < 0) break;
      _chunks[idx] = decision.updatedParent;
      _chunks.add(decision.newChild);
      callbacks?.onLog?.call('[SPLIT] #${decision.updatedParent.chunkId} -> #${decision.newChild.chunkId}');
      _launchAvailableWorkers(client);
    }
  }

  Future<void> _runWorker(HttpClient client, int chunkId) async {
    try {
      await _worker.run(
        httpClient: client,
        url: _resolvedUrl,
        headers: _effectiveHeaders,
        supportsRanges: _supportsRanges,
        readChunk: () => _chunks.firstWhere((c) => c.chunkId == chunkId),
        updateChunk: (updater) {
          final index = _chunks.indexWhere((c) => c.chunkId == chunkId);
          if (index >= 0) _chunks[index] = updater(_chunks[index]);
        },
        rateLimiter: _rateLimiter,
        onBytesWritten: _speedTracker.recordBytes,
        isPaused: () => _isPaused,
        isCancelled: () => _isCancelled,
        registerAborter: _aborters.add,
        unregisterAborter: _aborters.remove,
      );
    } catch (error) {
      if (_isPaused || _isCancelled) return;
      _fatalError ??= error;
      if (error is ChunkWorkerException) {
        _fatalLinkExpired = error.linkExpired;
        _fatalHttpStatus = error.httpStatus;
      }
      _abortAllWorkers();
    }
  }

  Future<void> _finalizePaused() async {
    _speedTracker.pause();
    _initialElapsedSec = _speedTracker.elapsedActiveSeconds;
    await _saveCurrentState();
    _status = DownloadStatus.paused;
    _emitProgress();
  }

  Future<void> _finalizeCancelled() async {
    _speedTracker.pause();
    await _saveQueue;
    await _persistence.cleanupTempDir(destinationPath);
    _status = DownloadStatus.cancelled;
    _emitProgress();
  }

  Future<void> _saveCurrentState() {
    if (_chunks.isEmpty || _isCancelled) return Future<void>.value();
    final state = PersistedDownloadState(
      url: _resolvedUrl.isNotEmpty ? _resolvedUrl : url,
      destinationPath: destinationPath,
      totalSize: _totalSize,
      supportsRanges: _supportsRanges,
      filename: _filename,
      headers: _effectiveHeaders,
      accumulatedActiveSeconds: _speedTracker.elapsedActiveSeconds,
      chunks: List<DownloadChunk>.unmodifiable(_chunks),
    );
    _saveQueue = _saveQueue.then((_) async {
      if (_isCancelled) return;
      await _persistence.saveState(state);
    }).catchError((_) {});
    return _saveQueue;
  }

  bool _shouldFallbackToSingleStream() {
    if (_fatalLinkExpired && ChunkWorker.isGoogleVideoUrl(_resolvedUrl)) return false;
    final msg = _fatalError.toString().toLowerCase();
    return _chunks.length > 1 ||
        msg.contains('ignored range') ||
        const <int>{403, 429, 503}.contains(_fatalHttpStatus) ||
        msg.contains('http 429') ||
        msg.contains('http 503') ||
        msg.contains('http 403') ||
        msg.contains('failed after');
  }

  Future<void> _resetToSingleStream() async {
    callbacks?.onLog?.call('[FALLBACK] Retrying as single-stream without Range');
    _isResetting = true;
    try {
      _supportsRanges = false;
      await _saveQueue;
      await _persistence.cleanupTempDir(destinationPath);
      _chunks
        ..clear()
        ..add(DownloadChunk(
          chunkId: 0, startByte: 0, endByte: -1,
          partFilepath: ChunkPersistence.partFilePathFor(destinationPath, 0),
        ));
      await _saveCurrentState();
    } finally {
      _isResetting = false;
    }
    _fatalLinkExpired = false;
    _fatalHttpStatus = null;
    _fatalError = null;
  }

  void _abortAllWorkers() {
    for (final abort in _aborters.toList(growable: false)) {
      try {
        abort();
      } catch (_) {}
    }
  }

  void _emitProgress() => callbacks?.onProgress?.call(snapshot());
}
