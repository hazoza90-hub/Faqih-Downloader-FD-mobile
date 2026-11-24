import 'dart:io';

/// Result returned by [HttpClientFactory.openWithCookieRedirects].
class HttpRedirectResult {
  const HttpRedirectResult({
    required this.response,
    required this.finalUri,
    this.cookieHeader = '',
  });

  final HttpClientResponse response;
  final Uri finalUri;
  final String cookieHeader;
}

/// Shared permissive HTTP client builder, manual cookie-redirect follower, and Netscape cookie parser.
abstract final class HttpClientFactory {
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static HttpClient create({
    Duration connectionTimeout = const Duration(seconds: 20),
    Duration idleTimeout = const Duration(seconds: 20),
    int? maxConnectionsPerHost,
  }) {
    final client = HttpClient()
      ..connectionTimeout = connectionTimeout
      ..idleTimeout = idleTimeout
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    if (maxConnectionsPerHost != null && maxConnectionsPerHost > 0) {
      client.maxConnectionsPerHost = maxConnectionsPerHost;
    }
    return client;
  }

  static Future<HttpRedirectResult> openWithCookieRedirects({
    required HttpClient client,
    required String method,
    required Uri uri,
    Map<String, String> headers = const <String, String>{},
    String? rangeHeader,
    Duration timeout = const Duration(seconds: 20),
    int maxRedirects = 8,
    void Function(HttpClientRequest? req)? onActiveRequest,
    bool Function()? shouldAbort,
  }) async {
    var current = uri;
    var currentMethod = method.toUpperCase();
    final cookies = <String, String>{};
    seedCookiesFromHeaders(headers, cookies);

    for (var hop = 0; hop <= maxRedirects; hop++) {
      if (shouldAbort?.call() ?? false) {
        throw const HttpException('Request aborted');
      }
      final req = await client.openUrl(currentMethod, current).timeout(timeout);
      onActiveRequest?.call(req);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, defaultUserAgent);
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      headers.forEach((k, v) {
        final lower = k.toLowerCase();
        if (lower == HttpHeaders.cookieHeader) return;
        if (rangeHeader != null && lower == HttpHeaders.rangeHeader) return;
        req.headers.set(k, v);
      });
      if (rangeHeader != null && rangeHeader.isNotEmpty) {
        req.headers.set(HttpHeaders.rangeHeader, rangeHeader);
      }
      if (cookies.isNotEmpty) {
        req.headers.set(HttpHeaders.cookieHeader, formatCookies(cookies));
      }
      if (shouldAbort?.call() ?? false) {
        req.abort();
        throw const HttpException('Request aborted');
      }

      final resp = await req.close().timeout(timeout);
      collectCookies(resp, cookies);

      final status = resp.statusCode;
      if (status == HttpStatus.movedPermanently ||
          status == HttpStatus.found ||
          status == HttpStatus.seeOther ||
          status == HttpStatus.temporaryRedirect ||
          status == 308) {
        final loc = resp.headers.value(HttpHeaders.locationHeader);
        final sub = resp.listen((_) {});
        await sub.cancel();
        if (loc == null || loc.trim().isEmpty) {
          return HttpRedirectResult(
            response: resp,
            finalUri: current,
            cookieHeader: formatCookies(cookies),
          );
        }
        final next = current.resolve(loc.trim());
        if (!const <String>{'http', 'https'}.contains(next.scheme.toLowerCase())) {
          throw HttpException('Unsupported redirect scheme: ${next.scheme}', uri: next);
        }
        if (status == HttpStatus.seeOther &&
            currentMethod != 'HEAD' &&
            currentMethod != 'GET') {
          currentMethod = 'GET';
        }
        current = next;
        continue;
      }

      return HttpRedirectResult(
        response: resp,
        finalUri: current,
        cookieHeader: formatCookies(cookies),
      );
    }
    throw HttpException('Too many redirects', uri: current);
  }

  static void seedCookiesFromHeaders(
    Map<String, String> headers,
    Map<String, String> out,
  ) {
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

  static void collectCookies(HttpClientResponse resp, Map<String, String> out) {
    for (final c in resp.cookies) {
      if (c.name.isNotEmpty) out[c.name] = c.value;
    }
  }

  static String formatCookies(Map<String, String> cookies) =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  static Map<String, String> withCookieHeader(
    Map<String, String> headers,
    String cookieHeader,
  ) {
    final trimmed = cookieHeader.trim();
    if (trimmed.isEmpty) return headers;
    final cookies = <String, String>{};
    seedCookiesFromHeaders(headers, cookies);
    seedCookiesFromHeaders(<String, String>{HttpHeaders.cookieHeader: trimmed}, cookies);
    final merged = formatCookies(cookies);
    if (merged.isEmpty) return headers;
    final out = <String, String>{
      for (final e in headers.entries)
        if (e.key.toLowerCase() != HttpHeaders.cookieHeader) e.key: e.value,
      'Cookie': merged,
    };
    return out;
  }

  static String effectiveUserAgent(Map<String, String> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == HttpHeaders.userAgentHeader &&
          entry.value.trim().isNotEmpty) {
        return entry.value.trim();
      }
    }
    return defaultUserAgent;
  }

  static String extractNetscapeCookieHeader(
    String? cookiesFilePath,
    String targetUrl,
  ) {
    final path = cookiesFilePath?.trim() ?? '';
    if (path.isEmpty) return '';
    final file = File(path);
    if (!file.existsSync()) return '';
    final uri = Uri.tryParse(targetUrl.trim());
    if (uri == null || uri.host.isEmpty) return '';

    final host = uri.host.toLowerCase();
    final urlPath = uri.path.isEmpty ? '/' : uri.path;
    final isHttps = uri.scheme.toLowerCase() == 'https';
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final out = <String, String>{};

    for (final rawLine in file.readAsLinesSync()) {
      var line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#HttpOnly_')) {
        line = line.substring('#HttpOnly_'.length);
      } else if (line.startsWith('#')) {
        continue;
      }
      final parts = line.split('\t');
      if (parts.length < 7) continue;
      var domain = parts[0].trim().toLowerCase();
      if (domain.startsWith('.')) domain = domain.substring(1);
      if (domain.isEmpty) continue;
      if (host != domain && !host.endsWith('.$domain')) continue;
      if (parts[3].trim().toUpperCase() == 'TRUE' && !isHttps) continue;
      final expiry = int.tryParse(parts[4].trim()) ?? 0;
      if (expiry > 0 && expiry < nowSec) continue;
      final cookiePath = parts[2].trim().isEmpty ? '/' : parts[2].trim();
      if (cookiePath != '/' && !urlPath.startsWith(cookiePath)) continue;
      final name = parts[5].trim();
      if (name.isEmpty) continue;
      out[name] = parts.sublist(6).join('\t').trim();
    }
    return formatCookies(out);
  }
}
