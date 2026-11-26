import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:faqih_downloader_mobile/app/app_controller.dart';
import 'package:faqih_downloader_mobile/core/i18n/strings_ar.dart';
import 'package:faqih_downloader_mobile/core/i18n/translator.dart';
import 'package:faqih_downloader_mobile/core/models/download_status.dart';
import 'package:faqih_downloader_mobile/core/models/video_format_option.dart';
import 'package:faqih_downloader_mobile/core/models/youtube_stream_info.dart';
import 'package:faqih_downloader_mobile/engine/isolate_download_runner.dart';
import 'package:faqih_downloader_mobile/features/home/download_job_card.dart';
import 'package:faqih_downloader_mobile/features/home/home_app_bar.dart';
import 'package:faqih_downloader_mobile/features/home/url_input_bar.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_job_models.dart';
import 'package:faqih_downloader_mobile/services/coordinator/media_stream_acquirer.dart';
import 'package:faqih_downloader_mobile/services/coordinator/media_stream_helpers.dart';
import 'package:faqih_downloader_mobile/services/coordinator/ytdlp_stream_downloader.dart';
import 'package:faqih_downloader_mobile/services/media/youtube_innertube_extractor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _RealHttpOverrides extends HttpOverrides {}

class _Always403TurboRunner extends IsolateDownloadRunner {
  _Always403TurboRunner({
    required super.url,
    required super.destinationPath,
    super.headers,
    super.maxConnections,
    super.speedLimitBytesPerSec,
    super.callbacks,
  });

  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get completion => _done.future;

  @override
  Future<void> start() async {
    try {
      callbacks?.onError?.call('HTTP 403 Forbidden', linkExpired: true, httpStatus: 403);
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
    tempDir = await Directory.systemTemp.createTemp('fd_b14_test_');
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

  group('Batch 14 strict quality guard & UI polish', () {
    test('1) pickInnerTubeFormat strictHeight rejects 360p for 720p, accepts >=85% height, and routes acquirer to yt-dlp', () async {
      const only360Info = YouTubeStreamInfo(
        videoId: 'vid_360_only',
        title: 'Only 360',
        cleanFilename: 'Only_360',
        isProgressive: true,
        videoUrl: 'https://cdn.example.com/360.mp4',
        videoFormats: <VideoFormatOption>[
          VideoFormatOption(
            formatId: '18',
            resolutionLabel: '360p',
            height: 360,
            vcodec: 'avc1.42001E',
            isProgressive: true,
            videoUrl: 'https://cdn.example.com/360.mp4',
          ),
        ],
      );

      expect(
        MediaStreamHelpers.pickInnerTubeFormat(
          only360Info,
          720,
          preferredFormatId: '18',
          preferredVcodec: 'avc1',
          strictHeight: true,
        ),
        isNull,
      );

      const near720Info = YouTubeStreamInfo(
        videoId: 'vid_640',
        title: '640p',
        cleanFilename: '640p',
        isProgressive: false,
        videoUrl: 'https://cdn.example.com/640.mp4',
        videoFormats: <VideoFormatOption>[
          VideoFormatOption(
            formatId: '247',
            resolutionLabel: '640p',
            height: 640,
            vcodec: 'vp09.00.31.08',
            videoUrl: 'https://cdn.example.com/640.webm',
          ),
          VideoFormatOption(
            formatId: '18',
            resolutionLabel: '360p',
            height: 360,
            vcodec: 'avc1.42001E',
            isProgressive: true,
            videoUrl: 'https://cdn.example.com/360.mp4',
          ),
        ],
      );

      expect(
        MediaStreamHelpers.pickInnerTubeFormat(
          near720Info,
          720,
          preferredVcodec: 'vp09',
          strictHeight: true,
        )?.formatId,
        '247',
      );

      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, dynamic>{
            'playabilityStatus': <String, dynamic>{'status': 'OK'},
            'videoDetails': <String, dynamic>{'videoId': 'dQw4w9WgXcQ', 'title': 'iOS 360 only'},
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

        final jobDir = p.join(tempDir.path, 'strict_fallback');
        await Directory(jobDir).create(recursive: true);
        var ytdlCalls = 0;
        messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
          if (call.method == 'downloadMedia') {
            ytdlCalls++;
            await File(p.join(jobDir, 'ytdlp_720.mp4')).writeAsBytes(<int>[1, 2, 3]);
            return <String, Object?>{'exitCode': 0, 'stdout': 'ok', 'stderr': ''};
          }
          return null;
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
              _Always403TurboRunner(
            url: url,
            destinationPath: destinationPath,
            headers: headers,
            maxConnections: maxConnections,
            speedLimitBytesPerSec: speedLimitBytesPerSec,
            callbacks: callbacks,
          ),
        );

        final acquired = await acquirer.acquireMedia(
          request: const DownloadJobRequest(
            id: 'strict_720',
            url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
            title: 'Strict 720',
            selectedVideoFormat: VideoFormatOption(
              formatId: '136',
              resolutionLabel: '720p',
              height: 720,
              vcodec: 'avc1.4d401f',
              videoUrl: 'https://stale.example.com/720.mp4',
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

        expect(ytdlCalls, 1);
        expect(acquired.videoPath, endsWith('ytdlp_720.mp4'));
      });
    });

    test('2) YtDlpStreamDownloader.buildSelector with strictHeight bounds >=612..720 without open 360p fallback', () {
      final strictWithCodec = YtDlpStreamDownloader.buildSelector(
        const DownloadJobRequest(id: 's1', url: 'https://youtube.com/watch?v=dQw4w9WgXcQ', title: 'T'),
        const VideoFormatOption(formatId: '136', resolutionLabel: '720p', height: 720, vcodec: 'avc1.4d401f'),
        null,
        strictHeight: true,
      );
      expect(
        strictWithCodec,
        '136+bestaudio/bestvideo[height>=612][height<=720][vcodec^=avc1]+bestaudio/'
        'bestvideo[height>=612][height<=720]+bestaudio/best[height>=612][height<=720]',
      );
      expect(strictWithCodec.contains('/best[height<=720]/best'), isFalse);

      final strictNoCodec = YtDlpStreamDownloader.buildSelector(
        const DownloadJobRequest(id: 's2', url: 'https://youtube.com/watch?v=dQw4w9WgXcQ', title: 'T'),
        const VideoFormatOption(formatId: '22', resolutionLabel: '720p', height: 720, isProgressive: true),
        null,
        strictHeight: true,
      );
      expect(
        strictNoCodec,
        '22/bestvideo[height>=612][height<=720]+bestaudio/best[height>=612][height<=720]',
      );
      expect(strictNoCodec.contains('/best[height<=720]/best'), isFalse);
    });

    test('3) YtDlpStreamDownloader.download uses android_vr,ios -> default -> mweb,web(cookies) and strict selector', () async {
      final jobDir = p.join(tempDir.path, 'fast_attempts');
      await Directory(jobDir).create(recursive: true);
      final seenArgs = <({Object? strategy, Object? cookie, Object? format})>[];

      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'downloadMedia') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          final opts = Map<Object?, Object?>.from(args['options'] as Map);
          seenArgs.add((
            strategy: args['extractorArgs'],
            cookie: opts['--cookies'],
            format: opts['-f'],
          ));
          if (seenArgs.length < 3) {
            return <String, Object?>{'exitCode': 1, 'stdout': '', 'stderr': '403'};
          }
          await File(p.join(jobDir, 'ytdlp_720.mp4')).writeAsBytes(<int>[1, 2, 3]);
          return <String, Object?>{'exitCode': 0, 'stdout': 'ok', 'stderr': ''};
        }
        return null;
      });

      final dl = YtDlpStreamDownloader(
        YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
      );
      final out = await dl.download(
        request: const DownloadJobRequest(
          id: 'yt_b14',
          url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          title: 'Strict 720',
          cookiesFile: '/tmp/yt_cookies.txt',
        ),
        jobDir: jobDir,
        formatOption: const VideoFormatOption(
          formatId: '136',
          resolutionLabel: '720p',
          height: 720,
          vcodec: 'avc1.4d401f',
        ),
        audioOption: null,
        isCancelled: () => false,
        setActiveProcessId: (_) {},
        setActivePhase: (_) {},
        onProgress: (_, _, _, _, _, _) {},
      );

      expect(out, endsWith('ytdlp_720.mp4'));
      expect(seenArgs.length, 3);
      expect(seenArgs.map((e) => e.strategy).toList(), <Object?>[
        'youtube:player_client=android_vr,ios',
        '',
        'youtube:player_client=mweb,web',
      ]);
      expect(seenArgs.map((e) => e.cookie).toList(), <Object?>[
        null,
        null,
        '/tmp/yt_cookies.txt',
      ]);
      expect(seenArgs.first.format, contains('height>=612'));
      expect(seenArgs.first.format.toString().contains('/best[height<=720]/best'), isFalse);
    });

    testWidgets('4) HomeAppBar, UrlInputBar, and DownloadJobCard render compactly with LTR metrics in RTL Arabic', (tester) async {
      final translator = AppTranslator(initialLanguage: 'ar');
      final controller = AppController(
        translator: translator,
        autoInitNative: false,
      );
      addTearDown(controller.dispose);
      final textCtrl = TextEditingController();
      addTearDown(textCtrl.dispose);

      final activeJob = DownloadJobState(
        id: 'rtl_job_1',
        title: 'درس تجربة الجودة',
        url: 'https://example.com/v.mp4',
        phase: DownloadPhase.downloadingVideo,
        status: DownloadStatus.downloading,
        progress: 0.25,
        downloadedBytes: 0,
        totalBytes: 293915852,
        speedBytesPerSec: 0,
        etaSeconds: 75,
        category: 'Video',
        createdAt: DateTime.utc(2026, 11, 26),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              appBar: HomeAppBar(
                translator: translator,
                controller: controller,
                onOpenCookies: () {},
                onOpenSettings: () {},
                onToggleLayoutMode: () {},
              ),
              body: Column(
                children: <Widget>[
                  UrlInputBar(
                    controller: textCtrl,
                    translator: translator,
                    isExtracting: false,
                    onPaste: () {},
                    onSubmit: () {},
                    onCancelExtract: () {},
                  ),
                  DownloadJobCard(
                    job: activeJob,
                    translator: translator,
                    onPause: () {},
                    onResume: () {},
                    onCancel: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // HomeAppBar keys, full app_short_name, EN compact label, Tooltip dot:
      expect(find.byKey(const Key('app_brand_icon')), findsOneWidget);
      expect(find.byKey(const Key('ytdlp_status_label')), findsOneWidget);
      expect(find.byKey(const Key('layout_mode_toggle_button')), findsOneWidget);
      expect(find.byKey(const Key('lang_toggle_button')), findsOneWidget);
      expect(find.byKey(const Key('open_cookies_button')), findsOneWidget);
      expect(find.byKey(const Key('open_settings_button')), findsOneWidget);
      expect(find.text(stringsAr['app_short_name']!), findsOneWidget);
      expect(find.text('EN'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byKey(const Key('ytdlp_status_label')),
          matching: find.byType(Tooltip),
        ),
        findsOneWidget,
      );

      // UrlInputBar single-line compact layout:
      final tf = tester.widget<TextField>(find.byKey(const Key('url_input_field')));
      expect(tf.maxLines, 1);
      expect(tf.minLines, 1);
      expect(find.byKey(const Key('url_paste_button')), findsOneWidget);
      expect(find.byKey(const Key('url_submit_button')), findsOneWidget);
      expect(tester.getSize(find.byType(UrlInputBar)).height, lessThan(80));

      // DownloadJobCard forces LTR on size, speed, and ETA inside RTL Arabic tree:
      final sizeTextFinder = find.textContaining('280.3 MB');
      final speedTextFinder = find.text('0 B/s');
      final etaTextFinder = find.text('1m 15s');
      expect(sizeTextFinder, findsOneWidget);
      expect(speedTextFinder, findsOneWidget);
      expect(etaTextFinder, findsOneWidget);
      expect(Directionality.of(tester.element(sizeTextFinder)), TextDirection.ltr);
      expect(Directionality.of(tester.element(speedTextFinder)), TextDirection.ltr);
      expect(Directionality.of(tester.element(etaTextFinder)), TextDirection.ltr);
    });
  });
}
