/// Sanitizes filenames across Android/Windows/Linux and applies media tags.
String sanitizeFilename(
  String name, {
  int maxLength = 180,
  bool isClip = false,
  bool hasSub = false,
  bool hasDub = false,
  String fallback = 'download',
}) {
  final strippedUnits = StringBuffer();
  for (final unit in name.codeUnits) {
    if (unit <= 0x1F || unit == 0x7F || unit == 0xFFFD) {
      continue;
    }
    strippedUnits.writeCharCode(unit);
  }

  // Strip illegal characters and trailing dots/spaces first so ".mp4" from
  // inputs like "???.mp4" still retains its extension before base normalization.
  final cleaned = strippedUnits
      .toString()
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^\s+|[.\s]+$'), '');

  final safeFallback = fallback.trim().isEmpty ? 'download' : fallback.trim();

  var base = cleaned;
  var ext = '';
  final dotIndex = cleaned.lastIndexOf('.');
  if (dotIndex >= 0 && dotIndex < cleaned.length - 1) {
    final candidateExt = cleaned.substring(dotIndex);
    if (RegExp(r'^\.[a-zA-Z0-9]{1,12}$').hasMatch(candidateExt)) {
      base = cleaned.substring(0, dotIndex);
      ext = candidateExt;
    }
  }

  base = base.replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
  if (base.isEmpty) {
    base = safeFallback;
  }

  final stem = base.split('.').first.toUpperCase();
  if (_reservedNames.contains(stem)) {
    base = '_$base';
  }

  final tagParts = <String>[];
  if (isClip && !RegExp(r'\[clip\]', caseSensitive: false).hasMatch(base)) {
    tagParts.add('[Clip]');
  }
  if (hasSub && !RegExp(r'\[sub\]', caseSensitive: false).hasMatch(base)) {
    tagParts.add('[Sub]');
  }
  if (hasDub && !RegExp(r'\[dub\]', caseSensitive: false).hasMatch(base)) {
    tagParts.add('[Dub]');
  }

  final tagSuffix = tagParts.isEmpty ? '' : ' ${tagParts.join(' ')}';
  final fullSuffix = '$tagSuffix$ext';

  if (maxLength > 0 && base.length + fullSuffix.length > maxLength) {
    final allowedBaseLength = maxLength - fullSuffix.length;
    if (allowedBaseLength >= 1) {
      base = _safeUtf16Substring(base, allowedBaseLength)
          .replaceAll(RegExp(r'[.\s]+$'), '');
      if (base.isEmpty) {
        base = _safeUtf16Substring(safeFallback, allowedBaseLength);
      }
    } else {
      return _safeUtf16Substring('$base$fullSuffix', maxLength)
          .replaceAll(RegExp(r'[.\s]+$'), '');
    }
  }

  return '$base$fullSuffix';
}

String _safeUtf16Substring(String value, int maxUnits) {
  if (maxUnits <= 0 || value.isEmpty) {
    return '';
  }
  if (value.length <= maxUnits) {
    return value;
  }
  var end = maxUnits;
  final lastCodeUnit = value.codeUnitAt(end - 1);
  if (lastCodeUnit >= 0xD800 && lastCodeUnit <= 0xDBFF) {
    end -= 1;
  }
  return value.substring(0, end);
}

const Set<String> _reservedNames = <String>{
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};
