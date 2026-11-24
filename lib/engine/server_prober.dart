import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/utils/filename_sanitizer.dart';
import 'http_client_factory.dart';

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
    this.cookieHeader = '',
  });

  final int totalSize;
  final bool supportsRanges;
  final String? filename;
  final String contentType;
  final String finalUrl;
  final int httpStatus;
  final bool linkExpired;
  final String cookieHeader;
}

/// Probes HTTP server capabilities (size, range support, filename, expiry).
class ServerProber {
  ServerProber({
    HttpClient? httpClient,
    this.timeout = const Duration(seconds: 20),
  }) : _injectedClient = httpClient;

  static const String defaultUserAgent = HttpClientFactory.defaultUserAgent;

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
        HttpClientFactory.create(
          connectionTimeout: timeout,
          idleTimeout: timeout,
        );
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
      final probeHeaders = result != null && result.cookieHeader.isNotEmpty
          ? HttpClientFactory.withCookieHeader(headers, result.cookieHeader)
          : headers;
      final rangeRes = await _probeGet(
        client,
        probeUri,
        probeHeaders,
        allowError: true,
        requestedRange: true,
      );
      if (rangeRes != null && rangeRes.linkExpired) return rangeRes;

      if (rangeRes != null && rangeRes.httpStatus >= 200 && rangeRes.httpStatus < 300) {
        result = _mergeProbe(result, rangeRes);
      } else if (!headOk) {
        final plainRes = await _probeGet(
          client,
          probeUri,
          probeHeaders,
          allowError: false,
          requestedRange: false,
        );
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
      cookieHeader: resolved.cookieHeader,
    );
  }

  Future<ProbeResult?> _tryHead(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    try {
      final redir = await HttpClientFactory.openWithCookieRedirects(
        client: client,
        method: 'HEAD',
        uri: uri,
        headers: headers,
        timeout: timeout,
      );
      final resp = redir.response;
      await resp.drain<void>();
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final totalSize = _parseContentLength(resp.headers);
      final ar = (resp.headers.value(HttpHeaders.acceptRangesHeader) ?? '').toLowerCase();
      return ProbeResult(
        totalSize: totalSize,
        supportsRanges: ar == 'bytes' && totalSize > 0,
        filename: _parseContentDisposition(resp.headers.value('content-disposition')),
        contentType: _parseContentType(resp.headers),
        finalUrl: redir.finalUri.toString(),
        httpStatus: resp.statusCode,
        cookieHeader: redir.cookieHeader,
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
    required bool requestedRange,
  }) async {
    try {
      final redir = await HttpClientFactory.openWithCookieRedirects(
        client: client,
        method: 'GET',
        uri: uri,
        headers: headers,
        rangeHeader: requestedRange ? 'bytes=0-0' : null,
        timeout: timeout,
      );
      final resp = redir.response;
      final finalUrl = redir.finalUri.toString();
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
          cookieHeader: redir.cookieHeader,
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
      if (status == HttpStatus.ok) {
        if (totalSize == 0) {
          totalSize = _parseContentLength(resp.headers);
        }
        if (requestedRange) {
          supportsRanges = false;
        } else {
          final ar = (resp.headers.value(HttpHeaders.acceptRangesHeader) ?? '').toLowerCase();
          supportsRanges = ar == 'bytes' && totalSize > 0;
        }
      }

      return ProbeResult(
        totalSize: totalSize,
        supportsRanges: supportsRanges,
        filename: _parseContentDisposition(resp.headers.value('content-disposition')),
        contentType: _parseContentType(resp.headers),
        finalUrl: finalUrl,
        httpStatus: status,
        cookieHeader: redir.cookieHeader,
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
      cookieHeader: next.cookieHeader.isNotEmpty ? next.cookieHeader : base.cookieHeader,
    );
  }

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
