import 'dart:async';
import 'dart:isolate';

import '../core/config/app_constants.dart';
import '../core/models/download_status.dart';
import 'chunk_worker.dart';
import 'engine_callbacks.dart';
import 'server_prober.dart';
import 'turbo_download_engine.dart';

/// Runs [TurboDownloadEngine] inside a background [Isolate] with throttled IPC.
class IsolateDownloadRunner {
  IsolateDownloadRunner({
    required this.url,
    required this.destinationPath,
    this.headers = const <String, String>{},
    this.maxConnections = AppConstants.defaultMaxConnections,
    this.minSplitThreshold = AppConstants.defaultMinSplitBytes,
    this.speedLimitBytesPerSec = 0.0,
    this.allowDynamicSplit = true,
    this.initialChunks,
    this.expectedSha256,
    this.callbacks,
    this.progressThrottleMs = 120,
  });

  final String url;
  final String destinationPath;
  final Map<String, String> headers;
  final int maxConnections;
  final int minSplitThreshold;
  final double speedLimitBytesPerSec;
  final bool allowDynamicSplit;
  final int? initialChunks;
  final String? expectedSha256;
  final EngineCallbacks? callbacks;
  final int progressThrottleMs;

  ReceivePort? _receivePort;
  SendPort? _commandPort;
  Isolate? _isolate;
  final Completer<void> _readyCompleter = Completer<void>();
  final Completer<void> _completionCompleter = Completer<void>();
  bool _disposed = false;

  Future<void> get completion => _completionCompleter.future;

  Future<void> start() async {
    if (_isolate != null || _disposed) {
      return _readyCompleter.future;
    }

    final receivePort = ReceivePort();
    _receivePort = receivePort;
    receivePort.listen(_handleIsolateMessage);

    _isolate = await Isolate.spawn<Map<String, dynamic>>(
      _isolateEntryPoint,
      <String, dynamic>{
        'sendPort': receivePort.sendPort,
        'url': url,
        'destinationPath': destinationPath,
        'headers': headers,
        'maxConnections': maxConnections,
        'minSplitThreshold': minSplitThreshold,
        'speedLimitBytesPerSec': speedLimitBytesPerSec,
        'allowDynamicSplit': allowDynamicSplit,
        'initialChunks': initialChunks,
        'expectedSha256': expectedSha256,
        'progressThrottleMs': progressThrottleMs,
      },
      errorsAreFatal: false,
    );

    return _readyCompleter.future;
  }

  void pause() => _sendCommand('pause');
  void resume() => _sendCommand('resume');
  void cancel() => _sendCommand('cancel');
  void setSpeedLimit(double bytesPerSec) =>
      _sendCommand('setSpeedLimit', value: bytesPerSec);

  void _sendCommand(String cmd, {Object? value}) {
    _commandPort?.send(<String, dynamic>{'cmd': cmd, 'value': value});
  }

  void _handleIsolateMessage(dynamic message) {
    if (message is! Map) return;
    final map = Map<String, dynamic>.from(message);
    final type = map['type']?.toString();

    switch (type) {
      case 'ready':
        _commandPort = map['port'] as SendPort?;
        if (!_readyCompleter.isCompleted) {
          _readyCompleter.complete();
        }
      case 'progress':
        final rawSnap = map['snapshot'];
        if (rawSnap is Map) {
          final snap = EngineProgressSnapshot.fromMap(
            Map<String, dynamic>.from(rawSnap),
          );
          callbacks?.onProgress?.call(snap);
        }
      case 'log':
        callbacks?.onLog?.call(map['message']?.toString() ?? '');
      case 'complete':
        callbacks?.onComplete?.call(
          map['filePath']?.toString() ?? destinationPath,
          (map['totalBytes'] as num?)?.toInt() ?? 0,
          (map['elapsedSeconds'] as num?)?.toDouble() ?? 0.0,
        );
        if (!_completionCompleter.isCompleted) {
          _completionCompleter.complete();
        }
        unawaited(dispose());
      case 'cancelled':
        if (!_completionCompleter.isCompleted) {
          _completionCompleter.complete();
        }
        unawaited(dispose());
      case 'error':
        final errorMsg = map['message']?.toString() ?? 'Download error';
        final linkExpired = map['linkExpired'] == true;
        final httpStatus = (map['httpStatus'] as num?)?.toInt();
        final err = StateError(errorMsg);
        callbacks?.onError?.call(
          err,
          linkExpired: linkExpired,
          httpStatus: httpStatus,
        );
        if (!_completionCompleter.isCompleted) {
          _completionCompleter.completeError(err);
        }
        unawaited(dispose());
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
    if (!_completionCompleter.isCompleted) {
      _completionCompleter.complete();
    }
    _receivePort?.close();
    _receivePort = null;
    _commandPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

void _isolateEntryPoint(Map<String, dynamic> config) {
  final mainPort = config['sendPort'] as SendPort;
  final commandPort = ReceivePort();
  mainPort.send(<String, dynamic>{'type': 'ready', 'port': commandPort.sendPort});

  final throttleMs = (config['progressThrottleMs'] as num?)?.toInt() ?? 120;
  var lastProgressSentMs = 0;
  DownloadStatus? lastSentStatus;
  var terminalSent = false;
  final stopwatch = Stopwatch()..start();

  final rawHeaders = config['headers'];
  final parsedHeaders = rawHeaders is Map
      ? <String, String>{
          for (final e in rawHeaders.entries)
            e.key.toString(): e.value?.toString() ?? '',
        }
      : const <String, String>{};

  late final TurboDownloadEngine engine;
  engine = TurboDownloadEngine(
    url: config['url'] as String,
    destinationPath: config['destinationPath'] as String,
    headers: parsedHeaders,
    maxConnections: (config['maxConnections'] as num?)?.toInt() ?? 6,
    minSplitThreshold:
        (config['minSplitThreshold'] as num?)?.toInt() ?? (128 * 1024),
    speedLimitBytesPerSec:
        (config['speedLimitBytesPerSec'] as num?)?.toDouble() ?? 0.0,
    allowDynamicSplit: config['allowDynamicSplit'] != false,
    initialChunks: (config['initialChunks'] as num?)?.toInt(),
    expectedSha256: config['expectedSha256']?.toString(),
    callbacks: EngineCallbacks(
      onProgress: (snap) {
        final nowMs = stopwatch.elapsedMilliseconds;
        final statusChanged = snap.status != lastSentStatus;
        if (statusChanged || nowMs - lastProgressSentMs >= throttleMs) {
          lastProgressSentMs = nowMs;
          lastSentStatus = snap.status;
          mainPort.send(<String, dynamic>{
            'type': 'progress',
            'snapshot': snap.toMap(),
          });
        }
        if (snap.status == DownloadStatus.cancelled && !terminalSent) {
          terminalSent = true;
          mainPort.send(const <String, dynamic>{'type': 'cancelled'});
          commandPort.close();
        }
      },
      onLog: (msg) {
        mainPort.send(<String, dynamic>{'type': 'log', 'message': msg});
      },
      onComplete: (filePath, totalBytes, elapsedSeconds) {
        if (terminalSent) return;
        terminalSent = true;
        mainPort.send(<String, dynamic>{
          'type': 'complete',
          'filePath': filePath,
          'totalBytes': totalBytes,
          'elapsedSeconds': elapsedSeconds,
        });
        commandPort.close();
      },
      onError: (err, {linkExpired = false, httpStatus}) {
        if (terminalSent) return;
        terminalSent = true;
        mainPort.send(<String, dynamic>{
          'type': 'error',
          'message': err.toString(),
          'linkExpired': linkExpired,
          'httpStatus': httpStatus,
        });
        commandPort.close();
      },
    ),
  );

  void launchRun(Future<void> Function() action) {
    unawaited(
      action().catchError((Object err) {
        if (terminalSent) return;
        terminalSent = true;
        var linkExpired = false;
        int? httpStatus;
        if (err is ChunkWorkerException) {
          linkExpired = err.linkExpired;
          httpStatus = err.httpStatus;
        } else if (err is ProbeException) {
          linkExpired = err.linkExpired;
          httpStatus = err.httpStatus;
        }
        mainPort.send(<String, dynamic>{
          'type': 'error',
          'message': err.toString(),
          'linkExpired': linkExpired,
          'httpStatus': httpStatus,
        });
        commandPort.close();
      }),
    );
  }

  commandPort.listen((dynamic message) {
    if (message is! Map) return;
    switch (message['cmd']?.toString()) {
      case 'pause':
        unawaited(engine.pause());
      case 'resume':
        launchRun(engine.resume);
      case 'cancel':
        unawaited(engine.cancel());
      case 'setSpeedLimit':
        final val = (message['value'] as num?)?.toDouble() ?? 0.0;
        engine.setSpeedLimit(val);
    }
  });

  launchRun(engine.start);
}
