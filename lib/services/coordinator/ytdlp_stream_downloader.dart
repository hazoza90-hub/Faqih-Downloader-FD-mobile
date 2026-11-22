import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/models/audio_track.dart';
import '../../core/models/video_format_option.dart';
import '../../platform/native_models.dart';
import '../../platform/youtube_dl_channel.dart';
import '../media/media_exceptions.dart';
import 'download_job_models.dart';

/// Fallback media stream downloader routed natively through `YoutubeDlChannel`.
class YtDlpStreamDownloader {
  const YtDlpStreamDownloader(this._youtubeDl);

  final YoutubeDlChannel _youtubeDl;

  Future<String> download({
    required DownloadJobRequest request,
    required String jobDir,
    required VideoFormatOption? formatOption,
    required AudioTrack? audioOption,
    required bool Function() isCancelled,
    required void Function(String? pid) setActiveProcessId,
    required void Function(DownloadPhase phase) setActivePhase,
    required void Function(DownloadPhase phase, double progress, double eta)
        onProgress,
  }) async {
    final phase = request.audioOnly
        ? DownloadPhase.downloadingAudio
        : DownloadPhase.downloadingVideo;
    setActivePhase(phase);
    final pid = '${request.id}_ytdlp';
    setActiveProcessId(pid);
    onProgress(phase, 0.0, -1.0);

    StreamSubscription<NativeProgressEvent>? sub;
    try {
      sub = _youtubeDl.events
          .where((e) => e.processId == pid && e.type == 'progress')
          .listen((ev) {
        if (!isCancelled()) {
          onProgress(
            phase,
            (ev.progress / 100.0).clamp(0.0, 1.0),
            ev.etaSeconds.toDouble(),
          );
        }
      });
    } catch (_) {}

    final formatSpec = buildSelector(request, formatOption, audioOption);
    final opts = <String, Object?>{
      '-f': formatSpec,
      '-o': p.join(jobDir, 'ytdlp_%(id)s.%(ext)s'),
      '--no-playlist': true,
      if (!request.audioOnly) '--merge-output-format': 'mp4',
      if (request.cookiesFile != null && request.cookiesFile!.isNotEmpty)
        '--cookies': request.cookiesFile,
      if (request.headers.isNotEmpty)
        '--add-header': <String>[
          for (final e in request.headers.entries) '${e.key}:${e.value}',
        ],
    };

    try {
      final res = await _youtubeDl.downloadMedia(
        url: request.url,
        processId: pid,
        options: opts,
      );
      if (isCancelled()) {
        throw const MediaExtractionException(
          kind: MediaErrorKind.cancelled,
          message: 'Download cancelled',
        );
      }
      if (!res.isSuccess) {
        throw MediaExtractionException(
          kind: MediaErrorKind.networkError,
          message: 'yt-dlp failed (${res.exitCode})',
          rawDetails: res.stderr,
        );
      }
      final downloaded = findDownloadedFile(jobDir);
      if (downloaded == null) {
        throw const MediaExtractionException(
          kind: MediaErrorKind.unknown,
          message: 'yt-dlp reported success but output file was not found',
        );
      }
      return downloaded;
    } finally {
      setActiveProcessId(null);
      await sub?.cancel();
    }
  }

  static String buildSelector(
    DownloadJobRequest request,
    VideoFormatOption? fmt,
    AudioTrack? audio,
  ) {
    if (request.audioOnly) {
      return (audio?.formatId.isNotEmpty ?? false)
          ? '${audio!.formatId}/bestaudio/best'
          : 'bestaudio/best';
    }
    if (fmt != null && fmt.formatId.isNotEmpty) {
      final hasDubbing =
          audio != null && !audio.isOriginal && audio.formatId.isNotEmpty;
      if (hasDubbing) {
        return '${fmt.formatId}+${audio.formatId}/best';
      }
      if (fmt.isProgressive) return '${fmt.formatId}/best';
      final aId = (audio?.formatId.isNotEmpty ?? false)
          ? audio!.formatId
          : 'bestaudio';
      return '${fmt.formatId}+$aId/best';
    }
    if (request.preferredVideoHeight > 0) {
      return 'bestvideo[height<=${request.preferredVideoHeight}]+bestaudio/'
          'best[height<=${request.preferredVideoHeight}]/best';
    }
    return 'bestvideo+bestaudio/best';
  }

  static String? findDownloadedFile(String jobDir) {
    final files = Directory(jobDir).listSync().whereType<File>().where((f) {
      final name = p.basename(f.path);
      return name.startsWith('ytdlp_') &&
          !name.endsWith('.part') &&
          !name.endsWith('.ytdl');
    }).toList();
    if (files.isEmpty) return null;
    files.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
    return files.first.path;
  }
}
