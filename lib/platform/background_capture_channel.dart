import 'package:flutter/services.dart';

import 'channel_names.dart';

/// Platform channel managing silent Accessibility auto-sniffer & Quick Settings Tile.
class BackgroundCaptureChannel {
  BackgroundCaptureChannel({MethodChannel? methodChannel})
      : _method =
            methodChannel ?? const MethodChannel(ChannelNames.backgroundCapture);

  final MethodChannel _method;

  Future<bool> isAccessibilityServiceEnabled() async {
    final res = await _method.invokeMethod<bool>('isAccessibilityServiceEnabled');
    return res ?? false;
  }

  Future<bool> openAccessibilitySettings() async {
    try {
      final res = await _method.invokeMethod<bool>('openAccessibilitySettings');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> openAppDetailsSettings() async {
    try {
      final res = await _method.invokeMethod<bool>('openAppDetailsSettings');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> setAutoSnifferConfig({
    required bool enabled,
    required Map<String, bool> platforms,
    required String notifTitle,
    required String notifActionLabel,
  }) async {
    final res = await _method.invokeMethod<bool>(
      'setAutoSnifferConfig',
      <String, Object?>{
        'enabled': enabled,
        'platforms': platforms,
        'notifTitle': notifTitle,
        'notifActionLabel': notifActionLabel,
      },
    );
    return res ?? false;
  }

  Future<bool> setQuickTileEnabled(bool enabled) async {
    try {
      final res = await _method.invokeMethod<bool>(
        'setQuickTileEnabled',
        <String, Object?>{'enabled': enabled},
      );
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestAddQuickTile({required String label}) async {
    try {
      final res = await _method.invokeMethod<bool>(
        'requestAddQuickTile',
        <String, Object?>{'label': label},
      );
      return res ?? false;
    } catch (_) {
      return false;
    }
  }
}
