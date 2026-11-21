import 'package:faqih_downloader_mobile/core/utils/filename_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeFilename', () {
    test('strips illegal filesystem and control characters', () {
      expect(
        sanitizeFilename('My<Video>: "Test"/\\|?*\x00\x1F.mp4  ..'),
        'MyVideo Test.mp4',
      );
    });

    test('preserves Arabic and Unicode characters cleanly', () {
      expect(
        sanitizeFilename('  شرح تطبيق فقيه التنزيلات: الدرس الأول?.mp4 '),
        'شرح تطبيق فقيه التنزيلات الدرس الأول.mp4',
      );
      expect(
        sanitizeFilename('درس البرمجة في فلاتر.mp4'),
        'درس البرمجة في فلاتر.mp4',
      );
    });

    test('protects against Windows reserved names', () {
      expect(sanitizeFilename('CON.txt'), '_CON.txt');
      expect(sanitizeFilename('nul'), '_nul');
      expect(sanitizeFilename('COM1.mp4'), '_COM1.mp4');
    });

    test('applies Clip, Sub, and Dub tags without duplication', () {
      expect(
        sanitizeFilename(
          'Lecture.mp4',
          isClip: true,
          hasSub: true,
          hasDub: true,
        ),
        'Lecture [Clip] [Sub] [Dub].mp4',
      );
      expect(
        sanitizeFilename(
          'Lecture [Clip].mp4',
          isClip: true,
          hasSub: true,
        ),
        'Lecture [Clip] [Sub].mp4',
      );
    });

    test('enforces safe maxLength while keeping tags and extension', () {
      final longName = '${'A' * 220}.mp4';
      final result = sanitizeFilename(longName, maxLength: 64, isClip: true);

      expect(result.length, lessThanOrEqualTo(64));
      expect(result.endsWith(' [Clip].mp4'), isTrue);
    });

    test('uses fallback when cleaned filename is empty', () {
      expect(sanitizeFilename('   ...///:::   '), 'download');
      expect(sanitizeFilename('???.mp4'), 'download.mp4');
    });
  });
}
