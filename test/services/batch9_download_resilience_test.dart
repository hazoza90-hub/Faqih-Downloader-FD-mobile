import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:faqih_downloader_mobile/core/models/audio_track.dart';
import 'package:faqih_downloader_mobile/core/models/download_status.dart';
import 'package:faqih_downloader_mobile/core/models/video_format_option.dart';
import 'package:faqih_downloader_mobile/core/utils/url_detector.dart';
import 'package:faqih_downloader_mobile/engine/engine_callbacks.dart';
import 'package:faqih_downloader_mobile/engine/isolate_download_runner.dart';
import 'package:faqih_downloader_mobile/engine/server_prober.dart';
import 'package:faqih_downloader_mobile/engine/turbo_download_engine.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_job_models.dart';
import 'package:faqih_downloader_mobile/services/coordinator/media_post_pipeline.dart';
import 'package:faqih_downloader_mobile/services/coordinator/media_stream_acquirer.dart';
import 'package:faqih_downloader_mobile/services/media/ffmpeg_media_processor.dart';
import 'package:faqih_downloader_mobile/services/media/format_ranker.dart';
import 'package:faqih_downloader_mobile/services/media/media_exceptions.dart';
import 'package:faqih_downloader_mobile/services/media/media_extractor_service.dart';
import 'package:faqih_downloader_mobile/services/media/subtitle_font_provisioner.dart';
import 'package:faqih_downloader_mobile/services/media/subtitle_processor.dart';
import 'package:faqih_downloader_mobile/services/resolver/html_candidate_parser.dart';
import 'package:faqih_downloader_mobile/services/resolver/html_download_resolver.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../engine/mock_range_server.dart';

class _StubRunner extends IsolateDownloadRunner {
  _StubRunner({
    required super.url,
    required super.destinationPath,
    super.headers,
    super.maxConnections,
    super.speedLimitBytesPerSec,
    super.callbacks,
    required this.onRun,
  });

  final Future<void> Function(_StubRunner runner) onRun;
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get completion => _done.future;

  @override
  Future<void> start() async {
    try {
      await onRun(this);
    } finally {
      if (!_done.isCompleted) _done.complete();
    }
  }
}

class _MuxFallbackFfmpeg extends FfmpegMediaProcessor {
  final List<String> requestedOutputs = <String>[];

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
    requestedOutputs.add(outputPath);
    if (outputPath.endsWith('.mp4')) {
      throw const MediaProcessingException(
        kind: MediaErrorKind.ffmpegFailed,
        message: 'Could not write header for output file: vp9 in mp4 unsupported',
      );
    }
    await File(outputPath).writeAsBytes(const <int>[1, 2, 3, 4], flush: true);
    return outputPath;
  }
}

class _RealHttpOverrides extends HttpOverrides {}

Future<T> _withRealHttp<T>(Future<T> Function() action) =>
    HttpOverrides.runZoned<Future<T>>(
      action,
      createHttpClient: (ctx) => _RealHttpOverrides().createHttpClient(ctx),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ytdlMethod = MethodChannel(ChannelNames.youtubeDl);
  const ytdlEvents = EventChannel(ChannelNames.youtubeDlEvents);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fd_batch9_test_');
    messenger.setMockStreamHandler(
      ytdlEvents,
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(ytdlMethod, null);
    messenger.setMockStreamHandler(ytdlEvents, null);
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Batch 9 download resilience', () {
    test('MediaStreamAcquirer falls back to yt-dlp on non-403 Turbo error, cleans parts, injects cookies, and blocks HLS audioOnly', () async {
      final cookiesFile = File(p.join(tempDir.path, 'cookies.txt'));
      final futureExpiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      await cookiesFile.writeAsString(
        '.cdn.example.com\tTRUE\t/\tTRUE\t$futureExpiry\tsession_id\tabc123\n',
      );

      final jobDir = p.join(tempDir.path, 'job_fallback');
      await Directory(jobDir).create(recursive: true);

      var dlCalled = 0;
      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'downloadMedia') {
          dlCalled++;
          final outFile = File(p.join(jobDir, 'ytdlp_v1.mp4'));
          await outFile.writeAsBytes(const <int>[9, 8, 7]);
          return <String, Object?>{'exitCode': 0, 'stdout': 'ok', 'stderr': ''};
        }
        return null;
      });

      Map<String, String> capturedHeaders = const <String, String>{};
      final acquirer = MediaStreamAcquirer(
        youtubeDl: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
        runnerFactory: ({
          required String url,
          required String destinationPath,
          Map<String, String> headers = const <String, String>{},
          int maxConnections = 4,
          double speedLimitBytesPerSec = 0.0,
          EngineCallbacks? callbacks,
        }) {
          capturedHeaders = headers;
          return _StubRunner(
            url: url,
            destinationPath: destinationPath,
            headers: headers,
            maxConnections: maxConnections,
            speedLimitBytesPerSec: speedLimitBytesPerSec,
            callbacks: callbacks,
            onRun: (r) async {
              await File(destinationPath).writeAsBytes(const <int>[0, 1]);
              r.callbacks?.onError?.call(
                Exception('Server ignored Range header (HTTP 500)'),
                linkExpired: false,
                httpStatus: 500,
              );
            },
          );
        },
      );

      const directFmt = VideoFormatOption(
        formatId: '22',
        resolutionLabel: '720p',
        height: 720,
        ext: 'mp4',
        isProgressive: true,
        videoUrl: 'https://video.cdn.example.com/clip.mp4',
      );
      final req = DownloadJobRequest(
        id: 'job_b9_1',
        url: 'https://example.com/watch?v=1',
        title: 'Clip',
        selectedVideoFormat: directFmt,
        cookiesFile: cookiesFile.path,
      );

      final res = await acquirer.acquireMedia(
        request: req,
        jobDir: jobDir,
        speedLimitBytesPerSec: 0,
        isCancelled: () => false,
        isPaused: () => false,
        setActiveRunner: (_) {},
        setActiveProcessId: (_) {},
        setActivePhase: (_) {},
        onTurboProgress: (_, _) {},
        onYtDlpProgress: (_, _, _) {},
      );

      expect(dlCalled, 1);
      expect(res.videoPath, endsWith('ytdlp_v1.mp4'));
      expect(capturedHeaders['Cookie'], contains('session_id=abc123'));
      expect(File(p.join(jobDir, 'raw_video.mp4')).existsSync(), isFalse);

      // HLS/DASH audioOnly must never hit Turbo:
      final hlsAudioReq = DownloadJobRequest(
        id: 'job_hls_aud',
        url: 'https://example.com/watch?v=2',
        title: 'HLS Audio',
        audioOnly: true,
        selectedVideoFormat: const VideoFormatOption(
          formatId: 'hls-1',
          resolutionLabel: '1080p',
          protocol: 'm3u8_native',
          videoUrl: 'https://cdn.example.com/manifest/hls/master.m3u8',
        ),
        selectedAudioTrack: const AudioTrack(
          trackId: 'ar_orig',
          formatId: 'aud-1',
          language: 'ar',
          label: 'Arabic',
          url: 'https://cdn.example.com/manifest/dash/audio.mpd',
          ext: 'm4a',
          codec: 'mp4a',
          bitrateKbps: 128,
          isOriginal: true,
        ),
      );
      expect(
        MediaStreamAcquirer.canTryTurbo(
          hlsAudioReq,
          hlsAudioReq.selectedVideoFormat,
          hlsAudioReq.selectedAudioTrack,
        ),
        isFalse,
      );
    });

    test('FormatRanker unwraps single entries, builds from raw url, accepts codec-less formats, and passes cookies', () {
      const ranker = FormatRanker();

      // 1. Single-entry carousel/social post -> unwrapped as single video:
      final singleEntryInfo = ranker.parse(<String, dynamic>{
        '_type': 'playlist',
        'id': 'ig_post_1',
        'title': 'Social Post Clip',
        'cookies': 'csrftoken=xyz; sessionid=abc',
        'entries': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'ig_clip_1',
            'url': 'https://cdn.example.com/social.mp4',
            'ext': 'mp4',
          },
        ],
      });
      expect(singleEntryInfo.isPlaylist, isFalse);
      expect(singleEntryInfo.videoFormats, isNotEmpty);
      expect(singleEntryInfo.videoFormats.first.isProgressive, isTrue);
      expect(
        singleEntryInfo.videoFormats.first.videoHeaders['Cookie'],
        'csrftoken=xyz; sessionid=abc',
      );

      // 2. Direct single-URL payload without formats array & codec-less format + map cookies:
      final directInfo = ranker.parse(<String, dynamic>{
        'id': 'direct_vid',
        'title': 'Direct Stream',
        'url': 'https://cdn.example.com/stream.mp4',
        'ext': 'mp4',
        'cookies': <String, String>{'auth': 'tok_1'},
      });
      expect(directInfo.videoFormats.length, 1);
      expect(directInfo.videoFormats.first.videoUrl, 'https://cdn.example.com/stream.mp4');
      expect(directInfo.videoFormats.first.isProgressive, isTrue);
      expect(directInfo.videoFormats.first.videoHeaders['Cookie'], 'auth=tok_1');

      // Audio-only format (vcodec: none) still rejected from videoFormats:
      final mixedInfo = ranker.parse(<String, dynamic>{
        'id': 'mix',
        'title': 'Mixed',
        'formats': <Map<String, dynamic>>[
          <String, dynamic>{
            'format_id': 'aud',
            'ext': 'm4a',
            'vcodec': 'none',
            'acodec': 'mp4a',
            'url': 'https://cdn.example.com/a.m4a',
          },
          <String, dynamic>{
            'format_id': 'no_codec_vid',
            'ext': 'mp4',
            'url': 'https://cdn.example.com/v.mp4',
          },
        ],
      });
      expect(mixedInfo.videoFormats.map((f) => f.formatId).toList(), <String>['no_codec_vid']);
    });

    test('TurboDownloadEngine falls back to single-stream on ignored Range (200) and HTTP 429', () => _withRealHttp(() async {
      final payload = generateTestPayload(256 * 1024, seed: 99);
      final expectedSha = sha256HexOf(payload);

      // Case A: Server claims Accept-Ranges: bytes on HEAD & ignores Range on non-zero chunks (HTTP 200)
      final serverA = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(serverA.close);
      serverA.listen((req) async {
        req.response.headers.contentType = ContentType.binary;
        req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        if (req.method == 'HEAD') {
          req.response.contentLength = payload.length;
          await req.response.close();
          return;
        }
        final range = req.headers.value(HttpHeaders.rangeHeader);
        if (range == 'bytes=0-0') {
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-0/${payload.length}',
          );
          req.response.contentLength = 1;
          req.response.add(<int>[payload[0]]);
          await req.response.close();
          return;
        }
        // Returns 200 OK full payload for ALL GETs (even non-zero offset chunks!):
        req.response.statusCode = HttpStatus.ok;
        req.response.contentLength = payload.length;
        req.response.add(payload);
        await req.response.close();
      });

      final destA = p.join(tempDir.path, 'ignored_range.bin');
      final engineA = TurboDownloadEngine(
        url: 'http://127.0.0.1:${serverA.port}/ignored_range.bin',
        destinationPath: destA,
        maxConnections: 4,
        minSplitThreshold: 32 * 1024,
        expectedSha256: expectedSha,
      );
      await engineA.start();
      expect(engineA.status, DownloadStatus.completed);
      expect(sha256HexOf(File(destA).readAsBytesSync()), expectedSha);

      // Case B: Server returns HTTP 429 on multi-range chunks, succeeds on non-Range single-stream GET
      final serverB = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(serverB.close);
      serverB.listen((req) async {
        req.response.headers.contentType = ContentType.binary;
        req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        if (req.method == 'HEAD') {
          req.response.contentLength = payload.length;
          await req.response.close();
          return;
        }
        final range = req.headers.value(HttpHeaders.rangeHeader);
        if (range == 'bytes=0-0') {
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-0/${payload.length}',
          );
          req.response.contentLength = 1;
          req.response.add(<int>[payload[0]]);
          await req.response.close();
          return;
        }
        if (range != null) {
          req.response.statusCode = 429;
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.ok;
        req.response.contentLength = payload.length;
        req.response.add(payload);
        await req.response.close();
      });

      final destB = p.join(tempDir.path, 'rate_limited.bin');
      final engineB = TurboDownloadEngine(
        url: 'http://127.0.0.1:${serverB.port}/rate_limited.bin',
        destinationPath: destB,
        maxConnections: 4,
        minSplitThreshold: 32 * 1024,
        expectedSha256: expectedSha,
      );
      await engineB.start();
      expect(engineB.status, DownloadStatus.completed);
      expect(engineB.chunks.length, 1);
      expect(sha256HexOf(File(destB).readAsBytesSync()), expectedSha);
    }));

    test('ServerProber and TurboDownloadEngine preserve Set-Cookie across 302 redirects', () => _withRealHttp(() async {
      final payload = generateTestPayload(128 * 1024, seed: 77);
      final expectedSha = sha256HexOf(payload);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final base = 'http://127.0.0.1:${server.port}';
      final chunkCookiesSeen = <String>[];

      server.listen((req) async {
        if (req.uri.path == '/entry') {
          req.response.statusCode = HttpStatus.movedTemporarily;
          req.response.cookies.add(Cookie('step1', 's1'));
          req.response.headers.set(HttpHeaders.locationHeader, '/hop2');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/hop2') {
          final cookie = req.headers.value(HttpHeaders.cookieHeader) ?? '';
          if (!cookie.contains('step1=s1')) {
            req.response.statusCode = HttpStatus.forbidden;
            await req.response.close();
            return;
          }
          req.response.statusCode = HttpStatus.movedTemporarily;
          req.response.cookies.add(Cookie('step2', 's2'));
          req.response.headers.set(HttpHeaders.locationHeader, '/cdn.bin');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/cdn.bin') {
          final cookie = req.headers.value(HttpHeaders.cookieHeader) ?? '';
          if (!cookie.contains('step1=s1') || !cookie.contains('step2=s2')) {
            req.response.statusCode = HttpStatus.forbidden;
            await req.response.close();
            return;
          }
          chunkCookiesSeen.add(cookie);
          req.response.headers.contentType = ContentType.binary;
          req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          if (req.method == 'HEAD') {
            req.response.contentLength = payload.length;
            await req.response.close();
            return;
          }
          final range = req.headers.value(HttpHeaders.rangeHeader);
          if (range != null && range.startsWith('bytes=')) {
            final parts = range.substring(6).split('-');
            final start = int.parse(parts[0]);
            final end = int.parse(parts[1]);
            req.response.statusCode = HttpStatus.partialContent;
            req.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${payload.length}',
            );
            req.response.contentLength = end - start + 1;
            req.response.add(payload.sublist(start, end + 1));
            await req.response.close();
            return;
          }
          req.response.statusCode = HttpStatus.ok;
          req.response.contentLength = payload.length;
          req.response.add(payload);
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });

      final probe = await ServerProber().probe('$base/entry');
      expect(probe.finalUrl, '$base/cdn.bin');
      expect(probe.cookieHeader, contains('step1=s1'));
      expect(probe.cookieHeader, contains('step2=s2'));

      final dest = p.join(tempDir.path, 'cookie_redirect.bin');
      final engine = TurboDownloadEngine(
        url: '$base/entry',
        destinationPath: dest,
        maxConnections: 2,
        minSplitThreshold: 32 * 1024,
        expectedSha256: expectedSha,
      );
      await engine.start();

      expect(engine.status, DownloadStatus.completed);
      expect(sha256HexOf(File(dest).readAsBytesSync()), expectedSha);
      expect(
        chunkCookiesSeen.every((c) => c.contains('step1=s1') && c.contains('step2=s2')),
        isTrue,
      );
    }));

    test('HtmlDownloadResolver probes >3 candidates, falls back to plain GET when Range rejected, and forwards UA; HtmlCandidateParser parses apks/form/iframe/json', () => _withRealHttp(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final base = 'http://127.0.0.1:${server.port}';

      server.listen((req) async {
        if (req.uri.path == '/gate') {
          req.response.headers.contentType = ContentType.html;
          req.response.write('''
            <html><body>
              <a href="/dead1.apk" download>Dead 1</a>
              <a href="/dead2.apk" download>Dead 2</a>
              <a href="/dead3.apk" download>Dead 3</a>
              <a href="/dead4.apk" download>Dead 4</a>
              <a href="/real5.apk">APK 5</a>
            </body></html>
          ''');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/real5.apk') {
          if (req.method == 'HEAD') {
            req.response.statusCode = HttpStatus.methodNotAllowed;
            await req.response.close();
            return;
          }
          if (req.headers.value(HttpHeaders.rangeHeader) != null) {
            req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            await req.response.close();
            return;
          }
          req.response.headers.contentType =
              ContentType.parse('application/vnd.android.package-archive');
          req.response.headers.set('Content-Length', '256');
          req.response.add(List<int>.filled(256, 5));
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });

      final res = await HtmlDownloadResolver().resolve('$base/gate');
      expect(res.url, '$base/real5.apk');
      expect(res.filename, 'real5.apk');
      expect(res.headers['User-Agent'], HtmlDownloadResolver.browserUserAgent);

      final extracted = HtmlCandidateParser.extractCandidates(
        '''
        <form action="https://cdn.example.com/step/bundle.apks" method="post"></form>
        <iframe src="https://cdn.example.com/dl/embed_file.obb"></iframe>
        <script>{"download_url":"https://cdn.example.com/mirror/app.ipa"}</script>
        ''',
        Uri.parse('https://example.org/app'),
      );
      expect(
        extracted,
        containsAll(<String>[
          'https://cdn.example.com/step/bundle.apks',
          'https://cdn.example.com/dl/embed_file.obb',
          'https://cdn.example.com/mirror/app.ipa',
        ]),
      );
    }));

    test('MediaPostPipeline falls back from .mp4 to .mkv when MP4 mux fails', () async {
      final jobDir = p.join(tempDir.path, 'job_mkv');
      await Directory(jobDir).create(recursive: true);
      final rawVid = File(p.join(jobDir, 'raw_video.mp4'))..writeAsBytesSync(<int>[1, 2]);
      final rawAud = File(p.join(jobDir, 'raw_audio.webm'))..writeAsBytesSync(<int>[3, 4]);

      final fakeFfmpeg = _MuxFallbackFfmpeg();
      final pipeline = MediaPostPipeline(
        ffmpeg: fakeFfmpeg,
        subtitleProcessor: SubtitleProcessor(),
        fontProvisioner: SubtitleFontProvisioner(),
      );

      final result = await pipeline.process(
        request: const DownloadJobRequest(
          id: 'mkv_job',
          url: 'https://example.com/v',
          title: 'MKV Fallback Video',
        ),
        jobDir: jobDir,
        workDir: tempDir.path,
        rawVideoPath: rawVid.path,
        rawAudioPath: rawAud.path,
        isCancelled: () => false,
        onPhase: (_, {progress}) {},
        onTrackProcess: (_) {},
      );

      expect(fakeFfmpeg.requestedOutputs.length, 2);
      expect(fakeFfmpeg.requestedOutputs[0], endsWith('stage_mux.mp4'));
      expect(fakeFfmpeg.requestedOutputs[1], endsWith('stage_mux.mkv'));
      expect(result.ext, 'mkv');
      expect(result.filePath, endsWith('stage_mux.mkv'));
    });

    test('MediaExtractorService runs once-per-session yt-dlp auto-update and YouTube client fallback; UrlDetector matches playlists and short links', () async {
      var updateCalls = 0;
      var updatedOnce = false;
      final seenExtractorArgs = <Object?>[];

      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'updateYoutubeDL') {
          updateCalls++;
          updatedOnce = true;
          return <String, Object?>{'status': 'DONE', 'ytdlpVersion': '2026.11.24'};
        }
        if (call.method == 'extractInfo') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          seenExtractorArgs.add(args['extractorArgs']);
          if (!updatedOnce) {
            throw PlatformException(code: 'YOUTUBEDL_ERROR', message: 'HTTP Error 403: Forbidden');
          }
          return jsonEncode(<String, dynamic>{
            'id': 'yt_pl_ok',
            'title': 'Recovered After Update',
            'formats': <Map<String, dynamic>>[
              <String, dynamic>{
                'format_id': '22',
                'url': 'https://cdn.example.com/ok.mp4',
                'ext': 'mp4',
                'vcodec': 'avc1',
                'acodec': 'mp4a',
                'height': 720,
              },
            ],
          });
        }
        return null;
      });

      final extractor = MediaExtractorService(
        channel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
      );

      final ok = await extractor.extractInfo('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      expect(ok.title, 'Recovered After Update');
      expect(updateCalls, 1);
      expect(seenExtractorArgs.take(3).toList(), <Object?>[
        null,
        '',
        'youtube:player_client=mweb,web_safari,ios',
      ]);

      // Subsequent permanent failure in same session must NOT trigger updateYoutubeDL again:
      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'updateYoutubeDL') {
          updateCalls++;
          return <String, Object?>{'status': 'DONE', 'ytdlpVersion': '2026.11.25'};
        }
        throw PlatformException(code: 'YOUTUBEDL_ERROR', message: 'Unsupported URL');
      });
      await expectLater(
        extractor.extractInfo('https://www.instagram.com/reel/abc123/'),
        throwsA(isA<MediaExtractionException>()),
      );
      expect(updateCalls, 1);

      expect(
        UrlDetector.isYouTubeUrl('https://www.youtube.com/playlist?list=PL_123456'),
        isTrue,
      );
      expect(
        UrlDetector.isMediaUrl('https://www.youtube.com/playlist?list=PL_123456'),
        isTrue,
      );
      expect(UrlDetector.isMediaUrl('https://fb.me/abcd1234'), isTrue);
      expect(UrlDetector.isMediaUrl('https://m.facebook.com/story.php?story_fbid=12345&id=1'), isTrue);
      expect(UrlDetector.isMediaUrl('https://x.com/i/status/189000111222'), isTrue);
    });
  });
}
