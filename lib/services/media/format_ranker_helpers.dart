import '../../core/models/audio_track.dart';
import '../../core/models/video_format_option.dart';
import '../../core/utils/url_detector.dart';

class ScoredCandidate<T> {
  const ScoredCandidate({required this.score, required this.value});
  final double score;
  final T value;
}

AudioTrack? pickDefaultAudio(List<AudioTrack> tracks) {
  if (tracks.isEmpty) return null;
  return tracks.firstWhere((t) => t.isOriginal, orElse: () => tracks.first);
}

List<Map<String, dynamic>> readFormatMaps(Object? raw) {
  if (raw is! List) return const <Map<String, dynamic>>[];
  return raw
      .whereType<Map>()
      .map(Map<String, dynamic>.from)
      .toList(growable: false);
}

String bucketForResolution(int height, int fps) {
  if (height >= 2160) return '2160p';
  if (height >= 1440) return '1440p';
  if (height >= 1080) return fps >= 50 ? '1080p60' : '1080p';
  if (height >= 720) return '720p';
  if (height >= 480) return '480p';
  if (height >= 360) return '360p';
  if (height >= 240) return '240p';
  return height > 0 ? '${height}p' : 'best';
}

String labelForResolutionBucket(String bucket, int height) {
  if (bucket == '2160p') return '2160p (4K)';
  if (bucket == '1440p') return '1440p (2K)';
  if (bucket == '1080p60') return '1080p 60fps';
  if (height > 0) return bucket;
  return 'Best';
}

double scoreVideoOption(VideoFormatOption f) {
  final directScore = f.isHlsOrDash ? 0.0 : 100000.0;
  final vc = f.vcodec.toLowerCase();
  final codecScore = (vc.contains('avc1') || vc.contains('h264'))
      ? 20000.0
      : (vc.contains('vp9') ? 4000.0 : 1500.0);
  final extScore = f.ext == 'mp4' ? 5000.0 : 0.0;
  final progScore = f.isProgressive ? 500.0 : 0.0;
  return directScore +
      codecScore +
      extScore +
      progScore +
      f.tbrKbps.clamp(0.0, 15000.0);
}

int resolveFormatHeight(Map<String, dynamic> fmt) {
  final h = parseIntValue(fmt['height']);
  if (h > 0) return h;
  final m = RegExp(r'(\d{3,4})p').firstMatch(
    '${fmt['resolution'] ?? ''} ${fmt['format_note'] ?? ''}',
  );
  return m != null ? (int.tryParse(m.group(1)!) ?? 0) : 0;
}

int resolveFormatFilesize(
  Map<String, dynamic> fmt, {
  required double rootDuration,
  required double tbrKbps,
}) {
  final exact = parseIntValue(
    fmt['filesize'],
    fallback: parseIntValue(fmt['filesize_approx']),
  );
  if (exact > 0) return exact;
  if (rootDuration > 0 && tbrKbps > 0) {
    return ((tbrKbps * 1000.0 / 8.0) * rootDuration).round();
  }
  return 0;
}

String readMediaTitle(Map<String, dynamic> raw, {required String fallback}) {
  final t = raw['title']?.toString().trim() ?? '';
  return t.isEmpty ? fallback : t;
}

String readMediaWebpageUrl(Map<String, dynamic> raw, String fallbackUrl) {
  final u =
      (raw['webpage_url'] ?? raw['original_url'])?.toString().trim() ?? '';
  return u.isEmpty ? fallbackUrl : u;
}

String resolveMediaPlatform(String url, Map<String, dynamic> raw) {
  return UrlDetector.extractMediaPlatform(url) ??
      raw['extractor_key']?.toString() ??
      'YouTube';
}

Map<String, String> toHeaderMap(Object? raw) {
  if (raw is! Map) return const <String, String>{};
  return <String, String>{
    for (final e in raw.entries) e.key.toString(): e.value?.toString() ?? '',
  };
}

Map<String, String> mergeHeaderMaps(
  Map<String, String> base,
  Map<String, String> over,
) =>
    <String, String>{...base, ...over};

bool isManifestUrlOrProto(String url, String protocol) {
  final p = protocol.toLowerCase();
  final u = url.toLowerCase();
  return p.contains('hls') ||
      p.contains('m3u8') ||
      p.contains('dash') ||
      u.contains('.m3u8') ||
      u.contains('.mpd');
}

String normalizeLanguageCode(String? raw) {
  final trimmed = (raw ?? '').trim().toLowerCase();
  if (trimmed.isEmpty) return 'und';
  return trimmed.split(RegExp(r'[-_]')).first;
}

int languageSortPriority(String lang) =>
    lang == 'ar' ? 0 : (lang == 'en' ? 1 : 2);

String languageDisplayName(String lang) {
  const names = <String, String>{
    'ar': 'Arabic',
    'en': 'English',
    'fr': 'French',
    'es': 'Spanish',
    'de': 'German',
    'tr': 'Turkish',
    'ur': 'Urdu',
    'und': 'Default',
  };
  return names[lang] ?? lang.toUpperCase();
}

String formatAudioTrackLabel(String lang, bool isOriginal) =>
    '${languageDisplayName(lang)} (${isOriginal ? 'Original' : 'Dubbed'})';

int parseIntValue(Object? raw, {int fallback = 0}) => raw is int
    ? raw
    : (raw is num ? raw.toInt() : int.tryParse('$raw') ?? fallback);

double parseDoubleValue(Object? raw, {double fallback = 0.0}) => raw is double
    ? raw
    : (raw is num ? raw.toDouble() : double.tryParse('$raw') ?? fallback);
