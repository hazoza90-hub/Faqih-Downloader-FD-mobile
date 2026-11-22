import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/foreground_service_channel.dart';
import 'package:faqih_downloader_mobile/platform/native_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(ChannelNames.foregroundService);
  const eventChannel = EventChannel(ChannelNames.serviceEvents);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  group('ForegroundServiceChannel', () {
    test('invokes lifecycle methods with expected payloads', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        calls.add(call);
        return true;
      });

      final channel = ForegroundServiceChannel(
        methodChannel: methodChannel,
        eventChannel: eventChannel,
      );

      expect(
        await channel.startService(
          const ForegroundProgressPayload(
            title: 'Faqih Downloader',
            body: 'Preparing...',
            progress: 0,
            indeterminate: true,
          ),
        ),
        isTrue,
      );
      expect(
        await channel.updateProgress(
          const ForegroundProgressPayload(
            title: 'Downloading video.mp4',
            body: '54% • 3.2 MB/s',
            progress: 54,
          ),
        ),
        isTrue,
      );
      expect(
        await channel.showCompletedNotification(
          title: 'Completed',
          body: 'video.mp4',
        ),
        isTrue,
      );
      expect(await channel.stopService(), isTrue);

      expect(calls.map((c) => c.method), <String>[
        'startService',
        'updateProgress',
        'showCompletedNotification',
        'stopService',
      ]);
      final updateArgs = calls[1].arguments as Map<Object?, Object?>;
      expect(updateArgs['progress'], 54);
      expect(updateArgs['indeterminate'], isFalse);
    });

    test('maps notification action events from EventChannel', () async {
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (_, events) {
            events.success(<String, Object?>{'action': 'pause_all'});
            events.success(<String, Object?>{'action': 'cancel_all'});
            events.success(<String, Object?>{'action': 'other'});
            events.endOfStream();
          },
        ),
      );

      final channel = ForegroundServiceChannel(
        methodChannel: methodChannel,
        eventChannel: eventChannel,
      );
      final actions = await channel.actions.toList();

      expect(actions, <ServiceNotificationAction>[
        ServiceNotificationAction.pauseAll,
        ServiceNotificationAction.cancelAll,
        ServiceNotificationAction.unknown,
      ]);
    });

    test('passes optional pauseLabel and cancelLabel only when provided', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        calls.add(call);
        return true;
      });

      final channel = ForegroundServiceChannel(
        methodChannel: methodChannel,
        eventChannel: eventChannel,
      );

      await channel.startService(
        const ForegroundProgressPayload(
          title: 'Active Downloads',
          body: 'Starting...',
          indeterminate: true,
        ),
      );
      await channel.updateProgress(
        const ForegroundProgressPayload(
          title: 'Active Downloads',
          body: '75%',
          progress: 75,
          pauseLabel: 'إيقاف الكل',
          cancelLabel: 'إلغاء الكل',
        ),
      );

      final startArgs = calls[0].arguments as Map<Object?, Object?>;
      expect(startArgs.containsKey('pauseLabel'), isFalse);
      expect(startArgs.containsKey('cancelLabel'), isFalse);

      final updateArgs = calls[1].arguments as Map<Object?, Object?>;
      expect(updateArgs['pauseLabel'], 'إيقاف الكل');
      expect(updateArgs['cancelLabel'], 'إلغاء الكل');
    });
  });
}
