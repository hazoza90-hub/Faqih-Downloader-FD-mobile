import 'package:flutter/services.dart';

import 'channel_names.dart';
import 'native_models.dart';

/// Typed Dart bridge for Android [DownloadForegroundService] and notification actions.
class ForegroundServiceChannel {
  ForegroundServiceChannel({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methodChannel =
            methodChannel ?? const MethodChannel(ChannelNames.foregroundService),
        _eventChannel =
            eventChannel ?? const EventChannel(ChannelNames.serviceEvents);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  Stream<ServiceNotificationAction> get actions {
    return _eventChannel.receiveBroadcastStream().map((dynamic raw) {
      if (raw is Map) {
        return parseServiceNotificationAction(raw['action']?.toString());
      }
      if (raw is String) {
        return parseServiceNotificationAction(raw);
      }
      return ServiceNotificationAction.unknown;
    });
  }

  Future<bool> startService(ForegroundProgressPayload payload) =>
      _invokeBool('startService', payload.toMap());

  Future<bool> updateProgress(ForegroundProgressPayload payload) =>
      _invokeBool('updateProgress', payload.toMap());

  Future<bool> showCompletedNotification({
    required String title,
    required String body,
  }) =>
      _invokeBool('showCompletedNotification', <String, dynamic>{
        'title': title,
        'body': body,
      });

  Future<bool> stopService() => _invokeBool('stopService');

  Future<bool> _invokeBool(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      final res = await _methodChannel.invokeMethod<bool>(method, arguments);
      return res ?? false;
    } on PlatformException catch (e) {
      throw NativeBridgeException(e.code, e.message ?? 'Platform error', e.details);
    } on MissingPluginException catch (e) {
      throw NativeBridgeException('MISSING_PLUGIN', e.message ?? 'Missing plugin');
    }
  }
}
