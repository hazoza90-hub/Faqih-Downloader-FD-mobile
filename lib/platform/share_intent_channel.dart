import 'package:flutter/services.dart';

import '../core/utils/url_detector.dart';
import 'channel_names.dart';
import 'native_models.dart';

/// Typed Dart bridge receiving cold-start and warm-start Android ACTION_SEND text/URLs.
class ShareIntentChannel {
  ShareIntentChannel({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methodChannel =
            methodChannel ?? const MethodChannel(ChannelNames.shareIntent),
        _eventChannel =
            eventChannel ?? const EventChannel(ChannelNames.shareEvents);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  Future<String?> consumeInitialSharedText() async {
    try {
      return await _methodChannel.invokeMethod<String>(
        'consumeInitialSharedText',
      );
    } on PlatformException catch (e) {
      throw NativeBridgeException(e.code, e.message ?? 'Platform error', e.details);
    } on MissingPluginException catch (e) {
      throw NativeBridgeException('MISSING_PLUGIN', e.message ?? 'Missing plugin');
    }
  }

  Future<List<String>> consumeInitialSharedUrls() async {
    final text = await consumeInitialSharedText();
    if (text == null || text.trim().isEmpty) {
      return const <String>[];
    }
    return UrlDetector.extractUrls(text);
  }

  Stream<String> get sharedTextStream {
    return _eventChannel
        .receiveBroadcastStream()
        .where((dynamic event) => event is String && event.trim().isNotEmpty)
        .cast<String>();
  }

  Stream<List<String>> get sharedUrlsStream {
    return sharedTextStream
        .map(UrlDetector.extractUrls)
        .where((urls) => urls.isNotEmpty);
  }
}
