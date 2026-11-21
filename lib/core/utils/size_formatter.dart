/// Human-readable formatting for file sizes, transfer speeds, durations, and ETA.
String formatFileSize(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  const kb = 1024.0;
  const mb = kb * 1024.0;
  const gb = mb * 1024.0;
  const tb = gb * 1024.0;

  if (bytes < kb) {
    return '$bytes B';
  }
  if (bytes < mb) {
    return '${(bytes / kb).toStringAsFixed(1)} KB';
  }
  if (bytes < gb) {
    return '${(bytes / mb).toStringAsFixed(1)} MB';
  }
  if (bytes < tb) {
    return '${(bytes / gb).toStringAsFixed(2)} GB';
  }
  return '${(bytes / tb).toStringAsFixed(2)} TB';
}

String formatSpeed(double bytesPerSec, {bool allowUnlimited = false}) {
  if (bytesPerSec.isNaN || bytesPerSec.isInfinite || bytesPerSec <= 0) {
    return allowUnlimited ? 'Unlimited' : '0 B/s';
  }
  const kb = 1024.0;
  const mb = kb * 1024.0;
  const gb = mb * 1024.0;

  if (bytesPerSec >= gb) {
    return '${(bytesPerSec / gb).toStringAsFixed(2)} GB/s';
  }
  if (bytesPerSec >= mb) {
    return '${(bytesPerSec / mb).toStringAsFixed(2)} MB/s';
  }
  if (bytesPerSec >= kb) {
    return '${(bytesPerSec / kb).toStringAsFixed(1)} KB/s';
  }
  return '${bytesPerSec.toStringAsFixed(0)} B/s';
}

String formatDuration(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final hours = safe ~/ 3600;
  final minutes = (safe % 3600) ~/ 60;
  final secs = safe % 60;

  final mm = minutes.toString().padLeft(2, '0');
  final ss = secs.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$mm:$ss';
  }
  return '$mm:$ss';
}

String formatEta(double seconds) {
  if (seconds.isNaN || seconds.isInfinite || seconds < 0) {
    return '--';
  }
  final totalSeconds = seconds.round();
  if (totalSeconds < 60) {
    return '${totalSeconds}s';
  }
  if (totalSeconds < 3600) {
    final minutes = totalSeconds ~/ 60;
    final remSeconds = totalSeconds % 60;
    return remSeconds > 0 ? '${minutes}m ${remSeconds}s' : '${minutes}m';
  }
  final hours = totalSeconds ~/ 3600;
  final remMinutes = (totalSeconds % 3600) ~/ 60;
  return remMinutes > 0 ? '${hours}h ${remMinutes}m' : '${hours}h';
}
