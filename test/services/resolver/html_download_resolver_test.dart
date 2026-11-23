import 'dart:io';

import 'package:faqih_downloader_mobile/services/resolver/html_download_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HtmlDownloadResolver', () {
    test('resolves indirect HTML landing page to real APK download link', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final base = 'http://127.0.0.1:${server.port}';
      String? seenReferer;

      server.listen((req) async {
        if (req.uri.path == '/landing') {
          req.response.headers.contentType = ContentType.html;
          req.response.write('''
            <html><body>
              <link rel="stylesheet" href="/style.css">
              <a href="/files/app-release.apk" download>Download APK</a>
            </body></html>
          ''');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/files/app-release.apk') {
          seenReferer = req.headers.value('referer');
          req.response.headers.contentType =
              ContentType.parse('application/vnd.android.package-archive');
          req.response.headers.set('Content-Length', '128');
          req.response.add(List<int>.filled(128, 7));
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });

      final res = await HtmlDownloadResolver().resolve('$base/landing');
      expect(res.isHtmlLanding, isFalse);
      expect(res.resolvedFromHtml, isTrue);
      expect(res.url, '$base/files/app-release.apk');
      expect(res.filename, 'app-release.apk');
      expect(res.contentType, 'application/vnd.android.package-archive');
      expect(seenReferer, '$base/landing');
    });

    test('extracts real filename from Content-Disposition header', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final base = 'http://127.0.0.1:${server.port}';

      server.listen((req) async {
        req.response.headers.contentType =
            ContentType.parse('application/vnd.android.package-archive');
        req.response.headers.set(
          'Content-Disposition',
          'attachment; filename="FaqihApp_v3.apk"',
        );
        req.response.headers.set('Content-Length', '64');
        req.response.add(List<int>.filled(64, 1));
        await req.response.close();
      });

      final res = await HtmlDownloadResolver().resolve('$base/dl?id=42');
      expect(res.isHtmlLanding, isFalse);
      expect(res.fromContentDisposition, isTrue);
      expect(res.filename, 'FaqihApp_v3.apk');
    });

    test('extracts JS redirect target from HTML landing page', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final base = 'http://127.0.0.1:${server.port}';

      server.listen((req) async {
        if (req.uri.path == '/js-gate') {
          req.response.headers.contentType = ContentType.html;
          req.response.write(
            '<html><script>window.location.href = "/bin/package_2.zip";</script></html>',
          );
          await req.response.close();
          return;
        }
        req.response.headers.contentType = ContentType.parse('application/zip');
        req.response.headers.set('Content-Length', '16');
        req.response.add(List<int>.filled(16, 2));
        await req.response.close();
      });

      final res = await HtmlDownloadResolver().resolve('$base/js-gate');
      expect(res.isHtmlLanding, isFalse);
      expect(res.resolvedFromHtml, isTrue);
      expect(res.filename, 'package_2.zip');
    });

    test('SSRF guard blocks private/loopback hosts for public URLs', () {
      for (final priv in <String>[
        'localhost',
        '127.0.0.1',
        '10.0.0.1',
        '172.16.5.1',
        '192.168.1.20',
        '169.254.169.254',
        '::1',
        '[::1]',
        'router.local',
      ]) {
        expect(
          HtmlDownloadResolver.isPrivateOrLoopbackHost(priv),
          isTrue,
          reason: '$priv should be detected as private',
        );
      }

      for (final pub in <String>['example.com', '8.8.8.8', '172.32.0.1']) {
        expect(
          HtmlDownloadResolver.isPrivateOrLoopbackHost(pub),
          isFalse,
          reason: '$pub should be public',
        );
      }

      final filtered = HtmlDownloadResolver.extractCandidates(
        '<a href="http://127.0.0.1/secret.apk" download>Local</a>'
        '<a href="https://cdn.example.com/public.apk" download>Public</a>',
        Uri.parse('https://example.org/app'),
        srcIsPublic: true,
      );
      expect(filtered, <String>['https://cdn.example.com/public.apk']);
    });
  });
}
