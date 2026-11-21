import 'dart:math' as math;

/// Async token bucket bandwidth limiter shared across active chunk workers.
class TokenBucketRateLimiter {
  TokenBucketRateLimiter({double bytesPerSec = 0.0}) {
    _stopwatch.start();
    setLimit(bytesPerSec);
  }

  final Stopwatch _stopwatch = Stopwatch();

  double _rateLimit = 0.0;
  double _capacity = 0.0;
  double _tokens = 0.0;
  int _lastElapsedUs = 0;

  double get limitBytesPerSec => _rateLimit;

  /// Dynamically updates bandwidth limit (`<= 0` disables throttling).
  void setLimit(double bytesPerSec) {
    _lastElapsedUs = _stopwatch.elapsedMicroseconds;
    if (bytesPerSec.isNaN || bytesPerSec <= 0) {
      _rateLimit = 0.0;
      _capacity = 0.0;
      _tokens = 0.0;
      return;
    }

    _rateLimit = bytesPerSec;
    _capacity = math.max(_rateLimit * 0.5, 65536.0);
    _tokens = math.min(_tokens, _capacity);
  }

  /// Consumes [bytes] tokens, awaiting smoothly without busy-waiting if needed.
  Future<void> consume(
    int bytes, {
    bool Function()? shouldAbort,
  }) async {
    if (bytes <= 0 || _rateLimit <= 0) {
      return;
    }

    while (true) {
      if (shouldAbort != null && shouldAbort()) {
        return;
      }
      if (_rateLimit <= 0) {
        return;
      }

      if (bytes > _capacity) {
        _capacity = bytes * 2.0;
      }

      _refillTokens();

      if (_tokens >= bytes) {
        _tokens -= bytes;
        return;
      }

      final needed = bytes - _tokens;
      final waitMs = ((needed / _rateLimit) * 1000.0).ceil().clamp(1, 50);
      await Future<void>.delayed(Duration(milliseconds: waitMs));
    }
  }

  void _refillTokens() {
    final nowUs = _stopwatch.elapsedMicroseconds;
    final elapsedSec = (nowUs - _lastElapsedUs) / 1000000.0;
    _lastElapsedUs = nowUs;
    if (elapsedSec > 0) {
      _tokens = math.min(_capacity, _tokens + elapsedSec * _rateLimit);
    }
  }
}
