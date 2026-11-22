import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/config/app_settings.dart';
import '../../core/models/download_status.dart';
import '../../platform/foreground_service_channel.dart';
import '../../platform/native_models.dart';
import 'download_job_models.dart';
import 'stream_download_coordinator.dart';

typedef CoordinatorFactory = StreamDownloadCoordinator Function(
  DownloadJobRequest request, {
  required void Function(DownloadJobState state) onStateChanged,
});

/// Manages concurrent download scheduling, Kanban buckets, and foreground notifications.
class DownloadQueueManager extends ChangeNotifier {
  DownloadQueueManager({
    AppSettings settings = const AppSettings(),
    ForegroundServiceChannel? foregroundService,
    CoordinatorFactory? coordinatorFactory,
    this.progressThrottleMs = 400,
    String? pauseLabel,
    String? cancelLabel,
  })  : _settings = settings,
        _foregroundService = foregroundService ?? ForegroundServiceChannel(),
        _coordinatorFactory = coordinatorFactory ?? _defaultCoordinatorFactory,
        _pauseLabel = pauseLabel,
        _cancelLabel = cancelLabel {
    _listenForegroundActions();
  }

  final ForegroundServiceChannel _foregroundService;
  final CoordinatorFactory _coordinatorFactory;
  final int progressThrottleMs;
  String? _pauseLabel;
  String? _cancelLabel;

  String? get pauseLabel => _pauseLabel;
  String? get cancelLabel => _cancelLabel;

  final Map<String, DownloadJobState> _jobs = <String, DownloadJobState>{};
  final Map<String, StreamDownloadCoordinator> _coordinators =
      <String, StreamDownloadCoordinator>{};
  final List<String> _queuedIds = <String>[];
  final Set<String> _runningIds = <String>{};

  AppSettings _settings;
  StreamSubscription<ServiceNotificationAction>? _actionSub;
  bool _fgServiceRunning = false;
  DateTime _lastFgProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;

  AppSettings get settings => _settings;
  Map<String, DownloadJobState> get jobs => Map.unmodifiable(_jobs);

  List<DownloadJobState> get queuedJobs => _jobs.values
      .where((j) => j.phase == DownloadPhase.queued)
      .toList(growable: false);

  List<DownloadJobState> get activeJobs => _jobs.values
      .where((j) =>
          j.phase != DownloadPhase.queued &&
          (j.status.isActive || j.status == DownloadStatus.paused))
      .toList(growable: false);

  List<DownloadJobState> get completedJobs =>
      _jobs.values.where((j) => j.status.isTerminal).toList(growable: false);

  void updateSettings(AppSettings next) {
    _settings = next;
    setGlobalSpeedLimit(next.speedLimitBytesPerSec);
    _pumpQueue();
    notifyListeners();
  }

  void updateNotificationLabels({
    required String pauseLabel,
    required String cancelLabel,
  }) {
    _pauseLabel = pauseLabel;
    _cancelLabel = cancelLabel;
    if (_fgServiceRunning) {
      _syncForegroundService(force: true);
    }
  }

  DownloadJobState enqueue(DownloadJobRequest request) {
    final effective = request.copyWith(
      speedLimitBytesPerSec: _settings.speedLimitBytesPerSec > 0
          ? _settings.speedLimitBytesPerSec
          : request.speedLimitBytesPerSec,
    );
    final initial = DownloadJobState.fromRequest(effective);
    _jobs[request.id] = initial;
    if (!_queuedIds.contains(request.id)) _queuedIds.add(request.id);
    _coordinators[request.id] = _coordinatorFactory(
      effective,
      onStateChanged: _handleJobStateChanged,
    );
    notifyListeners();
    _pumpQueue();
    return initial;
  }

  Future<void> pause(String id) async {
    await _coordinators[id]?.pause();
    _syncForegroundService(force: true);
  }

  Future<void> resume(String id) async {
    await _coordinators[id]?.resume();
    _syncForegroundService(force: true);
  }

  Future<void> cancel(String id) async {
    _queuedIds.remove(id);
    final coord = _coordinators[id];
    if (coord != null) {
      await coord.cancel();
    } else if (_jobs.containsKey(id)) {
      _jobs[id] = _jobs[id]!.copyWith(
        phase: DownloadPhase.cancelled,
        status: DownloadStatus.cancelled,
        speedBytesPerSec: 0.0,
      );
      notifyListeners();
    }
    _runningIds.remove(id);
    _pumpQueue();
    _syncForegroundService(force: true);
  }

  Future<void> pauseAll() async {
    for (final id in _runningIds.toList(growable: false)) {
      await _coordinators[id]?.pause();
    }
    _syncForegroundService(force: true);
  }

  Future<void> cancelAll() async {
    final queuedCopy = _queuedIds.toList(growable: false);
    _queuedIds.clear();
    for (final id in queuedCopy) {
      if (_jobs.containsKey(id)) {
        _jobs[id] = _jobs[id]!.copyWith(
          phase: DownloadPhase.cancelled,
          status: DownloadStatus.cancelled,
          speedBytesPerSec: 0.0,
        );
      }
      _coordinators.remove(id);
    }
    for (final id in _runningIds.toList(growable: false)) {
      await _coordinators[id]?.cancel();
    }
    _runningIds.clear();
    notifyListeners();
    _syncForegroundService(force: true);
  }

  void setGlobalSpeedLimit(int bytesPerSec) {
    for (final coord in _coordinators.values) {
      coord.setSpeedLimit(bytesPerSec);
    }
  }

  void clearCompleted() {
    _jobs.removeWhere((_, state) => state.status.isTerminal);
    notifyListeners();
  }

  void _pumpQueue() {
    if (_disposed) return;
    while (_runningIds.length < _settings.maxConcurrentDownloads &&
        _queuedIds.isNotEmpty) {
      final nextId = _queuedIds.removeAt(0);
      final coord = _coordinators[nextId];
      if (coord == null) continue;
      _runningIds.add(nextId);
      _syncForegroundService(force: true);
      unawaited(_runJob(nextId, coord));
    }
  }

  Future<void> _runJob(String id, StreamDownloadCoordinator coord) async {
    try {
      final finalState = await coord.start();
      if (_disposed) return;
      _jobs[id] = finalState;
      if (finalState.phase == DownloadPhase.completed) {
        unawaited(_safeFg(() => _foregroundService.showCompletedNotification(
              title: finalState.title,
              body: finalState.exportedDisplayPath ?? finalState.title,
            )));
      }
    } finally {
      _runningIds.remove(id);
      _coordinators.remove(id);
      if (!_disposed) {
        notifyListeners();
        _pumpQueue();
        _syncForegroundService(force: true);
      }
    }
  }

  void _handleJobStateChanged(DownloadJobState state) {
    if (_disposed) return;
    _jobs[state.id] = state;
    notifyListeners();
    _syncForegroundService();
  }

  bool get _hasActiveNonPausedJobs => _runningIds.any(
        (id) => _jobs[id]?.status != DownloadStatus.paused,
      );

  void _syncForegroundService({bool force = false}) {
    if (_disposed) return;
    if (!_hasActiveNonPausedJobs) {
      if (_fgServiceRunning) {
        _fgServiceRunning = false;
        unawaited(_safeFg(_foregroundService.stopService));
      }
      return;
    }

    final payload = _buildAggregatePayload();
    if (!_fgServiceRunning) {
      _fgServiceRunning = true;
      _lastFgProgressUpdate = DateTime.now();
      unawaited(
        _safeFg(() => _foregroundService.startService(payload)).then((ok) {
          if (!ok && !_disposed) _fgServiceRunning = false;
        }),
      );
      return;
    }

    final elapsed = DateTime.now().difference(_lastFgProgressUpdate).inMilliseconds;
    if (!force && elapsed < progressThrottleMs) return;

    _lastFgProgressUpdate = DateTime.now();
    unawaited(_safeFg(() => _foregroundService.updateProgress(payload)));
  }

  ForegroundProgressPayload _buildAggregatePayload() {
    var totalProgress = 0.0;
    var totalSpeed = 0.0;
    var count = 0;
    String? singleTitle;
    for (final id in _runningIds) {
      final job = _jobs[id];
      if (job == null || job.status == DownloadStatus.paused) continue;
      count++;
      singleTitle = job.title;
      totalProgress += job.progress;
      totalSpeed += job.speedBytesPerSec;
    }
    final avgPct = count == 0 ? 0 : ((totalProgress / count) * 100).round();
    final mbps = (totalSpeed / (1024 * 1024)).toStringAsFixed(1);
    return ForegroundProgressPayload(
      title: count == 1 && singleTitle != null
          ? singleTitle
          : 'Active Downloads ($count)',
      body: '$avgPct% • $mbps MB/s',
      progress: avgPct.clamp(0, 100),
      indeterminate: avgPct == 0 && totalSpeed == 0,
      pauseLabel: pauseLabel,
      cancelLabel: cancelLabel,
    );
  }

  void _listenForegroundActions() {
    try {
      _actionSub = _foregroundService.actions.listen(
        (action) {
          switch (action) {
            case ServiceNotificationAction.pauseAll:
              unawaited(pauseAll());
            case ServiceNotificationAction.cancelAll:
              unawaited(cancelAll());
            case ServiceNotificationAction.unknown:
              break;
          }
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  Future<bool> _safeFg(Future<bool> Function() op) async {
    try {
      return await op();
    } catch (_) {
      return false;
    }
  }

  static StreamDownloadCoordinator _defaultCoordinatorFactory(
    DownloadJobRequest request, {
    required void Function(DownloadJobState state) onStateChanged,
  }) =>
      StreamDownloadCoordinator(
        request: request,
        onStateChanged: onStateChanged,
      );

  @override
  void dispose() {
    _disposed = true;
    unawaited(_actionSub?.cancel());
    _actionSub = null;
    if (_fgServiceRunning) {
      _fgServiceRunning = false;
      unawaited(_safeFg(_foregroundService.stopService));
    }
    super.dispose();
  }
}
