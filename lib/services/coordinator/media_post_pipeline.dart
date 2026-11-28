import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/models/clip_range.dart';
import '../media/ffmpeg_media_processor.dart';
import '../media/media_exceptions.dart';
import '../media/subtitle_font_provisioner.dart';
import '../media/subtitle_processor.dart';
import 'download_job_models.dart';

class MediaPipelineResult {
  const MediaPipelineResult({
    required this.filePath,
    required this.ext,
  });

  final String filePath;
  final String ext;
}

/// Orchestrates post-download subtitle normalization, muxing, clipping, and audio extraction.
class MediaPostPipeline {
  const MediaPostPipeline({
    required this.ffmpeg,
    required this.subtitleProcessor,
    required this.fontProvisioner,
  });

  final FfmpegMediaProcessor ffmpeg;
  final SubtitleProcessor subtitleProcessor;
  final SubtitleFontProvisioner fontProvisioner;

  Future<MediaPipelineResult> process({
    required DownloadJobRequest request,
    required String jobDir,
    required String workDir,
    required String rawVideoPath,
    String? rawAudioPath,
    required bool Function() isCancelled,
    required void Function(DownloadPhase phase, {double? progress}) onPhase,
    required void Function(String? processId) onTrackProcess,
  }) async {
    _checkCancelled(isCancelled);

    final subTrack = request.selectedSubtitle;
    String? subPath;
    String? fontsDir;
    if (!request.audioOnly &&
        subTrack != null &&
        request.subtitleMode != SubtitleMode.none) {
      onPhase(DownloadPhase.downloadingSubtitle, progress: 0.05);
      final targetSub = p.join(jobDir, 'sub_${subTrack.language}.srt');
      final isHardAr = request.subtitleMode == SubtitleMode.hardBurn &&
          SubtitleProcessor.isArabicLanguage(subTrack.language);
      subPath = await subtitleProcessor.downloadAndNormalize(
        subTrack,
        targetSub,
        headers: request.headers,
        prepareForArabicHardBurn: isHardAr,
      );
      if (request.subtitleMode == SubtitleMode.hardBurn) {
        fontsDir = await fontProvisioner.ensureFontsDir(workDir);
      }
      _checkCancelled(isCancelled);
    }

    onPhase(DownloadPhase.processingFfmpeg, progress: 0.0);
    final durSec = request.durationSec > 0 ? request.durationSec.toDouble() : null;
    final sourceExt = p.extension(rawVideoPath).replaceFirst('.', '').trim().toLowerCase();
    var currentPath = rawVideoPath;
    var remuxedByFfmpeg = false;

    if (request.audioOnly) {
      return _processAudioOnly(
        request: request,
        jobDir: jobDir,
        sourcePath: rawAudioPath ?? rawVideoPath,
        durSec: durSec,
        isCancelled: isCancelled,
        onPhase: onPhase,
        onTrackProcess: onTrackProcess,
      );
    }

    var videoExt = _normalizedVideoExt(
      currentPath,
      request.selectedVideoFormat?.ext,
      vcodec: request.selectedVideoFormat?.vcodec ?? '',
    );
    var wasMuxedToMp4 = false;
    if (rawAudioPath != null && rawAudioPath.isNotEmpty) {
      final audioCodec = request.selectedAudioTrack?.codec ??
          request.selectedVideoFormat?.selectedAudioTrack?.codec ??
          request.selectedVideoFormat?.acodec;
      try {
        final muxOut = p.join(jobDir, 'stage_mux.$videoExt');
        final pid = '${request.id}_mux';
        onTrackProcess(pid);
        currentPath = await ffmpeg.muxVideoAndAudio(
          videoPath: currentPath,
          audioPath: rawAudioPath,
          outputPath: muxOut,
          audioCodec: audioCodec,
          processId: pid,
          durationSec: durSec,
          onProgress: (r) => onPhase(DownloadPhase.processingFfmpeg, progress: r),
        );
        wasMuxedToMp4 = videoExt == 'mp4';
      } on MediaProcessingException catch (e) {
        if (e.kind == MediaErrorKind.cancelled ||
            isCancelled() ||
            videoExt == 'mkv') {
          rethrow;
        }
        videoExt = 'mkv';
        final mkvOut = p.join(jobDir, 'stage_mux.mkv');
        final mkvPid = '${request.id}_mux_mkv';
        onTrackProcess(mkvPid);
        currentPath = await ffmpeg.muxVideoAndAudio(
          videoPath: currentPath,
          audioPath: rawAudioPath,
          outputPath: mkvOut,
          audioCodec: audioCodec,
          processId: mkvPid,
          durationSec: durSec,
          onProgress: (r) => onPhase(DownloadPhase.processingFfmpeg, progress: r),
        );
        wasMuxedToMp4 = false;
      } finally {
        onTrackProcess(null);
      }
      if (File(currentPath).existsSync() && File(currentPath).lengthSync() > 0) {
        _safeDeleteRaw(rawVideoPath, currentPath);
        _safeDeleteRaw(rawAudioPath, currentPath);
      }
      remuxedByFfmpeg = true;
      _checkCancelled(isCancelled);
    }

    final clipRange = request.clipRange;
    final hasClip = clipRange != null && clipRange.isActive;
    if (hasClip && subPath != null) {
      final rawSrt = await File(subPath).readAsString();
      final clippedSrt = SubtitleProcessor.shiftAndClipSrt(
        rawSrt,
        clipRange.startSec,
        endSec: clipRange.endSec > 0 ? clipRange.endSec : null,
      );
      final clippedSubPath = p.join(jobDir, 'sub_clipped.srt');
      await File(clippedSubPath).writeAsString(clippedSrt, flush: true);
      subPath = clippedSubPath;
    }

    if (subPath != null && request.subtitleMode == SubtitleMode.hardBurn) {
      final outExt = videoExt == 'mkv' ? 'mkv' : 'mp4';
      final burnOut = p.join(jobDir, 'stage_burn.$outExt');
      final pid = '${request.id}_burn';
      onTrackProcess(pid);
      currentPath = await ffmpeg.burnHardSubtitles(
        videoPath: currentPath,
        subtitlePath: subPath,
        outputPath: burnOut,
        fontsDir: fontsDir ?? workDir,
        subtitlePosition: request.subtitlePosition,
        subtitleFontSize: request.subtitleFontSize,
        audioCodec: wasMuxedToMp4
            ? 'aac'
            : (request.selectedAudioTrack?.codec ??
                request.selectedVideoFormat?.acodec),
        clipRange: hasClip ? clipRange : null,
        processId: pid,
        durationSec: durSec,
        onProgress: (r) => onPhase(DownloadPhase.processingFfmpeg, progress: r),
      );
      onTrackProcess(null);
      return MediaPipelineResult(filePath: currentPath, ext: outExt);
    }

    if (hasClip) {
      currentPath = await _clipWithFallback(
        inputPath: currentPath,
        outputPath: p.join(jobDir, 'stage_clip.$videoExt'),
        clipRange: clipRange,
        processId: '${request.id}_clip',
        isCancelled: isCancelled,
        onPhase: onPhase,
        onTrackProcess: onTrackProcess,
      );
      remuxedByFfmpeg = true;
      _checkCancelled(isCancelled);
    }

    if (subPath != null && request.subtitleMode == SubtitleMode.softMux) {
      var softExt = videoExt == 'mkv' ? 'mkv' : 'mp4';
      var softOut = p.join(jobDir, 'stage_softsub.$softExt');
      final pid = '${request.id}_softsub';
      try {
        onTrackProcess(pid);
        currentPath = await ffmpeg.muxSoftSubtitles(
          videoPath: currentPath,
          subtitlePath: subPath,
          outputPath: softOut,
          languageCode: subTrack!.language,
          processId: pid,
          durationSec: durSec,
          onProgress: (r) => onPhase(DownloadPhase.processingFfmpeg, progress: r),
        );
      } on MediaProcessingException catch (e) {
        if (e.kind == MediaErrorKind.cancelled ||
            isCancelled() ||
            softExt == 'mkv') {
          rethrow;
        }
        softExt = 'mkv';
        softOut = p.join(jobDir, 'stage_softsub.mkv');
        final mkvPid = '${request.id}_softsub_mkv';
        onTrackProcess(mkvPid);
        currentPath = await ffmpeg.muxSoftSubtitles(
          videoPath: currentPath,
          subtitlePath: subPath,
          outputPath: softOut,
          languageCode: subTrack!.language,
          processId: mkvPid,
          durationSec: durSec,
          onProgress: (r) => onPhase(DownloadPhase.processingFfmpeg, progress: r),
        );
      } finally {
        onTrackProcess(null);
      }
      return MediaPipelineResult(filePath: currentPath, ext: softExt);
    }

    final finalExt = (!remuxedByFfmpeg && sourceExt == 'webm') ? 'webm' : videoExt;
    return MediaPipelineResult(filePath: currentPath, ext: finalExt);
  }

  Future<MediaPipelineResult> _processAudioOnly({
    required DownloadJobRequest request,
    required String jobDir,
    required String sourcePath,
    required double? durSec,
    required bool Function() isCancelled,
    required void Function(DownloadPhase phase, {double? progress}) onPhase,
    required void Function(String? processId) onTrackProcess,
  }) async {
    final targetExt = request.audioFormat.trim().isEmpty
        ? 'mp3'
        : request.audioFormat.trim().toLowerCase();
    final sourceExt = p.extension(sourcePath).toLowerCase().replaceFirst('.', '');
    var currentPath = sourcePath;

    if (sourceExt != targetExt) {
      final extracted = p.join(jobDir, 'stage_audio.$targetExt');
      final pid = '${request.id}_audio';
      onTrackProcess(pid);
      currentPath = await ffmpeg.extractAudio(
        inputPath: currentPath,
        outputPath: extracted,
        format: targetExt,
        title: request.title,
        processId: pid,
        durationSec: durSec,
        onProgress: (r) => onPhase(DownloadPhase.processingFfmpeg, progress: r),
      );
      onTrackProcess(null);
      _checkCancelled(isCancelled);
    }

    final clipRange = request.clipRange;
    if (clipRange != null && clipRange.isActive) {
      currentPath = await _clipWithFallback(
        inputPath: currentPath,
        outputPath: p.join(jobDir, 'stage_audio_clip.$targetExt'),
        clipRange: clipRange,
        processId: '${request.id}_audioclip',
        isCancelled: isCancelled,
        onPhase: onPhase,
        onTrackProcess: onTrackProcess,
      );
    }

    if (!File(currentPath).existsSync()) {
      throw const MediaProcessingException(
        kind: MediaErrorKind.ffmpegFailed,
        message: 'Audio output file missing after FFmpeg processing',
      );
    }
    return MediaPipelineResult(filePath: currentPath, ext: targetExt);
  }

  Future<String> _clipWithFallback({
    required String inputPath,
    required String outputPath,
    required ClipRange clipRange,
    required String processId,
    required bool Function() isCancelled,
    required void Function(DownloadPhase phase, {double? progress}) onPhase,
    required void Function(String? processId) onTrackProcess,
  }) async {
    try {
      onTrackProcess(processId);
      final fastPath = await ffmpeg.clipMedia(
        inputPath: inputPath,
        outputPath: outputPath,
        clipRange: clipRange,
        accurateReencode: false,
        processId: processId,
        onProgress: (r) => onPhase(DownloadPhase.processingFfmpeg, progress: r),
      );
      final f = File(fastPath);
      if (f.existsSync() && f.lengthSync() > 0) return fastPath;
    } on MediaProcessingException catch (e) {
      if (e.kind == MediaErrorKind.cancelled || isCancelled()) rethrow;
    } finally {
      onTrackProcess(null);
    }
    _checkCancelled(isCancelled);
    final rePid = '${processId}_re';
    try {
      onTrackProcess(rePid);
      return await ffmpeg.clipMedia(
        inputPath: inputPath,
        outputPath: outputPath,
        clipRange: clipRange,
        accurateReencode: true,
        processId: rePid,
        onProgress: (r) => onPhase(DownloadPhase.processingFfmpeg, progress: r),
      );
    } finally {
      onTrackProcess(null);
    }
  }

  static void _safeDeleteRaw(String rawPath, String keepPath) {
    if (rawPath == keepPath || rawPath.isEmpty) return;
    try {
      final f = File(rawPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  static String _normalizedVideoExt(
    String path,
    String? preferredExt, {
    String vcodec = '',
  }) {
    final rawExt = p.extension(path).replaceFirst('.', '').trim().toLowerCase();
    final pref = (preferredExt ?? '').trim().toLowerCase();
    final vc = vcodec.toLowerCase();
    if (rawExt == 'mkv' || pref == 'mkv') return 'mkv';
    if (rawExt == 'webm' ||
        pref == 'webm' ||
        vc.contains('vp9') ||
        vc.contains('vp09') ||
        vc.contains('vp8') ||
        vc.contains('av01') ||
        vc.contains('theora')) {
      return 'mkv';
    }
    return 'mp4';
  }

  static void _checkCancelled(bool Function() isCancelled) {
    if (isCancelled()) {
      throw const MediaProcessingException(
        kind: MediaErrorKind.cancelled,
        message: 'Job cancelled',
      );
    }
  }
}
