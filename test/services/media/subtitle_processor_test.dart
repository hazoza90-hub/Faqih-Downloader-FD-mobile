import 'dart:io';

import 'package:faqih_downloader_mobile/core/models/subtitle_track.dart';
import 'package:faqih_downloader_mobile/services/media/subtitle_font_provisioner.dart';
import 'package:faqih_downloader_mobile/services/media/subtitle_processor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SubtitleProcessor', () {
    test('converts VTT to clean SRT and removes YouTube rolling caption duplicates', () {
      const sampleVtt = '''
WEBVTT
Kind: captions
Language: ar

NOTE intro comment

00:01.200 --> 00:03.500 align:start position:0%
<c>السلام عليكم</c>

00:03.500 --> 00:06.000
السلام عليكم
مرحبا بكم في <i>فقيه التنزيلات</i>

00:06.000 --> 00:08.000
مرحبا بكم في فقيه التنزيلات

00:08.000 --> 00:10.000
مرحبا بكم في فقيه التنزيلات
''';

      final srt = SubtitleProcessor.convertVttToSrt(sampleVtt);

      expect(srt, contains('00:00:01,200 --> 00:00:03,500'));
      expect(srt, contains('السلام عليكم'));
      expect(srt, contains('00:00:03,500 --> 00:00:10,000'));
      expect(srt, contains('مرحبا بكم في فقيه التنزيلات'));
      expect(srt.contains('WEBVTT'), isFalse);
      expect(srt.contains('<c>'), isFalse);
      expect(srt.contains('<i>'), isFalse);
      // Duplicate second "السلام عليكم" rolling top line and duplicate follow-up cues removed:
      expect(RegExp('السلام عليكم').allMatches(srt).length, 1);
      expect(RegExp('مرحبا بكم في فقيه التنزيلات').allMatches(srt).length, 1);
    });

    test('normalizes Arabic RTL dialogue lines while leaving timestamps untouched', () {
      const rawSrt = '1\n00:00:01,000 --> 00:00:04,000\nتجربة النص العربي\n';
      final rtl = SubtitleProcessor.normalizeForArabicRtl(rawSrt);

      expect(rtl, contains('\u202Bتجربة النص العربي\u202C'));
      expect(rtl, contains('1\n00:00:01,000 --> 00:00:04,000'));
    });

    test('shiftAndClipSrt filters out-of-range cues, clamps boundaries, and shifts to 00:00:...', () {
      const rawSrt = '''
1
00:00:10,000 --> 00:00:25,000
Before clip window

2
00:00:28,000 --> 00:00:35,000
Overlaps start boundary

3
00:00:45,500 --> 00:01:05,000
Overlaps end boundary

4
00:01:10,000 --> 00:01:15,000
After clip window
''';

      final clipped = SubtitleProcessor.shiftAndClipSrt(
        rawSrt,
        30.0,
        endSec: 60.0,
      );

      expect(clipped.contains('Before clip window'), isFalse);
      expect(clipped.contains('After clip window'), isFalse);
      expect(clipped, contains('1\n00:00:00,000 --> 00:00:05,000\nOverlaps start boundary'));
      expect(clipped, contains('2\n00:00:15,500 --> 00:00:30,000\nOverlaps end boundary'));
    });

    test('escapes backslash, colon, quotes, and brackets for FFmpeg filters', () {
      const path = r"C:\work\dir[1]\sub's:ar.srt";
      final escaped = SubtitleProcessor.escapeForFfmpegFilter(path);

      expect(escaped, r"C\:\\work\\dir\[1\]\\sub\'s\:ar.srt");
    });

    test('downloads VTT over HTTP with headers and writes RTL UTF-8 SRT file', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? capturedAuth;
      server.listen((req) async {
        capturedAuth = req.headers.value('x-custom-auth');
        req.response.headers.contentType = ContentType('text', 'vtt', charset: 'utf-8');
        req.response.write('WEBVTT\n\n00:00:00.500 --> 00:00:02.000\nأهلاً بكم\n');
        await req.response.close();
      });

      final tempDir = await Directory.systemTemp.createTemp('fd_sub_test_');
      try {
        final outSrt = p.join(tempDir.path, 'sub.srt');
        final processor = SubtitleProcessor(
          httpClientFactory: () => HttpOverrides.runWithHttpOverrides(
            HttpClient.new,
            _RealHttpOverrides(),
          ),
        );
        final path = await processor.downloadAndNormalize(
          SubtitleTrack(
            subId: 'sub_ar',
            language: 'ar',
            label: 'Arabic',
            url: 'http://127.0.0.1:${server.port}/sub.vtt',
            ext: 'vtt',
          ),
          outSrt,
          headers: const <String, String>{'x-custom-auth': 'token-xyz'},
          prepareForArabicHardBurn: true,
        );

        expect(path, outSrt);
        expect(capturedAuth, 'token-xyz');
        final content = await File(outSrt).readAsString();
        expect(content, contains('\u202Bأهلاً بكم\u202C'));
      } finally {
        await server.close(force: true);
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      }
    });

    test('bundled arabic_subtitle_font.ttf is valid TTF and SubtitleFontProvisioner copies it', () async {
      final fontFile = File('assets/fonts/arabic_subtitle_font.ttf');
      expect(fontFile.existsSync(), isTrue);
      final bytes = await fontFile.readAsBytes();
      expect(bytes.length, greaterThan(100000));
      // TrueType SFNT version 00 01 00 00
      expect(bytes.sublist(0, 4), <int>[0x00, 0x01, 0x00, 0x00]);

      final tempDir = await Directory.systemTemp.createTemp('fd_font_prov_');
      try {
        final provisioner = SubtitleFontProvisioner(bundle: rootBundle);
        final fontsDir = await provisioner.ensureFontsDir(tempDir.path);
        final copied = File(p.join(fontsDir, SubtitleFontProvisioner.outputFileName));
        expect(copied.existsSync(), isTrue);
        expect(copied.lengthSync(), bytes.length);
      } finally {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      }
    });

    test('downloadAndNormalize handles local und Arabic subtitle with malformed UTF-8 bytes', () async {
      final tempDir = await Directory.systemTemp.createTemp('fd_ext_sub_');
      try {
        final rawPath = p.join(tempDir.path, 'custom.srt');
        final outPath = p.join(tempDir.path, 'normalized.srt');
        final arabicBytes = '1\n00:00:01,000 --> 00:00:03,000\nمرحبا بالعالم\n'.codeUnits;
        final validUtf8Arabic = await File(rawPath).writeAsString(
          String.fromCharCodes(arabicBytes),
          flush: true,
        );
        final existing = validUtf8Arabic.readAsBytesSync();
        await File(rawPath).writeAsBytes(<int>[...existing, 0xFF, 0xFE], flush: true);

        final processor = SubtitleProcessor();
        await processor.downloadAndNormalize(
          SubtitleTrack(
            subId: 'ext_1',
            language: 'und',
            label: 'custom.srt',
            url: rawPath,
            localPath: rawPath,
            isExternal: true,
          ),
          outPath,
        );
        final result = await File(outPath).readAsString();
        expect(result, contains('\u202Bمرحبا بالعالم\u202C'));
      } finally {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      }
    });
  });
}

class _RealHttpOverrides extends HttpOverrides {}
