import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/models/audio_track.dart';
import '../../core/models/video_format_option.dart';
import '../../core/utils/url_detector.dart';
import '../../platform/native_models.dart';
import '../../platform/youtube_dl_channel.dart';
import '../media/media_exceptions.dart';
import 'download_job_models.dart';

/// Parsed sample from a single `yt-dlp` progress output line.
class YtDlpProgressSample {
  const YtDlpProgressSample({
    required this.progress,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.speedBytesPerSec,
    required this.etaSeconds,
  });

  final double progress;
  final int downloadedBytes;
  final int totalBytes;
  final double speedBytesPerSec;
  final double etaSeconds;
}

/// Fallback media stream downloader routed natively through `YoutubeDlChannel`.
class YtDlpStreamDownloader {
  const YtDlpStreamDownloader(this._youtubeDl);

  final YoutubeDlChannel _youtubeDl;

  static final RegExp _pctRegex = RegExp(r'(\d+(?:\.\d+)?)%');
  static final RegExp _totalRegex = RegExp(
    r'\bof\s+~?\s*([\d.]+)\s*(GiB|MiB|KiB|GB|MB|KB|B)\b',
    caseSensitive: false,
  );
  static final RegExp _unknownDlRegex = RegExp(
    r'\[download\]\s+([\d.]+)\s*(GiB|MiB|KiB|GB|MB|KB|B)\s+at\b',
    caseSensitive: false,
  );
  static final RegExp _speedRegex = RegExp(
    r'\bat\s+([\d.]+)\s*(GiB|MiB|KiB|GB|MB|KB|B)/s',
    caseSensitive: false,
  );
  static final RegExp _etaRegex = RegExp(r'\bETA\s+(?:(\d+):)?(\d+):(\d+)');

  static double _parseByteUnit(String numStr, String unit) {
    final val = double.tryParse(numStr) ?? 0.0;
    switch (unit.toLowerCase()) {
      case 'gib': return val * 1024 * 1024 * 1024;
      case 'mib': return val * 1024 * 1024;
      case 'kib': return val * 1024;
      case 'gb': return val * 1000 * 1000 * 1000;
      case 'mb': return val * 1000 * 1000;
      case 'kb': return val * 1000;
      default: return val;
    }
  }

  static YtDlpProgressSample parseProgressLine(
    String line, {
    double fallbackRatio = 0.0,
    double fallbackEta = -1.0,
    int lastTotalBytes = 0,
  }) {
    final pctM = _pctRegex.firstMatch(line);
    final ratio = pctM != null
        ? ((double.tryParse(pctM.group(1)!) ?? 0.0) / 100.0).clamp(0.0, 1.0)
        : fallbackRatio.clamp(0.0, 1.0);
    final totalM = _totalRegex.firstMatch(line);
    final parsedTotal = totalM != null
        ? _parseByteUnit(totalM.group(1)!, totalM.group(2)!).round()
        : 0;
    final totalBytes = parsedTotal > 0 ? parsedTotal : lastTotalBytes;

    var downloaded = 0;
    final unknownM = _unknownDlRegex.firstMatch(line);
    if (unknownM != null) {
      downloaded = _parseByteUnit(unknownM.group(1)!, unknownM.group(2)!).round();
    } else if (totalBytes > 0 && ratio > 0) {
      downloaded = (totalBytes * ratio).round();
    }

    final speedM = _speedRegex.firstMatch(line);
    final speed = speedM != null
        ? _parseByteUnit(speedM.group(1)!, speedM.group(2)!)
        : 0.0;

    final etaM = _etaRegex.firstMatch(line);
    var eta = fallbackEta;
    if (etaM != null) {
      final h = int.tryParse(etaM.group(1) ?? '0') ?? 0;
      final m = int.tryParse(etaM.group(2) ?? '0') ?? 0;
      final s = int.tryParse(etaM.group(3) ?? '0') ?? 0;
      eta = (h * 3600 + m * 60 + s).toDouble();
    }

    return YtDlpProgressSample(
      progress: ratio,
      downloadedBytes: downloaded,
      totalBytes: totalBytes,
      speedBytesPerSec: speed,
      etaSeconds: eta,
    );
  }

  static String mergeOutputFormatFor(VideoFormatOption? fmt) {
    final ext = (fmt?.ext ?? '').toLowerCase();
    final vc = (fmt?.vcodec ?? '').toLowerCase();
    if (ext == 'webm' || vc.contains('vp9') || vc.contains('vp8') || vc.contains('av01')) {
      return 'mkv';
    }
    return 'mp4';
  }

  static String extractStderrReason(String stderr, int exitCode) {
    final lines = stderr
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList(growable: false);
    for (var i = lines.length - 1; i >= 0; i--) {
      if (lines[i].startsWith('ERROR:')) {
        final cleaned = lines[i].substring('ERROR:'.length).trim();
        if (cleaned.isNotEmpty) return cleaned;
      }
    }
    return lines.isNotEmpty ? lines.last : 'exit code $exitCode';
  }

  Future<String> download({
    required DownloadJobRequest request,
    required String jobDir,
    required VideoFormatOption? formatOption,
    required AudioTrack? audioOption,
    required bool Function() isCancelled,
    required void Function(String? pid) setActiveProcessId,
    required void Function(DownloadPhase phase) setActivePhase,
    required void Function(
      DownloadPhase phase,
      double progress,
      double eta,
      int downloadedBytes,
      int totalBytes,
      double speedBytesPerSec,
    ) onProgress,
  }) async {
    final phase = request.audioOnly
        ? DownloadPhase.downloadingAudio
        : DownloadPhase.downloadingVideo;
    setActivePhase(phase);
    final pid = '${request.id}_ytdlp';
    setActiveProcessId(pid);
    var lastTotalBytes = request.audioOnly
        ? (audioOption?.filesize ?? formatOption?.audioSize ?? 0)
        : (formatOption?.filesizeApprox ?? 0) + (formatOption?.audioSize ?? 0);
    var lastDownloadedBytes = 0;
    var lastProgress = 0.0;
    var lastSampleAt = DateTime.now();
    onProgress(phase, 0.0, -1.0, 0, lastTotalBytes, 0.0);

    StreamSubscription<NativeProgressEvent>? sub;
    try {
      sub = _youtubeDl.events
          .where((e) => e.processId == pid && e.type == 'progress')
          .listen((ev) {
        if (isCancelled()) return;
        final hasMetrics = _pctRegex.hasMatch(ev.line) ||
            _unknownDlRegex.hasMatch(ev.line) ||
            _speedRegex.hasMatch(ev.line);
        if (ev.progress < 0 && (!ev.line.contains('[download]') || !hasMetrics)) {
          return;
        }
        final fallbackRatio = ev.progress >= 0
            ? (ev.progress / 100.0).clamp(0.0, 1.0)
            : lastProgress;
        final sample = parseProgressLine(
          ev.line,
          fallbackRatio: fallbackRatio,
          fallbackEta: ev.etaSeconds.toDouble(),
          lastTotalBytes: lastTotalBytes,
        );
        lastProgress = sample.progress;
        if (sample.totalBytes > 0) lastTotalBytes = sample.totalBytes;
        var speed = sample.speedBytesPerSec;
        final now = DateTime.now();
        final dt = now.difference(lastSampleAt).inMilliseconds / 1000.0;
        if (speed <= 0 && dt >= 0.1 && sample.downloadedBytes > lastDownloadedBytes) {
          speed = (sample.downloadedBytes - lastDownloadedBytes) / dt;
        }
        if (sample.downloadedBytes > 0) {
          lastDownloadedBytes = sample.downloadedBytes;
          lastSampleAt = now;
        }
        onProgress(
          phase,
          sample.progress,
          sample.etaSeconds,
          sample.downloadedBytes > 0 ? sample.downloadedBytes : lastDownloadedBytes,
          lastTotalBytes,
          speed,
        );
      });
    } catch (_) {}

    final formatSpec = buildSelector(request, formatOption, audioOption);
    final isYt = UrlDetector.isYouTubeUrl(request.url);
    final rawCookie = request.cookiesFile?.trim() ?? '';
    final attempts = isYt
        ? <({String? strategy, String? cookie})>[
            (strategy: null, cookie: null),
            (strategy: 'youtube:player_client=ios,mweb', cookie: null),
            (strategy: '', cookie: null),
            if (rawCookie.isNotEmpty)
              (strategy: 'youtube:player_client=mweb,web', cookie: rawCookie),
          ]
        : (rawCookie.isEmpty
            ? const <({String? strategy, String? cookie})>[
                (strategy: null, cookie: null),
              ]
            : <({String? strategy, String? cookie})>[
                (strategy: null, cookie: rawCookie),
                (strategy: null, cookie: null),
              ]);

    try {
      MediaExtractionException? lastError;
      for (final attempt in attempts) {
        if (isCancelled()) {
          throw const MediaExtractionException(
            kind: MediaErrorKind.cancelled,
            message: 'Download cancelled',
          );
        }
        _cleanupAttemptFiles(jobDir);
        lastDownloadedBytes = 0;
        lastProgress = 0.0;
        lastSampleAt = DateTime.now();
        final attemptCookie = attempt.cookie;
        final opts = <String, Object?>{
          '-f': formatSpec,
          '-o': p.join(jobDir, 'ytdlp_%(id)s.%(ext)s'),
          '--no-playlist': true,
          if (!request.audioOnly)
            '--merge-output-format': mergeOutputFormatFor(formatOption),
          if (attemptCookie != null && attemptCookie.isNotEmpty)
            '--cookies': attemptCookie,
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
            extractorArgs: attempt.strategy,
          );
          if (isCancelled()) {
            throw const MediaExtractionException(
              kind: MediaErrorKind.cancelled,
              message: 'Download cancelled',
            );
          }
          if (!res.isSuccess) {
            final reason = extractStderrReason(res.stderr, res.exitCode);
            throw MediaExtractionException(
              kind: MediaErrorKind.networkError,
              message: 'yt-dlp failed: $reason',
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
        } on MediaExtractionException catch (e) {
          if (e.kind == MediaErrorKind.cancelled || isCancelled()) rethrow;
          lastError = e;
        } catch (e) {
          if (isCancelled()) {
            throw const MediaExtractionException(
              kind: MediaErrorKind.cancelled,
              message: 'Download cancelled',
            );
          }
          lastError = MediaExtractionException(
            kind: MediaErrorKind.networkError,
            message: e.toString(),
          );
        }
      }
      throw lastError!;
    } finally {
      setActiveProcessId(null);
      await sub?.cancel();
    }
  }

  static void _cleanupAttemptFiles(String jobDir) {
    try {
      final dir = Directory(jobDir);
      if (!dir.existsSync()) return;
      for (final entity in dir.listSync()) {
        if (p.basename(entity.path).startsWith('ytdlp_')) {
          try {
            entity.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
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
