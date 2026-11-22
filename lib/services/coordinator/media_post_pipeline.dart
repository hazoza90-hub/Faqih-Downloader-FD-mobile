import 'dart:io';

import 'package:path/path.dart' as p;

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
    var currentPath = rawVideoPath;

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

    final videoExt = _normalizedVideoExt(currentPath, request.selectedVideoFormat?.ext);
    var wasMuxedToMp4 = false;
    if (rawAudioPath != null && rawAudioPath.isNotEmpty) {
      final muxOut = p.join(jobDir, 'stage_mux.$videoExt');
      final pid = '${request.id}_mux';
      onTrackProcess(pid);
      currentPath = await ffmpeg.muxVideoAndAudio(
        videoPath: currentPath,
        audioPath: rawAudioPath,
        outputPath: muxOut,
        audioCodec: request.selectedAudioTrack?.codec ??
            request.selectedVideoFormat?.selectedAudioTrack?.codec ??
            request.selectedVideoFormat?.acodec,
        processId: pid,
        durationSec: durSec,
        onProgress: (r) => onPhase(DownloadPhase.processingFfmpeg, progress: r),
      );
      wasMuxedToMp4 = videoExt == 'mp4';
      onTrackProcess(null);
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
      final clipOut = p.join(jobDir, 'stage_clip.$videoExt');
      final pid = '${request.id}_clip';
      onTrackProcess(pid);
      currentPath = await ffmpeg.clipMedia(
        inputPath: currentPath,
        outputPath: clipOut,
        clipRange: clipRange,
        processId: pid,
        onProgress: (r) => onPhase(DownloadPhase.processingFfmpeg, progress: r),
      );
      onTrackProcess(null);
      _checkCancelled(isCancelled);
    }

    if (subPath != null && request.subtitleMode == SubtitleMode.softMux) {
      final softExt = videoExt == 'mkv' ? 'mkv' : 'mp4';
      final softOut = p.join(jobDir, 'stage_softsub.$softExt');
      final pid = '${request.id}_softsub';
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
      onTrackProcess(null);
      return MediaPipelineResult(filePath: currentPath, ext: softExt);
    }

    return MediaPipelineResult(filePath: currentPath, ext: videoExt);
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
      final clipped = p.join(jobDir, 'stage_audio_clip.$targetExt');
      final pid = '${request.id}_audioclip';
      onTrackProcess(pid);
      currentPath = await ffmpeg.clipMedia(
        inputPath: currentPath,
        outputPath: clipped,
        clipRange: clipRange,
        processId: pid,
        onProgress: (r) => onPhase(DownloadPhase.processingFfmpeg, progress: r),
      );
      onTrackProcess(null);
    }

    if (!File(currentPath).existsSync()) {
      throw const MediaProcessingException(
        kind: MediaErrorKind.ffmpegFailed,
        message: 'Audio output file missing after FFmpeg processing',
      );
    }
    return MediaPipelineResult(filePath: currentPath, ext: targetExt);
  }

  static String _normalizedVideoExt(String path, String? preferredExt) {
    final cand = (preferredExt ?? p.extension(path).replaceFirst('.', ''))
        .trim()
        .toLowerCase();
    return cand == 'mkv' ? 'mkv' : 'mp4';
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
