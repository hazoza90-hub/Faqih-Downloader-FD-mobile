import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:faqih_downloader_mobile/core/models/download_status.dart';
import 'package:faqih_downloader_mobile/engine/isolate_download_runner.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/media_store_channel.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_job_models.dart';
import 'package:faqih_downloader_mobile/services/coordinator/media_stream_acquirer.dart';
import 'package:faqih_downloader_mobile/services/coordinator/stream_download_coordinator.dart';
import 'package:faqih_downloader_mobile/services/coordinator/ytdlp_stream_downloader.dart';
import 'package:faqih_downloader_mobile/services/media/media_exceptions.dart';
import 'package:faqih_downloader_mobile/services/media/media_extractor_service.dart';
import 'package:faqih_downloader_mobile/services/media/youtube_innertube_extractor.dart';
import 'package:faqih_downloader_mobile/services/resolver/html_download_resolver.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _RealHttpOverrides extends HttpOverrides {}

class _CountingHtmlResolver extends HtmlDownloadResolver {
  int resolveCalls = 0;

  @override
  Future<ResolvedDownloadResult> resolve(
    String url, {
    Map<String, String> headers = const <String, String>{},
    bool probeCandidates = true,
  }) async {
    resolveCalls++;
    return ResolvedDownloadResult(url: url, headers: headers);
  }
}

class _FakeTurboRunner extends IsolateDownloadRunner {
  _FakeTurboRunner({
    required super.url,
    required super.destinationPath,
    super.headers,
    super.maxConnections,
    super.speedLimitBytesPerSec,
    super.callbacks,
  });

  static final List<String> startedUrls = <String>[];
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get completion => _done.future;

  @override
  Future<void> start() async {
    try {
      startedUrls.add(url);
      await File(destinationPath).parent.create(recursive: true);
      await File(destinationPath).writeAsBytes(const <int>[1, 2, 3, 4]);
      callbacks?.onComplete?.call(destinationPath, 4, 0.01);
    } finally {
      if (!_done.isCompleted) _done.complete();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ytdlMethod = MethodChannel(ChannelNames.youtubeDl);
  const ytdlEvents = EventChannel(ChannelNames.youtubeDlEvents);
  const mediaStoreMethod = MethodChannel(ChannelNames.mediaStore);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fd_b10_start_');
    _FakeTurboRunner.startedUrls.clear();
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

  group('Batch 10 surgical fixes & fast download startup', () {
    test('1) YouTubeInnerTubeExtractor returns null when videoFormats is empty even if audioTracks exist', () {
      final extractor = YouTubeInnerTubeExtractor();
      final result = extractor.parsePlayerResponse(<String, dynamic>{
        'playabilityStatus': <String, dynamic>{'status': 'OK'},
        'videoDetails': <String, dynamic>{'videoId': 'dQw4w9WgXcQ', 'title': 'Encrypted Video'},
        'streamingData': <String, dynamic>{
          'formats': <Map<String, dynamic>>[
            <String, dynamic>{
              'itag': 18,
              'signatureCipher': 's=abc&url=https://example.com/v.mp4',
              'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
              'height': 360,
            },
          ],
          'adaptiveFormats': <Map<String, dynamic>>[
            <String, dynamic>{
              'itag': 140,
              'url': 'https://cdn.example.com/audio_only.m4a',
              'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
              'bitrate': 128000,
            },
          ],
        },
      }, 'dQw4w9WgXcQ');

      expect(result, isNull);
    });

    test('2) MediaExtractorService isolates cache by cookiesFile, uses mweb,web on cookie retry, and aborts in-flight InnerTube request', () async {
      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final requestStarted = Completer<void>();
        server.listen((req) async {
          if (!requestStarted.isCompleted) requestStarted.complete();
          // Hold response open until client aborts or closes.
          await Future<void>.delayed(const Duration(seconds: 4));
          try {
            await req.response.close();
          } catch (_) {}
        });

        messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
          if (call.method == 'cancelProcess') return true;
          return <String, Object?>{'status': 'ALREADY_UP_TO_DATE'};
        });

        final abortSvc = MediaExtractorService(
          channel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
          innerTubeExtractor: YouTubeInnerTubeExtractor(
            endpoint: Uri.parse('http://127.0.0.1:${server.port}/player'),
            timeout: const Duration(seconds: 4),
          ),
        );

        final extractFut = abortSvc.extractInfo(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          processId: 'abort_inner_1',
        );
        await requestStarted.future;
        final sw = Stopwatch()..start();
        await abortSvc.cancelExtraction('abort_inner_1');
        await expectLater(
          extractFut,
          throwsA(isA<MediaExtractionException>().having((e) => e.kind, 'kind', MediaErrorKind.cancelled)),
        );
        sw.stop();
        expect(sw.elapsedMilliseconds, lessThan(1500));
      });

      final calls = <({String? cookies, String? extractorArgs})>[];
      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'extractInfo') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          final ck = args['cookiesFile'] as String?;
          final ea = args['extractorArgs'] as String?;
          calls.add((cookies: ck, extractorArgs: ea));
          if (ck == null) {
            throw PlatformException(code: 'YOUTUBEDL_ERROR', message: 'Sign in required');
          }
          return jsonEncode(<String, dynamic>{
            'id': 'cookie_v1',
            'title': 'With Cookie $ck',
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
        return <String, Object?>{'status': 'ALREADY_UP_TO_DATE'};
      });

      final svc = MediaExtractorService(
        channel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
      );

      final first = await svc.extractInfo(
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        cookiesFile: '/tmp/cookie_a.txt',
      );
      expect(first.title, 'With Cookie /tmp/cookie_a.txt');
      expect(calls.length, 2);
      expect(calls.last.cookies, '/tmp/cookie_a.txt');
      expect(calls.last.extractorArgs, 'youtube:player_client=mweb,web');

      // Different cookiesFile must NOT reuse cache from cookie_a.txt:
      final second = await svc.extractInfo(
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        cookiesFile: '/tmp/cookie_b.txt',
      );
      expect(second.title, 'With Cookie /tmp/cookie_b.txt');
      expect(calls.length, 4);
    });

    test('3) StreamDownloadCoordinator skips HtmlDownloadResolver for skipHtmlResolve and direct download URLs', () async {
      messenger.setMockMethodCallHandler(mediaStoreMethod, (call) async {
        if (call.method == 'getAppWorkDir') return tempDir.path;
        if (call.method == 'exportToDownloads') {
          return <String, Object?>{
            'uri': 'content://media/external/downloads/901',
            'displayPath': 'Download/FaqihDownloader/Programs/app.apk',
            'sizeBytes': 4,
          };
        }
        return null;
      });

      final resolver = _CountingHtmlResolver();

      final coord1 = StreamDownloadCoordinator(
        request: const DownloadJobRequest(
          id: 'skip_flag_1',
          url: 'https://cdn.example.com/token/one-time',
          title: 'Token File',
          skipHtmlResolve: true,
        ),
        mediaStoreChannel: MediaStoreChannel(methodChannel: mediaStoreMethod),
        htmlResolver: resolver,
        runnerFactory: ({
          required url,
          required destinationPath,
          headers = const <String, String>{},
          maxConnections = 8,
          speedLimitBytesPerSec = 0.0,
          callbacks,
        }) =>
            _FakeTurboRunner(
          url: url,
          destinationPath: destinationPath,
          headers: headers,
          maxConnections: maxConnections,
          speedLimitBytesPerSec: speedLimitBytesPerSec,
          callbacks: callbacks,
        ),
      );
      final r1 = await coord1.start();
      expect(r1.status, DownloadStatus.completed);
      expect(resolver.resolveCalls, 0);

      final coord2 = StreamDownloadCoordinator(
        request: const DownloadJobRequest(
          id: 'direct_ext_2',
          url: 'https://cdn.example.com/releases/app-release.apk?v=1',
          title: 'App',
        ),
        mediaStoreChannel: MediaStoreChannel(methodChannel: mediaStoreMethod),
        htmlResolver: resolver,
        runnerFactory: ({
          required url,
          required destinationPath,
          headers = const <String, String>{},
          maxConnections = 8,
          speedLimitBytesPerSec = 0.0,
          callbacks,
        }) =>
            _FakeTurboRunner(
          url: url,
          destinationPath: destinationPath,
          headers: headers,
          maxConnections: maxConnections,
          speedLimitBytesPerSec: speedLimitBytesPerSec,
          callbacks: callbacks,
        ),
      );
      final r2 = await coord2.start();
      expect(r2.status, DownloadStatus.completed);
      expect(resolver.resolveCalls, 0);
    });

    test('4) YtDlpStreamDownloader uses deduplicated fast strategy list and mweb,web cookie client (4 calls max)', () async {
      final jobDir = p.join(tempDir.path, 'ytdlp_fast_4');
      await Directory(jobDir).create(recursive: true);
      final seen = <({Object? extArgs, Object? cookie})>[];

      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'downloadMedia') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          final opts = Map<Object?, Object?>.from(args['options'] as Map);
          seen.add((extArgs: args['extractorArgs'], cookie: opts['--cookies']));
          if (seen.length < 4) {
            return <String, Object?>{'exitCode': 1, 'stdout': '', 'stderr': '403'};
          }
          await File(p.join(jobDir, 'ytdlp_final.mp4')).writeAsBytes(<int>[1, 2, 3]);
          return <String, Object?>{'exitCode': 0, 'stdout': 'ok', 'stderr': ''};
        }
        return null;
      });

      final dl = YtDlpStreamDownloader(
        YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
      );
      final out = await dl.download(
        request: const DownloadJobRequest(
          id: 'fast_yt_4',
          url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          title: 'Fast YT',
          cookiesFile: '/tmp/cookies.txt',
        ),
        jobDir: jobDir,
        formatOption: null,
        audioOption: null,
        isCancelled: () => false,
        setActiveProcessId: (_) {},
        setActivePhase: (_) {},
        onProgress: (_, _, _) {},
      );
      expect(out, endsWith('ytdlp_final.mp4'));
      expect(seen.length, 4);
      expect(seen.map((e) => e.extArgs).toList(), <Object?>[
        null,
        'youtube:player_client=ios,mweb',
        '',
        'youtube:player_client=mweb,web',
      ]);
      expect(seen.map((e) => e.cookie).toList(), <Object?>[null, null, null, '/tmp/cookies.txt']);
    });

    test('5) MediaStreamAcquirer resolves YouTube URL without selectedVideoFormat via InnerTube and runs Turbo', () async {
      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, dynamic>{
            'playabilityStatus': <String, dynamic>{'status': 'OK'},
            'videoDetails': <String, dynamic>{'videoId': 'dQw4w9WgXcQ', 'title': 'Staged Turbo'},
            'streamingData': <String, dynamic>{
              'formats': <Map<String, dynamic>>[
                <String, dynamic>{
                  'itag': 18,
                  'url': 'https://cdn.example.com/staged_360.mp4',
                  'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
                  'height': 360,
                },
                <String, dynamic>{
                  'itag': 22,
                  'url': 'https://cdn.example.com/staged_720.mp4',
                  'mimeType': 'video/mp4; codecs="avc1.64001F, mp4a.40.2"',
                  'height': 720,
                },
              ],
            },
          }));
          await req.response.close();
        });

        var ytdlInvoked = 0;
        messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
          ytdlInvoked++;
          return <String, Object?>{'exitCode': 0};
        });

        final acquirer = MediaStreamAcquirer(
          youtubeDl: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
          innerTubeExtractor: YouTubeInnerTubeExtractor(
            endpoint: Uri.parse('http://127.0.0.1:${server.port}/player'),
          ),
          runnerFactory: ({
            required url,
            required destinationPath,
            headers = const <String, String>{},
            maxConnections = 8,
            speedLimitBytesPerSec = 0.0,
            callbacks,
          }) =>
              _FakeTurboRunner(
            url: url,
            destinationPath: destinationPath,
            headers: headers,
            maxConnections: maxConnections,
            speedLimitBytesPerSec: speedLimitBytesPerSec,
            callbacks: callbacks,
          ),
        );

        final jobDir = p.join(tempDir.path, 'acquirer_staged');
        await Directory(jobDir).create(recursive: true);

        final files = await acquirer.acquireMedia(
          request: const DownloadJobRequest(
            id: 'staged_yt_1',
            url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
            title: 'Staged YT',
            preferredVideoHeight: 360,
          ),
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

        expect(ytdlInvoked, 0);
        expect(_FakeTurboRunner.startedUrls, <String>['https://cdn.example.com/staged_360.mp4']);
        expect(File(files.videoPath).existsSync(), isTrue);
      });
    });
  });
}
