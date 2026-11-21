import 'package:faqih_downloader_mobile/core/utils/category_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyCategory', () {
    test('classifies all supported desktop categories accurately', () {
      expect(classifyCategory('movie.mp4'), 'Video');
      expect(classifyCategory('clip.MKV?token=123'), 'Video');
      expect(classifyCategory('podcast.mp3'), 'Audio');
      expect(classifyCategory('track.m4a#t=10'), 'Audio');
      expect(classifyCategory('archive.zip'), 'Compressed');
      expect(classifyCategory('backup.tar.gz'), 'Compressed');
      expect(classifyCategory('paper.pdf'), 'Documents');
      expect(classifyCategory('notes.docx'), 'Documents');
      expect(classifyCategory('app-release.apk'), 'Programs');
      expect(classifyCategory('installer.exe'), 'Programs');
      expect(classifyCategory('photo.png'), 'Images');
      expect(classifyCategory('avatar.JPEG'), 'Images');
    });

    test('falls back to Other for unknown or .bin files', () {
      expect(classifyCategory('download.bin'), 'Other');
      expect(classifyCategory('README'), 'Other');
      expect(classifyCategory(''), 'Other');
      expect(classifyCategory('data.unknownext'), 'Other');
    });
  });
}
