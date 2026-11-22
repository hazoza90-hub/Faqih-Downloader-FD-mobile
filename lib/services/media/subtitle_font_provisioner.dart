import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Provisions the bundled Arabic TTF subtitle font into a readable directory
/// so native FFmpeg's `subtitles` / `libass` filter can reference `fontsdir`.
class SubtitleFontProvisioner {
  SubtitleFontProvisioner({
    AssetBundle? bundle,
    this.assetPath = defaultAssetPath,
  }) : _bundle = bundle ?? rootBundle;

  static const String defaultAssetPath = 'assets/fonts/arabic_subtitle_font.ttf';
  static const String outputFileName = 'arabic_subtitle_font.ttf';
  static const String defaultFontFamily = 'Noto Sans Arabic';

  final AssetBundle _bundle;
  final String assetPath;

  Future<String> ensureFontsDir(String workDir) async {
    final fontsDir = p.join(workDir, 'fonts');
    final dir = Directory(fontsDir);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    final targetFile = File(p.join(fontsDir, outputFileName));
    if (targetFile.existsSync() && targetFile.lengthSync() > 0) {
      return fontsDir;
    }

    final data = await _bundle.load(assetPath);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    if (bytes.isEmpty) {
      throw StateError('Bundled subtitle font asset is empty: $assetPath');
    }

    final tmpFile = File('${targetFile.path}.tmp');
    await tmpFile.writeAsBytes(bytes, flush: true);
    if (targetFile.existsSync()) {
      await targetFile.delete();
    }
    await tmpFile.rename(targetFile.path);
    return fontsDir;
  }
}
