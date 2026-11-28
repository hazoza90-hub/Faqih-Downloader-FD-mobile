import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../engine/http_client_factory.dart';
import 'html_candidate_parser.dart';

@immutable
class ResolvedDownloadResult {
  const ResolvedDownloadResult({
    required this.url,
    this.filename,
    this.fromContentDisposition = false,
    this.contentType = '',
    this.contentLength = 0,
    this.isHtmlLanding = false,
    this.resolvedFromHtml = false,
    this.headers = const <String, String>{},
  });

  final String url;
  final String? filename;
  final bool fromContentDisposition;
  final String contentType;
  final int contentLength;
  final bool isHtmlLanding;
  final bool resolvedFromHtml;
  final Map<String, String> headers;
}

/// Resolves redirects, Content-Disposition filenames, and indirect HTML APK/binary download pages.
class HtmlDownloadResolver {
  HtmlDownloadResolver({
    HttpClient Function()? httpClientFactory,
    this.timeout = const Duration(seconds: 20),
  }) : _clientFactory = httpClientFactory ??
            (() => HttpClientFactory.create(connectionTimeout: timeout));

  static const String browserUserAgent = HttpClientFactory.defaultUserAgent;
  static const int _maxHtmlBytes = 1024 * 1024;
  static const int _maxRedirects = 8;

  final HttpClient Function() _clientFactory;
  final Duration timeout;

  static bool isPrivateOrLoopbackHost(String hostname) =>
      HtmlCandidateParser.isPrivateOrLoopbackHost(hostname);

  static List<String> extractCandidates(
    String html,
    Uri baseUri, {
    bool srcIsPublic = false,
  }) =>
      HtmlCandidateParser.extractCandidates(
        html,
        baseUri,
        srcIsPublic: srcIsPublic,
      );

  Future<ResolvedDownloadResult> resolve(
    String url, {
    Map<String, String> headers = const <String, String>{},
    bool probeCandidates = true,
  }) async {
    var startUri = Uri.tryParse(url.trim());
    if (startUri == null ||
        !const <String>{'http', 'https'}.contains(startUri.scheme.toLowerCase())) {
      throw ArgumentError('Invalid HTTP URL: $url');
    }
    final rewritten = HtmlCandidateParser.rewriteKnownDirectHostUrl(startUri);
    if (rewritten != null) {
      startUri = Uri.parse(rewritten);
    }
    final srcIsPublic = !isPrivateOrLoopbackHost(startUri.host);

    final client = _clientFactory()..connectionTimeout = timeout;
    try {
      final fetched = await _openWithRedirects(
        client: client,
        method: 'GET',
        startUri: startUri,
        headers: headers,
        srcIsPublic: srcIsPublic,
        readHtmlBody: true,
      );

      if (fetched.statusCode < 200 || fetched.statusCode >= 300) {
        throw HttpException('HTTP ${fetched.statusCode}', uri: fetched.finalUri);
      }

      final cookieStr = fetched.cookieHeader;
      if (!_isHtmlMime(fetched.contentType)) {
        final mergedHeaders = _withDefaultUa(<String, String>{
          ...headers,
          if (cookieStr.isNotEmpty) HttpHeaders.cookieHeader: cookieStr,
        });
        return ResolvedDownloadResult(
          url: fetched.finalUri.toString(),
          filename: fetched.filename ??
              HtmlCandidateParser.extractUrlFilename(fetched.finalUri),
          fromContentDisposition: fetched.filename != null,
          contentType: fetched.contentType,
          contentLength: fetched.contentLength,
          isHtmlLanding: false,
          resolvedFromHtml: false,
          headers: mergedHeaders,
        );
      }

      final candidates = extractCandidates(
        fetched.htmlBody,
        fetched.finalUri,
        srcIsPublic: srcIsPublic,
      );
      final candidateHeaders = _withDefaultUa(<String, String>{
        ...headers,
        'Referer': fetched.finalUri.toString(),
        if (cookieStr.isNotEmpty) HttpHeaders.cookieHeader: cookieStr,
      });
      if (!probeCandidates) {
        if (candidates.isNotEmpty) {
          final top = Uri.parse(candidates.first);
          return ResolvedDownloadResult(
            url: candidates.first,
            filename: HtmlCandidateParser.extractUrlFilename(top),
            resolvedFromHtml: true,
            headers: candidateHeaders,
          );
        }
        return ResolvedDownloadResult(
          url: fetched.finalUri.toString(),
          contentType: fetched.contentType,
          isHtmlLanding: true,
        );
      }

      for (final candidateUrl in candidates.take(8)) {
        final candUri = Uri.tryParse(candidateUrl);
        if (candUri == null) continue;
        final probed = await _probeCandidate(
          client: client,
          uri: candUri,
          headers: candidateHeaders,
          srcIsPublic: srcIsPublic,
        );
        if (probed != null) return probed;
      }

      return ResolvedDownloadResult(
        url: fetched.finalUri.toString(),
        contentType: fetched.contentType,
        isHtmlLanding: true,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<ResolvedDownloadResult?> _probeCandidate({
    required HttpClient client,
    required Uri uri,
    required Map<String, String> headers,
    required bool srcIsPublic,
  }) async {
    const attempts = <({String method, bool withRange})>[
      (method: 'HEAD', withRange: false),
      (method: 'GET', withRange: true),
      (method: 'GET', withRange: false),
    ];
    for (final attempt in attempts) {
      try {
        final reqHeaders = attempt.withRange
            ? <String, String>{...headers, HttpHeaders.rangeHeader: 'bytes=0-0'}
            : headers;
        final res = await _openWithRedirects(
          client: client,
          method: attempt.method,
          startUri: uri,
          headers: reqHeaders,
          srcIsPublic: srcIsPublic,
          readHtmlBody: false,
        );
        if (res.statusCode >= 200 &&
            res.statusCode < 300 &&
            !_isHtmlMime(res.contentType)) {
          final mergedHeaders = _withDefaultUa(<String, String>{
            ...headers,
            if (res.cookieHeader.isNotEmpty)
              HttpHeaders.cookieHeader: res.cookieHeader,
          });
          return ResolvedDownloadResult(
            url: res.finalUri.toString(),
            filename: res.filename ??
                HtmlCandidateParser.extractUrlFilename(res.finalUri),
            fromContentDisposition: res.filename != null,
            contentType: res.contentType,
            contentLength: res.contentLength,
            isHtmlLanding: false,
            resolvedFromHtml: true,
            headers: mergedHeaders,
          );
        }
      } on StateError {
        rethrow;
      } catch (_) {}
    }
    return null;
  }

  static Map<String, String> _withDefaultUa(Map<String, String> headers) {
    final hasUa = headers.entries.any(
      (e) => e.key.toLowerCase() == HttpHeaders.userAgentHeader &&
          e.value.trim().isNotEmpty,
    );
    if (hasUa) return headers;
    return <String, String>{
      'User-Agent': browserUserAgent,
      ...headers,
    };
  }

  Future<_HttpFetchInfo> _openWithRedirects({
    required HttpClient client,
    required String method,
    required Uri startUri,
    required Map<String, String> headers,
    required bool srcIsPublic,
    required bool readHtmlBody,
  }) async {
    var current = startUri;
    final cookies = <String, String>{};
    _seedCookies(headers, cookies);
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      final req = await client.openUrl(method, current).timeout(timeout);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, browserUserAgent);
      req.headers.set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      );
      headers.forEach(req.headers.set);
      if (cookies.isNotEmpty) {
        req.headers.set(HttpHeaders.cookieHeader, _formatCookies(cookies));
      }

      final resp = await req.close().timeout(timeout);
      for (final c in resp.cookies) {
        cookies[c.name] = c.value;
      }
      final status = resp.statusCode;
      if (status >= 300 && status < 400) {
        final loc = resp.headers.value(HttpHeaders.locationHeader);
        await _discardBody(resp);
        if (loc == null || loc.trim().isEmpty) break;
        final next = current.resolve(loc.trim());
        if (!const <String>{'http', 'https'}.contains(next.scheme.toLowerCase())) {
          throw StateError('Unsupported redirect scheme: ${next.scheme}');
        }
        if (srcIsPublic && isPrivateOrLoopbackHost(next.host)) {
          throw StateError('SSRF blocked: redirect to private host ${next.host}');
        }
        current = next;
        continue;
      }

      final ct = (resp.headers.value(HttpHeaders.contentTypeHeader) ?? '')
          .split(';')
          .first
          .trim()
          .toLowerCase();
      final cdName = HtmlCandidateParser.parseContentDispositionFilename(
        resp.headers.value('content-disposition'),
      );
      var length =
          int.tryParse(resp.headers.value(HttpHeaders.contentLengthHeader) ?? '') ??
              0;
      if (length <= 0) {
        final cr = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        if (cr.contains('/')) {
          length = int.tryParse(cr.split('/').last.trim()) ?? 0;
        }
      }

      var html = '';
      if (readHtmlBody && _isHtmlMime(ct)) {
        html = await _readBoundedUtf8(resp, _maxHtmlBytes);
      } else {
        await _discardBody(resp);
      }
      return _HttpFetchInfo(
        finalUri: current,
        statusCode: status,
        contentType: ct,
        contentLength: length,
        filename: cdName,
        htmlBody: html,
        cookieHeader: _formatCookies(cookies),
      );
    }
    throw HttpException('Too many redirects', uri: current);
  }

  static void _seedCookies(Map<String, String> headers, Map<String, String> out) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() != HttpHeaders.cookieHeader) continue;
      for (final part in entry.value.split(';')) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        final k = part.substring(0, eq).trim();
        final v = part.substring(eq + 1).trim();
        if (k.isNotEmpty) out[k] = v;
      }
    }
  }

  static String _formatCookies(Map<String, String> cookies) =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  static bool _isHtmlMime(String ct) =>
      ct == 'text/html' || ct == 'application/xhtml+xml';

  static Future<void> _discardBody(HttpClientResponse resp) async {
    final sub = resp.listen((_) {});
    await sub.cancel();
  }

  static Future<String> _readBoundedUtf8(
    HttpClientResponse resp,
    int limit,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      final rem = limit - builder.length;
      if (rem <= 0) break;
      builder.add(chunk.length <= rem ? chunk : chunk.sublist(0, rem));
      if (builder.length >= limit) break;
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }
}

class _HttpFetchInfo {
  const _HttpFetchInfo({
    required this.finalUri,
    required this.statusCode,
    required this.contentType,
    required this.contentLength,
    required this.filename,
    required this.htmlBody,
    this.cookieHeader = '',
  });

  final Uri finalUri;
  final int statusCode;
  final String contentType;
  final int contentLength;
  final String? filename;
  final String htmlBody;
  final String cookieHeader;
}
