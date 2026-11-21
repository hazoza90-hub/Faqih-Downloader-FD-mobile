import 'package:faqih_downloader_mobile/core/utils/size_formatter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('size_formatter', () {
    test('formatFileSize handles bytes through terabytes and negative input', () {
      expect(formatFileSize(-10), '0 B');
      expect(formatFileSize(0), '0 B');
      expect(formatFileSize(512), '512 B');
      expect(formatFileSize(1536), '1.5 KB');
      expect(formatFileSize(5 * 1024 * 1024), '5.0 MB');
      expect(formatFileSize(2 * 1024 * 1024 * 1024), '2.00 GB');
      expect(formatFileSize(1024 * 1024 * 1024 * 1024), '1.00 TB');
    });

    test('formatSpeed handles zero, unlimited flag, and units', () {
      expect(formatSpeed(0), '0 B/s');
      expect(formatSpeed(-5, allowUnlimited: true), 'Unlimited');
      expect(formatSpeed(500), '500 B/s');
      expect(formatSpeed(1024), '1.0 KB/s');
      expect(formatSpeed(2.5 * 1024 * 1024), '2.50 MB/s');
      expect(formatSpeed(1.5 * 1024 * 1024 * 1024), '1.50 GB/s');
    });

    test('formatDuration formats MM:SS and H:MM:SS cleanly', () {
      expect(formatDuration(-4), '00:00');
      expect(formatDuration(9), '00:09');
      expect(formatDuration(125), '02:05');
      expect(formatDuration(3661), '1:01:01');
    });

    test('formatEta formats seconds, minutes, hours, and invalid values', () {
      expect(formatEta(-1), '--');
      expect(formatEta(double.nan), '--');
      expect(formatEta(double.infinity), '--');
      expect(formatEta(42), '42s');
      expect(formatEta(125), '2m 5s');
      expect(formatEta(3660), '1h 1m');
      expect(formatEta(7200), '2h');
    });
  });
}
