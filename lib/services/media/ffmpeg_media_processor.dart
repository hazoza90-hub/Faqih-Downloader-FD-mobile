import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/models/clip_range.dart';
import '../../platform/native_models.dart';
import '../../platform/youtube_dl_channel.dart';
import 'ffmpeg_progress_parser.dart';
import 'media_exceptions.dart';
import 'subtitle_font_provisioner.dart';
import 'subtitle_processor.dart';

/// High-level native FFmpeg orchestrator routed exclusively through [YoutubeDlChannel].
class FfmpegMediaProcessor {
  FfmpegMediaProcessor({YoutubeDlChannel? channel})
      : _channel = channel ?? YoutubeDlChannel();

  final YoutubeDlChannel _channel;
  final Set<String> _cancelledIds = <String>{};

  Future<String> muxVideoAndAudio({
    required String videoPath,
    required String audioPath,
    required String outputPath,
    String? audioCodec,
    required String processId,
    double? durationSec,
    void Function(double ratio)? onProgress,
  }) async {
    final outExt = p.extension(outputPath).toLowerCase();
    final isMp4 = outExt == '.mp4' || outExt == '.m4v' || outExt == '.mov';
    final codecLower = (audioCodec ?? '').toLowerCase();
    final audioExt = p.extension(audioPath).toLowerCase();
    final incompatible = codecLower.contains('opus') ||
        codecLower.contains('vorbis') ||
        audioExt == '.opus' ||
        audioExt == '.webm' ||
        audioExt == '.ogg';

    final audioArgs = (isMp4 && incompatible)
        ? const <String>['-c:a', 'aac', '-b:a', '192k']
        : const <String>['-c:a', 'copy'];

    final args = <String>[
      '-y',
      '-i', videoPath,
      '-i', audioPath,
      '-c:v', 'copy',
      ...audioArgs,
      if (isMp4) ...const <String>['-movflags', '+faststart'],
      '-shortest',
      outputPath,
    ];
    await _run(args, outputPath, processId, durationSec, onProgress);
    return outputPath;
  }

  Future<String> extractAudio({
    required String inputPath,
    required String outputPath,
    String format = 'mp3',
    int bitrateKbps = 192,
    String? title,
    String? artist,
    required String processId,
    double? durationSec,
    void Function(double ratio)? onProgress,
  }) async {
    final norm = format.trim().toLowerCase();
    final codecArgs = switch (norm) {
      'mp3' => <String>['-c:a', 'libmp3lame', '-b:a', '${bitrateKbps}k', '-id3v2_version', '3'],
      'm4a' || 'aac' => <String>['-c:a', 'aac', '-b:a', '${bitrateKbps}k', '-movflags', '+faststart'],
      _ => <String>['-c:a', 'copy'],
    };
    final args = <String>[
      '-y',
      '-i', inputPath,
      '-vn',
      ...codecArgs,
      if (title != null && title.trim().isNotEmpty) ...<String>['-metadata', 'title=${title.trim()}'],
      if (artist != null && artist.trim().isNotEmpty) ...<String>['-metadata', 'artist=${artist.trim()}'],
      outputPath,
    ];
    await _run(args, outputPath, processId, durationSec, onProgress);
    return outputPath;
  }

  Future<String> clipMedia({
    required String inputPath,
    required String outputPath,
    required ClipRange clipRange,
    bool accurateReencode = false,
    required String processId,
    void Function(double ratio)? onProgress,
  }) async {
    if (!clipRange.isValid || !clipRange.isActive) {
      throw const MediaProcessingException(
        kind: MediaErrorKind.ffmpegFailed,
        message: 'Invalid clip range provided',
      );
    }

    final ext = p.extension(outputPath).toLowerCase();
    final audioOut = ext == '.mp3' || ext == '.m4a' || ext == '.aac' || ext == '.opus';
    final isMp4 = ext == '.mp4' || ext == '.m4v' || ext == '.mov';
    final clipDur = clipRange.endSec > clipRange.startSec
        ? (clipRange.endSec - clipRange.startSec)
        : null;

    final args = <String>[
      '-y',
      '-ss', _formatSeconds(clipRange.startSec),
      if (clipRange.endSec > 0) ...<String>['-to', _formatSeconds(clipRange.endSec)],
      '-i', inputPath,
      if (!accurateReencode)
        ...const <String>['-c', 'copy']
      else if (audioOut)
        ...<String>['-c:a', ext == '.mp3' ? 'libmp3lame' : 'aac', '-b:a', '192k']
      else
        ...const <String>['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '22', '-c:a', 'aac', '-b:a', '192k'],
      if (isMp4) ...const <String>['-movflags', '+faststart'],
      outputPath,
    ];
    await _run(args, outputPath, processId, clipDur, onProgress);
    return outputPath;
  }

  Future<String> muxSoftSubtitles({
    required String videoPath,
    required String subtitlePath,
    required String outputPath,
    required String languageCode,
    required String processId,
    double? durationSec,
    void Function(double ratio)? onProgress,
  }) async {
    final ext = p.extension(outputPath).toLowerCase();
    final isMkv = ext == '.mkv';
    final subCodec = isMkv ? 'srt' : 'mov_text';
    final lang = languageCode.trim().isEmpty ? 'und' : languageCode.trim().toLowerCase();

    final args = <String>[
      '-y',
      '-i', videoPath,
      '-i', subtitlePath,
      '-c:v', 'copy',
      '-c:a', 'copy',
      '-c:s', subCodec,
      '-metadata:s:s:0', 'language=$lang',
      if (!isMkv) ...const <String>['-movflags', '+faststart'],
      outputPath,
    ];
    await _run(args, outputPath, processId, durationSec, onProgress);
    return outputPath;
  }

  Future<String> burnHardSubtitles({
    required String videoPath,
    required String subtitlePath,
    required String outputPath,
    required String fontsDir,
    String? style,
    ClipRange? clipRange,
    required String processId,
    double? durationSec,
    void Function(double ratio)? onProgress,
  }) async {
    final escapedSub = SubtitleProcessor.escapeForFfmpegFilter(subtitlePath);
    final escapedFonts = SubtitleProcessor.escapeForFfmpegFilter(fontsDir);
    final effectiveStyle = (style == null || style.trim().isEmpty)
        ? 'FontName=${SubtitleFontProvisioner.defaultFontFamily},'
            'FontSize=20,PrimaryColour=&H00FFFFFF,'
            'OutlineColour=&H00000000,BorderStyle=1,Outline=2,Shadow=1'
        : style.trim();

    final filter = "subtitles='$escapedSub':fontsdir='$escapedFonts'"
        ":charenc=UTF-8:force_style='$effectiveStyle'";

    final hasClip = clipRange != null && clipRange.isActive;
    final effectiveDur = (hasClip && clipRange.endSec > clipRange.startSec)
        ? (clipRange.endSec - clipRange.startSec)
        : durationSec;

    final args = <String>[
      '-y',
      if (hasClip) ...<String>['-ss', _formatSeconds(clipRange.startSec)],
      if (hasClip && clipRange.endSec > 0) ...<String>['-to', _formatSeconds(clipRange.endSec)],
      '-i', videoPath,
      '-vf', filter,
      '-c:v', 'libx264',
      '-preset', 'veryfast',
      '-crf', '22',
      '-c:a', 'copy',
      '-movflags', '+faststart',
      outputPath,
    ];
    await _run(args, outputPath, processId, effectiveDur, onProgress);
    return outputPath;
  }

  Future<bool> cancel(String processId) async {
    _cancelledIds.add(processId);
    return _channel.cancelProcess(processId);
  }

  Future<void> _run(
    List<String> args,
    String outputPath,
    String processId,
    double? durationSec,
    void Function(double ratio)? onProgress,
  ) async {
    if (_cancelledIds.remove(processId)) {
      throw const MediaProcessingException(
        kind: MediaErrorKind.cancelled,
        message: 'FFmpeg job cancelled before start',
      );
    }

    final parent = File(outputPath).parent;
    if (!parent.existsSync()) await parent.create(recursive: true);

    final parser = FfmpegProgressParser(knownDurationSeconds: durationSec);
    StreamSubscription<NativeProgressEvent>? sub;
    try {
      sub = _channel.events
          .where((e) => e.type == 'ffmpeg_log' && e.processId == processId)
          .listen((event) {
        final update = parser.parseLine(event.line);
        if (update != null) onProgress?.call(update.ratio);
      });
    } on MissingPluginException {
      sub = null;
    } catch (_) {
      sub = null;
    }

    try {
      final result = await _channel.runFfmpeg(args: args, processId: processId);
      if (_cancelledIds.remove(processId)) {
        throw MediaProcessingException(
          kind: MediaErrorKind.cancelled,
          message: 'FFmpeg job cancelled',
          rawDetails: result.output,
          exitCode: result.exitCode,
        );
      }
      if (!result.isSuccess) {
        throw MediaProcessingException(
          kind: MediaErrorKind.ffmpegFailed,
          message: 'FFmpeg exited with code ${result.exitCode}',
          rawDetails: result.output,
          exitCode: result.exitCode,
        );
      }
      onProgress?.call(1.0);
    } on NativeBridgeException catch (e) {
      final cancelled = _cancelledIds.remove(processId);
      throw MediaProcessingException(
        kind: cancelled ? MediaErrorKind.cancelled : MediaErrorKind.ffmpegFailed,
        message: e.message,
        rawDetails: e.toString(),
      );
    } finally {
      _cancelledIds.remove(processId);
      await sub?.cancel();
    }
  }

  static String _formatSeconds(double seconds) {
    final s = seconds < 0 ? 0.0 : seconds;
    return s.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
  }
}
