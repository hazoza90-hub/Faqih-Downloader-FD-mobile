import 'package:faqih_downloader_mobile/engine/server_prober.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_range_server.dart';

void main() {
  late MockRangeServer server;
  final payload = generateTestPayload(64 * 1024);

  setUp(() async {
    server = await MockRangeServer.start(payload);
  });

  tearDown(() async {
    await server.close();
  });

  group('ServerProber', () {
    test('probes capabilities cleanly via HEAD when supported', () async {
      server.contentDisposition = 'attachment; filename="installer_v2.zip"';
      final result = await ServerProber().probe(server.fileUrl('/download'));

      expect(result.totalSize, payload.length);
      expect(result.supportsRanges, isTrue);
      expect(result.filename, 'installer_v2.zip');
      expect(result.linkExpired, isFalse);
      expect(server.headCount, 1);
      expect(server.rangeGetCount, 0);
    });

    test('falls back to GET Range 0-0 when HEAD returns 405', () async {
      server.rejectHeadWith405 = true;
      final result = await ServerProber().probe(server.fileUrl('/video.mp4'));

      expect(result.totalSize, payload.length);
      expect(result.supportsRanges, isTrue);
      expect(result.filename, 'video.mp4');
      expect(server.headCount, 1);
      expect(server.rangeGetCount, 1);
    });

    test('decodes RFC 5987 UTF-8 Arabic filename from Content-Disposition', () async {
      server.contentDisposition =
          "attachment; filename=\"fallback.mp4\"; filename*=UTF-8''%D9%81%D9%82%D9%8A%D9%87%20%D9%81%D9%8A%D8%AF%D9%8A%D9%88.mp4";
      final result = await ServerProber().probe(server.fileUrl('/dl'));

      expect(result.filename, 'فقيه فيديو.mp4');
    });

    test('extracts clen rapidly for googlevideo.com URLs without network call', () async {
      final result = await ServerProber().probe(
        'https://rr1---sn.googlevideo.com/videoplayback?clen=12345678&mime=video/mp4',
      );

      expect(result.totalSize, 12345678);
      expect(result.supportsRanges, isTrue);
      expect(result.httpStatus, 200);
    });

    test('rejects HTML landing pages when destination has no binary extension', () async {
      server.serveHtml = true;

      await expectLater(
        ServerProber().probe(
          server.fileUrl('/page'),
          destinationPath: '/downloads/download.bin',
        ),
        throwsA(
          isA<ProbeException>().having((e) => e.isHtmlResponse, 'isHtml', isTrue),
        ),
      );
    });

    test('flags HTTP 403/401/410 as expired links', () async {
      server.rejectHeadWith405 = true;
      server.forceErrorStatus = 403;

      final result = await ServerProber().probe(server.fileUrl('/expired.zip'));
      expect(result.linkExpired, isTrue);
      expect(result.httpStatus, 403);
    });

    test('tracks finalUrl across HTTP redirects', () async {
      server.redirectPath = '/real/archive.7z';
      final result = await ServerProber().probe(server.fileUrl('/short-link'));

      expect(result.finalUrl, endsWith('/real/archive.7z'));
      expect(result.filename, 'archive.7z');
    });

    test('returns supportsRanges false when Range 0-0 gets 200 OK despite Accept-Ranges header', () async {
      server.rejectHeadWith405 = true;
      server.supportRanges = false;
      server.fakeAcceptRangesHeader = true;

      final result = await ServerProber().probe(server.fileUrl('/deceptive.zip'));

      expect(result.httpStatus, 200);
      expect(result.totalSize, payload.length);
      expect(result.supportsRanges, isFalse);
    });
  });
}
