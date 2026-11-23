import 'dart:convert';

/// Parses embedded TikTok HTML JSON state (`__UNIVERSAL_DATA_FOR_REHYDRATION__` / `SIGI_STATE`)
/// and TikWM API payloads into FormatRanker-compatible maps.
abstract final class TikTokStateParser {
  static final RegExp _universalRe = RegExp(
    r'<script[^>]*\bid=["\x27]__UNIVERSAL_DATA_FOR_REHYDRATION__["\x27][^>]*>(.*?)</script>',
    dotAll: true,
    caseSensitive: false,
  );
  static final RegExp _sigiRe = RegExp(
    r'<script[^>]*\bid=["\x27]SIGI_STATE["\x27][^>]*>(.*?)</script>',
    dotAll: true,
    caseSensitive: false,
  );

  static Map<String, dynamic>? extractEmbeddedStateJson(String html) {
    for (final pat in <RegExp>[_universalRe, _sigiRe]) {
      final match = pat.firstMatch(html);
      final raw = match?.group(1)?.trim() ?? '';
      if (raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return null;
  }

  static Map<String, dynamic>? findItemStruct(Map<String, dynamic> data) {
    final scope = asStringMap(data['__DEFAULT_SCOPE__']);
    final detail = asStringMap(scope?['webapp.video-detail']);
    final info = asStringMap(detail?['itemInfo']);
    final direct = asStringMap(info?['itemStruct']);
    if (direct != null) return direct;

    final itemModule = asStringMap(data['ItemModule']);
    if (itemModule != null && itemModule.isNotEmpty) {
      final first = asStringMap(itemModule.values.first);
      if (first != null) return first;
    }
    return _findRecursiveItem(data, 0);
  }

  static Map<String, dynamic>? _findRecursiveItem(Object? node, int depth) {
    if (depth > 8 || node is! Map) return null;
    if (node['video'] is Map &&
        (node.containsKey('id') || node.containsKey('desc'))) {
      return Map<String, dynamic>.from(node);
    }
    for (final v in node.values) {
      final found = _findRecursiveItem(v, depth + 1);
      if (found != null) return found;
    }
    return null;
  }

  static List<Map<String, dynamic>> buildDirectFormats(
    Map<String, dynamic> video,
    Object? musicRaw,
  ) {
    final formats = <Map<String, dynamic>>[];
    final seenUrls = <String>{};

    void addFormat(Map<String, dynamic> fmt) {
      final u = fmt['url']?.toString().trim() ?? '';
      if (u.isEmpty || !seenUrls.add(u)) return;
      formats.add(fmt);
    }

    final bitrates = video['bitrateInfo'];
    if (bitrates is List) {
      for (var i = 0; i < bitrates.length; i++) {
        final br = asStringMap(bitrates[i]);
        final playAddr = asStringMap(br?['PlayAddr']);
        final urlList = playAddr?['UrlList'];
        if (br == null || urlList is! List) continue;
        final streamUrl = _firstHttpString(urlList);
        if (streamUrl == null) continue;
        final codec = (br['CodecType'] ?? 'h264').toString();
        final bitrate = toInt(br['Bitrate']);
        addFormat(<String, dynamic>{
          'format_id': br['GearName']?.toString() ?? 'tiktok_$i',
          'url': streamUrl,
          'ext': 'mp4',
          'vcodec': codec.isEmpty ? 'h264' : codec,
          'acodec': 'mp4a.40.2',
          'width': toInt(br['Width'] ?? video['width']),
          'height': toInt(br['Height'] ?? video['height']),
          'filesize': toInt(playAddr?['DataSize']),
          'tbr': bitrate > 0 ? bitrate / 1000.0 : 1000.0,
          'format_note': br['GearName']?.toString() ?? 'direct',
        });
      }
    }

    for (final entry in <(String, String?, double, String)>[
      ('download_addr', firstUrl(video['downloadAddr']), 1200.0, 'downloadAddr'),
      ('play_addr', firstUrl(video['playAddr']), 1000.0, 'playAddr'),
    ]) {
      if (entry.$2 == null) continue;
      addFormat(<String, dynamic>{
        'format_id': entry.$1,
        'url': entry.$2,
        'ext': 'mp4',
        'vcodec': 'h264',
        'acodec': 'mp4a.40.2',
        'width': toInt(video['width']),
        'height': toInt(video['height']),
        'tbr': entry.$3,
        'format_note': entry.$4,
      });
    }

    final music = asStringMap(musicRaw);
    final musicUrl = firstUrl(music?['playUrl']);
    if (musicUrl != null) {
      addFormat(_audioMap('music_audio', musicUrl, 'music'));
    }
    return formats;
  }

  static List<Map<String, dynamic>> buildTikwmFormats(
    Map<String, dynamic> data,
    String tikwmBaseUrl,
  ) {
    final formats = <Map<String, dynamic>>[];
    final candidates = <({String id, String key, int w, int h, double tbr, String note})>[
      (id: 'hd_no_watermark', key: 'hdplay', w: 1080, h: 1920, tbr: 2000.0, note: 'HD No Watermark'),
      (id: 'sd_no_watermark', key: 'play', w: 576, h: 1024, tbr: 1000.0, note: 'No Watermark'),
      (id: 'watermarked', key: 'wmplay', w: 480, h: 640, tbr: 600.0, note: 'Watermarked'),
    ];
    for (final c in candidates) {
      final u = resolveTikwmUrl(data[c.key]?.toString(), tikwmBaseUrl);
      if (u == null) continue;
      formats.add(<String, dynamic>{
        'format_id': c.id,
        'url': u,
        'ext': 'mp4',
        'vcodec': 'h264',
        'acodec': 'mp4a.40.2',
        'width': c.w,
        'height': c.h,
        'tbr': c.tbr,
        'format_note': c.note,
      });
    }
    final musicUrl = resolveTikwmUrl(data['music']?.toString(), tikwmBaseUrl);
    if (musicUrl != null) {
      formats.add(_audioMap('music_audio', musicUrl, 'Audio Only'));
    }
    return formats;
  }

  static Map<String, dynamic> buildDirectSubtitles(Map<String, dynamic> video) {
    final out = <String, dynamic>{};
    final cla = asStringMap(video['claInfo']);
    final list = cla?['captionInfos'] ?? video['subtitleInfos'];
    if (list is! List) return out;
    for (final item in list) {
      final m = asStringMap(item);
      if (m == null) continue;
      final url = firstNonEmpty(<String?>[m['url']?.toString(), m['Url']?.toString()]);
      if (url == null || !url.startsWith('http')) continue;
      final lang = firstNonEmpty(<String?>[
            m['language']?.toString(),
            m['lang']?.toString(),
            m['LanguageCodeName']?.toString(),
          ]) ??
          'en';
      (out.putIfAbsent(lang, () => <Map<String, dynamic>>[]) as List)
          .add(<String, dynamic>{'url': url, 'ext': 'vtt', 'name': lang});
    }
    return out;
  }

  static Map<String, dynamic> _audioMap(String id, String url, String note) =>
      <String, dynamic>{
        'format_id': id,
        'url': url,
        'ext': 'mp3',
        'vcodec': 'none',
        'acodec': 'mp3',
        'tbr': 128.0,
        'abr': 128,
        'is_original': true,
        'language': 'und',
        'format_note': note,
      };

  static String? resolveTikwmUrl(String? raw, String baseUrl) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('/')) return '$baseUrl$trimmed';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    return null;
  }

  static Map<String, dynamic>? asStringMap(Object? raw) =>
      raw is Map ? Map<String, dynamic>.from(raw) : null;

  static String? firstUrl(Object? raw) {
    if (raw is String && raw.trim().startsWith('http')) return raw.trim();
    if (raw is Map) return _firstHttpString(raw['UrlList'] ?? raw['urlList']);
    if (raw is List) return _firstHttpString(raw);
    return null;
  }

  static String? _firstHttpString(Object? raw) {
    if (raw is! List) return null;
    for (final item in raw) {
      final s = item?.toString().trim() ?? '';
      if (s.startsWith('http://') || s.startsWith('https://')) return s;
    }
    return null;
  }

  static String? firstNonEmpty(List<String?> values) {
    for (final v in values) {
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  static int toInt(Object? raw) =>
      raw is int ? raw : (raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0);
}
