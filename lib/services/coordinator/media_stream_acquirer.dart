import 'dart:async';

import 'package:path/path.dart' as p;

import '../../core/models/audio_track.dart';
import '../../core/models/download_status.dart';
import '../../core/models/video_format_option.dart';
import '../../engine/engine_callbacks.dart';
import '../../engine/isolate_download_runner.dart';
import '../../platform/youtube_dl_channel.dart';
import 'download_job_models.dart';
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
  })  : _ytDlpDownloader = YtDlpStreamDownloader(youtubeDl),
        _runnerFactory = runnerFactory;

  final YtDlpStreamDownloader _ytDlpDownloader;
  final DownloadRunnerFactory _runnerFactory;

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
    required void Function(DownloadPhase phase, double progress, double eta)
        onYtDlpProgress,
  }) async {
    final fmt = request.selectedVideoFormat;
    final audio = request.selectedAudioTrack ?? fmt?.selectedAudioTrack;

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
      } on TurboExpiredException {
        if (isCancelled()) rethrow;
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
        headers: {...request.headers, ...?audio?.httpHeaders},
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

    final vExt = fmt!.ext.trim().isEmpty ? 'mp4' : fmt.ext.trim();
    final vPath = p.join(jobDir, 'raw_video.$vExt');
    setActivePhase(DownloadPhase.downloadingVideo);
    await runTurboTransfer(
      url: fmt.videoUrl,
      destinationPath: vPath,
      headers: {...request.headers, ...fmt.videoHeaders},
      maxConnections: request.maxConnections,
      speedLimitBytesPerSec: speedLimitBytesPerSec,
      phase: DownloadPhase.downloadingVideo,
      isCancelled: isCancelled,
      isPaused: isPaused,
      setActiveRunner: setActiveRunner,
      onProgress: onTurboProgress,
    );

    String? aPath;
    final wantsSeparateAudio =
        fmt.needsAudioMerge || (audio != null && !audio.isOriginal);
    final aUrl = (audio?.url.isNotEmpty ?? false) ? audio!.url : fmt.audioUrl;
    if (wantsSeparateAudio && aUrl != null && aUrl.isNotEmpty) {
      final aExt = (audio?.ext ?? fmt.audioExt).trim();
      aPath = p.join(jobDir, 'raw_audio.${aExt.isEmpty ? 'm4a' : aExt}');
      setActivePhase(DownloadPhase.downloadingAudio);
      await runTurboTransfer(
        url: aUrl,
        destinationPath: aPath,
        headers: {...request.headers, ...fmt.audioHeaders, ...?audio?.httpHeaders},
        maxConnections: request.maxConnections,
        speedLimitBytesPerSec: speedLimitBytesPerSec,
        phase: DownloadPhase.downloadingAudio,
        isCancelled: isCancelled,
        isPaused: isPaused,
        setActiveRunner: setActiveRunner,
        onProgress: onTurboProgress,
      );
    }
    return AcquiredMediaFiles(videoPath: vPath, audioPath: aPath);
  }

  static bool canTryTurbo(
    DownloadJobRequest request,
    VideoFormatOption? fmt,
    AudioTrack? audio,
  ) {
    if (request.audioOnly) {
      final url = audio?.url ?? fmt?.audioUrl ?? fmt?.videoUrl ?? '';
      return url.isNotEmpty && !isManifestUrl(url);
    }
    if (fmt == null || !fmt.isDirectTurboSupported) return false;
    final wantsSeparateAudio =
        fmt.needsAudioMerge || (audio != null && !audio.isOriginal);
    if (wantsSeparateAudio) {
      final aUrl =
          (audio?.url.isNotEmpty ?? false) ? audio!.url : (fmt.audioUrl ?? '');
      if (aUrl.isNotEmpty && isManifestUrl(aUrl)) return false;
    }
    return true;
  }

  static bool isManifestUrl(String url) {
    final u = url.toLowerCase();
    return u.contains('.m3u8') || u.contains('.mpd');
  }
}
