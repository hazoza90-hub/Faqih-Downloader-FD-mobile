import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../core/models/audio_track.dart';
import '../../core/models/video_format_option.dart';
import '../../core/models/youtube_stream_info.dart';
import '../../engine/engine_callbacks.dart';
import '../../engine/http_client_factory.dart';
import 'download_job_models.dart';

/// Stateless helper functions supporting [MediaStreamAcquirer].
abstract final class MediaStreamHelpers {
  static Map<String, String> mergeStreamHeaders(
    String url,
    Map<String, String> rawHeaders,
    String? cookiesFile,
  ) {
    final hasCookie = rawHeaders.entries.any(
      (e) => e.key.toLowerCase() == 'cookie' && e.value.trim().isNotEmpty,
    );
    if (hasCookie) return rawHeaders;
    final cookieStr = HttpClientFactory.extractNetscapeCookieHeader(cookiesFile, url);
    if (cookieStr.isEmpty) return rawHeaders;
    return HttpClientFactory.withCookieHeader(rawHeaders, cookieStr);
  }

  static void cleanupTurboArtifacts(String jobDir) {
    try {
      final dir = Directory(jobDir);
      if (!dir.existsSync()) return;
      for (final entity in dir.listSync()) {
        final name = p.basename(entity.path);
        if (name.startsWith('raw_video.') ||
            name.startsWith('raw_audio.') ||
            name.endsWith('.sd_parts') ||
            name.contains('.part')) {
          try {
            entity.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  static String codecFamilyOf(String vcodec) {
    final vc = vcodec.trim().toLowerCase();
    if (vc.isEmpty || vc == 'none') return '';
    if (vc.contains('avc1') || vc.contains('h264')) return 'avc1';
    if (vc.contains('vp9') || vc.contains('vp09')) return 'vp9';
    if (vc.contains('av01') || vc.contains('av1')) return 'av01';
    return '';
  }

  static int minAcceptableHeightFor(int targetHeight) {
    if (targetHeight >= 2160) return 1500;
    if (targetHeight >= 1440) return 1100;
    if (targetHeight >= 1080) return 780;
    if (targetHeight >= 720) return 520;
    if (targetHeight >= 480) return 400;
    return 0;
  }

  static VideoFormatOption? pickInnerTubeFormat(
    YouTubeStreamInfo info,
    int preferredHeight, {
    String? preferredFormatId,
    String? preferredVcodec,
    bool strictHeight = false,
  }) {
    final minHeight = (strictHeight && preferredHeight > 0)
        ? minAcceptableHeightFor(preferredHeight)
        : 0;
    final direct = info.videoFormats.where((f) {
      if (!f.isDirectTurboSupported ||
          isManifestUrl(f.videoUrl, protocol: f.protocol)) {
        return false;
      }
      if (strictHeight && preferredHeight > 0) {
        return f.height >= minHeight && f.height <= preferredHeight;
      }
      return true;
    }).toList(growable: false);
    if (direct.isEmpty) return null;
    final targetId = (preferredFormatId ?? '').trim();
    if (targetId.isNotEmpty) {
      for (final f in direct) {
        if (f.formatId == targetId) return f;
      }
    }
    final targetCodec = codecFamilyOf(preferredVcodec ?? '');
    if (targetCodec.isNotEmpty && preferredHeight > 0) {
      for (final f in direct) {
        if (f.height == preferredHeight && codecFamilyOf(f.vcodec) == targetCodec) {
          return f;
        }
      }
      for (final f in direct) {
        if (f.height > 0 && f.height <= preferredHeight && codecFamilyOf(f.vcodec) == targetCodec) {
          return f;
        }
      }
    }
    if (preferredHeight > 0) {
      for (final f in direct) {
        if (f.height > 0 && f.height <= preferredHeight) return f;
      }
    }
    return direct.first;
  }

  static int resolveCompletedFileBytes(String filePath, {int fallbackBytes = 0}) {
    try {
      final f = File(filePath);
      if (f.existsSync()) {
        final len = f.lengthSync();
        if (len > 0) return len;
      }
    } catch (_) {}
    return fallbackBytes > 0 ? fallbackBytes : 0;
  }

  static EngineProgressSnapshot combineDualStreamSnapshot(
    EngineProgressSnapshot snap, {
    required bool isAudioStage,
    required int estimatedAudioBytes,
    int completedVideoBytes = 0,
  }) {
    final safeAudioEst = math.max(0, estimatedAudioBytes);
    final safeVideoDone = math.max(0, completedVideoBytes);
    final int combinedTotal;
    final int combinedDownloaded;
    if (!isAudioStage) {
      combinedTotal = snap.totalBytes > 0 ? snap.totalBytes + safeAudioEst : 0;
      combinedDownloaded = snap.downloadedBytes;
    } else {
      final audioTotal = snap.totalBytes > 0 ? snap.totalBytes : safeAudioEst;
      combinedTotal = safeVideoDone + audioTotal;
      combinedDownloaded = safeVideoDone + snap.downloadedBytes;
    }
    return EngineProgressSnapshot(
      downloadedBytes: combinedDownloaded,
      totalBytes: combinedTotal,
      speedBytesPerSec: snap.speedBytesPerSec,
      etaSeconds: snap.etaSeconds,
      activeWorkers: snap.activeWorkers,
      status: snap.status,
      chunks: snap.chunks,
    );
  }

  static AudioTrack? matchAudioTrack(
    YouTubeStreamInfo info, {
    AudioTrack? preferredAudio,
    VideoFormatOption? pickedVideo,
    required bool wantsAudio,
  }) {
    if (!wantsAudio) return pickedVideo?.selectedAudioTrack;
    if (preferredAudio != null) {
      final lang = preferredAudio.language.trim().toLowerCase();
      for (final t in info.audioTracks) {
        if (t.language.toLowerCase() == lang && t.isOriginal == preferredAudio.isOriginal) {
          return t;
        }
      }
      for (final t in info.audioTracks) {
        if (t.language.toLowerCase() == lang) return t;
      }
    }
    return pickedVideo?.selectedAudioTrack ??
        info.selectedAudioTrack ??
        (info.audioTracks.isNotEmpty ? info.audioTracks.first : null);
  }

  static bool canTryTurbo(
    DownloadJobRequest request,
    VideoFormatOption? fmt,
    AudioTrack? audio,
  ) {
    if (request.audioOnly) {
      if (fmt != null && fmt.isHlsOrDash) return false;
      final url = audio?.url ?? fmt?.audioUrl ?? fmt?.videoUrl ?? '';
      final ext = (audio?.ext ?? fmt?.audioExt ?? '').trim().toLowerCase();
      if (ext == 'm3u8' || ext == 'mpd') return false;
      return url.isNotEmpty && !isManifestUrl(url, protocol: fmt?.protocol ?? '');
    }
    if (fmt == null || !fmt.isDirectTurboSupported) return false;
    if (isManifestUrl(fmt.videoUrl, protocol: fmt.protocol)) return false;
    final wantsSeparateAudio = fmt.needsAudioMerge || (audio != null && !audio.isOriginal);
    if (wantsSeparateAudio) {
      final aUrl = (audio?.url.isNotEmpty ?? false) ? audio!.url : (fmt.audioUrl ?? '');
      if (aUrl.isEmpty) return false;
      final aExt = (audio?.ext ?? fmt.audioExt).trim().toLowerCase();
      if (aExt == 'm3u8' || aExt == 'mpd') return false;
      if (isManifestUrl(aUrl, protocol: fmt.protocol)) return false;
    }
    return true;
  }

  static bool isManifestUrl(String url, {String protocol = ''}) {
    final pLower = protocol.toLowerCase();
    final u = url.toLowerCase();
    return pLower.contains('m3u8') ||
        pLower.contains('hls') ||
        pLower.contains('dash') ||
        pLower.contains('f4m') ||
        u.contains('.m3u8') ||
        u.contains('.mpd') ||
        u.contains('/manifest/hls') ||
        u.contains('/manifest/dash');
  }
}
