import 'dart:convert';
import 'dart:io';

import 'package:faqih_downloader_mobile/core/i18n/translator.dart';
import 'package:faqih_downloader_mobile/core/models/download_status.dart';
import 'package:faqih_downloader_mobile/core/models/video_format_option.dart';
import 'package:faqih_downloader_mobile/engine/turbo_download_engine.dart';
import 'package:faqih_downloader_mobile/features/home/download_job_card.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/media_store_channel.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_job_models.dart';
import 'package:faqih_downloader_mobile/services/coordinator/stream_download_coordinator.dart';
import 'package:faqih_downloader_mobile/services/coordinator/ytdlp_stream_downloader.dart';
import 'package:faqih_downloader_mobile/services/media/media_exceptions.dart';
import 'package:faqih_downloader_mobile/services/media/media_extractor_service.dart';
import 'package:faqih_downloader_mobile/services/media/tiktok_fallback_extractor.dart';
import 'package:faqih_downloader_mobile/services/media/youtube_innertube_extractor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ytdlMethod = MethodChannel(ChannelNames.youtubeDl);
  const ytdlEvents = EventChannel(ChannelNames.youtubeDlEvents);
  const mediaStoreMethod = MethodChannel(ChannelNames.mediaStore);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fd_b11_test_');
    messenger.setMockStreamHandler(ytdlEvents, MockStreamHandler.inline(onListen: (_, _) {}));
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(ytdlMethod, null);
    messenger.setMockMethodCallHandler(mediaStoreMethod, null);
    messenger.setMockStreamHandler(ytdlEvents, null);
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<T> runWithRealHttp<T>(Future<T> Function() fn) =>
      HttpOverrides.runZoned(fn, createHttpClient: (ctx) => _RealHttpOverrides().createHttpClient(ctx));

  group('Batch 11 live progress, fast-fail, and extraction speed', () {
    test('1) parses real yt-dlp lines and propagates downloaded/total/speed through StreamDownloadCoordinator', () async {
      final s1 = YtDlpStreamDownloader.parseProgressLine(
        '[download]  23.5% of   45.20MiB at    2.34MiB/s ETA 00:15',
      );
      expect(s1.progress, closeTo(0.235, 0.001));
      expect(s1.totalBytes, (45.20 * 1024 * 1024).round());
      expect(s1.downloadedBytes, closeTo(45.20 * 1024 * 1024 * 0.235, 1024));
      expect(s1.speedBytesPerSec, closeTo(2.34 * 1024 * 1024, 1024));
      expect(s1.etaSeconds, 15.0);

      final s2 = YtDlpStreamDownloader.parseProgressLine(
        '[download]  50.0% of ~  45.20MiB at  512.00KiB/s ETA 01:05',
      );
      expect(s2.progress, closeTo(0.5, 0.001));
      expect(s2.speedBytesPerSec, closeTo(512 * 1024, 128));
      expect(s2.etaSeconds, 65.0);

      final s3 = YtDlpStreamDownloader.parseProgressLine(
        '[download]   12.30MiB at    1.50MiB/s',
        fallbackRatio: 0.4,
      );
      expect(s3.downloadedBytes, (12.30 * 1024 * 1024).round());
      expect(s3.speedBytesPerSec, closeTo(1.50 * 1024 * 1024, 1024));
      expect(s3.totalBytes, 0);

      // Initial state carries estimated totalBytes from format:
      const req = DownloadJobRequest(
        id: 'b11_prog_1',
        url: 'https://www.instagram.com/reel/xyz123/',
        title: 'Live Clip',
        forceMediaPipeline: true,
        selectedVideoFormat: VideoFormatOption(
          formatId: 'h264',
          resolutionLabel: '720p',
          ext: 'mp4',
          vcodec: 'avc1',
          filesizeApprox: 8000000,
          audioSize: 2000000,
          videoUrl: '',
        ),
      );
      expect(DownloadJobState.fromRequest(req).totalBytes, 10000000);

      messenger.setMockMethodCallHandler(mediaStoreMethod, (call) async {
        if (call.method == 'getAppWorkDir') return tempDir.path;
        if (call.method == 'exportToDownloads') {
          return <String, Object?>{
            'uri': 'content://media/external/downloads/777',
            'displayPath': 'Download/FaqihDownloader/Video/Live Clip.mp4',
            'sizeBytes': 47395635,
          };
        }
        return null;
      });

      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'downloadMedia') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          final pid = args['processId'].toString();
          final opts = Map<Object?, Object?>.from(args['options'] as Map);
          final outPattern = opts['-o'].toString();
          final jobDir = File(outPattern).parent;
          await messenger.handlePlatformMessage(
            ChannelNames.youtubeDlEvents,
            const StandardMethodCodec().encodeSuccessEnvelope(<String, Object?>{
              'type': 'progress',
              'processId': pid,
              'progress': 25.0,
              'etaSeconds': 12,
              'line': '[download]  25.0% of   40.00MiB at    2.50MiB/s ETA 00:12',
            }),
            (_) {},
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await File(p.join(jobDir.path, 'ytdlp_clip.mp4')).writeAsBytes(<int>[1, 2, 3, 4]);
          return <String, Object?>{'exitCode': 0, 'stdout': 'ok', 'stderr': ''};
        }
        return true;
      });

      final emitted = <DownloadJobState>[];
      final coord = StreamDownloadCoordinator(
        request: req,
        youtubeDlChannel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
        mediaStoreChannel: MediaStoreChannel(methodChannel: mediaStoreMethod),
        onStateChanged: emitted.add,
      );
      final done = await coord.start();
      expect(done.status, DownloadStatus.completed);
      final liveState = emitted.firstWhere((s) => s.speedBytesPerSec > 0);
      expect(liveState.totalBytes, (40.0 * 1024 * 1024).round());
      expect(liveState.downloadedBytes, closeTo(10.0 * 1024 * 1024, 1024));
      expect(liveState.speedBytesPerSec, closeTo(2.5 * 1024 * 1024, 1024));
    });

    test('2) selects mkv for VP9/WebM, mp4 for H.264, and surfaces stderr ERROR reason', () async {
      final jobDir = p.join(tempDir.path, 'mkv_err_job');
      await Directory(jobDir).create(recursive: true);

      final seenMergeFmt = <Object?>[];
      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'downloadMedia') {
          final opts = Map<Object?, Object?>.from((call.arguments as Map)['options'] as Map);
          seenMergeFmt.add(opts['--merge-output-format']);
          if (seenMergeFmt.length == 1) {
            await File(p.join(jobDir, 'ytdlp_v.mkv')).writeAsBytes(<int>[1, 2]);
            return <String, Object?>{'exitCode': 0, 'stdout': 'ok', 'stderr': ''};
          }
          return <String, Object?>{
            'exitCode': 1,
            'stdout': '',
            'stderr': 'WARNING: something\nERROR: HTTP Error 403: Forbidden on fragment 2\n',
          };
        }
        return null;
      });

      final dl = YtDlpStreamDownloader(
        YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
      );

      final outMkv = await dl.download(
        request: const DownloadJobRequest(
          id: 'vp9_job',
          url: 'https://www.instagram.com/reel/vp9/',
          title: 'VP9',
        ),
        jobDir: jobDir,
        formatOption: const VideoFormatOption(
          formatId: '248',
          resolutionLabel: '1080p',
          ext: 'webm',
          vcodec: 'vp9',
        ),
        audioOption: null,
        isCancelled: () => false,
        setActiveProcessId: (_) {},
        setActivePhase: (_) {},
        onProgress: (_, _, _, _, _, _) {},
      );
      expect(outMkv, endsWith('.mkv'));
      expect(seenMergeFmt.first, 'mkv');

      await expectLater(
        dl.download(
          request: const DownloadJobRequest(
            id: 'h264_fail',
            url: 'https://www.instagram.com/reel/h264/',
            title: 'H264',
          ),
          jobDir: jobDir,
          formatOption: const VideoFormatOption(
            formatId: '137',
            resolutionLabel: '1080p',
            ext: 'mp4',
            vcodec: 'avc1.640028',
          ),
          audioOption: null,
          isCancelled: () => false,
          setActiveProcessId: (_) {},
          setActivePhase: (_) {},
          onProgress: (_, _, _, _, _, _) {},
        ),
        throwsA(
          isA<MediaExtractionException>().having(
            (e) => e.message,
            'message',
            contains('HTTP Error 403: Forbidden on fragment 2'),
          ),
        ),
      );
      expect(seenMergeFmt.last, 'mp4');
    });

    test('3) TurboDownloadEngine fast-fails without single-stream retry on 403 googlevideo.com URL', () async {
      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var plainGetCount = 0;

        server.listen((req) async {
          req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          if (req.method == 'HEAD') {
            req.response.contentLength = 256 * 1024;
            await req.response.close();
            return;
          }
          final range = req.headers.value(HttpHeaders.rangeHeader);
          final rangeQuery = req.uri.queryParameters['range'];
          if (range == 'bytes=0-0') {
            req.response.statusCode = HttpStatus.partialContent;
            req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/${256 * 1024}');
            req.response.contentLength = 1;
            req.response.add(<int>[1]);
            await req.response.close();
            return;
          }
          if (range == null && rangeQuery == null) {
            plainGetCount++;
          }
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
        });

        final client = _ScriptHostRedirectClient(
          realClient: _RealHttpOverrides().createHttpClient(null),
          rewrittenHost: 'rr1---sn.googlevideo.com',
          serverPort: server.port,
        );

        final dest = p.join(tempDir.path, 'gv_fail.mp4');
        final engine = TurboDownloadEngine(
          url: 'http://rr1---sn.googlevideo.com:${server.port}/videoplayback?expire=1',
          destinationPath: dest,
          maxConnections: 2,
          minSplitThreshold: 32 * 1024,
          httpClient: client,
        );
        await expectLater(engine.start(), throwsA(anything));
        expect(plainGetCount, 0);
        expect(engine.status, DownloadStatus.failed);
      });
    });

    test('4) MediaExtractorService runs TikTokFallbackExtractor before calling YoutubeDlChannel.extractInfo', () async {
      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final base = 'http://127.0.0.1:${server.port}';
        server.listen((req) async {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, dynamic>{
            'code': 0,
            'data': <String, dynamic>{
              'id': 'fast_tt',
              'title': 'Instant TikTok',
              'duration': 12,
              'hdplay': '$base/fast_tt.mp4',
            },
          }));
          await req.response.close();
        });

        var ytdlExtractCalls = 0;
        messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
          if (call.method == 'extractInfo') ytdlExtractCalls++;
          return null;
        });

        final svc = MediaExtractorService(
          channel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
          tiktokFallback: TikTokFallbackExtractor(
            httpClientFactory: () => _RealHttpOverrides().createHttpClient(null),
            tikwmBaseUrl: base,
          ),
        );
        final info = await svc.extractInfo('https://vt.tiktok.com/ZSfast11/');
        expect(info.title, 'Instant TikTok');
        expect(ytdlExtractCalls, 0);
      });
    });

    test('5) YouTubeInnerTubeExtractor falls back to IOS client when ANDROID_VR fails', () async {
      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final seenClientIds = <String?>[];

        server.listen((req) async {
          final clientId = req.headers.value('x-youtube-client-name');
          seenClientIds.add(clientId);
          if (clientId == '28') {
            req.response.statusCode = HttpStatus.forbidden;
            await req.response.close();
            return;
          }
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, dynamic>{
            'playabilityStatus': <String, dynamic>{'status': 'OK'},
            'videoDetails': <String, dynamic>{'videoId': 'dQw4w9WgXcQ', 'title': 'iOS Recovered'},
            'streamingData': <String, dynamic>{
              'formats': <Map<String, dynamic>>[
                <String, dynamic>{
                  'itag': 18,
                  'url': 'https://cdn.example.com/ios360.mp4',
                  'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
                  'height': 360,
                },
              ],
            },
          }));
          await req.response.close();
        });

        final extractor = YouTubeInnerTubeExtractor(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}/youtubei/v1/player'),
        );
        final info = await extractor.extract('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
        expect(seenClientIds, <String?>['28', '5']);
        expect(info, isNotNull);
        expect(info!.title, 'iOS Recovered');
        expect(info.videoFormats.single.videoUrl, 'https://cdn.example.com/ios360.mp4');
      });
    });

    testWidgets('6) DownloadJobCard shows error message up to 4 lines with copy button', (tester) async {
      String? copiedText;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = ((call.arguments as Map)['text'])?.toString();
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      final failedJob = DownloadJobState(
        id: 'err_1',
        title: 'Broken Video',
        url: 'https://example.com/v',
        phase: DownloadPhase.failed,
        status: DownloadStatus.failed,
        progress: 0.2,
        downloadedBytes: 100,
        totalBytes: 500,
        speedBytesPerSec: 0,
        etaSeconds: -1,
        errorMessage: 'yt-dlp failed: HTTP Error 403: Forbidden',
        category: 'Video',
        createdAt: DateTime.utc(2026, 11, 26),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadJobCard(
              job: failedJob,
              translator: AppTranslator(initialLanguage: 'en'),
              onPause: () {},
              onResume: () {},
              onCancel: () {},
            ),
          ),
        ),
      );

      final copyBtn = find.byKey(const Key('job_copy_error_err_1'));
      expect(copyBtn, findsOneWidget);
      await tester.tap(copyBtn);
      await tester.pump();
      expect(copiedText, 'yt-dlp failed: HTTP Error 403: Forbidden');
    });
  });
}

class _ScriptHostRedirectClient implements HttpClient {
  _ScriptHostRedirectClient({
    required this.realClient,
    required this.rewrittenHost,
    required this.serverPort,
  });

  final HttpClient realClient;
  final String rewrittenHost;
  final int serverPort;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final target = Uri.parse('http://127.0.0.1:$serverPort${url.path}?${url.query}');
    final realReq = await realClient.openUrl(method, target);
    return _UriOverrideRequest(realReq, Uri.parse('http://$rewrittenHost:$serverPort${url.path}'));
  }

  @override
  void close({bool force = false}) => realClient.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _UriOverrideRequest implements HttpClientRequest {
  _UriOverrideRequest(this.inner, this.reportedUri);
  final HttpClientRequest inner;
  final Uri reportedUri;

  @override
  Uri get uri => reportedUri;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  bool get followRedirects => inner.followRedirects;
  @override
  set followRedirects(bool v) => inner.followRedirects = v;
  @override
  Future<HttpClientResponse> close() => inner.close();
  @override
  void abort([Object? exception, StackTrace? stackTrace]) => inner.abort(exception, stackTrace);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
