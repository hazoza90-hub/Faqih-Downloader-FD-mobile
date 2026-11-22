/// Progress parsed from native FFmpeg stderr output lines.
class FfmpegProgressUpdate {
  const FfmpegProgressUpdate({
    required this.ratio,
    required this.currentSeconds,
    required this.totalSeconds,
    required this.speedFactor,
  });

  final double ratio;
  final double currentSeconds;
  final double totalSeconds;
  final double speedFactor;
}

/// Incremental stateful parser for FFmpeg `Duration:`, `time=`, and `speed=` lines.
class FfmpegProgressParser {
  FfmpegProgressParser({double? knownDurationSeconds})
      : _totalSeconds = knownDurationSeconds ?? 0.0;

  static final RegExp _durationRegex = RegExp(
    r'Duration:\s*(\d{1,3}):(\d{2}):(\d{2}(?:\.\d+)?)',
  );
  static final RegExp _timeRegex = RegExp(
    r'time=(\d{1,3}):(\d{2}):(\d{2}(?:\.\d+)?)',
  );
  static final RegExp _speedRegex = RegExp(r'speed=\s*([\d.]+)x');

  double _totalSeconds;
  double _lastSpeedFactor = 0.0;

  double get totalSeconds => _totalSeconds;
  double get lastSpeedFactor => _lastSpeedFactor;

  FfmpegProgressUpdate? parseLine(String line) {
    final durMatch = _durationRegex.firstMatch(line);
    if (durMatch != null && _totalSeconds <= 0.0) {
      _totalSeconds = _hmsToSeconds(
        durMatch.group(1)!,
        durMatch.group(2)!,
        durMatch.group(3)!,
      );
    }

    final speedMatch = _speedRegex.firstMatch(line);
    if (speedMatch != null) {
      _lastSpeedFactor = double.tryParse(speedMatch.group(1)!) ?? _lastSpeedFactor;
    }

    final timeMatch = _timeRegex.firstMatch(line);
    if (timeMatch == null) {
      return null;
    }

    final current = _hmsToSeconds(
      timeMatch.group(1)!,
      timeMatch.group(2)!,
      timeMatch.group(3)!,
    );
    final ratio = _totalSeconds > 0.0
        ? (current / _totalSeconds).clamp(0.0, 1.0)
        : 0.0;

    return FfmpegProgressUpdate(
      ratio: ratio,
      currentSeconds: current,
      totalSeconds: _totalSeconds,
      speedFactor: _lastSpeedFactor,
    );
  }

  static double _hmsToSeconds(String h, String m, String s) {
    final hours = int.tryParse(h) ?? 0;
    final mins = int.tryParse(m) ?? 0;
    final secs = double.tryParse(s) ?? 0.0;
    return hours * 3600.0 + mins * 60.0 + secs;
  }
}
