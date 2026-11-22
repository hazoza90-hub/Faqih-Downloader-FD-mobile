import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/native_models.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(ChannelNames.youtubeDl);
  const eventChannel = EventChannel(ChannelNames.youtubeDlEvents);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  group('YoutubeDlChannel', () {
    test('initialize, updateYoutubeDL, and extractInfo send expected contracts', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'initialize':
            return <String, Object?>{
              'initialized': true,
              'ytdlpVersion': '2026.11.01',
              'ffmpegReady': true,
            };
          case 'updateYoutubeDL':
            return <String, Object?>{
              'status': 'DONE',
              'ytdlpVersion': '2026.11.15',
            };
          case 'extractInfo':
            return '{"id":"dQw4w9WgXcQ","title":"Sample"}';
        }
        return null;
      });

      final channel = YoutubeDlChannel(
        methodChannel: methodChannel,
        eventChannel: eventChannel,
      );

      final init = await channel.initialize();
      expect(init.initialized, isTrue);
      expect(init.ytdlpVersion, '2026.11.01');
      expect(init.ffmpegReady, isTrue);

      final update = await channel.updateYoutubeDL();
      expect(update.status, 'DONE');
      expect(update.ytdlpVersion, '2026.11.15');

      final rawJson = await channel.extractInfo(
        url: 'https://youtu.be/dQw4w9WgXcQ',
        processId: 'proc_1',
        userAgent: 'FD-Mobile',
        headers: const <String, String>{'Referer': 'https://youtube.com'},
        timeoutSeconds: 20,
      );
      expect(rawJson, contains('dQw4w9WgXcQ'));

      expect(calls.map((c) => c.method), <String>[
        'initialize',
        'updateYoutubeDL',
        'extractInfo',
      ]);
      final extractArgs = calls.last.arguments as Map<Object?, Object?>;
      expect(extractArgs['url'], 'https://youtu.be/dQw4w9WgXcQ');
      expect(extractArgs['processId'], 'proc_1');
      expect(extractArgs['userAgent'], 'FD-Mobile');
      expect(extractArgs['timeoutSeconds'], 20);
    });

    test('downloadMedia, runFfmpeg, and cancelProcess handle responses and errors', () async {
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'downloadMedia':
            return <String, Object?>{
              'exitCode': 0,
              'stdout': 'ok',
              'stderr': '',
            };
          case 'runFfmpeg':
            final args = (call.arguments as Map<Object?, Object?>)['args'] as List<Object?>;
            expect(args, contains('-c:a'));
            return <String, Object?>{
              'exitCode': 0,
              'output': 'mux complete',
            };
          case 'cancelProcess':
            return true;
          default:
            throw PlatformException(code: 'ERR', message: 'Boom');
        }
      });

      final channel = YoutubeDlChannel(
        methodChannel: methodChannel,
        eventChannel: eventChannel,
      );

      final dlRes = await channel.downloadMedia(
        url: 'https://youtu.be/dQw4w9WgXcQ',
        processId: 'dl_1',
        options: const <String, Object?>{'-f': 'best'},
      );
      expect(dlRes.isSuccess, isTrue);
      expect(dlRes.output, 'ok');

      final ffRes = await channel.runFfmpeg(
        args: const <String>['-i', 'v.mp4', '-i', 'a.m4a', '-c:v', 'copy', '-c:a', 'copy', 'out.mp4'],
        processId: 'ff_1',
      );
      expect(ffRes.isSuccess, isTrue);
      expect(ffRes.output, 'mux complete');

      expect(await channel.cancelProcess('ff_1'), isTrue);

      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        throw PlatformException(code: 'YOUTUBEDL_ERROR', message: 'Failed');
      });
      await expectLater(
        channel.initialize(),
        throwsA(
          isA<NativeBridgeException>().having((e) => e.code, 'code', 'YOUTUBEDL_ERROR'),
        ),
      );
    });

    test('streams progress and ffmpeg logs from EventChannel', () async {
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (_, events) {
            events.success(<String, Object?>{
              'type': 'progress',
              'processId': 'dl_1',
              'progress': 42.5,
              'etaSeconds': 12,
              'line': '[download] 42.5%',
            });
            events.success(<String, Object?>{
              'type': 'ffmpeg_log',
              'processId': 'ff_1',
              'line': 'frame=120',
            });
            events.endOfStream();
          },
        ),
      );

      final channel = YoutubeDlChannel(
        methodChannel: methodChannel,
        eventChannel: eventChannel,
      );
      final emitted = await channel.events.toList();

      expect(emitted.length, 2);
      expect(emitted[0].type, 'progress');
      expect(emitted[0].processId, 'dl_1');
      expect(emitted[0].progress, 42.5);
      expect(emitted[0].etaSeconds, 12);
      expect(emitted[1].type, 'ffmpeg_log');
      expect(emitted[1].line, 'frame=120');
    });
  });
}
