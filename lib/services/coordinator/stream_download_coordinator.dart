import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/models/download_status.dart';
import '../../core/utils/category_classifier.dart';
import '../../core/utils/filename_sanitizer.dart';
import '../../core/utils/url_detector.dart';
import '../../engine/engine_callbacks.dart';
import '../../engine/isolate_download_runner.dart';
import '../../platform/media_store_channel.dart';
import '../../platform/youtube_dl_channel.dart';
import '../history/history_manager.dart';
import '../media/ffmpeg_media_processor.dart';
import '../media/subtitle_font_provisioner.dart';
import '../media/subtitle_processor.dart';
import '../resolver/html_candidate_parser.dart';
import '../resolver/html_download_resolver.dart';
import 'download_job_models.dart';
import 'job_export_helper.dart';
import 'media_post_pipeline.dart';
import 'media_stream_acquirer.dart';

/// Coordinates a complete download job from transfer through post-processing and MediaStore export.
class StreamDownloadCoordinator {
  StreamDownloadCoordinator({
    required this.request,
    YoutubeDlChannel? youtubeDlChannel,
    MediaStoreChannel? mediaStoreChannel,
    FfmpegMediaProcessor? ffmpegProcessor,
    SubtitleProcessor? subtitleProcessor,
    SubtitleFontProvisioner? fontProvisioner,
    DownloadHistoryManager? historyManager,
    DownloadRunnerFactory? runnerFactory,
    HtmlDownloadResolver? htmlResolver,
    void Function(DownloadJobState state)? onStateChanged,
    DateTime Function()? clock,
  })  : _youtubeDl = youtubeDlChannel ?? YoutubeDlChannel(),
        _mediaStore = mediaStoreChannel ?? MediaStoreChannel(),
        _ffmpeg =
            ffmpegProcessor ?? FfmpegMediaProcessor(channel: youtubeDlChannel),
        _subtitleProcessor = subtitleProcessor ?? SubtitleProcessor(),
        _fontProvisioner = fontProvisioner ?? SubtitleFontProvisioner(),
        _history = historyManager,
        _runnerFactory =
            runnerFactory ?? CoordinatorHelpers.defaultRunnerFactory,
        _hasCustomRunner = runnerFactory != null,
        _hasCustomResolver = htmlResolver != null,
        _htmlResolver = htmlResolver ?? HtmlDownloadResolver(),
        _onStateChanged = onStateChanged,
        _clock = clock ?? (() => DateTime.now().toUtc()),
        _speedLimitBytesPerSec = request.speedLimitBytesPerSec,
        _state = DownloadJobState.fromRequest(
          request,
          createdAt: (clock ?? (() => DateTime.now().toUtc()))(),
          category:
              request.categorySubFolder ?? classifyCategory(request.title),
        );

  final DownloadJobRequest request;
  final YoutubeDlChannel _youtubeDl;
  final MediaStoreChannel _mediaStore;
  final FfmpegMediaProcessor _ffmpeg;
  final SubtitleProcessor _subtitleProcessor;
  final SubtitleFontProvisioner _fontProvisioner;
  final DownloadHistoryManager? _history;
  final DownloadRunnerFactory _runnerFactory;
  final bool _hasCustomRunner;
  final bool _hasCustomResolver;
  final HtmlDownloadResolver _htmlResolver;
  final void Function(DownloadJobState state)? _onStateChanged;
  final DateTime Function() _clock;

  DownloadJobState _state;
  IsolateDownloadRunner? _activeRunner;
  String? _activeProcessId;
  String? _jobDirPath;
  bool _pauseRequested = false;
  bool _cancelRequested = false;
  int _speedLimitBytesPerSec;
  DownloadPhase _activeDownloadPhase = DownloadPhase.downloadingDirect;

  DownloadJobState get state => _state;

  Future<DownloadJobState> start() async {
    try {
      final workDir = await _mediaStore.getAppWorkDir();
      final jobDir = p.join(
        workDir,
        'job_${sanitizeFilename(request.id, fallback: 'job')}',
      );
      _jobDirPath = jobDir;
      await Directory(jobDir).create(recursive: true);

      _emitState(_state.copyWith(phase: DownloadPhase.probing, progress: 0.0));
      unawaited(_saveHistory(DownloadStatus.probing).catchError((_) {}));

      final acquirer = MediaStreamAcquirer(
        youtubeDl: _youtubeDl,
        runnerFactory: _runnerFactory,
      );
      final plan = request.isMediaJob
          ? await _executeMediaJob(jobDir, workDir, acquirer)
          : await _executeDirectJob(jobDir, acquirer);

      if (_cancelRequested) return await _finalizeCancelled();

      _emitState(_state.copyWith(
        phase: DownloadPhase.exporting,
        progress: 0.96,
        speedBytesPerSec: 0.0,
        etaSeconds: 0.0,
        category: plan.category,
      ));

      final exported = await _mediaStore.exportToDownloads(
        sourcePath: plan.sourcePath,
        displayName: plan.displayName,
        mimeType: CoordinatorHelpers.mimeTypeForExt(plan.ext),
        subFolder: request.autoCategorizeFolders ? plan.category : null,
        treeUri: request.customSaveTreeUri.isEmpty ? null : request.customSaveTreeUri,
        deleteSource: true,
      );

      final finalSize =
          exported.sizeBytes > 0 ? exported.sizeBytes : _state.totalBytes;
      final completed = _state.copyWith(
        phase: DownloadPhase.completed,
        status: DownloadStatus.completed,
        progress: 1.0,
        downloadedBytes: finalSize,
        totalBytes: finalSize,
        speedBytesPerSec: 0.0,
        etaSeconds: 0.0,
        exportedUri: exported.uri,
        exportedDisplayPath: exported.displayPath,
        category: plan.category,
        clearErrorMessage: true,
      );
      _emitState(completed);
      await _saveHistory(
        DownloadStatus.completed,
        stateOverride: completed,
        filename: plan.displayName,
        filePath: exported.displayPath,
        contentUri: exported.uri,
        category: plan.category,
        totalSize: finalSize,
        downloadedBytes: finalSize,
        completedAt: _clock(),
      );
      return completed;
    } catch (err) {
      if (_cancelRequested || CoordinatorHelpers.isCancelledError(err)) {
        return await _finalizeCancelled();
      }
      final failed = _state.copyWith(
        phase: DownloadPhase.failed,
        status: DownloadStatus.failed,
        speedBytesPerSec: 0.0,
        errorMessage: err.toString(),
      );
      _emitState(failed);
      await _saveHistory(DownloadStatus.failed, stateOverride: failed);
      return failed;
    } finally {
      if (_state.phase != DownloadPhase.paused) {
        await CoordinatorHelpers.cleanupDirectory(_jobDirPath);
      }
    }
  }

  Future<void> pause() async {
    if (_cancelRequested || _state.status.isTerminal) return;
    _pauseRequested = true;
    _activeRunner?.pause();
    _emitState(_state.copyWith(
      phase: DownloadPhase.paused,
      status: DownloadStatus.paused,
      speedBytesPerSec: 0.0,
    ));
    await _saveHistory(DownloadStatus.paused);
  }

  Future<void> resume() async {
    if (_cancelRequested || _state.status.isTerminal) return;
    _pauseRequested = false;
    _activeRunner?.resume();
    _emitState(_state.copyWith(
      phase: _activeDownloadPhase,
      status: statusForPhase(_activeDownloadPhase),
    ));
    await _saveHistory(DownloadStatus.downloading);
  }

  Future<void> cancel() async {
    _cancelRequested = true;
    _pauseRequested = false;
    final runner = _activeRunner;
    runner?.cancel();
    final pid = _activeProcessId;
    if (pid != null) {
      unawaited(_youtubeDl.cancelProcess(pid).catchError((_) => false));
      unawaited(_ffmpeg.cancel(pid).catchError((_) => false));
    }
    if (runner != null) {
      try {
        await runner.completion.timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    await _finalizeCancelled();
    await CoordinatorHelpers.cleanupDirectory(_jobDirPath);
  }

  void setSpeedLimit(int bytesPerSec) {
    _speedLimitBytesPerSec = bytesPerSec < 0 ? 0 : bytesPerSec;
    _activeRunner?.setSpeedLimit(_speedLimitBytesPerSec.toDouble());
  }

  Future<ExportPlan> _executeDirectJob(
    String jobDir,
    MediaStreamAcquirer acquirer,
  ) async {
    final targetUrl = HtmlCandidateParser.normalizeDirectUrl(request.url);
    final skipResolve =
        request.skipHtmlResolve || UrlDetector.isDirectDownloadUrl(targetUrl);
    final resolved = (!skipResolve && (_hasCustomResolver || !_hasCustomRunner))
        ? await CoordinatorHelpers.resolveDirectTarget(
            _htmlResolver,
            url: targetUrl,
            headers: request.headers,
          )
        : null;

    final effectiveUrl =
        (resolved != null && resolved.url.isNotEmpty) ? resolved.url : targetUrl;
    final effectiveHeaders = resolved != null && resolved.headers.isNotEmpty
        ? <String, String>{...request.headers, ...resolved.headers}
        : request.headers;
    final displayName = CoordinatorHelpers.resolveDirectDisplayName(
      requestTitle: request.title,
      requestUrl: request.url,
      effectiveUrl: effectiveUrl,
      resolved: resolved,
    );
    final resolvedCategory = CoordinatorHelpers.resolveCategory(request, displayName);
    if (displayName != _state.title || resolvedCategory != _state.category) {
      _emitState(_state.copyWith(title: displayName, category: resolvedCategory));
    }

    final destPath = p.join(jobDir, displayName);
    _activeDownloadPhase = DownloadPhase.downloadingDirect;
    await acquirer.runTurboTransfer(
      url: effectiveUrl,
      destinationPath: destPath,
      headers: effectiveHeaders,
      maxConnections: request.maxConnections,
      speedLimitBytesPerSec: _speedLimitBytesPerSec.toDouble(),
      phase: DownloadPhase.downloadingDirect,
      isCancelled: () => _cancelRequested,
      isPaused: () => _pauseRequested,
      setActiveRunner: (r) => _activeRunner = r,
      onProgress: _handleTurboProgress,
    );

    final finalExt = p.extension(displayName).replaceFirst('.', '').trim();
    return ExportPlan(
      sourcePath: destPath,
      displayName: displayName,
      ext: finalExt.isEmpty ? CoordinatorHelpers.extractUrlExtension(effectiveUrl) : finalExt,
      category: resolvedCategory,
    );
  }

  Future<ExportPlan> _executeMediaJob(
    String jobDir,
    String workDir,
    MediaStreamAcquirer acquirer,
  ) async {
    final audioOpt =
        request.selectedAudioTrack ?? request.selectedVideoFormat?.selectedAudioTrack;
    final acquired = await acquirer.acquireMedia(
      request: request,
      jobDir: jobDir,
      speedLimitBytesPerSec: _speedLimitBytesPerSec.toDouble(),
      isCancelled: () => _cancelRequested,
      isPaused: () => _pauseRequested,
      setActiveRunner: (r) => _activeRunner = r,
      setActiveProcessId: (pid) => _activeProcessId = pid,
      setActivePhase: (phase) => _activeDownloadPhase = phase,
      onTurboProgress: _handleTurboProgress,
      onYtDlpProgress: (phase, ratio, eta, downloaded, total, speed) {
        _emitState(_state.copyWith(
          phase: phase,
          progress: ratio,
          etaSeconds: eta,
          downloadedBytes: downloaded > 0 ? downloaded : _state.downloadedBytes,
          totalBytes: total > 0 ? total : _state.totalBytes,
          speedBytesPerSec: speed,
        ));
      },
    );

    final pipeline = MediaPostPipeline(
      ffmpeg: _ffmpeg,
      subtitleProcessor: _subtitleProcessor,
      fontProvisioner: _fontProvisioner,
    );
    final result = await pipeline.process(
      request: request,
      jobDir: jobDir,
      workDir: workDir,
      rawVideoPath: acquired.videoPath,
      rawAudioPath: acquired.audioPath,
      isCancelled: () => _cancelRequested,
      onPhase: (phase, {progress}) {
        _emitState(_state.copyWith(
          phase: phase,
          progress: progress ?? _state.progress,
          speedBytesPerSec: 0.0,
        ));
      },
      onTrackProcess: (pid) => _activeProcessId = pid,
    );

    final cleanStem = sanitizeFilename(
      request.title,
      isClip: request.clipRange?.isActive ?? false,
      hasSub: request.selectedSubtitle != null &&
          request.subtitleMode != SubtitleMode.none,
      hasDub: audioOpt != null && !audioOpt.isOriginal,
      fallback: 'media',
    );
    final displayName = '$cleanStem.${result.ext}';
    return ExportPlan(
      sourcePath: result.filePath,
      displayName: displayName,
      ext: result.ext,
      category: CoordinatorHelpers.resolveCategory(request, displayName),
    );
  }

  void _handleTurboProgress(DownloadPhase phase, EngineProgressSnapshot snap) {
    if (_pauseRequested || _cancelRequested) return;
    _emitState(_state.copyWith(
      phase: phase,
      status: statusForPhase(phase),
      progress: snap.progressRatio,
      downloadedBytes: snap.downloadedBytes,
      totalBytes: snap.totalBytes,
      speedBytesPerSec: snap.speedBytesPerSec,
      etaSeconds: snap.etaSeconds,
    ));
  }

  Future<DownloadJobState> _finalizeCancelled() async {
    final cancelled = _state.copyWith(
      phase: DownloadPhase.cancelled,
      status: DownloadStatus.cancelled,
      speedBytesPerSec: 0.0,
    );
    _emitState(cancelled);
    await _saveHistory(DownloadStatus.cancelled, stateOverride: cancelled);
    return cancelled;
  }

  Future<void> _saveHistory(
    DownloadStatus status, {
    DownloadJobState? stateOverride,
    String? filename,
    String? filePath,
    String? contentUri,
    String? category,
    int? totalSize,
    int? downloadedBytes,
    DateTime? completedAt,
  }) =>
      CoordinatorHelpers.upsertHistory(
        _history,
        request: request,
        state: stateOverride ?? _state,
        status: status,
        filename: filename,
        filePath: filePath,
        contentUri: contentUri,
        category: category,
        totalSize: totalSize,
        downloadedBytes: downloadedBytes,
        completedAt: completedAt,
      );

  void _emitState(DownloadJobState next) {
    _state = next;
    _onStateChanged?.call(next);
  }
}
