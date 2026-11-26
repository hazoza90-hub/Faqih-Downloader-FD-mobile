import 'dart:async';
import 'dart:io';

import 'package:faqih_downloader_mobile/core/models/download_status.dart';
import 'package:faqih_downloader_mobile/core/models/video_format_option.dart';
import 'package:faqih_downloader_mobile/engine/http_client_factory.dart';
import 'package:faqih_downloader_mobile/engine/server_prober.dart';
import 'package:faqih_downloader_mobile/engine/turbo_download_engine.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_job_models.dart';
import 'package:faqih_downloader_mobile/services/coordinator/media_post_pipeline.dart';
import 'package:faqih_downloader_mobile/services/coordinator/ytdlp_stream_downloader.dart';
import 'package:faqih_downloader_mobile/services/media/ffmpeg_media_processor.dart';
import 'package:faqih_downloader_mobile/services/media/media_exceptions.dart';
import 'package:faqih_downloader_mobile/services/media/media_extractor_service.dart';
import 'package:faqih_downloader_mobile/services/media/subtitle_font_provisioner.dart';
import 'package:faqih_downloader_mobile/services/media/subtitle_processor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../engine/mock_range_server.dart';

class _RealHttpOverrides extends HttpOverrides {}

Future<T> _withRealHttp<T>(Future<T> Function() action) =>
    HttpOverrides.runZoned<Future<T>>(
      action,
      createHttpClient: (ctx) => _RealHttpOverrides().createHttpClient(ctx),
    );

class _FakeHeaders implements HttpHeaders {
  final Map<String, List<String>> _map = <String, List<String>>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _map[name.toLowerCase()] = <String>[value.toString()];
  }

  @override
  String? value(String name) => _map[name.toLowerCase()]?.firstOrNull;

  @override
  List<String>? operator [](String name) => _map[name.toLowerCase()];

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _map.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, this.headers, this.cookies);

  @override
  final int statusCode;
  @override
  final HttpHeaders headers;
  @override
  final List<Cookie> cookies;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      const Stream<List<int>>.empty().listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.uri, this.responder);

  @override
  final Uri uri;
  @override
  final HttpHeaders headers = _FakeHeaders();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;

  final HttpClientResponse Function(Uri uri, HttpHeaders headers) responder;

  @override
  Future<HttpClientResponse> close() async => responder(uri, headers);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ScriptedHttpClient implements HttpClient {
  _ScriptedHttpClient(this.responder);
  final HttpClientResponse Function(Uri uri, HttpHeaders headers) responder;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeRequest(url, responder);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingFfmpeg extends FfmpegMediaProcessor {
  final List<String> muxOutputs = <String>[];

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
    muxOutputs.add(outputPath);
    await File(outputPath).writeAsBytes(const <int>[1, 2, 3], flush: true);
    return outputPath;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ytdlMethod = MethodChannel(ChannelNames.youtubeDl);
  const ytdlEvents = EventChannel(ChannelNames.youtubeDlEvents);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fd_b9_fix_test_');
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

  group('Batch 9 surgical fixes', () {
    test('YtDlpStreamDownloader retries YouTube strategies & cookie ordering and cleans stale attempt files', () async {
      final jobDir = p.join(tempDir.path, 'job_yt_retry');
      await Directory(jobDir).create(recursive: true);
      final attempts = <String>[];

      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'downloadMedia') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          final opts = Map<Object?, Object?>.from(args['options'] as Map);
          final extArgs = args['extractorArgs'];
          final cookie = opts['--cookies'];
          attempts.add('${extArgs ?? 'DEFAULT'}|${cookie ?? 'NO_COOKIE'}');
          if (attempts.length == 1) {
            await File(p.join(jobDir, 'ytdlp_stale.part')).writeAsBytes(<int>[1]);
          }
          if (attempts.length < 4) {
            return <String, Object?>{'exitCode': 1, 'stdout': '', 'stderr': '403'};
          }
          await File(p.join(jobDir, 'ytdlp_ok.mp4')).writeAsBytes(<int>[1, 2, 3]);
          return <String, Object?>{'exitCode': 0, 'stdout': 'ok', 'stderr': ''};
        }
        return null;
      });

      final downloader = YtDlpStreamDownloader(
        YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
      );
      final outPath = await downloader.download(
        request: const DownloadJobRequest(
          id: 'yt_retry_1',
          url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          title: 'YT',
          cookiesFile: '/tmp/cookies.txt',
        ),
        jobDir: jobDir,
        formatOption: null,
        audioOption: null,
        isCancelled: () => false,
        setActiveProcessId: (_) {},
        setActivePhase: (_) {},
        onProgress: (_, _, _, _, _, _) {},
      );

      expect(outPath, endsWith('ytdlp_ok.mp4'));
      expect(File(p.join(jobDir, 'ytdlp_stale.part')).existsSync(), isFalse);
      expect(attempts, <String>[
        'youtube:player_client=android_vr|NO_COOKIE',
        'youtube:player_client=ios,mweb|NO_COOKIE',
        '|NO_COOKIE',
        'youtube:player_client=mweb,web|/tmp/cookies.txt',
      ]);

      // Non-YouTube tries with cookies first, then without cookies:
      attempts.clear();
      final igDir = p.join(tempDir.path, 'job_ig_retry');
      await Directory(igDir).create(recursive: true);
      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'downloadMedia') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          final opts = Map<Object?, Object?>.from(args['options'] as Map);
          final cookie = opts['--cookies'];
          attempts.add('${cookie ?? 'NO_COOKIE'}');
          if (cookie != null) {
            return <String, Object?>{'exitCode': 1, 'stdout': '', 'stderr': 'bad'};
          }
          await File(p.join(igDir, 'ytdlp_ig.mp4')).writeAsBytes(<int>[7, 8]);
          return <String, Object?>{'exitCode': 0, 'stdout': 'ok', 'stderr': ''};
        }
        return null;
      });

      final igOut = await downloader.download(
        request: const DownloadJobRequest(
          id: 'ig_retry_1',
          url: 'https://www.instagram.com/reel/abc123/',
          title: 'IG',
          cookiesFile: '/tmp/cookies.txt',
        ),
        jobDir: igDir,
        formatOption: null,
        audioOption: null,
        isCancelled: () => false,
        setActiveProcessId: (_) {},
        setActivePhase: (_) {},
        onProgress: (_, _, _, _, _, _) {},
      );
      expect(igOut, endsWith('ytdlp_ig.mp4'));
      expect(attempts, <String>['/tmp/cookies.txt', 'NO_COOKIE']);
    });

    test('ServerProber recovers via plain GET when Range fails with 403, and Turbo single-stream fallback accepts different final size', () => _withRealHttp(() async {
      final actualPayload = generateTestPayload(64 * 1024, seed: 51);
      final actualSha = sha256HexOf(actualPayload);

      // 1. HEAD -> 405, GET Range -> 403, GET plain -> 200 (1024 bytes)
      final proberSrv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(proberSrv.close);
      proberSrv.listen((req) async {
        if (req.method == 'HEAD') {
          req.response.statusCode = HttpStatus.methodNotAllowed;
          await req.response.close();
          return;
        }
        if (req.headers.value(HttpHeaders.rangeHeader) != null) {
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.ok;
        req.response.contentLength = 1024;
        req.response.add(List<int>.filled(1024, 1));
        await req.response.close();
      });

      final probe = await ServerProber().probe('http://127.0.0.1:${proberSrv.port}/app.apk');
      expect(probe.linkExpired, isFalse);
      expect(probe.httpStatus, HttpStatus.ok);
      expect(probe.totalSize, 1024);
      expect(probe.supportsRanges, isFalse);

      // 2. Probed size 100000 with 403 on ranged multi-chunk, plain single-stream returns 65536 bytes:
      final engSrv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(engSrv.close);
      engSrv.listen((req) async {
        req.response.headers.contentType = ContentType.binary;
        req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        if (req.method == 'HEAD') {
          req.response.contentLength = 100000;
          await req.response.close();
          return;
        }
        final range = req.headers.value(HttpHeaders.rangeHeader);
        if (range == 'bytes=0-0') {
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/100000');
          req.response.contentLength = 1;
          req.response.add(<int>[actualPayload[0]]);
          await req.response.close();
          return;
        }
        if (range != null) {
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.ok;
        req.response.contentLength = actualPayload.length;
        req.response.add(actualPayload);
        await req.response.close();
      });

      final dest = p.join(tempDir.path, 'diff_size_fallback.bin');
      final engine = TurboDownloadEngine(
        url: 'http://127.0.0.1:${engSrv.port}/diff.bin',
        destinationPath: dest,
        maxConnections: 4,
        minSplitThreshold: 16 * 1024,
        expectedSha256: actualSha,
      );
      await engine.start();
      expect(engine.status, DownloadStatus.completed);
      expect(File(dest).lengthSync(), actualPayload.length);
      expect(sha256HexOf(File(dest).readAsBytesSync()), actualSha);
    }));

    test('HttpClientFactory blocks SSRF private redirects, scopes cookies by domain, and rejects malformed Location', () async {
      // 1. Public -> 127.0.0.1 SSRF block
      final ssrfClient = _ScriptedHttpClient((uri, _) {
        final h = _FakeHeaders()..set(HttpHeaders.locationHeader, 'http://127.0.0.1:8080/internal');
        return _FakeResponse(HttpStatus.found, h, const <Cookie>[]);
      });
      await expectLater(
        HttpClientFactory.openWithCookieRedirects(
          client: ssrfClient,
          method: 'GET',
          uri: Uri.parse('https://public.example.com/start'),
        ),
        throwsA(isA<StateError>()),
      );

      // 2. Domain-scoped cookies: a.example.com -> dl.example.com (receives cookie) -> other-cdn.test (does NOT receive cookie)
      final seenByHost = <String, String?>{};
      final scopeClient = _ScriptedHttpClient((uri, reqHeaders) {
        seenByHost[uri.host] = reqHeaders.value(HttpHeaders.cookieHeader);
        if (uri.host == 'a.example.com') {
          final h = _FakeHeaders()..set(HttpHeaders.locationHeader, 'https://dl.example.com/step2');
          return _FakeResponse(
            HttpStatus.found,
            h,
            <Cookie>[Cookie('auth_tok', 'secret')..domain = 'example.com'],
          );
        }
        if (uri.host == 'dl.example.com') {
          final h = _FakeHeaders()..set(HttpHeaders.locationHeader, 'https://other-cdn.test/final.bin');
          return _FakeResponse(HttpStatus.found, h, const <Cookie>[]);
        }
        return _FakeResponse(HttpStatus.ok, _FakeHeaders(), const <Cookie>[]);
      });

      final scopedRes = await HttpClientFactory.openWithCookieRedirects(
        client: scopeClient,
        method: 'GET',
        uri: Uri.parse('https://a.example.com/start'),
      );
      expect(scopedRes.finalUri.host, 'other-cdn.test');
      expect(seenByHost['dl.example.com'], contains('auth_tok=secret'));
      expect(seenByHost['other-cdn.test'], isNull);

      // 3. Malformed Location throws HttpException
      final badLocClient = _ScriptedHttpClient((uri, _) {
        final h = _FakeHeaders()..set(HttpHeaders.locationHeader, 'http://[::invalid');
        return _FakeResponse(HttpStatus.found, h, const <Cookie>[]);
      });
      await expectLater(
        HttpClientFactory.openWithCookieRedirects(
          client: badLocClient,
          method: 'GET',
          uri: Uri.parse('https://public.example.com/bad'),
        ),
        throwsA(isA<HttpException>()),
      );
    });

    test('MediaExtractorService skips updateYtDlp on non-media unsupportedUrl and halts on cancelExtraction', () async {
      var updateCalls = 0;
      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'updateYoutubeDL') {
          updateCalls++;
          return <String, Object?>{'status': 'DONE', 'ytdlpVersion': '2026.12.01'};
        }
        if (call.method == 'extractInfo') {
          throw PlatformException(code: 'YOUTUBEDL_ERROR', message: 'Unsupported URL: https://plain.example.com/page');
        }
        return null;
      });

      final extractor = MediaExtractorService(
        channel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
      );
      await expectLater(
        extractor.extractInfo('https://plain.example.com/page'),
        throwsA(isA<MediaExtractionException>().having((e) => e.kind, 'kind', MediaErrorKind.unsupportedUrl)),
      );
      expect(updateCalls, 0);

      // Cancel mid-strategy: must NOT invoke remaining YouTube strategies
      var extractCalls = 0;
      late MediaExtractorService cancellable;
      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'cancelProcess') return true;
        if (call.method == 'extractInfo') {
          extractCalls++;
          await cancellable.cancelExtraction('ext_stop');
          throw PlatformException(code: 'YOUTUBEDL_ERROR', message: 'timed out');
        }
        return null;
      });
      cancellable = MediaExtractorService(
        channel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
      );

      await expectLater(
        cancellable.extractInfo('https://www.youtube.com/watch?v=dQw4w9WgXcQ', processId: 'ext_stop'),
        throwsA(isA<MediaExtractionException>().having((e) => e.kind, 'kind', MediaErrorKind.cancelled)),
      );
      expect(extractCalls, 1);
    });

    test('MediaPostPipeline preserves ext webm when unmuxed and uses mkv when muxing VP9/WebM audio', () async {
      final jobDir = p.join(tempDir.path, 'job_webm');
      await Directory(jobDir).create(recursive: true);
      final rawWebm = File(p.join(jobDir, 'raw_video.webm'))..writeAsBytesSync(<int>[1, 2, 3]);
      final rawAud = File(p.join(jobDir, 'raw_audio.opus'))..writeAsBytesSync(<int>[4, 5, 6]);

      final ffmpeg = _RecordingFfmpeg();
      final pipeline = MediaPostPipeline(
        ffmpeg: ffmpeg,
        subtitleProcessor: SubtitleProcessor(),
        fontProvisioner: SubtitleFontProvisioner(),
      );

      // 1. Progressive/unmuxed raw .webm keeps .webm ext:
      final rawRes = await pipeline.process(
        request: const DownloadJobRequest(
          id: 'raw_webm_job',
          url: 'https://example.com/v.webm',
          title: 'Raw WebM',
          selectedVideoFormat: VideoFormatOption(
            formatId: '43',
            resolutionLabel: '360p',
            ext: 'webm',
            vcodec: 'vp8',
            isProgressive: true,
          ),
        ),
        jobDir: jobDir,
        workDir: tempDir.path,
        rawVideoPath: rawWebm.path,
        rawAudioPath: null,
        isCancelled: () => false,
        onPhase: (_, {progress}) {},
        onTrackProcess: (_) {},
      );
      expect(rawRes.ext, 'webm');
      expect(rawRes.filePath, rawWebm.path);
      expect(ffmpeg.muxOutputs, isEmpty);

      // 2. VP9 + WebM muxed with separate audio uses .mkv container directly:
      final muxRes = await pipeline.process(
        request: const DownloadJobRequest(
          id: 'mux_webm_job',
          url: 'https://example.com/v_vp9',
          title: 'Muxed VP9',
          selectedVideoFormat: VideoFormatOption(
            formatId: '248',
            resolutionLabel: '1080p',
            ext: 'webm',
            vcodec: 'vp9',
          ),
        ),
        jobDir: jobDir,
        workDir: tempDir.path,
        rawVideoPath: rawWebm.path,
        rawAudioPath: rawAud.path,
        isCancelled: () => false,
        onPhase: (_, {progress}) {},
        onTrackProcess: (_) {},
      );
      expect(ffmpeg.muxOutputs.single, endsWith('stage_mux.mkv'));
      expect(muxRes.ext, 'mkv');
      expect(muxRes.filePath, endsWith('stage_mux.mkv'));
    });
  });
}
