import 'dart:convert';

import '../../core/models/audio_track.dart';
import '../../core/models/subtitle_track.dart';
import '../../core/models/video_format_option.dart';
import '../../core/models/youtube_stream_info.dart';
import '../../core/utils/filename_sanitizer.dart';
import 'format_ranker_helpers.dart';

/// Pure Dart parser and ranker for `yt-dlp --dump-single-json` output.
class FormatRanker {
  const FormatRanker();

  YouTubeStreamInfo parseJsonString(String rawJson, {String fallbackUrl = ''}) {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) {
      throw const FormatException('yt-dlp output is not a JSON object');
    }
    return parse(Map<String, dynamic>.from(decoded), fallbackUrl: fallbackUrl);
  }

  YouTubeStreamInfo parse(Map<String, dynamic> raw, {String fallbackUrl = ''}) {
    final rawEntries = raw['entries'];
    final isPlaylist = raw['_type']?.toString() == 'playlist' ||
        (rawEntries is List && rawEntries.isNotEmpty);

    if (isPlaylist) {
      final entries = <YouTubeStreamInfo>[
        if (rawEntries is List)
          for (final item in rawEntries.whereType<Map>())
            parse(Map<String, dynamic>.from(item), fallbackUrl: fallbackUrl),
      ];
      final title = readMediaTitle(raw, fallback: 'Playlist');
      final pageUrl = readMediaWebpageUrl(raw, fallbackUrl);
      return YouTubeStreamInfo(
        videoId: raw['id']?.toString() ?? '',
        title: title,
        cleanFilename: sanitizeFilename(title, fallback: 'playlist'),
        isProgressive: true,
        videoUrl: pageUrl,
        webpageUrl: pageUrl,
        thumbnailUrl: raw['thumbnail']?.toString() ?? '',
        platform: resolveMediaPlatform(pageUrl, raw),
        isPlaylist: true,
        playlistEntries: entries,
      );
    }

    final formats = readFormatMaps(raw['formats']);
    final audioTracks = rankAudioTracks(formats, root: raw);
    final defaultAudio = pickDefaultAudio(audioTracks);
    final videoFormats = rankVideoFormats(
      formats,
      root: raw,
      defaultAudio: defaultAudio,
    );
    final subtitleTracks = rankSubtitleTracks(raw);

    final bestVideo = videoFormats.isNotEmpty ? videoFormats.first : null;
    final rootHeaders = toHeaderMap(raw['http_headers']);
    final pageUrl = readMediaWebpageUrl(raw, fallbackUrl);
    final title = readMediaTitle(raw, fallback: 'video');
    final ext = bestVideo?.ext ?? defaultAudio?.ext ?? raw['ext']?.toString() ?? 'mp4';
    final isAudioOnly = bestVideo == null && defaultAudio != null;
    final needsMerge = bestVideo?.needsAudioMerge ?? false;

    return YouTubeStreamInfo(
      videoId: raw['id']?.toString() ?? '',
      title: title,
      cleanFilename: sanitizeFilename('$title.$ext'),
      isProgressive: bestVideo?.isProgressive ?? false,
      videoUrl: bestVideo?.videoUrl ?? raw['url']?.toString() ?? '',
      videoHeaders: bestVideo?.videoHeaders ?? rootHeaders,
      videoExt: ext,
      videoResolution:
          bestVideo?.resolutionLabel ?? (isAudioOnly ? 'Audio Only' : 'Best'),
      videoSize: bestVideo?.filesizeApprox ?? defaultAudio?.filesize ?? 0,
      audioUrl: isAudioOnly
          ? defaultAudio.url
          : (needsMerge ? (bestVideo?.audioUrl ?? defaultAudio?.url) : null),
      audioHeaders: isAudioOnly
          ? defaultAudio.httpHeaders
          : (needsMerge
                ? (bestVideo?.audioHeaders ??
                    defaultAudio?.httpHeaders ??
                    const <String, String>{})
                : const <String, String>{}),
      audioExt: defaultAudio?.ext ?? 'm4a',
      audioSize:
          needsMerge ? (bestVideo?.audioSize ?? defaultAudio?.filesize ?? 0) : 0,
      durationSec: parseIntValue(raw['duration']),
      thumbnailUrl: raw['thumbnail']?.toString() ?? '',
      isAudioOnly: isAudioOnly,
      platform: resolveMediaPlatform(pageUrl, raw),
      webpageUrl: pageUrl,
      audioFormatId: defaultAudio?.formatId ?? '',
      audioLanguage: defaultAudio?.language,
      selectedAudioTrack: defaultAudio,
      videoFormats: videoFormats,
      audioTracks: audioTracks,
      subtitleTracks: subtitleTracks,
    );
  }

  List<VideoFormatOption> rankVideoFormats(
    List<Map<String, dynamic>> formats, {
    Map<String, dynamic> root = const <String, dynamic>{},
    AudioTrack? defaultAudio,
  }) {
    final byBucket = <String, ScoredCandidate<VideoFormatOption>>{};
    final fallbackHeaders = toHeaderMap(root['http_headers']);
    final duration = parseDoubleValue(root['duration']);

    for (final fmt in formats) {
      final url = fmt['url']?.toString().trim() ?? '';
      if (url.isEmpty) continue;
      final ext = (fmt['ext']?.toString() ?? 'mp4').toLowerCase();
      final note = fmt['format_note']?.toString() ?? '';
      if (ext == 'mhtml' || note.toLowerCase().contains('storyboard')) continue;

      final vcodec = (fmt['vcodec']?.toString() ?? '').trim();
      final acodec = (fmt['acodec']?.toString() ?? '').trim();
      final height = resolveFormatHeight(fmt);
      final isVideo = (vcodec.isNotEmpty && vcodec != 'none') || height > 0;
      if (!isVideo) continue;

      final fps = parseIntValue(fmt['fps'], fallback: 30);
      final tbr = parseDoubleValue(fmt['tbr']);
      final progressive = acodec.isNotEmpty && acodec != 'none';
      final needsMerge = !progressive;
      final bucket = bucketForResolution(height, fps);

      final option = VideoFormatOption(
        formatId: fmt['format_id']?.toString() ?? '',
        resolutionLabel: labelForResolutionBucket(bucket, height),
        height: height,
        width: parseIntValue(fmt['width']),
        fps: fps,
        ext: ext,
        filesizeApprox:
            resolveFormatFilesize(fmt, rootDuration: duration, tbrKbps: tbr),
        vcodec: vcodec,
        acodec: acodec,
        protocol: fmt['protocol']?.toString() ?? '',
        tbrKbps: tbr,
        isProgressive: progressive,
        videoUrl: url,
        videoHeaders:
            mergeHeaderMaps(fallbackHeaders, toHeaderMap(fmt['http_headers'])),
        audioUrl: needsMerge ? defaultAudio?.url : null,
        audioHeaders: needsMerge
            ? (defaultAudio?.httpHeaders ?? const <String, String>{})
            : const <String, String>{},
        audioExt: defaultAudio?.ext ?? 'm4a',
        audioSize: needsMerge ? (defaultAudio?.filesize ?? 0) : 0,
        note: note,
        selectedAudioTrack: needsMerge ? defaultAudio : null,
      );

      final score = scoreVideoOption(option);
      final existing = byBucket[bucket];
      if (existing == null || score > existing.score) {
        byBucket[bucket] = ScoredCandidate(score: score, value: option);
      }
    }

    final ranked = byBucket.values.map((e) => e.value).toList();
    ranked.sort((a, b) {
      final byH = b.height.compareTo(a.height);
      if (byH != 0) return byH;
      final byFps = b.fps.compareTo(a.fps);
      if (byFps != 0) return byFps;
      return b.tbrKbps.compareTo(a.tbrKbps);
    });
    return List<VideoFormatOption>.unmodifiable(ranked);
  }

  List<AudioTrack> rankAudioTracks(
    List<Map<String, dynamic>> formats, {
    Map<String, dynamic> root = const <String, dynamic>{},
  }) {
    final byKey = <String, ScoredCandidate<AudioTrack>>{};
    final rootLang = normalizeLanguageCode(root['language']?.toString());
    final fallbackHeaders = toHeaderMap(root['http_headers']);
    final duration = parseDoubleValue(root['duration']);

    for (final fmt in formats) {
      final url = fmt['url']?.toString().trim() ?? '';
      if (url.isEmpty) continue;
      final vcodec = (fmt['vcodec']?.toString() ?? 'none').toLowerCase();
      final acodec = (fmt['acodec']?.toString() ?? '').trim();
      if (acodec.isEmpty || acodec == 'none') continue;
      if (vcodec.isNotEmpty && vcodec != 'none') continue;

      final lang = normalizeLanguageCode(fmt['language']?.toString());
      final note = (fmt['format_note']?.toString() ?? '').toLowerCase();
      final langPref = parseDoubleValue(fmt['language_preference'], fallback: -1);
      final isOriginal = fmt['is_original'] == true ||
          note.contains('original') ||
          (!note.contains('dub') &&
              (langPref >= 5 || (rootLang != 'und' && lang == rootLang)));
      final abr =
          parseDoubleValue(fmt['abr'], fallback: parseDoubleValue(fmt['tbr']))
              .round();
      final ext = (fmt['ext']?.toString() ?? 'm4a').toLowerCase();

      final track = AudioTrack(
        trackId: '${lang}_${isOriginal ? 'orig' : 'dub'}',
        formatId: fmt['format_id']?.toString() ?? '',
        language: lang,
        label: formatAudioTrackLabel(lang, isOriginal),
        url: url,
        ext: ext,
        codec: acodec,
        bitrateKbps: abr,
        filesize: resolveFormatFilesize(fmt,
            rootDuration: duration, tbrKbps: abr.toDouble()),
        isOriginal: isOriginal,
        httpHeaders:
            mergeHeaderMaps(fallbackHeaders, toHeaderMap(fmt['http_headers'])),
      );

      final isDirect =
          !isManifestUrlOrProto(url, fmt['protocol']?.toString() ?? '');
      final codecScore = (ext == 'm4a' || acodec.contains('mp4a')) ? 300 : 100;
      final score = (isDirect ? 100000.0 : 0.0) + codecScore + abr;
      final key = '$lang|${isOriginal ? 1 : 0}';
      final prev = byKey[key];
      if (prev == null || score > prev.score) {
        byKey[key] = ScoredCandidate(score: score, value: track);
      }
    }

    final tracks = byKey.values.map((e) => e.value).toList();
    tracks.sort((a, b) {
      if (a.isOriginal != b.isOriginal) return a.isOriginal ? -1 : 1;
      final p = languageSortPriority(a.language)
          .compareTo(languageSortPriority(b.language));
      if (p != 0) return p;
      final l = a.language.compareTo(b.language);
      return l != 0 ? l : b.bitrateKbps.compareTo(a.bitrateKbps);
    });
    return List<AudioTrack>.unmodifiable(tracks);
  }

  List<SubtitleTrack> rankSubtitleTracks(Map<String, dynamic> root) {
    final result = <SubtitleTrack>[];
    _collectSubGroup(root['subtitles'], isAuto: false, out: result);
    _collectSubGroup(root['automatic_captions'], isAuto: true, out: result);
    result.sort((a, b) {
      if (a.isAutoGenerated != b.isAutoGenerated) {
        return a.isAutoGenerated ? 1 : -1;
      }
      final p = languageSortPriority(a.language)
          .compareTo(languageSortPriority(b.language));
      return p != 0 ? p : a.language.compareTo(b.language);
    });
    return List<SubtitleTrack>.unmodifiable(result);
  }

  void _collectSubGroup(
    Object? rawGroup, {
    required bool isAuto,
    required List<SubtitleTrack> out,
  }) {
    if (rawGroup is! Map) return;
    for (final entry in rawGroup.entries) {
      final lang = normalizeLanguageCode(entry.key.toString());
      if (entry.value is! List) continue;
      Map<String, dynamic>? picked;
      var bestScore = -1;
      for (final rawItem in entry.value as List) {
        if (rawItem is! Map) continue;
        final item = Map<String, dynamic>.from(rawItem);
        final url = item['url']?.toString().trim() ?? '';
        if (url.isEmpty) continue;
        final ext = (item['ext']?.toString() ?? '').toLowerCase();
        final s = ext == 'vtt' ? 3 : (ext == 'srt' ? 2 : 1);
        if (s > bestScore) {
          bestScore = s;
          picked = item;
        }
      }
      if (picked != null) {
        final ext = (picked['ext']?.toString() ?? 'vtt').toLowerCase();
        final name =
            picked['name']?.toString().trim() ?? languageDisplayName(lang);
        out.add(SubtitleTrack(
          subId: '${isAuto ? 'auto' : 'sub'}_$lang',
          language: lang,
          label: isAuto ? '$name (Auto)' : name,
          url: picked['url'].toString().trim(),
          ext: ext,
          isAutoGenerated: isAuto,
        ));
      }
    }
  }
}
