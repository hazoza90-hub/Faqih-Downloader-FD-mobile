import 'package:faqih_downloader_mobile/engine/token_bucket_rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TokenBucketRateLimiter', () {
    test('passes immediately when speed is unlimited (<= 0)', () async {
      final limiter = TokenBucketRateLimiter(bytesPerSec: 0);
      final sw = Stopwatch()..start();
      await limiter.consume(5 * 1024 * 1024);
      expect(sw.elapsedMilliseconds, lessThan(100));
    });

    test('throttles byte consumption according to configured limit', () async {
      // 128 KB/s consuming 96 KB from an empty bucket should take ~750ms.
      final limiter = TokenBucketRateLimiter(bytesPerSec: 128 * 1024);
      final sw = Stopwatch()..start();

      for (var i = 0; i < 3; i++) {
        await limiter.consume(32 * 1024);
      }

      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(550));
    });

    test('dynamic setLimit(0) removes throttling immediately', () async {
      final limiter = TokenBucketRateLimiter(bytesPerSec: 1024);
      Future<void>.delayed(const Duration(milliseconds: 60), () {
        limiter.setLimit(0);
      });

      final sw = Stopwatch()..start();
      await limiter.consume(256 * 1024);
      expect(sw.elapsedMilliseconds, lessThan(400));
    });

    test('aborts waiting immediately when shouldAbort returns true', () async {
      final limiter = TokenBucketRateLimiter(bytesPerSec: 512);
      var abort = false;
      Future<void>.delayed(const Duration(milliseconds: 40), () {
        abort = true;
      });

      final sw = Stopwatch()..start();
      await limiter.consume(100 * 1024, shouldAbort: () => abort);
      expect(sw.elapsedMilliseconds, lessThan(300));
    });
  });
}
