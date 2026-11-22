import 'dart:convert';
import 'dart:io';

import '../../core/models/subtitle_track.dart';

/// Downloads, normalizes VTT->SRT, deduplicates rolling captions, prepares RTL Arabic text,
/// and escapes paths for native FFmpeg subtitle filters.
class SubtitleProcessor {
  SubtitleProcessor({HttpClient Function()? httpClientFactory})
      : _httpClientFactory = httpClientFactory;

  final HttpClient Function()? _httpClientFactory;

  Future<String> downloadAndNormalize(
    SubtitleTrack track,
    String outputSrtPath, {
    Map<String, String> headers = const <String, String>{},
    bool prepareForArabicHardBurn = false,
  }) async {
    final rawText = await _readTrackContent(track, headers);
    final isVtt = track.ext.toLowerCase() == 'vtt' ||
        rawText.trimLeft().startsWith('WEBVTT');

    var srt = isVtt
        ? convertVttToSrt(rawText)
        : deduplicateRollingCaptions(rawText);

    if (prepareForArabicHardBurn ||
        isArabicLanguage(track.language) ||
        RegExp(r'[\u0600-\u06FF]').hasMatch(srt)) {
      srt = normalizeForArabicRtl(srt);
    }

    final outFile = File(outputSrtPath);
    if (!outFile.parent.existsSync()) {
      await outFile.parent.create(recursive: true);
    }
    await outFile.writeAsString(srt, encoding: utf8, flush: true);
    return outputSrtPath;
  }

  Future<String> _readTrackContent(
    SubtitleTrack track,
    Map<String, String> headers,
  ) async {
    final local = track.localPath?.trim();
    if (local != null && local.isNotEmpty) {
      final file = File(local);
      if (file.existsSync()) {
        final bytes = await file.readAsBytes();
        return utf8.decode(bytes, allowMalformed: true);
      }
    }

    final uri = Uri.parse(track.url.trim());
    final client = (_httpClientFactory ?? HttpClient.new)();
    try {
      client.connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(uri);
      headers.forEach((k, v) {
        if (k.trim().isNotEmpty) req.headers.set(k, v);
      });
      final res = await req.close();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException('Subtitle HTTP ${res.statusCode}', uri: uri);
      }
      final chunks = await res.fold<List<int>>(<int>[], (acc, b) => acc..addAll(b));
      return utf8.decode(chunks, allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }

  static bool isArabicLanguage(String languageCode) {
    final norm = languageCode.trim().toLowerCase();
    return norm == 'ar' || norm.startsWith('ar-') || norm.startsWith('ar_');
  }

  /// Converts WebVTT cues to clean sequential SRT and strips YouTube rolling caption duplicates.
  static String convertVttToSrt(String vttContent) {
    final normalized = vttContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final blocks = normalized.split(RegExp(r'\n{2,}'));
    final cues = <_SubtitleCue>[];

    for (final rawBlock in blocks) {
      final lines = rawBlock
          .split('\n')
          .map((l) => l.trimRight())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.isEmpty) continue;
      final head = lines.first.trim();
      if (head.startsWith('WEBVTT') ||
          head.startsWith('Kind:') ||
          head.startsWith('Language:') ||
          head.startsWith('NOTE') ||
          head.startsWith('STYLE') ||
          head.startsWith('REGION')) {
        continue;
      }

      var timingIdx = lines.indexWhere((l) => l.contains('-->'));
      if (timingIdx < 0) continue;

      final timingLine = _convertTimingLine(lines[timingIdx]);
      final textLines = lines
          .sublist(timingIdx + 1)
          .map(_stripVttMarkup)
          .where((l) => l.isNotEmpty)
          .toList();
      if (textLines.isEmpty) continue;

      cues.add(_SubtitleCue(timing: timingLine, lines: textLines));
    }

    return _formatCues(_deduplicateCueList(cues));
  }

  /// Deduplicates rolling overlapping caption lines inside SRT text.
  static String deduplicateRollingCaptions(String srtContent) {
    final normalized = srtContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final blocks = normalized.split(RegExp(r'\n{2,}'));
    final cues = <_SubtitleCue>[];

    for (final block in blocks) {
      final lines = block.split('\n').where((l) => l.trim().isNotEmpty).toList();
      final timingIdx = lines.indexWhere((l) => l.contains('-->'));
      if (timingIdx < 0) continue;
      final textLines = lines
          .sublist(timingIdx + 1)
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (textLines.isEmpty) continue;
      cues.add(_SubtitleCue(timing: _convertTimingLine(lines[timingIdx]), lines: textLines));
    }

    return _formatCues(_deduplicateCueList(cues));
  }

  /// Wraps Arabic dialogue lines with Unicode RLE/PDF markers for accurate libass RTL layout.
  static String normalizeForArabicRtl(String srtText) {
    final lines = srtText.replaceAll('\r\n', '\n').split('\n');
    final arabicRegex = RegExp(r'[\u0600-\u06FF]');
    final out = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty ||
          RegExp(r'^\d+$').hasMatch(trimmed) ||
          trimmed.contains('-->')) {
        out.add(line);
        continue;
      }
      if (arabicRegex.hasMatch(trimmed) && !trimmed.startsWith('\u202B')) {
        out.add('\u202B$trimmed\u202C');
      } else {
        out.add(line);
      }
    }
    return out.join('\n');
  }

  /// Escapes paths for FFmpeg `subtitles='...'` and `fontsdir='...'` filter options.
  static String escapeForFfmpegFilter(String path) {
    return path
        .replaceAll(r'\', r'\\')
        .replaceAll(':', r'\:')
        .replaceAll("'", r"\'")
        .replaceAll('[', r'\[')
        .replaceAll(']', r'\]');
  }

  /// Excludes out-of-range cues, shifts timestamps by `-startSec`, and renumbers from 1.
  static String shiftAndClipSrt(
    String srtContent,
    double startSec, {
    double? endSec,
  }) {
    final normalized = srtContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final blocks = normalized.split(RegExp(r'\n{2,}'));
    final hasEndLimit = endSec != null && endSec > startSec;
    final cues = <_SubtitleCue>[];

    for (final block in blocks) {
      final lines = block.split('\n').where((l) => l.trim().isNotEmpty).toList();
      final tIdx = lines.indexWhere((l) => l.contains('-->'));
      if (tIdx < 0) continue;
      final parts = lines[tIdx].split('-->');
      if (parts.length < 2) continue;
      final cueStart = _parseSeconds(parts[0]);
      final cueEnd = _parseSeconds(parts[1]);
      if (cueStart == null || cueEnd == null || cueEnd <= startSec) continue;
      if (hasEndLimit && cueStart >= endSec) continue;

      final shiftedStart = cueStart < startSec ? 0.0 : (cueStart - startSec);
      var shiftedEnd = cueEnd - startSec;
      if (hasEndLimit && shiftedEnd > (endSec - startSec)) {
        shiftedEnd = endSec - startSec;
      }
      if (shiftedEnd <= shiftedStart) continue;

      final textLines = lines.sublist(tIdx + 1);
      if (textLines.isEmpty) continue;
      cues.add(_SubtitleCue(
        timing: '${_formatSrtTime(shiftedStart)} --> ${_formatSrtTime(shiftedEnd)}',
        lines: textLines,
      ));
    }
    return _formatCues(cues);
  }

  static double? _parseSeconds(String raw) {
    final token = raw.trim().split(RegExp(r'\s+')).first.replaceAll(',', '.');
    final segs = token.split(':');
    if (segs.length < 2 || segs.length > 3) return null;
    if (segs.length == 2) {
      final m = int.tryParse(segs[0]);
      final s = double.tryParse(segs[1]);
      return (m == null || s == null) ? null : m * 60.0 + s;
    }
    final h = int.tryParse(segs[0]);
    final m = int.tryParse(segs[1]);
    final s = double.tryParse(segs[2]);
    return (h == null || m == null || s == null) ? null : h * 3600.0 + m * 60.0 + s;
  }

  static String _formatSrtTime(double seconds) {
    final totalMs = seconds <= 0 ? 0 : (seconds * 1000).round();
    final ms = totalMs % 1000;
    final totalSec = totalMs ~/ 1000;
    final s = totalSec % 60;
    final totalMin = totalSec ~/ 60;
    final m = totalMin % 60;
    final h = totalMin ~/ 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')},'
        '${ms.toString().padLeft(3, '0')}';
  }

  static List<_SubtitleCue> _deduplicateCueList(List<_SubtitleCue> cues) {
    final cleaned = <_SubtitleCue>[];
    for (final cue in cues) {
      var candidateLines = List<String>.from(cue.lines);
      if (cleaned.isNotEmpty) {
        final prev = cleaned.last;
        if (_listsEqual(prev.lines, candidateLines)) {
          cleaned[cleaned.length - 1] = _SubtitleCue(
            timing: _mergeTimingEnd(prev.timing, cue.timing),
            lines: prev.lines,
          );
          continue;
        }
        // Strip repeated overlapping top line(s) from rolling YouTube auto-captions.
        final lastPrevLine = prev.lines.last;
        if (candidateLines.length > 1 && candidateLines.first == lastPrevLine) {
          candidateLines = candidateLines.sublist(1);
        }
      }
      if (candidateLines.isNotEmpty) {
        cleaned.add(_SubtitleCue(timing: cue.timing, lines: candidateLines));
      }
    }
    return cleaned;
  }

  static String _formatCues(List<_SubtitleCue> cues) {
    final buf = StringBuffer();
    for (var i = 0; i < cues.length; i++) {
      buf.writeln(i + 1);
      buf.writeln(cues[i].timing);
      for (final line in cues[i].lines) {
        buf.writeln(line);
      }
      if (i < cues.length - 1) buf.writeln();
    }
    return buf.toString();
  }

  static String _stripVttMarkup(String line) {
    return line
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .trim();
  }

  static String _convertTimingLine(String line) {
    final parts = line.split('-->');
    if (parts.length < 2) return line;
    final start = _normalizeTimestamp(parts[0].trim().split(RegExp(r'\s+')).first);
    final end = _normalizeTimestamp(parts[1].trim().split(RegExp(r'\s+')).first);
    return '$start --> $end';
  }

  static String _normalizeTimestamp(String ts) {
    var clean = ts.replaceAll('.', ',');
    final segs = clean.split(':');
    if (segs.length == 2) {
      clean = '00:${segs[0].padLeft(2, '0')}:${segs[1]}';
    } else if (segs.length == 3) {
      clean = '${segs[0].padLeft(2, '0')}:${segs[1].padLeft(2, '0')}:${segs[2]}';
    }
    return clean;
  }

  static String _mergeTimingEnd(String prevTiming, String nextTiming) {
    final prevStart = prevTiming.split('-->').first.trim();
    final nextEnd = nextTiming.split('-->').last.trim();
    return '$prevStart --> $nextEnd';
  }

  static bool _listsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _SubtitleCue {
  const _SubtitleCue({required this.timing, required this.lines});
  final String timing;
  final List<String> lines;
}
