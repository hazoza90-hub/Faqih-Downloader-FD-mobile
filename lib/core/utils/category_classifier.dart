import 'package:path/path.dart' as p;

/// Classifies a filename or URL path into canonical Faqih Downloader categories.
String classifyCategory(String filename) {
  final clean = filename.split('?').first.split('#').first.trim();
  if (clean.isEmpty) {
    return 'Other';
  }
  final ext = p.extension(clean).toLowerCase().replaceFirst('.', '');
  if (ext.isEmpty || ext == 'bin') {
    return 'Other';
  }
  if (_videoExts.contains(ext)) return 'Video';
  if (_audioExts.contains(ext)) return 'Audio';
  if (_compressedExts.contains(ext)) return 'Compressed';
  if (_documentExts.contains(ext)) return 'Documents';
  if (_programExts.contains(ext)) return 'Programs';
  if (_imageExts.contains(ext)) return 'Images';
  return 'Other';
}

/// Namespaced facade for [classifyCategory].
abstract final class CategoryClassifier {
  static String classify(String filename) => classifyCategory(filename);
}

const Set<String> _videoExts = <String>{
  'mp4',
  'mkv',
  'webm',
  'avi',
  'mov',
  'wmv',
  'flv',
  'm4v',
  '3gp',
  'ts',
  'm2ts',
  'ogv',
  'm3u8',
};

const Set<String> _audioExts = <String>{
  'mp3',
  'wav',
  'flac',
  'aac',
  'ogg',
  'm4a',
  'wma',
  'opus',
  'mka',
  'alac',
  'aiff',
};

const Set<String> _compressedExts = <String>{
  'zip',
  'rar',
  '7z',
  'tar',
  'gz',
  'bz2',
  'xz',
  'iso',
  'tgz',
  '7zip',
  'z',
  'zst',
  'cab',
};

const Set<String> _documentExts = <String>{
  'pdf',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'txt',
  'rtf',
  'epub',
  'csv',
  'json',
  'xml',
  'djvu',
  'md',
};

const Set<String> _programExts = <String>{
  'exe',
  'msi',
  'dmg',
  'pkg',
  'deb',
  'rpm',
  'apk',
  'appimage',
  'bat',
  'cmd',
  'ps1',
  'appx',
  'msix',
  'ipa',
};

const Set<String> _imageExts = <String>{
  'jpg',
  'jpeg',
  'png',
  'gif',
  'bmp',
  'webp',
  'svg',
  'ico',
  'tiff',
  'tif',
};
