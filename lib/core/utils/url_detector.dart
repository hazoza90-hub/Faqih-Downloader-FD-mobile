final RegExp _youtubeRegex = RegExp(
  r'^(?:https?://)?(?:www\.|m\.|music\.)?'
  r'(?:youtube\.com/(?:watch\?(?:.*&)?v=|shorts/|embed/|v/|live/)|youtu\.be/)'
  r'([a-zA-Z0-9_-]{11})(?:[/?#&]|$)',
  caseSensitive: false,
);

final RegExp _youtubePlaylistRegex = RegExp(
  r'^(?:https?://)?(?:www\.|m\.|music\.)?youtube\.com/playlist\?(?:.*&)?list=[a-zA-Z0-9_-]+',
  caseSensitive: false,
);

final Map<String, RegExp> _socialMediaPatterns = <String, RegExp>{
  'tiktok': RegExp(
    r'^(?:https?://)?(?:[a-zA-Z0-9-]+\.)?tiktok\.com/(?:@[^/?#]+/(?:video|photo)/\d+|share/video/\d+|t/[a-zA-Z0-9_-]+|v/\d+)|^(?:https?://)?(?:vt|vm)\.tiktok\.com/[a-zA-Z0-9_-]+',
    caseSensitive: false,
  ),
  'instagram': RegExp(
    r'^(?:https?://)?(?:[a-zA-Z0-9-]+\.)?(?:instagram\.com|instagr\.am)/(?:p|reel|reels|stories|tv|share)/(?:[a-zA-Z0-9_.-]+/)?[a-zA-Z0-9_.-]+',
    caseSensitive: false,
  ),
  'facebook': RegExp(
    r'^(?:https?://)?(?:[a-zA-Z0-9-]+\.)?(?:fb\.watch|fb\.me)/[a-zA-Z0-9_.-]+/?|^(?:https?://)?(?:[a-zA-Z0-9-]+\.)?facebook\.com/(?:watch/?(?:\?|$)|reel/\d+|reels/\d+|share/[vr]/[a-zA-Z0-9_-]+|[^/?#]+/videos/\d+|(?:video|story)\.php\?(?:.*&)?(?:v|story_fbid)=\d+)',
    caseSensitive: false,
  ),
  'twitter': RegExp(
    r'^(?:https?://)?(?:[a-zA-Z0-9-]+\.)?(?:twitter\.com|x\.com)/(?:i(?:/web)?/status|[^/?#]+/status)/\d+',
    caseSensitive: false,
  ),
  'reddit': RegExp(
    r'^(?:https?://)?(?:[a-zA-Z0-9-]+\.)?(?:reddit\.com/r/[^/?#]+/comments/[a-zA-Z0-9]+|redd\.it/[a-zA-Z0-9]+|v\.redd\.it/[a-zA-Z0-9]+)',
    caseSensitive: false,
  ),
  'vimeo': RegExp(
    r'^(?:https?://)?(?:[a-zA-Z0-9-]+\.)?vimeo\.com/(?:channels/[a-zA-Z0-9_-]+/|groups/[a-zA-Z0-9_-]+/videos/|album/\d+/video/|video/)?\d+',
    caseSensitive: false,
  ),
  'dailymotion': RegExp(
    r'^(?:https?://)?(?:[a-zA-Z0-9-]+\.)?(?:dailymotion\.com/(?:video|embed/video)/|dai\.ly/)[a-zA-Z0-9]+',
    caseSensitive: false,
  ),
  'pinterest': RegExp(
    r'^(?:https?://)?(?:[a-zA-Z0-9-]+\.)?(?:pinterest\.(?:com|[a-z]{2}(?:\.[a-z]{2})?)/pin/|pin\.it/)[a-zA-Z0-9_-]+',
    caseSensitive: false,
  ),
  'threads': RegExp(
    r'^(?:https?://)?(?:www\.)?threads\.net/@?[^/?#]+/post/[a-zA-Z0-9_-]+',
    caseSensitive: false,
  ),
  'snapchat': RegExp(
    r'^(?:https?://)?(?:[a-zA-Z0-9-]+\.)?snapchat\.com/(?:spotlight|story|t)/[a-zA-Z0-9_-]+',
    caseSensitive: false,
  ),
  'twitch': RegExp(
    r'^(?:https?://)?(?:[a-zA-Z0-9-]+\.)?twitch\.tv/(?:videos/\d+|clips/[a-zA-Z0-9_-]+)',
    caseSensitive: false,
  ),
  'rumble': RegExp(
    r'^(?:https?://)?(?:www\.)?rumble\.com/v[a-zA-Z0-9_-]+',
    caseSensitive: false,
  ),
};

const Map<String, String> _platformDisplayNames = <String, String>{
  'tiktok': 'TikTok',
  'instagram': 'Instagram',
  'facebook': 'Facebook',
  'twitter': 'Twitter / X',
  'reddit': 'Reddit',
  'vimeo': 'Vimeo',
  'dailymotion': 'Dailymotion',
  'pinterest': 'Pinterest',
  'threads': 'Threads',
  'snapchat': 'Snapchat',
  'twitch': 'Twitch',
  'rumble': 'Rumble',
};

bool isHttpUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty || RegExp(r'\s').hasMatch(trimmed)) {
    return false;
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme) {
    return false;
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host.isEmpty) {
    return false;
  }
  return host.contains('.') || host == 'localhost' || host.contains(':');
}

bool isYouTubeUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  return _youtubeRegex.hasMatch(trimmed) || _youtubePlaylistRegex.hasMatch(trimmed);
}

bool isSocialMediaUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  for (final pattern in _socialMediaPatterns.values) {
    if (pattern.hasMatch(trimmed)) {
      return true;
    }
  }
  return false;
}

const Set<String> _directDownloadExtensions = <String>{
  '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.tgz',
  '.exe', '.msi', '.iso', '.dmg', '.pkg', '.deb', '.rpm', '.apk', '.xapk',
  '.bin', '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.epub', '.txt',
  '.mp4', '.mp3', '.m4a', '.mkv', '.webm', '.avi', '.mov', '.flv',
  '.wav', '.flac', '.ogg', '.opus', '.jpg', '.jpeg', '.png', '.webp', '.gif',
};

bool isTikTokUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return false;
  if (_socialMediaPatterns['tiktok']!.hasMatch(trimmed)) return true;
  final host = Uri.tryParse(trimmed)?.host.toLowerCase() ?? '';
  return host == 'tiktok.com' || host.endsWith('.tiktok.com');
}

bool isDirectDownloadUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return false;
  final clean = trimmed.split('?').first.split('#').first.toLowerCase();
  if (clean.endsWith('.tar.gz') || clean.endsWith('.tar.bz2') || clean.endsWith('.tar.xz')) {
    return true;
  }
  final path = Uri.tryParse(clean)?.path.toLowerCase() ?? clean;
  for (final ext in _directDownloadExtensions) {
    if (clean.endsWith(ext) || path.endsWith(ext)) return true;
  }
  return false;
}

bool isMediaUrl(String url) {
  return isYouTubeUrl(url) || isSocialMediaUrl(url);
}

String? extractMediaPlatform(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  if (isYouTubeUrl(trimmed)) {
    return 'YouTube';
  }
  for (final entry in _socialMediaPatterns.entries) {
    if (entry.value.hasMatch(trimmed)) {
      return _platformDisplayNames[entry.key] ?? entry.key;
    }
  }
  return null;
}

String? extractYouTubeId(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final match = _youtubeRegex.firstMatch(trimmed);
  return match?.group(1);
}

final RegExp _httpUrlScanRegex = RegExp(r'https?://\S+', caseSensitive: false);
final RegExp _trailingPunctuationRegex = RegExp(r'''[.,;:!?)\]\}>"']+$''');

List<String> extractUrls(String text) {
  if (text.trim().isEmpty) {
    return const <String>[];
  }
  final seen = <String>{};
  final extracted = <String>[];
  for (final match in _httpUrlScanRegex.allMatches(text)) {
    var candidate = match.group(0)!.trim();
    candidate = candidate.replaceFirst(_trailingPunctuationRegex, '');
    if (isHttpUrl(candidate) && seen.add(candidate)) {
      extracted.add(candidate);
    }
  }
  return List<String>.unmodifiable(extracted);
}

/// Namespaced helper facade around URL validation and extraction utilities.
abstract final class UrlDetector {
  static bool isHttpUrl(String url) => _topIsHttpUrl(url);
  static bool isYouTubeUrl(String url) => _topIsYouTubeUrl(url);
  static bool isSocialMediaUrl(String url) => _topIsSocialMediaUrl(url);
  static bool isTikTokUrl(String url) => _topIsTikTokUrl(url);
  static bool isDirectDownloadUrl(String url) => _topIsDirectDownloadUrl(url);
  static bool isMediaUrl(String url) => _topIsMediaUrl(url);
  static String? extractMediaPlatform(String url) => _topExtractMediaPlatform(url);
  static String? extractYouTubeId(String url) => _topExtractYouTubeId(url);
  static List<String> extractUrls(String text) => _topExtractUrls(text);
}

bool _topIsHttpUrl(String url) => isHttpUrl(url);
bool _topIsYouTubeUrl(String url) => isYouTubeUrl(url);
bool _topIsSocialMediaUrl(String url) => isSocialMediaUrl(url);
bool _topIsTikTokUrl(String url) => isTikTokUrl(url);
bool _topIsDirectDownloadUrl(String url) => isDirectDownloadUrl(url);
bool _topIsMediaUrl(String url) => isMediaUrl(url);
String? _topExtractMediaPlatform(String url) => extractMediaPlatform(url);
String? _topExtractYouTubeId(String url) => extractYouTubeId(url);
List<String> _topExtractUrls(String text) => extractUrls(text);
