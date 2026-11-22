import 'package:flutter/services.dart';

import 'channel_names.dart';
import 'native_models.dart';

/// Typed Dart bridge for exporting Android WebView cookies (including HttpOnly) for `yt-dlp`.
class CookiesChannel {
  CookiesChannel({MethodChannel? methodChannel})
      : _methodChannel =
            methodChannel ?? const MethodChannel(ChannelNames.cookies);

  final MethodChannel _methodChannel;

  Future<int> exportCookiesForUrls({
    required List<String> urls,
    required String outputPath,
  }) async {
    try {
      final count = await _methodChannel.invokeMethod<int>(
        'exportCookiesForUrls',
        <String, dynamic>{
          'urls': urls,
          'outputPath': outputPath,
        },
      );
      return count ?? 0;
    } on PlatformException catch (e) {
      throw NativeBridgeException(e.code, e.message ?? 'Platform error', e.details);
    } on MissingPluginException catch (e) {
      throw NativeBridgeException('MISSING_PLUGIN', e.message ?? 'Missing plugin');
    }
  }

  Future<bool> clearAllCookies({String? cookiesFilePath}) async {
    try {
      final res = await _methodChannel.invokeMethod<bool>(
        'clearAllCookies',
        <String, dynamic>{
          'cookiesFilePath': ?cookiesFilePath,
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
