import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/models/audio_track.dart';
import '../../core/models/video_format_option.dart';
import '../../core/models/youtube_stream_info.dart';
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

  static VideoFormatOption? pickInnerTubeFormat(
    YouTubeStreamInfo info,
    int preferredHeight,
  ) {
    final direct = info.videoFormats
        .where((f) => f.isDirectTurboSupported && !isManifestUrl(f.videoUrl, protocol: f.protocol))
        .toList(growable: false);
    if (direct.isEmpty) return null;
    if (preferredHeight > 0) {
      for (final f in direct) {
        if (f.height > 0 && f.height <= preferredHeight) return f;
      }
    }
    return direct.first;
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
      final aExt = (audio?.ext ?? fmt.audioExt).trim().toLowerCase();
      if (aExt == 'm3u8' || aExt == 'mpd') return false;
      if (aUrl.isNotEmpty && isManifestUrl(aUrl, protocol: fmt.protocol)) return false;
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
