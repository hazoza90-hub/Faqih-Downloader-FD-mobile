import 'dart:async';

import 'package:path/path.dart' as p;

import '../../core/models/audio_track.dart';
import '../../core/models/download_status.dart';
import '../../core/models/video_format_option.dart';
import '../../core/utils/url_detector.dart';
import '../../engine/engine_callbacks.dart';
import '../../engine/isolate_download_runner.dart';
import '../../platform/youtube_dl_channel.dart';
import '../media/media_exceptions.dart';
import '../media/youtube_innertube_extractor.dart';
import 'download_job_models.dart';
import 'media_stream_helpers.dart';
import 'ytdlp_stream_downloader.dart';

typedef DownloadRunnerFactory = IsolateDownloadRunner Function({
  required String url,
  required String destinationPath,
  Map<String, String> headers,
  int maxConnections,
  double speedLimitBytesPerSec,
  EngineCallbacks? callbacks,
});

class AcquiredMediaFiles {
  const AcquiredMediaFiles({required this.videoPath, this.audioPath});
  final String videoPath;
  final String? audioPath;
}

class TurboExpiredException implements Exception {
  const TurboExpiredException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Acquires raw video/audio streams via Turbo engine or [YtDlpStreamDownloader] fallback.
class MediaStreamAcquirer {
  MediaStreamAcquirer({
    required YoutubeDlChannel youtubeDl,
    required DownloadRunnerFactory runnerFactory,
    YouTubeInnerTubeExtractor? innerTubeExtractor,
  })  : _ytDlpDownloader = YtDlpStreamDownloader(youtubeDl),
        _runnerFactory = runnerFactory,
        _innerTube = innerTubeExtractor ?? YouTubeInnerTubeExtractor();

  final YtDlpStreamDownloader _ytDlpDownloader;
  final DownloadRunnerFactory _runnerFactory;
  final YouTubeInnerTubeExtractor _innerTube;

  Future<void> runTurboTransfer({
    required String url,
    required String destinationPath,
    required Map<String, String> headers,
    required int maxConnections,
    required double speedLimitBytesPerSec,
    required DownloadPhase phase,
    required bool Function() isCancelled,
    required bool Function() isPaused,
    required void Function(IsolateDownloadRunner? runner) setActiveRunner,
    required void Function(DownloadPhase p, EngineProgressSnapshot snap) onProgress,
  }) async {
    Object? capturedError;
    var expiredError = false;
    var completed = false;

    final runner = _runnerFactory(
      url: url,
      destinationPath: destinationPath,
      headers: headers,
      maxConnections: maxConnections,
      speedLimitBytesPerSec: speedLimitBytesPerSec,
      callbacks: EngineCallbacks(
        onProgress: (snap) {
          if (isCancelled() || isPaused()) return;
          onProgress(
            snap.status == DownloadStatus.probing ? DownloadPhase.probing : phase,
            snap,
          );
        },
        onComplete: (_, _, _) => completed = true,
        onError: (err, {linkExpired = false, httpStatus}) {
          capturedError = err;
          expiredError = linkExpired || httpStatus == 403 || httpStatus == 410;
        },
      ),
    );

    setActiveRunner(runner);
    try {
      await runner.start();
      if (isPaused()) runner.pause();
      if (isCancelled()) runner.cancel();
      await runner.completion;
    } finally {
      setActiveRunner(null);
    }

    if (isCancelled()) return;
    if (capturedError != null) {
      if (expiredError) throw TurboExpiredException(capturedError.toString());
      throw capturedError!;
    }
    if (!completed) {
      throw StateError('Turbo transfer finished without completion signal');
    }
  }

  Future<AcquiredMediaFiles> acquireMedia({
    required DownloadJobRequest request,
    required String jobDir,
    required double speedLimitBytesPerSec,
    required bool Function() isCancelled,
    required bool Function() isPaused,
    required void Function(IsolateDownloadRunner? runner) setActiveRunner,
    required void Function(String? pid) setActiveProcessId,
    required void Function(DownloadPhase phase) setActivePhase,
    required void Function(DownloadPhase phase, EngineProgressSnapshot snap)
        onTurboProgress,
    required void Function(
      DownloadPhase phase,
      double progress,
      double eta,
      int downloadedBytes,
      int totalBytes,
      double speedBytesPerSec,
    ) onYtDlpProgress,
  }) async {
    var fmt = request.selectedVideoFormat;
    var audio = request.selectedAudioTrack ?? fmt?.selectedAudioTrack;

    if (fmt == null &&
        !request.audioOnly &&
        UrlDetector.extractYouTubeId(request.url) != null &&
        !request.url.toLowerCase().contains('/playlist?')) {
      final fast = await _innerTube.extract(request.url);
      if (isCancelled()) {
        throw const MediaExtractionException(
          kind: MediaErrorKind.cancelled,
          message: 'Download cancelled',
        );
      }
      final picked = fast == null
          ? null
          : MediaStreamHelpers.pickInnerTubeFormat(fast, request.preferredVideoHeight);
      if (picked != null) {
        fmt = picked;
        audio ??= picked.selectedAudioTrack ?? fast!.selectedAudioTrack;
      }
    }

    if (canTryTurbo(request, fmt, audio)) {
      try {
        return await _downloadDirectStreams(
          request: request,
          jobDir: jobDir,
          fmt: fmt,
          audio: audio,
          speedLimitBytesPerSec: speedLimitBytesPerSec,
          isCancelled: isCancelled,
          isPaused: isPaused,
          setActiveRunner: setActiveRunner,
          setActivePhase: setActivePhase,
          onTurboProgress: onTurboProgress,
        );
      } catch (err) {
        if (isCancelled()) rethrow;
        if (err is MediaExtractionException &&
            err.kind == MediaErrorKind.cancelled) {
          rethrow;
        }
        MediaStreamHelpers.cleanupTurboArtifacts(jobDir);
        if (err is TurboExpiredException &&
            UrlDetector.extractYouTubeId(request.url) != null &&
            !request.url.toLowerCase().contains('/playlist?')) {
          final rotated = await _retryTurboWithBackupProfile(
            request: request,
            jobDir: jobDir,
            originalFmt: fmt,
            originalAudio: audio,
            speedLimitBytesPerSec: speedLimitBytesPerSec,
            isCancelled: isCancelled,
            isPaused: isPaused,
            setActiveRunner: setActiveRunner,
            setActivePhase: setActivePhase,
            onTurboProgress: onTurboProgress,
          );
          if (rotated != null) return rotated;
          MediaStreamHelpers.cleanupTurboArtifacts(jobDir);
        }
      }
    }

    final path = await _ytDlpDownloader.download(
      request: request,
      jobDir: jobDir,
      formatOption: fmt,
      audioOption: audio,
      isCancelled: isCancelled,
      setActiveProcessId: setActiveProcessId,
      setActivePhase: setActivePhase,
      onProgress: onYtDlpProgress,
    );
    return AcquiredMediaFiles(videoPath: path);
  }

  Future<AcquiredMediaFiles?> _retryTurboWithBackupProfile({
    required DownloadJobRequest request,
    required String jobDir,
    required VideoFormatOption? originalFmt,
    required AudioTrack? originalAudio,
    required double speedLimitBytesPerSec,
    required bool Function() isCancelled,
    required bool Function() isPaused,
    required void Function(IsolateDownloadRunner? runner) setActiveRunner,
    required void Function(DownloadPhase phase) setActivePhase,
    required void Function(DownloadPhase phase, EngineProgressSnapshot snap)
        onTurboProgress,
  }) async {
    final backupInfo = await _innerTube.extract(request.url, startProfileIndex: 1);
    if (isCancelled()) {
      throw const MediaExtractionException(
        kind: MediaErrorKind.cancelled,
        message: 'Download cancelled',
      );
    }
    if (backupInfo == null) return null;
    final targetHeight = (originalFmt?.height ?? 0) > 0
        ? originalFmt!.height
        : request.preferredVideoHeight;
    final altFmt = request.audioOnly
        ? null
        : MediaStreamHelpers.pickInnerTubeFormat(
            backupInfo, targetHeight,
            preferredFormatId: originalFmt?.formatId,
            preferredVcodec: originalFmt?.vcodec,
          );
    final wantsAudio = request.audioOnly ||
        (altFmt?.needsAudioMerge ?? false) ||
        (originalAudio != null && !originalAudio.isOriginal);
    final altAudio = MediaStreamHelpers.matchAudioTrack(
      backupInfo,
      preferredAudio: originalAudio,
      pickedVideo: altFmt,
      wantsAudio: wantsAudio,
    );
    if (!canTryTurbo(request, altFmt, altAudio)) return null;
    try {
      return await _downloadDirectStreams(
        request: request,
        jobDir: jobDir,
        fmt: altFmt,
        audio: altAudio,
        speedLimitBytesPerSec: speedLimitBytesPerSec,
        isCancelled: isCancelled,
        isPaused: isPaused,
        setActiveRunner: setActiveRunner,
        setActivePhase: setActivePhase,
        onTurboProgress: onTurboProgress,
      );
    } catch (err) {
      if (isCancelled()) rethrow;
      if (err is MediaExtractionException &&
          err.kind == MediaErrorKind.cancelled) {
        rethrow;
      }
      return null;
    }
  }

  Future<AcquiredMediaFiles> _downloadDirectStreams({
    required DownloadJobRequest request,
    required String jobDir,
    required VideoFormatOption? fmt,
    required AudioTrack? audio,
    required double speedLimitBytesPerSec,
    required bool Function() isCancelled,
    required bool Function() isPaused,
    required void Function(IsolateDownloadRunner? runner) setActiveRunner,
    required void Function(DownloadPhase phase) setActivePhase,
    required void Function(DownloadPhase phase, EngineProgressSnapshot snap)
        onTurboProgress,
  }) async {
    if (request.audioOnly) {
      final audioUrl = (audio?.url.isNotEmpty ?? false)
          ? audio!.url
          : (fmt?.audioUrl ?? fmt!.videoUrl);
      final ext = (audio?.ext ?? fmt?.audioExt ?? 'm4a').trim();
      final audioPath = p.join(jobDir, 'raw_audio.${ext.isEmpty ? 'm4a' : ext}');
      setActivePhase(DownloadPhase.downloadingAudio);
      await runTurboTransfer(
        url: audioUrl,
        destinationPath: audioPath,
        headers: MediaStreamHelpers.mergeStreamHeaders(
          audioUrl,
          {...request.headers, ...?audio?.httpHeaders},
          request.cookiesFile,
        ),
        maxConnections: request.maxConnections,
        speedLimitBytesPerSec: speedLimitBytesPerSec,
        phase: DownloadPhase.downloadingAudio,
        isCancelled: isCancelled,
        isPaused: isPaused,
        setActiveRunner: setActiveRunner,
        onProgress: onTurboProgress,
      );
      return AcquiredMediaFiles(videoPath: audioPath);
    }

    final wantsSeparateAudio =
        fmt!.needsAudioMerge || (audio != null && !audio.isOriginal);
    final aUrl = (audio?.url.isNotEmpty ?? false) ? audio!.url : fmt.audioUrl;
    final hasSeparateAudio =
        wantsSeparateAudio && aUrl != null && aUrl.isNotEmpty;
    final estimatedAudioBytes =
        (audio?.filesize ?? 0) > 0 ? audio!.filesize : fmt.audioSize;
    var lastVideoTotalBytes = 0;

    final vExt = fmt.ext.trim().isEmpty ? 'mp4' : fmt.ext.trim();
    final vPath = p.join(jobDir, 'raw_video.$vExt');
    setActivePhase(DownloadPhase.downloadingVideo);
    await runTurboTransfer(
      url: fmt.videoUrl,
      destinationPath: vPath,
      headers: MediaStreamHelpers.mergeStreamHeaders(
        fmt.videoUrl,
        {...request.headers, ...fmt.videoHeaders},
        request.cookiesFile,
      ),
      maxConnections: request.maxConnections,
      speedLimitBytesPerSec: speedLimitBytesPerSec,
      phase: DownloadPhase.downloadingVideo,
      isCancelled: isCancelled,
      isPaused: isPaused,
      setActiveRunner: setActiveRunner,
      onProgress: (p, snap) {
        if (snap.totalBytes > 0) lastVideoTotalBytes = snap.totalBytes;
        final out = hasSeparateAudio
            ? MediaStreamHelpers.combineDualStreamSnapshot(
                snap, isAudioStage: false, estimatedAudioBytes: estimatedAudioBytes)
            : snap;
        onTurboProgress(p, out);
      },
    );

    String? aPath;
    if (hasSeparateAudio) {
      final actualVideoBytes = MediaStreamHelpers.resolveCompletedFileBytes(
          vPath, fallbackBytes: lastVideoTotalBytes);
      final aExt = (audio?.ext ?? fmt.audioExt).trim();
      aPath = p.join(jobDir, 'raw_audio.${aExt.isEmpty ? 'm4a' : aExt}');
      setActivePhase(DownloadPhase.downloadingAudio);
      await runTurboTransfer(
        url: aUrl,
        destinationPath: aPath,
        headers: MediaStreamHelpers.mergeStreamHeaders(
          aUrl,
          {...request.headers, ...fmt.audioHeaders, ...?audio?.httpHeaders},
          request.cookiesFile,
        ),
        maxConnections: request.maxConnections,
        speedLimitBytesPerSec: speedLimitBytesPerSec,
        phase: DownloadPhase.downloadingAudio,
        isCancelled: isCancelled,
        isPaused: isPaused,
        setActiveRunner: setActiveRunner,
        onProgress: (p, snap) => onTurboProgress(
          p,
          MediaStreamHelpers.combineDualStreamSnapshot(
            snap, isAudioStage: true, estimatedAudioBytes: estimatedAudioBytes,
            completedVideoBytes: actualVideoBytes,
          ),
        ),
      );
    }
    return AcquiredMediaFiles(videoPath: vPath, audioPath: aPath);
  }

  static bool canTryTurbo(
    DownloadJobRequest request, VideoFormatOption? fmt, AudioTrack? audio,
  ) => MediaStreamHelpers.canTryTurbo(request, fmt, audio);

  static bool isManifestUrl(String url, {String protocol = ''}) =>
      MediaStreamHelpers.isManifestUrl(url, protocol: protocol);
}
