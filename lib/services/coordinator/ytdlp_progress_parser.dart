import '../../core/models/video_format_option.dart';

/// Parsed sample from a single `yt-dlp` progress output line.
class YtDlpProgressSample {
  const YtDlpProgressSample({
    required this.progress,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.speedBytesPerSec,
    required this.etaSeconds,
    this.isTotalApproximate = false,
  });

  final double progress;
  final int downloadedBytes;
  final int totalBytes;
  final double speedBytesPerSec;
  final double etaSeconds;
  final bool isTotalApproximate;
}

/// Regex and line parsers for `yt-dlp` progress, merge containers, and stderr errors.
abstract final class YtDlpProgressParser {
  static final RegExp pctRegex = RegExp(r'(\d+(?:\.\d+)?)%');
  static final RegExp totalRegex = RegExp(
    r'\bof\s+(~)?\s*([\d.]+)\s*(GiB|MiB|KiB|GB|MB|KB|B)\b',
    caseSensitive: false,
  );
  static final RegExp unknownDlRegex = RegExp(
    r'\[download\]\s+([\d.]+)\s*(GiB|MiB|KiB|GB|MB|KB|B)\s+at\b',
    caseSensitive: false,
  );
  static final RegExp speedRegex = RegExp(
    r'\bat\s+([\d.]+)\s*(GiB|MiB|KiB|GB|MB|KB|B)/s',
    caseSensitive: false,
  );
  static final RegExp _etaRegex = RegExp(r'\bETA\s+(?:(\d+):)?(\d+):(\d+)');

  static double parseByteUnit(String numStr, String unit) {
    final val = double.tryParse(numStr) ?? 0.0;
    switch (unit.toLowerCase()) {
      case 'gib':
        return val * 1024 * 1024 * 1024;
      case 'mib':
        return val * 1024 * 1024;
      case 'kib':
        return val * 1024;
      case 'gb':
        return val * 1000 * 1000 * 1000;
      case 'mb':
        return val * 1000 * 1000;
      case 'kb':
        return val * 1000;
      default:
        return val;
    }
  }

  static YtDlpProgressSample parseProgressLine(
    String line, {
    double fallbackRatio = 0.0,
    double fallbackEta = -1.0,
    int lastTotalBytes = 0,
  }) {
    final pctM = pctRegex.firstMatch(line);
    final ratio = pctM != null
        ? ((double.tryParse(pctM.group(1)!) ?? 0.0) / 100.0).clamp(0.0, 1.0)
        : fallbackRatio.clamp(0.0, 1.0);
    final totalM = totalRegex.firstMatch(line);
    final isTotalApproximate = totalM != null && totalM.group(1) != null;
    final parsedTotal = totalM != null
        ? parseByteUnit(totalM.group(2)!, totalM.group(3)!).round()
        : 0;
    final totalBytes = parsedTotal > 0 ? parsedTotal : lastTotalBytes;

    var downloaded = 0;
    final unknownM = unknownDlRegex.firstMatch(line);
    if (unknownM != null) {
      downloaded = parseByteUnit(unknownM.group(1)!, unknownM.group(2)!).round();
    } else if (totalBytes > 0 && ratio > 0) {
      downloaded = (totalBytes * ratio).round();
    }

    final speedM = speedRegex.firstMatch(line);
    final speed = speedM != null
        ? parseByteUnit(speedM.group(1)!, speedM.group(2)!)
        : 0.0;

    final etaM = _etaRegex.firstMatch(line);
    var eta = fallbackEta;
    if (etaM != null) {
      final h = int.tryParse(etaM.group(1) ?? '0') ?? 0;
      final m = int.tryParse(etaM.group(2) ?? '0') ?? 0;
      final s = int.tryParse(etaM.group(3) ?? '0') ?? 0;
      eta = (h * 3600 + m * 60 + s).toDouble();
    }

    return YtDlpProgressSample(
      progress: ratio,
      downloadedBytes: downloaded,
      totalBytes: totalBytes,
      speedBytesPerSec: speed,
      etaSeconds: eta,
      isTotalApproximate: isTotalApproximate,
    );
  }

  static String mergeOutputFormatFor(VideoFormatOption? fmt) {
    final ext = (fmt?.ext ?? '').toLowerCase();
    final vc = (fmt?.vcodec ?? '').toLowerCase();
    if (ext == 'webm' ||
        vc.contains('vp9') ||
        vc.contains('vp09') ||
        vc.contains('vp8') ||
        vc.contains('av01')) {
      return 'mkv';
    }
    return 'mp4';
  }

  static String extractStderrReason(String stderr, int exitCode) {
    final lines = stderr
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList(growable: false);
    for (var i = lines.length - 1; i >= 0; i--) {
      if (lines[i].startsWith('ERROR:')) {
        final cleaned = lines[i].substring('ERROR:'.length).trim();
        if (cleaned.isNotEmpty) return cleaned;
      }
    }
    return lines.isNotEmpty ? lines.last : 'exit code $exitCode';
  }
}
