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

  /// Returns the IP family encoded in YouTube CDN's `ip=` query parameter, or `null`.
  static InternetAddressType? preferredAddressTypeForUri(Uri uri) {
    final host = uri.host.trim().toLowerCase();
    if (!host.contains('googlevideo.com') || isPrivateOrLoopbackHost(host)) {
      return null;
    }
    final ip = (uri.queryParameters['ip'] ?? '').trim();
    if (ip.isEmpty) return null;
    return ip.contains(':') ? InternetAddressType.IPv6 : InternetAddressType.IPv4;
  }

  static HttpClient create({
    Duration connectionTimeout = const Duration(seconds: 20),
    Duration idleTimeout = const Duration(seconds: 20),
    int? maxConnectionsPerHost,
  }) {
    final client = HttpClient()
      ..connectionTimeout = connectionTimeout
      ..idleTimeout = idleTimeout
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
      if (proxyHost != null) {
        return Socket.startConnect(proxyHost, proxyPort ?? 80);
      }
      final port = uri.hasPort
          ? uri.port
          : (uri.scheme.toLowerCase() == 'https' ? 443 : 80);
      final preferredType = preferredAddressTypeForUri(uri);
      if (preferredType != null) {
        try {
          final addrs = await InternetAddress.lookup(uri.host, type: preferredType);
          if (addrs.isNotEmpty) {
            return Socket.startConnect(addrs.first, port);
          }
        } catch (_) {}
      }
      return Socket.startConnect(uri.host, port);
    };
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
    final initialIsPrivate = isPrivateOrLoopbackHost(uri.host);
    final cookiesByHost = <String, Map<String, String>>{};
    final seedHost = uri.host.toLowerCase();
    final seeded = <String, String>{};
    seedCookiesFromHeaders(headers, seeded);
    if (seeded.isNotEmpty) cookiesByHost[seedHost] = seeded;

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
      final outgoingCookies = _cookiesForHost(cookiesByHost, current.host);
      if (outgoingCookies.isNotEmpty) {
        req.headers.set(HttpHeaders.cookieHeader, formatCookies(outgoingCookies));
      }
      if (shouldAbort?.call() ?? false) {
        req.abort();
        throw const HttpException('Request aborted');
      }

      final resp = await req.close().timeout(timeout);
      _collectScopedCookies(resp, current.host, cookiesByHost);

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
            cookieHeader: formatCookies(_cookiesForHost(cookiesByHost, current.host)),
          );
        }
        final Uri next;
        try {
          next = current.resolve(loc.trim());
        } on FormatException {
          throw HttpException('Invalid redirect Location', uri: current);
        }
        if (!const <String>{'http', 'https'}.contains(next.scheme.toLowerCase())) {
          throw HttpException('Unsupported redirect scheme: ${next.scheme}', uri: next);
        }
        if (!initialIsPrivate && isPrivateOrLoopbackHost(next.host)) {
          throw StateError('SSRF blocked: redirect to private host ${next.host}');
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
        cookieHeader: formatCookies(_cookiesForHost(cookiesByHost, current.host)),
      );
    }
    throw HttpException('Too many redirects', uri: current);
  }

  static void _collectScopedCookies(
    HttpClientResponse resp,
    String requestHost,
    Map<String, Map<String, String>> cookiesByHost,
  ) {
    final normReqHost = requestHost.toLowerCase();
    for (final c in resp.cookies) {
      if (c.name.isEmpty) continue;
      var rawDomain = (c.domain ?? '').trim().toLowerCase();
      if (rawDomain.startsWith('.')) rawDomain = rawDomain.substring(1);
      final scopeHost = (rawDomain.isNotEmpty && isSameSiteOrParentDomain(rawDomain, normReqHost))
          ? rawDomain
          : normReqHost;
      (cookiesByHost[scopeHost] ??= <String, String>{})[c.name] = c.value;
    }
  }

  static Map<String, String> _cookiesForHost(
    Map<String, Map<String, String>> cookiesByHost,
    String targetHost,
  ) {
    final merged = <String, String>{};
    for (final entry in cookiesByHost.entries) {
      if (isSameSiteOrParentDomain(entry.key, targetHost)) {
        merged.addAll(entry.value);
      }
    }
    return merged;
  }

  static bool isSameSiteOrParentDomain(String hostA, String hostB) {
    var a = hostA.trim().toLowerCase().replaceAll(RegExp(r'^\.+|\.+$'), '');
    var b = hostB.trim().toLowerCase().replaceAll(RegExp(r'^\.+|\.+$'), '');
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    if (_isIpLiteral(a) || _isIpLiteral(b)) return false;
    if (a.endsWith('.$b') || b.endsWith('.$a')) return true;
    return _registrableParent(a) == _registrableParent(b);
  }

  static String _registrableParent(String host) {
    final parts = host.split('.');
    if (parts.length <= 2) return host;
    const multiPartTlds = <String>{
      'co.uk', 'org.uk', 'ac.uk', 'gov.uk',
      'com.au', 'net.au', 'org.au',
      'co.jp', 'co.in', 'com.br', 'com.eg', 'com.sa', 'com.tr',
    };
    final lastTwo = '${parts[parts.length - 2]}.${parts.last}';
    if (multiPartTlds.contains(lastTwo) && parts.length >= 3) {
      return parts.sublist(parts.length - 3).join('.');
    }
    return lastTwo;
  }

  static bool _isIpLiteral(String host) {
    try {
      Uri.parseIPv4Address(host);
      return true;
    } catch (_) {}
    try {
      Uri.parseIPv6Address(host);
      return true;
    } catch (_) {}
    return host.contains(':');
  }

  static bool isPrivateOrLoopbackHost(String hostname) {
    var h = hostname.trim().toLowerCase();
    if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
    final zoneIdx = h.indexOf('%');
    if (zoneIdx > 0) h = h.substring(0, zoneIdx);
    if (h.isEmpty || h == 'localhost' || h.endsWith('.local') || h.endsWith('.internal')) {
      return true;
    }
    try {
      return _isPrivateIpv4Bytes(Uri.parseIPv4Address(h));
    } catch (_) {}
    try {
      final b = Uri.parseIPv6Address(h);
      var allZero = true;
      for (var i = 0; i < 15; i++) {
        if (b[i] != 0) allZero = false;
      }
      if (allZero && (b[15] == 0 || b[15] == 1)) return true;
      if ((b[0] & 0xfe) == 0xfc) return true;
      if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return true;
      if (b[0] == 0xff) return true;
      if (b.take(10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff) {
        return _isPrivateIpv4Bytes(b.sublist(12, 16));
      }
    } catch (_) {}
    return false;
  }

  static bool _isPrivateIpv4Bytes(List<int> b) {
    if (b.length != 4) return false;
    final a = b[0], c = b[1];
    return a == 0 ||
        a == 10 ||
        a == 127 ||
        a >= 224 ||
        (a == 100 && c >= 64 && c <= 127) ||
        (a == 169 && c == 254) ||
        (a == 172 && c >= 16 && c <= 31) ||
        (a == 192 && c == 168);
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
