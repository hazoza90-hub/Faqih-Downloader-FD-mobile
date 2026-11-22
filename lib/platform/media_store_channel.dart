import 'package:flutter/services.dart';

import 'channel_names.dart';
import 'native_models.dart';

/// Typed Dart bridge for Android scoped Downloads export, work dir, and file opening.
class MediaStoreChannel {
  MediaStoreChannel({MethodChannel? methodChannel})
      : _methodChannel =
            methodChannel ?? const MethodChannel(ChannelNames.mediaStore);

  final MethodChannel _methodChannel;

  Future<String> getAppWorkDir() async {
    try {
      final path = await _methodChannel.invokeMethod<String>('getAppWorkDir');
      if (path == null || path.trim().isEmpty) {
        throw const NativeBridgeException(
          'EMPTY_DIR',
          'Native side returned an empty work directory path',
        );
      }
      return path;
    } on PlatformException catch (e) {
      throw NativeBridgeException(e.code, e.message ?? 'Platform error', e.details);
    } on MissingPluginException catch (e) {
      throw NativeBridgeException('MISSING_PLUGIN', e.message ?? 'Missing plugin');
    }
  }

  Future<ExportResult> exportToDownloads({
    required String sourcePath,
    required String displayName,
    required String mimeType,
    String? subFolder,
    bool deleteSource = false,
  }) async {
    try {
      final result = await _methodChannel.invokeMethod<Map<Object?, Object?>>(
        'exportToDownloads',
        <String, dynamic>{
          'sourcePath': sourcePath,
          'displayName': displayName,
          'mimeType': mimeType,
          if (subFolder != null && subFolder.trim().isNotEmpty)
            'subFolder': subFolder,
          'deleteSource': deleteSource,
        },
      );
      return ExportResult.fromMap(result ?? const <Object?, Object?>{});
    } on PlatformException catch (e) {
      throw NativeBridgeException(e.code, e.message ?? 'Platform error', e.details);
    } on MissingPluginException catch (e) {
      throw NativeBridgeException('MISSING_PLUGIN', e.message ?? 'Missing plugin');
    }
  }

  Future<bool> openFile({
    required String pathOrUri,
    String? mimeType,
  }) async {
    try {
      final res = await _methodChannel.invokeMethod<bool>(
        'openFile',
        <String, dynamic>{
          'pathOrUri': pathOrUri,
          if (mimeType != null && mimeType.trim().isNotEmpty)
            'mimeType': mimeType,
        },
      );
      return res ?? false;
    } on PlatformException catch (e) {
      throw NativeBridgeException(e.code, e.message ?? 'Platform error', e.details);
    } on MissingPluginException catch (e) {
      throw NativeBridgeException('MISSING_PLUGIN', e.message ?? 'Missing plugin');
    }
  }
}
