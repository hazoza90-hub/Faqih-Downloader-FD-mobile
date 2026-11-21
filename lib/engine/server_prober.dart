import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/utils/filename_sanitizer.dart';

class ProbeException implements Exception {
  const ProbeException(
    this.message, {
    this.httpStatus,
    this.linkExpired = false,
    this.isHtmlResponse = false,
  });

  final String message;
  final int? httpStatus;
  final bool linkExpired;
  final bool isHtmlResponse;

  @override
  String toString() => 'ProbeException($message, status=$httpStatus)';
}

@immutable
class ProbeResult {
  const ProbeResult({
    required this.totalSize,
    required this.supportsRanges,
    required this.filename,
    required this.contentType,
    required this.finalUrl,
    required this.httpStatus,
    this.linkExpired = false,
  });

  final int totalSize;
  final bool supportsRanges;
  final String? filename;
  final String contentType;
  final String finalUrl;
  final int httpStatus;
  final bool linkExpired;
}

/// Probes HTTP server capabilities (size, range support, filename, expiry).
class ServerProber {
  ServerProber({
    HttpClient? httpClient,
    this.timeout = const Duration(seconds: 12),
  }) : _injectedClient = httpClient;

  static const String defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  final HttpClient? _injectedClient;
  final Duration timeout;

  Future<ProbeResult> probe(
    String url, {
    Map<String, String> headers = const <String, String>{},
    String? destinationPath,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme.toLowerCase())) {
      throw ProbeException('Invalid download URL: $url');
    }
    if (uri.host.toLowerCase().contains('googlevideo.com')) {
      final clen = int.tryParse(uri.queryParameters['clen'] ?? '');
      if (clen != null && clen > 0) {
        return ProbeResult(
          totalSize: clen,
          supportsRanges: true,
          filename: _extractUrlFilename(uri),
          contentType: 'application/octet-stream',
          finalUrl: url,
          httpStatus: 200,
        );
      }
    }

    final ownsClient = _injectedClient == null;
    final client = _injectedClient ??
        (HttpClient()
          ..connectionTimeout = timeout
          ..idleTimeout = const Duration(seconds: 15));
    try {
      return await _probeWithClient(
        client,
        uri,
        headers: headers,
        destinationPath: destinationPath,
      );
    } finally {
      if (ownsClient) client.close(force: true);
    }
  }

  Future<ProbeResult> _probeWithClient(
    HttpClient client,
    Uri uri, {
    required Map<String, String> headers,
    String? destinationPath,
  }) async {
    var result = await _tryHead(client, uri, headers);
    final headOk = result != null;

    if (result == null || !result.supportsRanges) {
      final probeUri = Uri.parse(result?.finalUrl ?? uri.toString());
      final rangeRes = await _probeGet(
        client,
        probeUri,
        <String, String>{...headers, HttpHeaders.rangeHeader: 'bytes=0-0'},
        allowError: true,
      );
      if (rangeRes != null && rangeRes.linkExpired) return rangeRes;

      if (rangeRes != null && rangeRes.httpStatus >= 200 && rangeRes.httpStatus < 300) {
        result = _mergeProbe(result, rangeRes);
      } else if (!headOk) {
        final plainRes = await _probeGet(client, probeUri, headers, allowError: false);
        if (plainRes!.linkExpired) return plainRes;
        result = _mergeProbe(result, plainRes);
      }
    }

    final resolved = result;
    final finalFilename = resolved.filename ?? _extractUrlFilename(Uri.parse(resolved.finalUrl));
    _guardHtmlResponse(
      contentType: resolved.contentType,
      filename: finalFilename,
      destinationPath: destinationPath,
      statusCode: resolved.httpStatus,
    );
    return ProbeResult(
      totalSize: resolved.totalSize,
      supportsRanges: resolved.supportsRanges,
      filename: finalFilename,
      contentType: resolved.contentType,
      finalUrl: resolved.finalUrl,
      httpStatus: resolved.httpStatus,
    );
  }

  Future<ProbeResult?> _tryHead(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    try {
      final resp = await _send(client, 'HEAD', uri, headers);
      await resp.drain<void>();
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final totalSize = _parseContentLength(resp.headers);
      final ar = (resp.headers.value(HttpHeaders.acceptRangesHeader) ?? '').toLowerCase();
      return ProbeResult(
        totalSize: totalSize,
        supportsRanges: ar == 'bytes' && totalSize > 0,
        filename: _parseContentDisposition(resp.headers.value('content-disposition')),
        contentType: _parseContentType(resp.headers),
        finalUrl: _resolveFinalUrl(uri, resp.redirects),
        httpStatus: resp.statusCode,
      );
    } catch (_) {
      return null;
    }
  }

  Future<ProbeResult?> _probeGet(
    HttpClient client,
    Uri uri,
    Map<String, String> headers, {
    required bool allowError,
  }) async {
    try {
      final resp = await _send(client, 'GET', uri, headers);
      final finalUrl = _resolveFinalUrl(uri, resp.redirects);
      final status = resp.statusCode;
      final sub = resp.listen((_) {});
      await sub.cancel();

      if (status == 401 || status == 403 || status == 410) {
        return ProbeResult(
          totalSize: 0,
          supportsRanges: false,
          filename: null,
          contentType: _parseContentType(resp.headers),
          finalUrl: finalUrl,
          httpStatus: status,
          linkExpired: true,
        );
      }
      if (!allowError && (status < 200 || status >= 400)) {
        throw ProbeException('Server returned HTTP $status', httpStatus: status);
      }

      var totalSize = 0;
      var supportsRanges = status == HttpStatus.partialContent;
      final contentRange = resp.headers.value(HttpHeaders.contentRangeHeader);
      if (contentRange != null && contentRange.contains('/')) {
        final parsed = int.tryParse(contentRange.split('/').last.trim());
        if (parsed != null && parsed > 0) {
          totalSize = parsed;
          supportsRanges = true;
        }
      }
      if (totalSize == 0 && status == HttpStatus.ok) {
        totalSize = _parseContentLength(resp.headers);
        final ar = (resp.headers.value(HttpHeaders.acceptRangesHeader) ?? '').toLowerCase();
        supportsRanges = ar == 'bytes' && totalSize > 0;
      }

      return ProbeResult(
        totalSize: totalSize,
        supportsRanges: supportsRanges,
        filename: _parseContentDisposition(resp.headers.value('content-disposition')),
        contentType: _parseContentType(resp.headers),
        finalUrl: finalUrl,
        httpStatus: status,
      );
    } on ProbeException {
      rethrow;
    } catch (e) {
      if (!allowError) throw ProbeException('Probe request failed: $e');
      return null;
    }
  }

  ProbeResult _mergeProbe(ProbeResult? base, ProbeResult next) {
    if (base == null) return next;
    return ProbeResult(
      totalSize: next.totalSize > 0 ? next.totalSize : base.totalSize,
      supportsRanges: next.supportsRanges,
      filename: next.filename ?? base.filename,
      contentType: next.contentType.isNotEmpty ? next.contentType : base.contentType,
      finalUrl: next.finalUrl,
      httpStatus: next.httpStatus,
    );
  }

  Future<HttpClientResponse> _send(
    HttpClient client,
    String method,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final req = await client.openUrl(method, uri).timeout(timeout);
    req.followRedirects = true;
    req.maxRedirects = 8;
    req.headers.set(HttpHeaders.userAgentHeader, defaultUserAgent);
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    headers.forEach(req.headers.set);
    return req.close().timeout(timeout);
  }

  static String _resolveFinalUrl(Uri initial, List<RedirectInfo> redirects) =>
      redirects.fold<Uri>(initial, (cur, r) => cur.resolveUri(r.location)).toString();

  static String _parseContentType(HttpHeaders headers) =>
      (headers.value(HttpHeaders.contentTypeHeader) ?? '').split(';').first.trim().toLowerCase();

  static int _parseContentLength(HttpHeaders headers) {
    final parsed = int.tryParse((headers.value(HttpHeaders.contentLengthHeader) ?? '').trim());
    return (parsed != null && parsed > 0) ? parsed : 0;
  }

  static String? _parseContentDisposition(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    final patterns = <RegExp>[
      RegExp(r"filename\*\s*=\s*(?:[A-Za-z0-9_-]+'')?([^;\r\n]+)", caseSensitive: false),
      RegExp(r'filename\s*=\s*(?:"([^"]+)"|([^;\s\r\n]+))', caseSensitive: false),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(header);
      if (match == null) continue;
      final raw = (match.group(1) ?? (match.groupCount >= 2 ? match.group(2) : null) ?? '')
          .replaceAll('"', '')
          .replaceAll("'", '')
          .trim();
      final base = p.posix.basename(_safeDecode(raw).replaceAll('\\', '/'));
      if (base.isNotEmpty && base != '.' && base != '..') return sanitizeFilename(base);
    }
    return null;
  }

  static String _safeDecode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  static String? _extractUrlFilename(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.trim().isNotEmpty).toList();
    if (segments.isEmpty) return null;
    final decoded = _safeDecode(segments.last).trim();
    if (decoded.isEmpty || decoded == '.' || decoded == '..') return null;
    return sanitizeFilename(decoded);
  }

  static void _guardHtmlResponse({
    required String contentType,
    required String? filename,
    required String? destinationPath,
    required int statusCode,
  }) {
    if (contentType != 'text/html') return;
    final candidate = filename ?? (destinationPath != null ? p.basename(destinationPath) : '');
    final ext = p.extension(candidate).toLowerCase();
    if (ext.isEmpty || ext == '.bin') {
      throw ProbeException(
        'Server returned an HTML web page instead of a binary file',
        httpStatus: statusCode,
        isHtmlResponse: true,
      );
    }
  }
}
