import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/share_intent_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(ChannelNames.shareIntent);
  const eventChannel = EventChannel(ChannelNames.shareEvents);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  group('ShareIntentChannel', () {
    test('consumes initial shared text once and extracts HTTP URLs', () async {
      String? pending = 'Watch: https://youtu.be/dQw4w9WgXcQ';
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        expect(call.method, 'consumeInitialSharedText');
        final out = pending;
        pending = null;
        return out;
      });

      final channel = ShareIntentChannel(
        methodChannel: methodChannel,
        eventChannel: eventChannel,
      );

      final urls = await channel.consumeInitialSharedUrls();
      expect(urls, <String>['https://youtu.be/dQw4w9WgXcQ']);

      // Subsequent read returns empty after native side clears initial value.
      expect(await channel.consumeInitialSharedUrls(), isEmpty);
    });

    test('streams warm-start shared URLs from EventChannel', () async {
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (_, events) {
            events.success('No link text');
            events.success('TikTok: https://vt.tiktok.com/ZSNabcdef/!');
            events.endOfStream();
          },
        ),
      );

      final channel = ShareIntentChannel(
        methodChannel: methodChannel,
        eventChannel: eventChannel,
      );

      final emitted = await channel.sharedUrlsStream.toList();
      expect(emitted, <List<String>>[
        <String>['https://vt.tiktok.com/ZSNabcdef/'],
      ]);
    });
  });
}
