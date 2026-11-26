import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:faqih_downloader_mobile/core/i18n/strings_ar.dart';
import 'package:faqih_downloader_mobile/core/i18n/strings_en.dart';
import 'package:faqih_downloader_mobile/core/i18n/translator.dart';
import 'package:faqih_downloader_mobile/core/models/audio_track.dart';
import 'package:faqih_downloader_mobile/core/models/download_chunk.dart';
import 'package:faqih_downloader_mobile/core/models/download_status.dart';
import 'package:faqih_downloader_mobile/core/models/history_entry.dart';
import 'package:faqih_downloader_mobile/core/models/video_format_option.dart';
import 'package:faqih_downloader_mobile/engine/chunk_worker.dart';
import 'package:faqih_downloader_mobile/engine/isolate_download_runner.dart';
import 'package:faqih_downloader_mobile/engine/token_bucket_rate_limiter.dart';
import 'package:faqih_downloader_mobile/features/home/vault_tab.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_job_models.dart';
import 'package:faqih_downloader_mobile/services/coordinator/media_stream_acquirer.dart';
import 'package:faqih_downloader_mobile/services/coordinator/ytdlp_stream_downloader.dart';
import 'package:faqih_downloader_mobile/services/media/youtube_innertube_extractor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _RealHttpOverrides extends HttpOverrides {}

class _RotateTurboRunner extends IsolateDownloadRunner {
  _RotateTurboRunner({
    required super.url,
    required super.destinationPath,
    super.headers,
    super.maxConnections,
    super.speedLimitBytesPerSec,
    super.callbacks,
  });

  static final List<String> urls = <String>[];
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get completion => _done.future;

  @override
  Future<void> start() async {
    try {
      urls.add(url);
      if (urls.length == 1) {
        callbacks?.onError?.call('HTTP 403 Forbidden', linkExpired: true, httpStatus: 403);
        return;
      }
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
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fd_b12_test_');
    _RotateTurboRunner.urls.clear();
    YtDlpStreamDownloader.resetAutoUpdateStateForTest();
    messenger.setMockStreamHandler(ytdlEvents, MockStreamHandler.inline(onListen: (_, _) {}));
  });

  tearDown(() async {
    YtDlpStreamDownloader.resetAutoUpdateStateForTest();
    messenger.setMockMethodCallHandler(ytdlMethod, null);
    messenger.setMockStreamHandler(ytdlEvents, null);
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<T> runWithRealHttp<T>(Future<T> Function() fn) =>
      HttpOverrides.runZoned(fn, createHttpClient: (ctx) => _RealHttpOverrides().createHttpClient(ctx));

  group('Batch 12 YouTube resilience, chunk guard & VaultTab errors', () {
    test('1) YouTubeInnerTubeExtractor uses ANDROID_VR 1.61.48 and honors startProfileIndex', () async {
      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final calls = <({String? id, String? ver})>[];

        server.listen((req) async {
          final id = req.headers.value('x-youtube-client-name');
          final ver = req.headers.value('x-youtube-client-version');
          calls.add((id: id, ver: ver));
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, dynamic>{
            'playabilityStatus': <String, dynamic>{'status': 'OK'},
            'videoDetails': <String, dynamic>{'videoId': 'dQw4w9WgXcQ', 'title': 'Client $id'},
            'streamingData': <String, dynamic>{
              'formats': <Map<String, dynamic>>[
                <String, dynamic>{
                  'itag': 18,
                  'url': 'https://cdn.example.com/$id.mp4',
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

        final vr = await extractor.extract('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
        expect(vr, isNotNull);
        expect(calls.last, (id: '28', ver: '1.61.48'));

        final ios = await extractor.extract(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          startProfileIndex: 1,
        );
        expect(ios, isNotNull);
        expect(ios!.videoFormats.single.videoUrl, 'https://cdn.example.com/5.mp4');
        expect(calls.last, (id: '5', ver: '20.10.4'));

        expect(
          await extractor.extract(
            'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
            startProfileIndex: 2,
          ),
          isNull,
        );
      });
    });

    test('2) MediaStreamAcquirer rotates to InnerTube profile 1 on Turbo 403/410 without falling back to yt-dlp', () async {
      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final seenClientIds = <String?>[];

        server.listen((req) async {
          seenClientIds.add(req.headers.value('x-youtube-client-name'));
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, dynamic>{
            'playabilityStatus': <String, dynamic>{'status': 'OK'},
            'videoDetails': <String, dynamic>{'videoId': 'dQw4w9WgXcQ', 'title': 'Rotated'},
            'streamingData': <String, dynamic>{
              'formats': <Map<String, dynamic>>[
                <String, dynamic>{
                  'itag': 18,
                  'url': 'https://cdn.example.com/ios_360.mp4',
                  'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
                  'height': 360,
                },
                <String, dynamic>{
                  'itag': 22,
                  'url': 'https://cdn.example.com/ios_720.mp4',
                  'mimeType': 'video/mp4; codecs="avc1.64001F, mp4a.40.2"',
                  'height': 720,
                },
              ],
            },
          }));
          await req.response.close();
        });

        var ytdlCalls = 0;
        messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
          ytdlCalls++;
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
              _RotateTurboRunner(
            url: url,
            destinationPath: destinationPath,
            headers: headers,
            maxConnections: maxConnections,
            speedLimitBytesPerSec: speedLimitBytesPerSec,
            callbacks: callbacks,
          ),
        );

        final jobDir = p.join(tempDir.path, 'rotate_job');
        await Directory(jobDir).create(recursive: true);

        final res = await acquirer.acquireMedia(
          request: const DownloadJobRequest(
            id: 'rot_1',
            url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
            title: 'Rotated',
            selectedVideoFormat: VideoFormatOption(
              formatId: '22',
              resolutionLabel: '720p',
              height: 720,
              isProgressive: true,
              videoUrl: 'https://stale.example.com/vr_720.mp4',
            ),
          ),
          jobDir: jobDir,
          speedLimitBytesPerSec: 0,
          isCancelled: () => false,
          isPaused: () => false,
          setActiveRunner: (_) {},
          setActiveProcessId: (_) {},
          setActivePhase: (_) {},
          onTurboProgress: (_, _) {},
          onYtDlpProgress: (_, _, _, _, _, _) {},
        );

        expect(ytdlCalls, 0);
        expect(seenClientIds, <String?>['5']);
        expect(_RotateTurboRunner.urls, <String>[
          'https://stale.example.com/vr_720.mp4',
          'https://cdn.example.com/ios_720.mp4',
        ]);
        expect(File(res.videoPath).existsSync(), isTrue);
      });
    });

    test('3) YtDlpStreamDownloader strips YouTube User-Agent, uses height fallback selector, and auto-updates once', () async {
      final dubSel = YtDlpStreamDownloader.buildSelector(
        const DownloadJobRequest(id: '1', url: 'https://youtube.com/watch?v=dQw4w9WgXcQ', title: 'T'),
        const VideoFormatOption(formatId: '137', resolutionLabel: '1080p', height: 1080),
        const AudioTrack(
          trackId: 'ar_dub', formatId: '140-ar', language: 'ar', label: 'Arabic', url: 'u', isOriginal: false,
        ),
      );
      expect(dubSel, '137+140-ar/bestvideo[height<=1080]+bestaudio/best[height<=1080]/best');

      final progSel = YtDlpStreamDownloader.buildSelector(
        const DownloadJobRequest(id: '2', url: 'https://youtube.com/watch?v=dQw4w9WgXcQ', title: 'T'),
        const VideoFormatOption(formatId: '22', resolutionLabel: '720p', height: 720, isProgressive: true),
        null,
      );
      expect(progSel, '22/bestvideo[height<=720]+bestaudio/best[height<=720]/best');

      final jobDir = p.join(tempDir.path, 'yt_ua_update');
      await Directory(jobDir).create(recursive: true);
      var updated = false;
      var updateCalls = 0;
      final seenHeaders = <List<Object?>>[];

      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'updateYoutubeDL') {
          updateCalls++;
          updated = true;
          return <String, Object?>{'status': 'DONE', 'ytdlpVersion': '2026.12.01'};
        }
        if (call.method == 'downloadMedia') {
          final opts = Map<Object?, Object?>.from((call.arguments as Map)['options'] as Map);
          seenHeaders.add(List<Object?>.from(opts['--add-header'] as List? ?? const <Object?>[]));
          if (!updated) {
            return <String, Object?>{'exitCode': 1, 'stdout': '', 'stderr': 'ERROR: HTTP Error 403'};
          }
          await File(p.join(jobDir, 'ytdlp_ok.mp4')).writeAsBytes(<int>[1, 2, 3]);
          return <String, Object?>{'exitCode': 0, 'stdout': 'ok', 'stderr': ''};
        }
        return null;
      });

      final dl = YtDlpStreamDownloader(
        YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
      );
      final out = await dl.download(
        request: const DownloadJobRequest(
          id: 'ua_upd',
          url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          title: 'UA Test',
          headers: <String, String>{
            'User-Agent': 'CustomBrowser/1.0',
            'Referer': 'https://www.youtube.com/',
          },
        ),
        jobDir: jobDir,
        formatOption: null,
        audioOption: null,
        isCancelled: () => false,
        setActiveProcessId: (_) {},
        setActivePhase: (_) {},
        onProgress: (_, _, _, _, _, _) {},
      );
      expect(out, endsWith('ytdlp_ok.mp4'));
      expect(updateCalls, 1);
      for (final hList in seenHeaders) {
        expect(hList.any((h) => h.toString().toLowerCase().contains('user-agent')), isFalse);
        expect(hList, contains('Referer:https://www.youtube.com/'));
      }
    });

    test('4) ChunkWorker exits cleanly on 0-byte empty ranged response instead of looping infinitely', () async {
      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var requests = 0;

        server.listen((req) async {
          requests++;
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set('Content-Range', 'bytes 0-99/100');
          req.response.contentLength = 0;
          await req.response.close();
        });

        var chunk = DownloadChunk(
          chunkId: 0,
          startByte: 0,
          endByte: 99,
          partFilepath: p.join(tempDir.path, 'empty.part'),
        );

        await expectLater(
          ChunkWorker().run(
            httpClient: _RealHttpOverrides().createHttpClient(null),
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
            maxRetries: 1,
          ),
          throwsA(
            isA<ChunkWorkerException>().having(
              (e) => e.message,
              'message',
              contains('Empty response during ranged chunk transfer'),
            ),
          ),
        );
        expect(requests, 2);
      });
    });

    testWidgets('5) HistoryEntry persists errorMessage and VaultTab renders & copies error with SnackBar', (tester) async {
      expect(stringsAr.keys.toSet(), stringsEn.keys.toSet());

      final legacy = HistoryEntry.fromJson(<String, dynamic>{
        'id': 'old_1',
        'url': 'https://example.com/old.zip',
        'filename': 'old.zip',
        'filePath': '/old.zip',
        'category': 'Compressed',
        'totalSize': 100,
        'downloadedBytes': 100,
        'status': 'completed',
        'createdAt': '2026-11-01T00:00:00Z',
      });
      expect(legacy.errorMessage, isNull);

      final failed = HistoryEntry(
        id: 'fail_v1',
        url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        filename: 'Broken.mp4',
        filePath: '',
        category: 'Video',
        totalSize: 5000,
        downloadedBytes: 0,
        status: DownloadStatus.failed,
        createdAt: DateTime.utc(2026, 11, 26),
        platform: 'YouTube',
        errorMessage: 'yt-dlp failed: Sign in to confirm',
      );
      final roundTrip = HistoryEntry.fromJson(failed.toJson());
      expect(roundTrip, failed);

      String? clipboardText;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = ((call.arguments as Map)['text'])?.toString();
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VaultTab(
              translator: AppTranslator(initialLanguage: 'en'),
              entries: <HistoryEntry>[failed],
              onOpenEntry: (_) {},
              onShareEntry: (_) {},
              onRetryEntry: (_) {},
              onDeleteEntry: (_, {required deleteFile}) {},
            ),
          ),
        ),
      );

      expect(find.text('yt-dlp failed: Sign in to confirm'), findsOneWidget);
      final copyBtn = find.byKey(const Key('vault_copy_error_fail_v1'));
      expect(copyBtn, findsOneWidget);
      await tester.tap(copyBtn);
      await tester.pump();
      expect(clipboardText, 'yt-dlp failed: Sign in to confirm');
      expect(find.text(stringsEn['msg_error_copied']!), findsOneWidget);
    });
  });
}
