import 'package:flutter/services.dart';

import 'channel_names.dart';

/// Platform channel wrapper controlling the outside-app Floating Bubble & Persistent Capture notification.
class FloatingCaptureChannel {
  FloatingCaptureChannel({MethodChannel? methodChannel})
      : _method = methodChannel ?? const MethodChannel(ChannelNames.floatingCapture);

  final MethodChannel _method;

  Future<bool> canDrawOverlays() async {
    final res = await _method.invokeMethod<bool>('canDrawOverlays');
    return res ?? false;
  }

  Future<bool> requestOverlayPermission() async {
    final res = await _method.invokeMethod<bool>('requestOverlayPermission');
    return res ?? false;
  }

  Future<bool> startFloatingCapture({
    required String title,
    required String body,
    required String captureLabel,
    required String stopLabel,
    required String emptyClipboardMsg,
  }) async {
    final res = await _method.invokeMethod<bool>(
      'startFloatingCapture',
      <String, Object?>{
        'title': title,
        'body': body,
        'captureLabel': captureLabel,
        'stopLabel': stopLabel,
        'emptyClipboardMsg': emptyClipboardMsg,
      },
    );
    return res ?? false;
  }

  Future<bool> stopFloatingCapture() async {
    final res = await _method.invokeMethod<bool>('stopFloatingCapture');
    return res ?? false;
  }

  Future<bool> isRunning() async {
    final res = await _method.invokeMethod<bool>('isRunning');
    return res ?? false;
  }
}
