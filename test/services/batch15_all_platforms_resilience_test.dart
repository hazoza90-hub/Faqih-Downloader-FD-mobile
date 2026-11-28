import 'dart:async';
import 'dart:io';

import 'package:faqih_downloader_mobile/core/models/clip_range.dart';
import 'package:faqih_downloader_mobile/core/models/download_chunk.dart';
import 'package:faqih_downloader_mobile/core/models/subtitle_track.dart';
import 'package:faqih_downloader_mobile/core/models/video_format_option.dart';
import 'package:faqih_downloader_mobile/core/models/youtube_stream_info.dart';
import 'package:faqih_downloader_mobile/core/utils/url_detector.dart';
import 'package:faqih_downloader_mobile/engine/chunk_worker.dart';
import 'package:faqih_downloader_mobile/engine/token_bucket_rate_limiter.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_job_models.dart';
import 'package:faqih_downloader_mobile/services/coordinator/media_post_pipeline.dart';
import 'package:faqih_downloader_mobile/services/coordinator/media_stream_helpers.dart';
import 'package:faqih_downloader_mobile/services/coordinator/ytdlp_stream_downloader.dart';
import 'package:faqih_downloader_mobile/services/media/ffmpeg_media_processor.dart';
import 'package:faqih_downloader_mobile/services/media/media_exceptions.dart';
import 'package:faqih_downloader_mobile/services/media/media_extractor_service.dart';
import 'package:faqih_downloader_mobile/services/media/subtitle_font_provisioner.dart';
import 'package:faqih_downloader_mobile/services/media/subtitle_processor.dart';
import 'package:faqih_downloader_mobile/services/media/tiktok_fallback_extractor.dart';
import 'package:faqih_downloader_mobile/services/resolver/html_candidate_parser.dart';
import 'package:faqih_downloader_mobile/services/resolver/html_download_resolver.dart';
import 'package:faqih_downloader_mobile/services/resolver/smart_url_analyzer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _RealHttpOverrides extends HttpOverrides {}

class _ThrowingUnsupportedExtractor extends MediaExtractorService {
  _ThrowingUnsupportedExtractor({required super.channel});

  @override
  Future<YouTubeStreamInfo> extractInfo(
    String url, {
    String? cookiesFile,
    String? userAgent,
    Map<String, String>? headers,
    String? playlistItems,
    String? processId,
    int timeoutSeconds = 15,
  }) async {
    throw const MediaExtractionException(
      kind: MediaErrorKind.unsupportedUrl,
      message: 'Unsupported URL',
    );
  }
}

class _HardenedTestFfmpeg extends FfmpegMediaProcessor {
  final List<String> softSubOutputs = <String>[];
  final List<bool> clipReencodeFlags = <bool>[];

  @override
  Future<String> muxVideoAndAudio({
    required String videoPath,
    required String audioPath,
    required String outputPath,
    String? audioCodec,
    required String processId,
    double? durationSec,
    void Function(double ratio)? onProgress,
  }) async {
    await File(outputPath).writeAsBytes(const <int>[1, 2, 3, 4], flush: true);
    return outputPath;
  }

  @override
  Future<String> muxSoftSubtitles({
    required String videoPath,
    required String subtitlePath,
    required String outputPath,
    required String languageCode,
    required String processId,
    double? durationSec,
    void Function(double ratio)? onProgress,
  }) async {
    softSubOutputs.add(outputPath);
    if (outputPath.endsWith('.mp4')) {
      throw const MediaProcessingException(
        kind: MediaErrorKind.ffmpegFailed,
        message: 'mov_text not supported in mp4 for this stream',
      );
    }
    await File(outputPath).writeAsBytes(const <int>[5, 6, 7], flush: true);
    return outputPath;
  }

  @override
  Future<String> clipMedia({
    required String inputPath,
    required String outputPath,
    required ClipRange clipRange,
    bool accurateReencode = false,
    required String processId,
    void Function(double ratio)? onProgress,
  }) async {
    clipReencodeFlags.add(accurateReencode);
    if (!accurateReencode) {
      throw const MediaProcessingException(
        kind: MediaErrorKind.ffmpegFailed,
        message: 'stream copy failed on non-keyframe',
      );
    }
    await File(outputPath).writeAsBytes(const <int>[8, 9, 10], flush: true);
    return outputPath;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ytdlMethod = MethodChannel(ChannelNames.youtubeDl);
  const ytdlEvents = EventChannel(ChannelNames.youtubeDlEvents);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fd_b15_test_');
    messenger.setMockStreamHandler(ytdlEvents, MockStreamHandler.inline(onListen: (_, _) {}));
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(ytdlMethod, null);
    messenger.setMockStreamHandler(ytdlEvents, null);
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<T> runWithRealHttp<T>(Future<T> Function() fn) =>
      HttpOverrides.runZoned(fn, createHttpClient: (ctx) => _RealHttpOverrides().createHttpClient(ctx));

  group('Batch 15 full platform & pipeline resilience', () {
    test('1) UrlDetector recognizes modern URLs and 10 newly added media platforms', () {
      const expectedPlatforms = <String, String>{
        'https://www.facebook.com/share/p/1AbCdEfGh/': 'Facebook',
        'https://www.facebook.com/share/1XyZ987/': 'Facebook',
        'https://www.facebook.com/groups/flutterdev/posts/1234567890/': 'Facebook',
        'https://www.threads.com/@user/post/C123456789': 'Threads',
        'https://clips.twitch.tv/FunClipSlug123': 'Twitch',
        'https://www.twitch.tv/streamer/clip/AwesomeClip99': 'Twitch',
        'https://www.youtube.com/clip/UgkxClipId12345': 'YouTube',
        'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ': 'YouTube',
        'https://fxtwitter.com/user/status/1800000000000000000': 'Twitter / X',
        'https://vxtwitter.com/user/status/1800000000000000000': 'Twitter / X',
        'https://x.com/i/broadcasts/1ZkKzAbCdEf': 'Twitter / X',
        'https://soundcloud.com/artist/track-name': 'SoundCloud',
        'https://on.soundcloud.com/abc123XYZ': 'SoundCloud',
        'https://www.bilibili.com/video/BV1xx411c7mD': 'Bilibili',
        'https://b23.tv/abc123': 'Bilibili',
        'https://vk.com/video-12345_67890': 'VK',
        'https://vkvideo.ru/video-12345_67890': 'VK',
        'https://kick.com/streamer/clips/clip_123': 'Kick',
        'https://streamable.com/abc123': 'Streamable',
        'https://ok.ru/video/1234567890': 'OK.ru',
        'https://likee.video/@user/video/123456': 'Likee',
        'https://www.ted.com/talks/sir_ken_robinson_do_schools_kill_creativity': 'TED',
        'https://odysee.com/@channel:1/video-title:2': 'Odysee',
        'https://artist.bandcamp.com/track/amazing-song': 'Bandcamp',
      };

      for (final entry in expectedPlatforms.entries) {
        expect(UrlDetector.isMediaUrl(entry.key), isTrue, reason: entry.key);
        expect(
          UrlDetector.extractMediaPlatform(entry.key),
          entry.value,
          reason: entry.key,
        );
      }
      expect(UrlDetector.extractYouTubeId('https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
      expect(UrlDetector.extractYouTubeId('https://www.youtube.com/clip/UgkxClipId12345'), isNull);
    });

    test('2) canTryTurbo rejects silent video-only without audio URL; minAcceptableHeightFor accepts 21:9 cinema', () {
      const silentVideoReq = DownloadJobRequest(
        id: 'silent_1',
        url: 'https://www.reddit.com/r/videos/comments/abc/test/',
        title: 'Silent Guard',
        selectedVideoFormat: VideoFormatOption(
          formatId: 'dash_v',
          resolutionLabel: '1080p',
          height: 1080,
          isProgressive: false,
          videoUrl: 'https://v.redd.it/abc/DASH_1080.mp4',
          audioUrl: null,
        ),
      );
      expect(
        MediaStreamHelpers.canTryTurbo(
          silentVideoReq,
          silentVideoReq.selectedVideoFormat,
          null,
        ),
        isFalse,
      );

      expect(MediaStreamHelpers.minAcceptableHeightFor(2160), 1500);
      expect(MediaStreamHelpers.minAcceptableHeightFor(1440), 1100);
      expect(MediaStreamHelpers.minAcceptableHeightFor(1080), 780);
      expect(MediaStreamHelpers.minAcceptableHeightFor(720), 520);
      expect(MediaStreamHelpers.minAcceptableHeightFor(480), 400);

      const cinemaInfo = YouTubeStreamInfo(
        videoId: 'cin1',
        title: 'Cinema 21:9',
        cleanFilename: 'Cinema.mp4',
        isProgressive: false,
        videoUrl: 'https://cdn.example.com/536.mp4',
        videoFormats: <VideoFormatOption>[
          VideoFormatOption(formatId: 'c720', resolutionLabel: '720p', height: 536, vcodec: 'avc1', videoUrl: 'https://cdn.example.com/536.mp4'),
          VideoFormatOption(formatId: 'c480', resolutionLabel: '480p', height: 480, vcodec: 'avc1', videoUrl: 'https://cdn.example.com/480.mp4'),
          VideoFormatOption(formatId: 'c360', resolutionLabel: '360p', height: 360, vcodec: 'avc1', videoUrl: 'https://cdn.example.com/360.mp4'),
        ],
      );
      expect(
        MediaStreamHelpers.pickInnerTubeFormat(cinemaInfo, 720, strictHeight: true)?.formatId,
        'c720',
      );
      expect(
        MediaStreamHelpers.pickInnerTubeFormat(cinemaInfo, 1080, strictHeight: true),
        isNull,
      );

      const cinema1080Info = YouTubeStreamInfo(
        videoId: 'cin2',
        title: 'Cinema 1080',
        cleanFilename: 'Cinema1080.mp4',
        isProgressive: false,
        videoUrl: 'https://cdn.example.com/804.mp4',
        videoFormats: <VideoFormatOption>[
          VideoFormatOption(formatId: 'c1080', resolutionLabel: '1080p', height: 804, vcodec: 'avc1', videoUrl: 'https://cdn.example.com/804.mp4'),
          VideoFormatOption(formatId: 'c720', resolutionLabel: '720p', height: 720, vcodec: 'avc1', videoUrl: 'https://cdn.example.com/720.mp4'),
        ],
      );
      expect(
        MediaStreamHelpers.pickInnerTubeFormat(cinema1080Info, 1080, strictHeight: true)?.formatId,
        'c1080',
      );
    });

    test('3) YtDlpStreamDownloader strips conflicting headers and TikTokFallbackExtractor honors onRegisterAbort', () async {
      final nonYtWithCookie = YtDlpStreamDownloader.buildSafeHeaders(
        const <String, String>{
          'Host': 'example.com',
          'Content-Length': '999',
          'Accept-Encoding': 'gzip',
          'Range': 'bytes=0-100',
          'Connection': 'keep-alive',
          'User-Agent': 'CustomUA/1.0',
          'Cookie': 'sid=abc',
          'Referer': 'https://www.tiktok.com/',
        },
        isYouTube: false,
        hasCookieFile: true,
      );
      expect(nonYtWithCookie, <String>['User-Agent:CustomUA/1.0', 'Referer:https://www.tiktok.com/']);

      final ytNoCookie = YtDlpStreamDownloader.buildSafeHeaders(
        const <String, String>{
          'User-Agent': 'CustomUA/1.0',
          'Cookie': 'sid=abc',
          'Referer': 'https://www.youtube.com/',
        },
        isYouTube: true,
        hasCookieFile: false,
      );
      expect(ytNoCookie, <String>['Cookie:sid=abc', 'Referer:https://www.youtube.com/']);

      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final started = Completer<void>();
        server.listen((req) async {
          if (!started.isCompleted) started.complete();
          await Future<void>.delayed(const Duration(seconds: 5));
          try {
            await req.response.close();
          } catch (_) {}
        });

        final tt = TikTokFallbackExtractor(
          httpClientFactory: () => _RealHttpOverrides().createHttpClient(null),
          timeout: const Duration(seconds: 5),
        );
        void Function()? abortFn;
        final fut = tt.extract(
          'http://127.0.0.1:${server.port}/@user/video/1',
          onRegisterAbort: (fn) => abortFn = fn,
        );
        await started.future;
        final sw = Stopwatch()..start();
        abortFn?.call();
        final res = await fut;
        sw.stop();
        expect(res, isNull);
        expect(sw.elapsedMilliseconds, lessThan(1500));
      });
    });

    test('4) ChunkWorker stallTimeout aborts stalled stream and recovers on retry', () async {
      await runWithRealHttp(() async {
        final payload = List<int>.generate(256, (i) => i & 0xff);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var reqCount = 0;
        final seenRanges = <String?>[];

        server.listen((req) async {
          reqCount++;
          seenRanges.add(req.headers.value(HttpHeaders.rangeHeader));
          req.response.headers.contentType = ContentType.binary;
          if (reqCount == 1) {
            req.response.bufferOutput = false;
            req.response.statusCode = HttpStatus.partialContent;
            req.response.headers.set('Content-Range', 'bytes 0-255/256');
            req.response.contentLength = 256;
            req.response.add(payload.sublist(0, 64));
            await req.response.flush();
            await Future<void>.delayed(const Duration(seconds: 3));
            try {
              await req.response.close();
            } catch (_) {}
            return;
          }
          final rangeHeader = req.headers.value(HttpHeaders.rangeHeader) ?? 'bytes=0-255';
          final start = int.parse(rangeHeader.substring(6).split('-').first);
          final slice = payload.sublist(start);
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set('Content-Range', 'bytes $start-255/256');
          req.response.contentLength = slice.length;
          req.response.add(slice);
          await req.response.close();
        });

        final partPath = p.join(tempDir.path, 'stall.part');
        var chunk = DownloadChunk(
          chunkId: 0,
          startByte: 0,
          endByte: 255,
          partFilepath: partPath,
        );
        final client = _RealHttpOverrides().createHttpClient(null);
        addTearDown(() => client.close(force: true));

        await ChunkWorker().run(
          httpClient: client,
          url: 'http://127.0.0.1:${server.port}/file.bin',
          headers: const <String, String>{},
          supportsRanges: true,
          readChunk: () => chunk,
          updateChunk: (u) => chunk = u(chunk),
          rateLimiter: TokenBucketRateLimiter(bytesPerSec: 0),
          onBytesWritten: (_) {},
          isPaused: () => false,
          isCancelled: () => false,
          registerAborter: (_) {},
          unregisterAborter: (_) {},
          stallTimeout: const Duration(milliseconds: 400),
          maxRetries: 2,
        );

        expect(reqCount, 2, reason: 'ranges=$seenRanges');
        expect(seenRanges, <String?>['bytes=0-255', 'bytes=64-255']);
        expect(chunk.isCompleted, isTrue);
        expect(File(partPath).readAsBytesSync(), payload);
      });
    });

    test('5) rewriteKnownDirectHostUrl rewrites Drive/Dropbox/GitHub and SmartUrlAnalyzer surfaces real resolverError', () async {
      expect(
        HtmlCandidateParser.rewriteKnownDirectHostUrl(
          Uri.parse('https://drive.google.com/file/d/1AbCdEfGhIjK/view?usp=sharing'),
        ),
        'https://drive.usercontent.google.com/download?id=1AbCdEfGhIjK&export=download&confirm=t',
      );
      expect(
        HtmlCandidateParser.rewriteKnownDirectHostUrl(
          Uri.parse('https://drive.google.com/open?id=XYZ_987'),
        ),
        'https://drive.usercontent.google.com/download?id=XYZ_987&export=download&confirm=t',
      );
      expect(
        HtmlCandidateParser.rewriteKnownDirectHostUrl(
          Uri.parse('https://www.dropbox.com/s/abc123/test.zip?dl=0'),
        ),
        'https://www.dropbox.com/s/abc123/test.zip?dl=1',
      );
      expect(
        HtmlCandidateParser.rewriteKnownDirectHostUrl(
          Uri.parse('https://www.dropbox.com/scl/fi/abc/doc.pdf'),
        ),
        'https://www.dropbox.com/scl/fi/abc/doc.pdf?dl=1',
      );
      expect(
        HtmlCandidateParser.rewriteKnownDirectHostUrl(
          Uri.parse('https://github.com/owner/repo/blob/main/dir/tool.zip'),
        ),
        'https://raw.githubusercontent.com/owner/repo/main/dir/tool.zip',
      );

      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
        });

        final analyzer = SmartUrlAnalyzer(
          extractor: _ThrowingUnsupportedExtractor(
            channel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
          ),
          htmlResolver: HtmlDownloadResolver(
            httpClientFactory: () => _RealHttpOverrides().createHttpClient(null),
          ),
        );

        await expectLater(
          analyzer.analyze('http://127.0.0.1:${server.port}/protected-page', processId: 'p_real_403'),
          throwsA(isA<HttpException>()),
        );
      });
    });

    test('6) MediaPostPipeline cleans raw streams, falls back softsub->mkv and clip->reencode, and SubtitleProcessor follows redirects', () async {
      await runWithRealHttp(() async {
        final subServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => subServer.close(force: true));
        final subBase = 'http://127.0.0.1:${subServer.port}';
        subServer.listen((req) async {
          if (req.uri.path == '/sub-start') {
            req.response.statusCode = HttpStatus.movedTemporarily;
            req.response.cookies.add(Cookie('sub_ck', 'ok'));
            req.response.headers.set(HttpHeaders.locationHeader, '/sub.vtt');
            await req.response.close();
            return;
          }
          final cookie = req.headers.value(HttpHeaders.cookieHeader) ?? '';
          if (!cookie.contains('sub_ck=ok')) {
            req.response.statusCode = HttpStatus.forbidden;
            await req.response.close();
            return;
          }
          req.response.headers.contentType = ContentType.text;
          req.response.write('WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHello world\n');
          await req.response.close();
        });

        final jobDir = p.join(tempDir.path, 'pipe_hard');
        await Directory(jobDir).create(recursive: true);
        final rawVid = File(p.join(jobDir, 'raw_video.mp4'))..writeAsBytesSync(<int>[1, 2, 3]);
        final rawAud = File(p.join(jobDir, 'raw_audio.m4a'))..writeAsBytesSync(<int>[4, 5, 6]);

        final fakeFfmpeg = _HardenedTestFfmpeg();
        final pipeline = MediaPostPipeline(
          ffmpeg: fakeFfmpeg,
          subtitleProcessor: SubtitleProcessor(
            httpClientFactory: () => _RealHttpOverrides().createHttpClient(null),
          ),
          fontProvisioner: SubtitleFontProvisioner(),
        );

        final res = await pipeline.process(
          request: DownloadJobRequest(
            id: 'b15_pipe',
            url: 'https://example.com/v',
            title: 'Hardened Video',
            clipRange: const ClipRange(startSec: 2, endSec: 8),
            subtitleMode: SubtitleMode.softMux,
            selectedSubtitle: SubtitleTrack(
              subId: 'en',
              language: 'en',
              label: 'English',
              url: '$subBase/sub-start',
              ext: 'vtt',
            ),
            selectedVideoFormat: const VideoFormatOption(
              formatId: '137',
              resolutionLabel: '1080p',
              ext: 'mp4',
              vcodec: 'avc1',
            ),
          ),
          jobDir: jobDir,
          workDir: tempDir.path,
          rawVideoPath: rawVid.path,
          rawAudioPath: rawAud.path,
          isCancelled: () => false,
          onPhase: (_, {progress}) {},
          onTrackProcess: (_) {},
        );

        expect(rawVid.existsSync(), isFalse);
        expect(rawAud.existsSync(), isFalse);
        expect(fakeFfmpeg.clipReencodeFlags, <bool>[false, true]);
        expect(fakeFfmpeg.softSubOutputs.length, 2);
        expect(fakeFfmpeg.softSubOutputs[0], endsWith('stage_softsub.mp4'));
        expect(fakeFfmpeg.softSubOutputs[1], endsWith('stage_softsub.mkv'));
        expect(res.ext, 'mkv');
        expect(res.filePath, endsWith('stage_softsub.mkv'));
      });
    });
  });
}
