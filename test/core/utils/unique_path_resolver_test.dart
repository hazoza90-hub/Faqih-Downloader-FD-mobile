import 'package:faqih_downloader_mobile/core/utils/unique_path_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('generateUniquePath', () {
    test('returns original path when unoccupied', () {
      final resolved = generateUniquePath(
        '/downloads/video.mp4',
        existsCheck: (_) => false,
      );
      expect(resolved, '/downloads/video.mp4');
    });

    test('increments sequentially across existing disk files', () {
      final existing = <String>{
        '/downloads/video.mp4',
        '/downloads/video (1).mp4',
        '/downloads/video (2).mp4',
      };

      final resolved = generateUniquePath(
        '/downloads/video.mp4',
        existsCheck: existing.contains,
      );
      expect(resolved, '/downloads/video (3).mp4');
    });

    test('continues numbering when desiredPath already ends with (N)', () {
      final existing = <String>{
        '/downloads/video (1).mp4',
        '/downloads/video (2).mp4',
      };

      final resolved = generateUniquePath(
        '/downloads/video (1).mp4',
        existsCheck: existing.contains,
      );
      expect(resolved, '/downloads/video (3).mp4');
    });

    test('respects reservedPaths and handles extensionless files', () {
      final resolved = generateUniquePath(
        '/downloads/archive',
        existsCheck: (_) => false,
        reservedPaths: <String>{'/downloads/archive'},
      );
      expect(resolved, '/downloads/archive (1)');
    });
  });
}
