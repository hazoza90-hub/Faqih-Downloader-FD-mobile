import 'dart:io';

import 'package:faqih_downloader_mobile/core/models/video_format_option.dart';
import 'package:faqih_downloader_mobile/core/models/youtube_stream_info.dart';
import 'package:faqih_downloader_mobile/services/media/media_extractor_service.dart';
import 'package:faqih_downloader_mobile/services/resolver/html_candidate_parser.dart';
import 'package:faqih_downloader_mobile/services/resolver/html_download_resolver.dart';
import 'package:faqih_downloader_mobile/services/resolver/smart_url_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeMediaExtractor extends MediaExtractorService {
  int extractCalls = 0;

  @override
  Future<YouTubeStreamInfo> extractInfo(
    String url, {
    String? cookiesFile,
    String? userAgent,
    Map<String, String>? headers,
    String? playlistItems,
    String? processId,
    int timeoutSeconds = 30,
  }) async {
    extractCalls++;
    return const YouTubeStreamInfo(
      videoId: 'vid_403',
      title: 'Fallback Video',
      cleanFilename: 'Fallback Video.mp4',
      isProgressive: true,
      videoUrl: 'https://cdn.example.com/fallback.mp4',
      videoFormats: <VideoFormatOption>[
        VideoFormatOption(
          formatId: '22',
          resolutionLabel: '720p',
          height: 720,
          ext: 'mp4',
          isProgressive: true,
          videoUrl: 'https://cdn.example.com/fallback.mp4',
        ),
      ],
    );
  }
}

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

    test('rejects non-2xx JSON 403 response and allows SmartUrlAnalyzer yt-dlp fallback', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final url = 'http://127.0.0.1:${server.port}/watch/protected';

      server.listen((req) async {
        req.response.statusCode = HttpStatus.forbidden;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"error":"forbidden"}');
        await req.response.close();
      });

      await expectLater(
        HtmlDownloadResolver().resolve(url),
        throwsA(isA<HttpException>()),
      );

      final fakeExtractor = _FakeMediaExtractor();
      final analyzer = SmartUrlAnalyzer(
        extractor: fakeExtractor,
        htmlResolver: HtmlDownloadResolver(),
      );
      final analysis = await analyzer.analyze(url, processId: 'p_403');
      expect(fakeExtractor.extractCalls, 1);
      expect(analysis.isMedia, isTrue);
      expect(analysis.mediaInfo?.videoId, 'vid_403');
    });

    test('preserves and forwards Set-Cookie across redirects and HTML-to-APK requests', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final base = 'http://127.0.0.1:${server.port}';
      String? seenApkCookie;

      server.listen((req) async {
        if (req.uri.path == '/start') {
          req.response.statusCode = HttpStatus.movedTemporarily;
          req.response.cookies.add(Cookie('sid', 'step1'));
          req.response.headers.set(HttpHeaders.locationHeader, '/gate');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/gate') {
          final cookie = req.headers.value(HttpHeaders.cookieHeader) ?? '';
          if (!cookie.contains('sid=step1')) {
            req.response.statusCode = HttpStatus.forbidden;
            await req.response.close();
            return;
          }
          req.response.cookies.add(Cookie('tok', 'step2'));
          req.response.headers.contentType = ContentType.html;
          req.response.write('<html><body><a href="/secure.apk" download>APK</a></body></html>');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/secure.apk') {
          final cookie = req.headers.value(HttpHeaders.cookieHeader) ?? '';
          if (!cookie.contains('sid=step1') || !cookie.contains('tok=step2')) {
            req.response.statusCode = HttpStatus.forbidden;
            await req.response.close();
            return;
          }
          seenApkCookie = cookie;
          req.response.headers.contentType =
              ContentType.parse('application/vnd.android.package-archive');
          req.response.headers.set('Content-Length', '32');
          req.response.add(List<int>.filled(32, 3));
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });

      final res = await HtmlDownloadResolver().resolve('$base/start');
      expect(res.isHtmlLanding, isFalse);
      expect(res.resolvedFromHtml, isTrue);
      expect(res.url, '$base/secure.apk');
      expect(res.filename, 'secure.apk');
      expect(seenApkCookie, contains('sid=step1'));
      expect(seenApkCookie, contains('tok=step2'));
      expect(res.headers[HttpHeaders.cookieHeader], contains('sid=step1'));
      expect(res.headers[HttpHeaders.cookieHeader], contains('tok=step2'));
    });

    test('HtmlCandidateParser ignores malformed href URLs without crashing APK extraction', () {
      final candidates = HtmlCandidateParser.extractCandidates(
        '<a href="http://bad%ZZ[url" download>Broken</a>'
        '<a href="/files/valid.apk" download>Valid APK</a>',
        Uri.parse('https://example.org/app'),
      );
      expect(candidates, <String>['https://example.org/files/valid.apk']);
    });
  });
}
