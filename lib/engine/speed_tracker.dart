import 'dart:collection';
import 'dart:math' as math;

class _ByteSample {
  const _ByteSample(this.timestampMs, this.bytes);

  final int timestampMs;
  final int bytes;
}

/// Sliding-window EMA speed tracker excluding paused time from elapsed duration.
class SpeedTracker {
  SpeedTracker({
    this.windowMs = 2500,
    int Function()? clockMs,
  })  : _clockMs = clockMs,
        _stopwatch = clockMs == null ? (Stopwatch()..start()) : null;

  final int windowMs;
  final int Function()? _clockMs;
  final Stopwatch? _stopwatch;
  final Queue<_ByteSample> _samples = Queue<_ByteSample>();

  static const double _emaAlpha = 0.35;

  int _accumulatedActiveMs = 0;
  int? _activeStartMs;
  double _emaSpeed = 0.0;

  bool get isRunning => _activeStartMs != null;

  int get _nowMs => _clockMs?.call() ?? _stopwatch!.elapsedMilliseconds;

  double get elapsedActiveSeconds {
    final activeSegment = _activeStartMs != null
        ? math.max(0, _nowMs - _activeStartMs!)
        : 0;
    return (_accumulatedActiveMs + activeSegment) / 1000.0;
  }

  void start({double initialElapsedSeconds = 0.0}) {
    _accumulatedActiveMs = initialElapsedSeconds > 0
        ? (initialElapsedSeconds * 1000.0).round()
        : 0;
    _activeStartMs = _nowMs;
    _samples.clear();
    _emaSpeed = 0.0;
  }

  void pause() {
    if (_activeStartMs != null) {
      _accumulatedActiveMs += math.max(0, _nowMs - _activeStartMs!);
      _activeStartMs = null;
    }
    _samples.clear();
    _emaSpeed = 0.0;
  }

  void resume() {
    if (_activeStartMs == null) {
      _activeStartMs = _nowMs;
      _samples.clear();
      _emaSpeed = 0.0;
    }
  }

  void reset() {
    _accumulatedActiveMs = 0;
    _activeStartMs = null;
    _samples.clear();
    _emaSpeed = 0.0;
  }

  void recordBytes(int deltaBytes) {
    if (deltaBytes <= 0 || _activeStartMs == null) {
      return;
    }

    final now = _nowMs;
    _samples.addLast(_ByteSample(now, deltaBytes));
    _pruneOldSamples(now);

    final windowStart = math.max(now - windowMs, _activeStartMs!);
    final spanMs = math.max(now - windowStart, 100);
    var windowBytes = 0;
    for (final sample in _samples) {
      windowBytes += sample.bytes;
    }

    final instantSpeed = (windowBytes * 1000.0) / spanMs;
    if (_emaSpeed <= 0.0) {
      _emaSpeed = instantSpeed;
    } else {
      _emaSpeed = (_emaAlpha * instantSpeed) + ((1.0 - _emaAlpha) * _emaSpeed);
    }
  }

  double currentSpeedBytesPerSec() {
    if (_activeStartMs == null) {
      return 0.0;
    }
    final now = _nowMs;
    _pruneOldSamples(now);
    if (_samples.isEmpty) {
      _emaSpeed = 0.0;
      return 0.0;
    }
    return _emaSpeed;
  }

  double estimateEtaSeconds({required int remainingBytes}) {
    if (remainingBytes <= 0) {
      return 0.0;
    }
    final speed = currentSpeedBytesPerSec();
    if (speed <= 0.0) {
      return -1.0;
    }
    return remainingBytes / speed;
  }

  void _pruneOldSamples(int nowMs) {
    final cutoff = nowMs - windowMs;
    while (_samples.isNotEmpty && _samples.first.timestampMs < cutoff) {
      _samples.removeFirst();
    }
  }
}
