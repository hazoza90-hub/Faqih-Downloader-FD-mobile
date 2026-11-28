import 'package:path/path.dart' as p;

import '../../core/utils/filename_sanitizer.dart';

/// SSRF host guard and HTML candidate extractor for indirect download landing pages.
abstract final class HtmlCandidateParser {
  static const Set<String> _ignoredStaticExts = <String>{
    '.css', '.js', '.mjs', '.map', '.svg', '.woff', '.woff2', '.ttf', '.eot', '.ico',
  };
  static const Set<String> _imageExts = <String>{
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp',
  };
  static const Set<String> _strongBinaryExts = <String>{
    '.apk', '.xapk', '.apks', '.apkm', '.obb', '.ipa', '.torrent', '.zip', '.rar',
    '.7z', '.tar', '.gz', '.bz2', '.xz', '.tgz', '.exe', '.msi', '.iso', '.dmg',
    '.pkg', '.deb', '.rpm', '.pdf', '.epub', '.doc', '.docx', '.xls', '.xlsx',
    '.ppt', '.pptx', '.mp4', '.mkv', '.mp3', '.m4a', '.webm', '.avi', '.mov',
    '.flac', '.wav', '.bin',
  };

  static String? rewriteKnownDirectHostUrl(Uri uri) {
    final host = uri.host.trim().toLowerCase();
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
    if (host == 'drive.google.com') {
      String? fileId;
      if (segs.length >= 3 && segs[0] == 'file' && segs[1] == 'd') {
        fileId = segs[2];
      } else if (segs.length == 1 && segs[0] == 'open') {
        fileId = uri.queryParameters['id']?.trim();
      }
      if (fileId != null && fileId.isNotEmpty) {
        return 'https://drive.usercontent.google.com/download'
            '?id=${Uri.encodeQueryComponent(fileId)}&export=download&confirm=t';
      }
    }
    if ((host == 'dropbox.com' || host.endsWith('.dropbox.com')) && segs.isNotEmpty) {
      if (uri.queryParameters['dl'] != '1') {
        final nextParams = <String, String>{...uri.queryParameters, 'dl': '1'};
        return uri.replace(queryParameters: nextParams).toString();
      }
    }
    if (host == 'github.com' && segs.length >= 5 && segs[2] == 'blob') {
      final owner = segs[0];
      final repo = segs[1];
      final rest = segs.sublist(3).join('/');
      return 'https://raw.githubusercontent.com/$owner/$repo/$rest';
    }
    return null;
  }

  static bool isPrivateOrLoopbackHost(String hostname) {
    var h = hostname.trim().toLowerCase();
    if (h.startsWith('[') && h.endsWith(']')) {
      h = h.substring(1, h.length - 1);
    }
    final zoneIdx = h.indexOf('%');
    if (zoneIdx > 0) h = h.substring(0, zoneIdx);
    if (h.isEmpty ||
        h == 'localhost' ||
        h.endsWith('.local') ||
        h.endsWith('.internal')) {
      return true;
    }
    try {
      return _isPrivateIpv4Bytes(Uri.parseIPv4Address(h));
    } catch (_) {}
    try {
      return _isPrivateIpv6Bytes(Uri.parseIPv6Address(h));
    } catch (_) {}
    return false;
  }

  static bool _isPrivateIpv4Bytes(List<int> b) {
    if (b.length != 4) return false;
    final a = b[0];
    final c = b[1];
    if (a == 0 || a == 10 || a == 127 || a >= 224) return true;
    if (a == 100 && c >= 64 && c <= 127) return true;
    if (a == 169 && c == 254) return true;
    if (a == 172 && c >= 16 && c <= 31) return true;
    if (a == 192 && c == 168) return true;
    return false;
  }

  static bool _isPrivateIpv6Bytes(List<int> b) {
    if (b.length != 16) return false;
    var allZero = true;
    for (var i = 0; i < 15; i++) {
      if (b[i] != 0) allZero = false;
    }
    if (allZero && (b[15] == 0 || b[15] == 1)) return true;
    if ((b[0] & 0xfe) == 0xfc) return true;
    if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return true;
    if (b[0] == 0xff) return true;
    var mappedPrefix = true;
    for (var i = 0; i < 10; i++) {
      if (b[i] != 0) mappedPrefix = false;
    }
    if (mappedPrefix && b[10] == 0xff && b[11] == 0xff) {
      return _isPrivateIpv4Bytes(b.sublist(12, 16));
    }
    return false;
  }

  static List<String> extractCandidates(
    String html,
    Uri baseUri, {
    bool srcIsPublic = false,
  }) {
    final scores = <String, int>{};

    void consider(String? rawUrl, int bonus, {bool allowImage = false}) {
      if (rawUrl == null) return;
      final cleaned =
          rawUrl.trim().replaceAll('&amp;', '&').replaceAll(r'\/', '/');
      if (cleaned.isEmpty ||
          cleaned.startsWith('#') ||
          cleaned.startsWith('javascript:') ||
          cleaned.startsWith('mailto:') ||
          cleaned.startsWith('data:')) {
        return;
      }
      final Uri target;
      try {
        final parsed = Uri.tryParse(cleaned);
        target = (parsed != null && parsed.hasScheme)
            ? parsed
            : baseUri.resolve(cleaned);
      } catch (_) {
        return;
      }
      final scheme = target.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') return;
      if (srcIsPublic && isPrivateOrLoopbackHost(target.host)) return;

      final full = target.toString();
      final ext = p.extension(target.path).toLowerCase();
      if (_ignoredStaticExts.contains(ext)) return;
      if (!allowImage && _imageExts.contains(ext)) return;

      var total = bonus;
      if (_strongBinaryExts.contains(ext) ||
          full.toLowerCase().contains('.tar.gz')) {
        total += 120;
        if (ext == '.apk' ||
            ext == '.xapk' ||
            ext == '.apks' ||
            ext == '.apkm' ||
            ext == '.obb' ||
            ext == '.zip' ||
            ext == '.exe') {
          total += 30;
        }
      }
      final lower = full.toLowerCase();
      if (lower.contains('download') || lower.contains('releases/download')) {
        total += 45;
      }
      if (total <= 0) return;
      final prev = scores[full];
      if (prev == null || total > prev) scores[full] = total;
    }

    for (final m in _metaTagRe.allMatches(html)) {
      final tag = m.group(0)!;
      if (!_metaRefreshCheckRe.hasMatch(tag)) continue;
      final cm = _metaRefreshUrlRe.firstMatch(tag);
      consider(cm?.group(1), 80);
    }
    for (final m in _anchorRe.allMatches(html)) {
      final attrs = m.group(1) ?? '';
      final hrefMatch = _hrefAttrRe.firstMatch(attrs);
      final href = hrefMatch?.group(1) ?? hrefMatch?.group(2);
      final hasDlAttr =
          RegExp(r'\bdownload\b', caseSensitive: false).hasMatch(attrs);
      final inner = (m.group(2) ?? '').toLowerCase();
      var bonus = hasDlAttr ? 75 : 5;
      if (inner.contains('download') ||
          inner.contains('apk') ||
          inner.contains('تحميل') ||
          inner.contains('تنزيل')) {
        bonus += 35;
      }
      consider(href, bonus, allowImage: hasDlAttr);
    }
    for (final m in _dataAttrRe.allMatches(html)) {
      consider(m.group(1), 65);
    }
    for (final m in _jsRedirectRe.allMatches(html)) {
      consider(m.group(1) ?? m.group(2), 80);
    }
    for (final m in _formActionRe.allMatches(html)) {
      consider(m.group(1) ?? m.group(2), 55);
    }
    for (final m in _iframeSrcRe.allMatches(html)) {
      consider(m.group(1) ?? m.group(2), 50);
    }
    for (final m in _jsonDownloadUrlRe.allMatches(html)) {
      consider(m.group(1), 75);
    }
    for (final m in _scriptUrlRe.allMatches(html)) {
      consider(m.group(1), 20);
    }

    final ranked = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ranked.map((e) => e.key).toList(growable: false);
  }

  static String? parseContentDispositionFilename(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    for (final pat in <RegExp>[_cdStarRe, _cdPlainRe]) {
      final m = pat.firstMatch(header);
      if (m == null) continue;
      final raw = (m.group(1) ?? (m.groupCount >= 2 ? m.group(2) : null) ?? '')
          .replaceAll('"', '')
          .replaceAll("'", '')
          .trim();
      final decoded = _safeDecode(raw).replaceAll('\\', '/');
      final base = p.posix.basename(decoded);
      if (base.isNotEmpty && base != '.' && base != '..') {
        return sanitizeFilename(base);
      }
    }
    return null;
  }

  static String? extractUrlFilename(Uri uri) {
    final segs = uri.pathSegments.where((s) => s.trim().isNotEmpty).toList();
    if (segs.isEmpty) return null;
    final decoded = _safeDecode(segs.last).trim();
    if (decoded.isEmpty || decoded == '.' || decoded == '..') return null;
    return sanitizeFilename(decoded);
  }

  static String _safeDecode(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  static final RegExp _metaTagRe =
      RegExp(r'<meta\b[^>]*>', caseSensitive: false);
  static final RegExp _metaRefreshCheckRe = RegExp(
    r'''http-equiv\s*=\s*["']?refresh["']?''',
    caseSensitive: false,
  );
  static final RegExp _metaRefreshUrlRe = RegExp(
    r'''content\s*=\s*["'][^"']*url\s*=\s*([^"';\s>]+)''',
    caseSensitive: false,
  );
  static final RegExp _anchorRe = RegExp(
    r'<a\b([^>]*)>(.*?)</a>',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _hrefAttrRe = RegExp(
    r'''href\s*=\s*(?:"([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final RegExp _dataAttrRe = RegExp(
    r'''data-(?:download-url|download|href|url|src|link|file)\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );
  static final RegExp _jsRedirectRe = RegExp(
    r'''(?:location(?:\.href)?\s*=\s*["']([^"']+)["']|(?:location\.(?:assign|replace)|window\.open)\(\s*["']([^"']+)["'])''',
    caseSensitive: false,
  );
  static final RegExp _formActionRe = RegExp(
    r'''<form\b[^>]*\baction\s*=\s*(?:"([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final RegExp _iframeSrcRe = RegExp(
    r'''<iframe\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final RegExp _jsonDownloadUrlRe = RegExp(
    r'''"(?:download_url|downloadUrl|file_url)"\s*:\s*"([^"]+)"''',
    caseSensitive: false,
  );
  static final RegExp _scriptUrlRe = RegExp(
    r'''["'](https?:(?:\\/|/)[^\s"'<>]+\.(?:apk|xapk|apks|apkm|obb|ipa|torrent|zip|rar|7z|exe|msi|pdf|mp4|mkv|mp3)(?:\?[^"'\s<>]*)?)["']''',
    caseSensitive: false,
  );
  static final RegExp _cdStarRe = RegExp(
    r"filename\*\s*=\s*(?:[A-Za-z0-9_-]+'')?([^;\r\n]+)",
    caseSensitive: false,
  );
  static final RegExp _cdPlainRe = RegExp(
    r'filename\s*=\s*(?:"([^"]+)"|([^;\s\r\n]+))',
    caseSensitive: false,
  );
}
