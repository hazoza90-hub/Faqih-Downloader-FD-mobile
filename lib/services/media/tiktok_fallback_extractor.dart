import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/models/youtube_stream_info.dart';
import '../../engine/http_client_factory.dart';
import 'format_ranker.dart';
import 'tiktok_state_parser.dart';

/// Pure Dart TikTok fallback extractor matching desktop `tiktok_fallback.py`.
class TikTokFallbackExtractor {
  TikTokFallbackExtractor({
    HttpClient Function()? httpClientFactory,
    FormatRanker ranker = const FormatRanker(),
    String tikwmBaseUrl = 'https://www.tikwm.com',
    this.timeout = const Duration(seconds: 20),
  })  : _clientFactory = httpClientFactory ??
            (() => HttpClientFactory.create(connectionTimeout: timeout)),
        _ranker = ranker,
        _tikwmBaseUrl = tikwmBaseUrl.replaceFirst(RegExp(r'/+$'), '');

  static const String _chromeUa = HttpClientFactory.defaultUserAgent;
  static const int _maxHtmlBytes = 4 * 1024 * 1024;

  final HttpClient Function() _clientFactory;
  final FormatRanker _ranker;
  final String _tikwmBaseUrl;
  final Duration timeout;

  Future<YouTubeStreamInfo?> extract(String url) async {
    final direct = await _extractDirect(url);
    if (direct != null) return direct;
    return _extractViaTikwm(url);
  }

  Future<YouTubeStreamInfo?> _extractDirect(String url) async {
    final page = await _fetchPageWithCookies(url);
    if (page == null || page.html.isEmpty) return null;

    final stateJson = TikTokStateParser.extractEmbeddedStateJson(page.html);
    if (stateJson == null) return null;

    final item = TikTokStateParser.findItemStruct(stateJson);
    if (item == null) return null;

    final video = TikTokStateParser.asStringMap(item['video']);
    if (video == null) return null;

    final formats = TikTokStateParser.buildDirectFormats(video, item['music']);
    if (formats.isEmpty) return null;

    final subtitles = TikTokStateParser.buildDirectSubtitles(video);
    final reqHeaders = <String, String>{
      'User-Agent': _chromeUa,
      'Referer': 'https://www.tiktok.com/',
      if (page.cookieHeader.isNotEmpty) 'Cookie': page.cookieHeader,
    };

    final author = TikTokStateParser.asStringMap(item['author']);
    final title = TikTokStateParser.firstNonEmpty(<String?>[
          item['desc']?.toString(),
          author?['nickname']?.toString(),
          author?['uniqueId']?.toString(),
        ]) ??
        'TikTok Video';

    final cover = TikTokStateParser.firstUrl(video['originCover']) ??
        TikTokStateParser.firstUrl(video['cover']) ??
        '';
    final raw = <String, dynamic>{
      'id': (item['id'] ?? '').toString(),
      'title': title,
      'duration': TikTokStateParser.toInt(video['duration']),
      'thumbnail': cover,
      'webpage_url': page.finalUrl,
      'extractor_key': 'TikTok',
      'http_headers': reqHeaders,
      'formats': formats,
      if (subtitles.isNotEmpty) 'subtitles': subtitles,
    };
    return _ranker.parse(raw, fallbackUrl: page.finalUrl);
  }

  Future<YouTubeStreamInfo?> _extractViaTikwm(String url) async {
    final client = _clientFactory()..connectionTimeout = timeout;
    try {
      final apiUri = Uri.parse(
        '$_tikwmBaseUrl/api/?url=${Uri.encodeQueryComponent(url)}&hd=1',
      );
      final req = await client.getUrl(apiUri).timeout(timeout);
      req.headers.set(HttpHeaders.userAgentHeader, _chromeUa);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 400) {
        await resp.drain<void>();
        return null;
      }
      final body = await _readBoundedUtf8(resp, 1024 * 1024);
      final decoded = jsonDecode(body);
      if (decoded is! Map || decoded['code'] != 0) return null;
      final data = TikTokStateParser.asStringMap(decoded['data']);
      if (data == null) return null;

      final formats = TikTokStateParser.buildTikwmFormats(data, _tikwmBaseUrl);
      if (formats.isEmpty) return null;

      final author = TikTokStateParser.asStringMap(data['author']);
      final title = TikTokStateParser.firstNonEmpty(<String?>[
            data['title']?.toString(),
            author?['nickname']?.toString(),
            author?['unique_id']?.toString(),
          ]) ??
          'TikTok Video';

      final raw = <String, dynamic>{
        'id': (data['id'] ?? '').toString(),
        'title': title,
        'duration': TikTokStateParser.toInt(data['duration']),
        'thumbnail': TikTokStateParser.resolveTikwmUrl(
              data['origin_cover']?.toString() ?? data['cover']?.toString(),
              _tikwmBaseUrl,
            ) ??
            '',
        'webpage_url': url,
        'extractor_key': 'TikTok',
        'http_headers': const <String, String>{
          'User-Agent': _chromeUa,
          'Referer': 'https://www.tiktok.com/',
        },
        'formats': formats,
      };
      return _ranker.parse(raw, fallbackUrl: url);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<_FetchedTikTokPage?> _fetchPageWithCookies(String rawUrl) async {
    var current = Uri.tryParse(rawUrl.trim());
    if (current == null ||
        (current.scheme != 'http' && current.scheme != 'https')) {
      return null;
    }
    final cookies = <String, String>{};
    final client = _clientFactory()..connectionTimeout = timeout;
    try {
      for (var hop = 0; hop < 8; hop++) {
        final req = await client.getUrl(current!).timeout(timeout);
        req.followRedirects = false;
        req.headers.set(HttpHeaders.userAgentHeader, _chromeUa);
        req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
        req.headers.set('Referer', 'https://www.tiktok.com/');
        if (cookies.isNotEmpty) {
          req.headers.set(
            HttpHeaders.cookieHeader,
            cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
          );
        }
        final resp = await req.close().timeout(timeout);
        for (final c in resp.cookies) {
          cookies[c.name] = c.value;
        }
        final status = resp.statusCode;
        if (status >= 300 && status < 400) {
          final loc = resp.headers.value(HttpHeaders.locationHeader);
          await resp.drain<void>();
          if (loc == null || loc.trim().isEmpty) return null;
          current = current.resolve(loc.trim());
          continue;
        }
        if (status < 200 || status >= 400) {
          await resp.drain<void>();
          return null;
        }
        final html = await _readBoundedUtf8(resp, _maxHtmlBytes);
        return _FetchedTikTokPage(
          finalUrl: current.toString(),
          html: html,
          cookieHeader: cookies.entries
              .map((e) => '${e.key}=${e.value}')
              .join('; '),
        );
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _readBoundedUtf8(
    HttpClientResponse resp,
    int maxBytes,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      final remaining = maxBytes - builder.length;
      if (remaining <= 0) break;
      builder.add(
        chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
      );
      if (builder.length >= maxBytes) break;
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }
}

class _FetchedTikTokPage {
  const _FetchedTikTokPage({
    required this.finalUrl,
    required this.html,
    required this.cookieHeader,
  });

  final String finalUrl;
  final String html;
  final String cookieHeader;
}
