import 'package:faqih_downloader_mobile/core/utils/url_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('url_detector', () {
    test('validates HTTP/HTTPS URLs cleanly', () {
      expect(isHttpUrl('https://example.com/file.zip'), isTrue);
      expect(isHttpUrl('http://localhost:8080/test.mp4'), isTrue);
      expect(isHttpUrl('ftp://example.com/file.zip'), isFalse);
      expect(isHttpUrl('not a url'), isFalse);
      expect(isHttpUrl('https://example.com/bad space.zip'), isFalse);
      expect(isHttpUrl(''), isFalse);
    });

    test('detects YouTube URLs and extracts 11-char IDs', () {
      const watchUrl = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s';
      const shortUrl = 'https://youtu.be/dQw4w9WgXcQ?si=abc';
      const shortsUrl = 'https://youtube.com/shorts/AbCdEf12345';
      const musicUrl = 'https://music.youtube.com/watch?v=XyZ_9876543';
      const liveUrl = 'https://www.youtube.com/live/LiveId12345';

      for (final u in <String>[
        watchUrl,
        shortUrl,
        shortsUrl,
        musicUrl,
        liveUrl,
      ]) {
        expect(isYouTubeUrl(u), isTrue, reason: u);
        expect(isMediaUrl(u), isTrue, reason: u);
        expect(extractMediaPlatform(u), 'YouTube', reason: u);
      }

      expect(extractYouTubeId(watchUrl), 'dQw4w9WgXcQ');
      expect(extractYouTubeId(shortUrl), 'dQw4w9WgXcQ');
      expect(extractYouTubeId(shortsUrl), 'AbCdEf12345');
      expect(extractYouTubeId('https://example.com/video.mp4'), isNull);
    });

    test('detects social media platforms and returns display names', () {
      const cases = <String, String>{
        'https://www.tiktok.com/@creator/video/7123456789012345678': 'TikTok',
        'https://vt.tiktok.com/ZSNabcdef/': 'TikTok',
        'https://www.instagram.com/reel/CxYz12345/': 'Instagram',
        'https://x.com/user/status/1800000000000000000': 'Twitter / X',
        'https://twitter.com/user/status/1800000000000000000': 'Twitter / X',
        'https://www.facebook.com/reel/1234567890': 'Facebook',
        'https://fb.watch/abcDEF123/': 'Facebook',
        'https://www.reddit.com/r/flutterdev/comments/1abcde/title/': 'Reddit',
        'https://vimeo.com/123456789': 'Vimeo',
      };

      for (final entry in cases.entries) {
        expect(isSocialMediaUrl(entry.key), isTrue, reason: entry.key);
        expect(isMediaUrl(entry.key), isTrue, reason: entry.key);
        expect(extractMediaPlatform(entry.key), entry.value, reason: entry.key);
      }

      expect(isMediaUrl('https://cdn.example.com/archive.zip'), isFalse);
      expect(extractMediaPlatform('https://cdn.example.com/archive.zip'), isNull);
    });
  });
}
