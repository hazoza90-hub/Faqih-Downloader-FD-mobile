import 'dart:async';

import 'package:faqih_downloader_mobile/core/models/clip_range.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
import 'package:faqih_downloader_mobile/services/media/ffmpeg_media_processor.dart';
import 'package:faqih_downloader_mobile/services/media/ffmpeg_progress_parser.dart';
import 'package:faqih_downloader_mobile/services/media/media_exceptions.dart';
import 'package:faqih_downloader_mobile/services/media/media_extractor_service.dart';
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

  group('FfmpegProgressParser & MediaExtractorService', () {
    test('parses FFmpeg Duration, time, and speed accurately', () {
      final parser = FfmpegProgressParser();
      expect(parser.parseLine('  Duration: 00:02:00.00, start: 0.000'), isNull);
      expect(parser.totalSeconds, closeTo(120.0, 0.01));

      final mid = parser.parseLine('frame= 120 fps=30 time=00:01:00.00 speed=2.50x');
      expect(mid, isNotNull);
      expect(mid!.ratio, closeTo(0.5, 0.001));
      expect(mid.speedFactor, closeTo(2.5, 0.001));
    });

    test('classifies yt-dlp errors into precise MediaErrorKind', () {
      expect(MediaExtractorService.classifyError('Unsupported URL: xyz'), MediaErrorKind.unsupportedUrl);
      expect(MediaExtractorService.classifyError('Sign in to confirm you’re not a bot'), MediaErrorKind.loginRequired);
      expect(MediaExtractorService.classifyError('Video is not available in your country'), MediaErrorKind.geoBlocked);
      expect(MediaExtractorService.classifyError('HTTP Error 403: Forbidden'), MediaErrorKind.linkExpired);
      expect(MediaExtractorService.classifyError('Connection timed out'), MediaErrorKind.networkError);
      expect(MediaExtractorService.classifyError('Process destroyed by user'), MediaErrorKind.cancelled);
    });

    test('MediaExtractorService.extractInfo parses metadata and wraps errors via YoutubeDlChannel', () async {
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        if (call.method == 'extractInfo') {
          return '{"id":"abc","title":"Extracted Video","formats":[{"format_id":"22","height":720,"ext":"mp4","vcodec":"avc1","acodec":"mp4a.40.2","url":"https://cdn.example.com/v.mp4"}]}';
        }
        return true;
      });

      final extractor = MediaExtractorService(
        channel: YoutubeDlChannel(methodChannel: methodChannel, eventChannel: eventChannel),
      );
      final info = await extractor.extractInfo('https://youtube.com/watch?v=abc', processId: 'ext_1');
      expect(info.videoId, 'abc');
      expect(info.videoFormats.single.formatId, '22');

      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        throw PlatformException(code: 'YOUTUBEDL_ERROR', message: 'Sign in to confirm you are not a bot');
      });
      await expectLater(
        extractor.extractInfo('https://youtube.com/watch?v=abc', processId: 'ext_2'),
        throwsA(isA<MediaExtractionException>().having((e) => e.kind, 'kind', MediaErrorKind.loginRequired)),
      );
    });
  });

  group('FfmpegMediaProcessor', () {
    test('builds correct FFmpeg arguments across mux, opus->aac, mp3, clip, softMux, and hardBurn', () async {
      final capturedCalls = <List<String>>[];

      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        if (call.method == 'runFfmpeg') {
          final args = ((call.arguments as Map<Object?, Object?>)['args'] as List<Object?>)
              .map((e) => e.toString())
              .toList();
          capturedCalls.add(args);
          return <String, Object?>{'exitCode': 0, 'output': 'ok'};
        }
        return true;
      });
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (_, events) {
            scheduleMicrotask(() {
              events.success(<String, Object?>{
                'type': 'ffmpeg_log',
                'processId': 'p_burn',
                'line': 'Duration: 00:00:20.00',
              });
              events.success(<String, Object?>{
                'type': 'ffmpeg_log',
                'processId': 'p_burn',
                'line': 'time=00:00:10.00 speed=2.0x',
              });
            });
          },
        ),
      );

      final processor = FfmpegMediaProcessor(
        channel: YoutubeDlChannel(
          methodChannel: methodChannel,
          eventChannel: eventChannel,
        ),
      );

      // 1. Fast copy mux (mp4 + m4a)
      await processor.muxVideoAndAudio(
        videoPath: 'v.mp4',
        audioPath: 'a.m4a',
        outputPath: 'out_fast.mp4',
        audioCodec: 'mp4a.40.2',
        processId: 'p_mux1',
      );
      expect(capturedCalls.last, containsAllInOrder(<String>['-c:v', 'copy', '-c:a', 'copy', '-movflags', '+faststart']));

      // 2. Opus audio -> MP4 forces AAC transcode
      await processor.muxVideoAndAudio(
        videoPath: 'v.mp4',
        audioPath: 'a.webm',
        outputPath: 'out_aac.mp4',
        audioCodec: 'opus',
        processId: 'p_mux2',
      );
      expect(capturedCalls.last, containsAllInOrder(<String>['-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k']));

      // 3. Extract MP3
      await processor.extractAudio(
        inputPath: 'in.m4a',
        outputPath: 'out.mp3',
        format: 'mp3',
        title: 'Nasheed',
        processId: 'p_mp3',
      );
      expect(capturedCalls.last, containsAllInOrder(<String>['-vn', '-c:a', 'libmp3lame', '-b:a', '192k']));
      expect(capturedCalls.last, contains('title=Nasheed'));

      // 4. Fast clip vs accurate clip
      await processor.clipMedia(
        inputPath: 'in.mp4',
        outputPath: 'clip.mp4',
        clipRange: const ClipRange(startSec: 12, endSec: 45),
        processId: 'p_clip',
      );
      expect(capturedCalls.last, containsAllInOrder(<String>['-ss', '12', '-to', '45', '-i', 'in.mp4', '-c', 'copy']));

      // 5. Soft subtitle mux
      await processor.muxSoftSubtitles(
        videoPath: 'in.mp4',
        subtitlePath: 'ar.srt',
        outputPath: 'soft.mp4',
        languageCode: 'ar',
        processId: 'p_soft',
      );
      expect(capturedCalls.last, containsAllInOrder(<String>['-c:s', 'mov_text', '-metadata:s:s:0', 'language=ar']));

      // 6. Single-pass hard burn + clip + progress parsing
      final ratios = <double>[];
      await processor.burnHardSubtitles(
        videoPath: 'in.mp4',
        subtitlePath: r"C:\tmp\ar'sub:1.srt",
        outputPath: 'burned.mp4',
        fontsDir: r'C:\tmp\fonts',
        clipRange: const ClipRange(startSec: 10, endSec: 30),
        processId: 'p_burn',
        onProgress: ratios.add,
      );
      final burnArgs = capturedCalls.last;
      expect(burnArgs, containsAllInOrder(<String>['-ss', '10', '-to', '30', '-i', 'in.mp4']));
      final vfArg = burnArgs[burnArgs.indexOf('-vf') + 1];
      expect(vfArg, contains('fontsdir='));
      expect(vfArg, contains('charenc=UTF-8'));
      expect(vfArg, contains(r"\'sub\:1.srt"));
      expect(burnArgs, containsAllInOrder(<String>['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '22', '-c:a', 'copy']));
      expect(ratios.last, 1.0);
    });
  });
}
