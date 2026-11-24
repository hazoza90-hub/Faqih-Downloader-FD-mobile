import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/models/youtube_stream_info.dart';
import '../../core/utils/url_detector.dart';
import '../../engine/http_client_factory.dart';
import 'format_ranker.dart';

/// Fast pure-Dart YouTube InnerTube (`ANDROID_VR`) metadata & stream extractor.
class YouTubeInnerTubeExtractor {
  YouTubeInnerTubeExtractor({
    FormatRanker ranker = const FormatRanker(),
    HttpClient Function()? httpClientFactory,
    Uri? endpoint,
    Duration timeout = const Duration(seconds: 5),
  })  : _ranker = ranker,
        _httpClientFactory = httpClientFactory,
        _endpoint = endpoint ?? _defaultEndpoint,
        _timeout = timeout;

  static final Uri _defaultEndpoint =
      Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  static const String androidVrUserAgent =
      'com.google.android.apps.youtube.vr.oculus/1.60.19 '
      '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';

  static const Map<String, Object?> _vrClient = <String, Object?>{
    'clientName': 'ANDROID_VR',
    'clientVersion': '1.60.19',
    'deviceMake': 'Oculus',
    'deviceModel': 'Quest 3',
    'osName': 'Android',
    'osVersion': '12L',
    'androidSdkVersion': 32,
    'hl': 'en',
    'gl': 'US',
  };

  final FormatRanker _ranker;
  final HttpClient Function()? _httpClientFactory;
  final Uri _endpoint;
  final Duration _timeout;

  /// Extracts ranked streams for a single YouTube video URL, or returns `null`.
  Future<YouTubeStreamInfo?> extract(
    String url, {
    void Function(void Function() aborter)? onRegisterAbort,
  }) async {
    final cleanUrl = url.trim();
    if (cleanUrl.toLowerCase().contains('/playlist?')) return null;
    final videoId = UrlDetector.extractYouTubeId(cleanUrl);
    if (videoId == null) return null;

    HttpClient? client;
    var aborted = false;
    onRegisterAbort?.call(() {
      aborted = true;
      client?.close(force: true);
    });
    try {
      if (aborted) return null;
      client = _httpClientFactory?.call() ??
          HttpClientFactory.create(connectionTimeout: _timeout, idleTimeout: _timeout);
      if (aborted) return null;
      final req = await client.postUrl(_endpoint).timeout(_timeout);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      req.headers.set(HttpHeaders.userAgentHeader, androidVrUserAgent);
      req.headers.set('X-YouTube-Client-Name', '28');
      req.headers.set('X-YouTube-Client-Version', '1.60.19');
      req.write(jsonEncode(<String, dynamic>{
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
        'context': const <String, Object?>{'client': _vrClient},
      }));
      final resp = await req.close().timeout(_timeout);
      if (aborted || resp.statusCode != HttpStatus.ok) {
        await resp.drain<void>().catchError((_) {});
        return null;
      }
      final decoded = jsonDecode(await utf8.decodeStream(resp).timeout(_timeout));
      if (aborted || decoded is! Map) return null;
      return parsePlayerResponse(
        Map<String, dynamic>.from(decoded),
        videoId,
        fallbackUrl: cleanUrl,
      );
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  /// Parses a raw InnerTube `/youtubei/v1/player` JSON map into [YouTubeStreamInfo].
  YouTubeStreamInfo? parsePlayerResponse(
    Map<String, dynamic> data,
    String videoId, {
    String? fallbackUrl,
  }) {
    final playability = data['playabilityStatus'];
    if (playability is! Map || playability['status']?.toString() != 'OK') {
      return null;
    }
    final streaming = data['streamingData'];
    if (streaming is! Map) return null;

    final normalizedFormats = <Map<String, dynamic>>[];
    _collectFormats(streaming['formats'], progressive: true, out: normalizedFormats);
    _collectFormats(streaming['adaptiveFormats'], progressive: false, out: normalizedFormats);
    if (normalizedFormats.isEmpty) return null;

    final videoDetails = data['videoDetails'] is Map
        ? Map<String, dynamic>.from(data['videoDetails'] as Map)
        : const <String, dynamic>{};
    final captions = _extractCaptions(data['captions']);
    final watchUrl = 'https://www.youtube.com/watch?v=$videoId';

    final normalized = <String, dynamic>{
      'id': videoDetails['videoId']?.toString() ?? videoId,
      'title': videoDetails['title']?.toString() ?? 'YouTube Video',
      'duration': int.tryParse('${videoDetails['lengthSeconds'] ?? ''}') ?? 0,
      'thumbnail': _pickBestThumbnail(videoDetails['thumbnail']),
      'webpage_url': watchUrl,
      'extractor_key': 'Youtube',
      'http_headers': const <String, String>{'User-Agent': androidVrUserAgent},
      'formats': normalizedFormats,
      'subtitles': captions.manual,
      'automatic_captions': captions.auto,
    };

    final info = _ranker.parse(normalized, fallbackUrl: fallbackUrl ?? watchUrl);
    return info.videoFormats.isEmpty ? null : info;
  }

  void _collectFormats(Object? rawList, {required bool progressive, required List<Map<String, dynamic>> out}) {
    if (rawList is! List) return;
    for (final raw in rawList.whereType<Map>()) {
      final url = raw['url']?.toString().trim() ?? '';
      if (!UrlDetector.isHttpUrl(url)) continue;

      final parsedMime = _parseMime(raw['mimeType']?.toString() ?? '', progressive: progressive);
      final bitrate = int.tryParse('${raw['bitrate'] ?? ''}') ?? 0;
      final tbrKbps = bitrate > 0 ? bitrate / 1000.0 : 0.0;
      final contentLen = int.tryParse('${raw['contentLength'] ?? ''}');
      final qualityNote = (raw['qualityLabel'] ?? raw['quality'] ?? '').toString().trim();
      final fmt = <String, dynamic>{
        'format_id': '${raw['itag'] ?? ''}', 'url': url, 'ext': parsedMime.ext,
        'vcodec': parsedMime.vcodec, 'acodec': parsedMime.acodec,
        if (raw['width'] != null) 'width': raw['width'],
        if (raw['height'] != null) 'height': raw['height'],
        if (raw['fps'] != null) 'fps': raw['fps'],
        if (contentLen != null && contentLen > 0) 'filesize': contentLen,
        if (tbrKbps > 0) 'tbr': tbrKbps,
        if (parsedMime.isAudioOnly && tbrKbps > 0) 'abr': tbrKbps,
        'format_note': qualityNote,
      };
      if (raw['audioTrack'] is Map) {
        final track = raw['audioTrack'] as Map;
        final display = track['displayName']?.toString().trim() ?? '';
        final rawId = track['id']?.toString().trim() ?? '';
        final isOrig = track['audioIsDefault'] == true || display.toLowerCase().contains('original');
        fmt['language'] = rawId.isNotEmpty ? rawId.split('.').first : 'und';
        fmt['is_original'] = isOrig;
        fmt['language_preference'] = isOrig ? 10 : 0;
        if (!isOrig && !qualityNote.toLowerCase().contains('dub')) {
          fmt['format_note'] = qualityNote.isEmpty ? 'dubbed' : '$qualityNote dubbed';
        }
      }
      out.add(fmt);
    }
  }

  static ({String ext, String vcodec, String acodec, bool isAudioOnly}) _parseMime(
    String mimeType, {
    required bool progressive,
  }) {
    final parts = mimeType.split(';');
    final base = parts.first.trim().toLowerCase();
    final isAudioOnly = !progressive && base.startsWith('audio/');
    final rawSub = base.contains('/') ? base.split('/').last : 'mp4';
    final ext = isAudioOnly && rawSub == 'mp4'
        ? 'm4a'
        : (rawSub == '3gpp' ? '3gp' : (rawSub.isEmpty ? 'mp4' : rawSub));

    var codecsStr = '';
    for (final part in parts.skip(1)) {
      final m = RegExp(r'''codecs\s*=\s*"?([^"]+)"?''', caseSensitive: false)
          .firstMatch(part);
      if (m != null) {
        codecsStr = m.group(1)!.trim();
        break;
      }
    }
    final codecList = codecsStr
        .split(',')
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList(growable: false);

    if (progressive) {
      final vcodec = codecList.isNotEmpty ? codecList.first : 'avc1';
      final acodec = codecList.length > 1 ? codecList[1] : 'mp4a.40.2';
      return (ext: ext, vcodec: vcodec, acodec: acodec, isAudioOnly: false);
    }
    if (isAudioOnly) {
      final acodec = codecList.isNotEmpty ? codecList.first : (ext == 'webm' ? 'opus' : 'mp4a.40.2');
      return (ext: ext, vcodec: 'none', acodec: acodec, isAudioOnly: true);
    }
    final vcodec = codecList.isNotEmpty ? codecList.first : (ext == 'webm' ? 'vp9' : 'avc1');
    return (ext: ext, vcodec: vcodec, acodec: 'none', isAudioOnly: false);
  }

  static ({Map<String, List<Map<String, dynamic>>> manual, Map<String, List<Map<String, dynamic>>> auto})
      _extractCaptions(Object? rawCaptions) {
    final manual = <String, List<Map<String, dynamic>>>{};
    final auto = <String, List<Map<String, dynamic>>>{};
    if (rawCaptions is! Map) return (manual: manual, auto: auto);
    final renderer = rawCaptions['playerCaptionsTracklistRenderer'];
    if (renderer is! Map || renderer['captionTracks'] is! List) {
      return (manual: manual, auto: auto);
    }
    for (final raw in (renderer['captionTracks'] as List).whereType<Map>()) {
      var baseUrl = raw['baseUrl']?.toString().trim() ?? '';
      if (!UrlDetector.isHttpUrl(baseUrl)) continue;
      if (!baseUrl.contains('fmt=')) {
        baseUrl = '$baseUrl${baseUrl.contains('?') ? '&' : '?'}fmt=vtt';
      }
      final lang = (raw['languageCode']?.toString() ?? 'und').trim();
      final nameObj = raw['name'];
      var name = '';
      if (nameObj is Map) {
        name = nameObj['simpleText']?.toString().trim() ?? '';
        if (name.isEmpty && nameObj['runs'] is List) {
          name = (nameObj['runs'] as List).whereType<Map>().map((r) => r['text']?.toString() ?? '').join().trim();
        }
      }
      final isAuto = raw['kind']?.toString().toLowerCase() == 'asr';
      ((isAuto ? auto : manual)[lang] ??= <Map<String, dynamic>>[]).add(<String, dynamic>{
        'url': baseUrl,
        'ext': 'vtt',
        if (name.isNotEmpty) 'name': name,
      });
    }
    return (manual: manual, auto: auto);
  }

  static String _pickBestThumbnail(Object? rawThumbnail) {
    if (rawThumbnail is! Map || rawThumbnail['thumbnails'] is! List) return '';
    final list = (rawThumbnail['thumbnails'] as List).whereType<Map>().toList();
    if (list.isEmpty) return '';
    list.sort((a, b) => (int.tryParse('${b['width']}') ?? 0).compareTo(int.tryParse('${a['width']}') ?? 0));
    return list.first['url']?.toString().trim() ?? '';
  }
}
