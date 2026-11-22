import 'package:flutter/services.dart';

import 'channel_names.dart';
import 'native_models.dart';

/// Typed Dart bridge over Android `YoutubeDlBridge` (yt-dlp + native FFmpeg).
class YoutubeDlChannel {
  YoutubeDlChannel({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methodChannel =
            methodChannel ?? const MethodChannel(ChannelNames.youtubeDl),
        _eventChannel =
            eventChannel ?? const EventChannel(ChannelNames.youtubeDlEvents);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  Stream<NativeProgressEvent> get events {
    return _eventChannel.receiveBroadcastStream().map((dynamic raw) {
      if (raw is Map) {
        return NativeProgressEvent.fromMap(raw);
      }
      return const NativeProgressEvent(type: 'unknown', processId: '');
    });
  }

  Future<NativeInitStatus> initialize() async {
    final map = await _invokeMap('initialize');
    return NativeInitStatus.fromMap(map);
  }

  Future<NativeUpdateResult> updateYoutubeDL() async {
    final map = await _invokeMap('updateYoutubeDL');
    return NativeUpdateResult.fromMap(map);
  }

  Future<String> extractInfo({
    required String url,
    required String processId,
    String? cookiesFile,
    String? userAgent,
    Map<String, String>? headers,
    String? playlistItems,
    int? timeoutSeconds,
  }) async {
    try {
      final result = await _methodChannel.invokeMethod<String>(
        'extractInfo',
        <String, dynamic>{
          'url': url,
          'processId': processId,
          'cookiesFile': ?cookiesFile,
          'userAgent': ?userAgent,
          if (headers != null && headers.isNotEmpty) 'headers': headers,
          'playlistItems': ?playlistItems,
          'timeoutSeconds': ?timeoutSeconds,
        },
      );
      return result ?? '';
    } on PlatformException catch (e) {
      throw NativeBridgeException(e.code, e.message ?? 'Platform error', e.details);
    } on MissingPluginException catch (e) {
      throw NativeBridgeException('MISSING_PLUGIN', e.message ?? 'Missing plugin');
    }
  }

  Future<NativeCommandResult> downloadMedia({
    required String url,
    required String processId,
    List<String> args = const <String>[],
    Map<String, Object?> options = const <String, Object?>{},
  }) async {
    final map = await _invokeMap(
      'downloadMedia',
      <String, dynamic>{
        'url': url,
        'processId': processId,
        'args': args,
        'options': options,
      },
    );
    return NativeCommandResult.fromMap(map);
  }

  Future<NativeCommandResult> runFfmpeg({
    required List<String> args,
    required String processId,
  }) async {
    final map = await _invokeMap(
      'runFfmpeg',
      <String, dynamic>{
        'args': args,
        'processId': processId,
      },
    );
    return NativeCommandResult.fromMap(map);
  }

  Future<bool> cancelProcess(String processId) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>(
        'cancelProcess',
        <String, dynamic>{'processId': processId},
      );
      return result ?? false;
    } on PlatformException catch (e) {
      throw NativeBridgeException(e.code, e.message ?? 'Platform error', e.details);
    } on MissingPluginException catch (e) {
      throw NativeBridgeException('MISSING_PLUGIN', e.message ?? 'Missing plugin');
    }
  }

  Future<Map<Object?, Object?>> _invokeMap(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      final result = await _methodChannel.invokeMethod<Map<Object?, Object?>>(
        method,
        arguments,
      );
      return result ?? const <Object?, Object?>{};
    } on PlatformException catch (e) {
      throw NativeBridgeException(e.code, e.message ?? 'Platform error', e.details);
    } on MissingPluginException catch (e) {
      throw NativeBridgeException('MISSING_PLUGIN', e.message ?? 'Missing plugin');
    }
  }
}
