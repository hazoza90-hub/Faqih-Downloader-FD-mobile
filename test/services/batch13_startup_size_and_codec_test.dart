import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:faqih_downloader_mobile/core/models/audio_track.dart';
import 'package:faqih_downloader_mobile/core/models/download_status.dart';
import 'package:faqih_downloader_mobile/core/models/video_format_option.dart';
import 'package:faqih_downloader_mobile/core/models/youtube_stream_info.dart';
import 'package:faqih_downloader_mobile/engine/engine_callbacks.dart';
import 'package:faqih_downloader_mobile/engine/http_client_factory.dart';
import 'package:faqih_downloader_mobile/engine/isolate_download_runner.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_job_models.dart';
import 'package:faqih_downloader_mobile/services/coordinator/media_post_pipeline.dart';
import 'package:faqih_downloader_mobile/services/coordinator/media_stream_acquirer.dart';
import 'package:faqih_downloader_mobile/services/coordinator/media_stream_helpers.dart';
import 'package:faqih_downloader_mobile/services/coordinator/ytdlp_progress_parser.dart';
import 'package:faqih_downloader_mobile/services/coordinator/ytdlp_stream_downloader.dart';
import 'package:faqih_downloader_mobile/services/media/ffmpeg_media_processor.dart';
import 'package:faqih_downloader_mobile/services/media/format_ranker.dart';
import 'package:faqih_downloader_mobile/services/media/format_ranker_helpers.dart';
import 'package:faqih_downloader_mobile/services/media/media_extractor_service.dart';
import 'package:faqih_downloader_mobile/services/media/subtitle_font_provisioner.dart';
import 'package:faqih_downloader_mobile/services/media/subtitle_processor.dart';
import 'package:faqih_downloader_mobile/services/media/youtube_innertube_extractor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _RealHttpOverrides extends HttpOverrides {}

class _NullInnerTubeExtractor extends YouTubeInnerTubeExtractor {
  @override
  Future<YouTubeStreamInfo?> extract(
    String url, {
    void Function(void Function() aborter)? onRegisterAbort,
    int startProfileIndex = 0,
  }) async =>
      null;
}

class _FakeFfmpegMux extends FfmpegMediaProcessor {
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

class _DualProgressTurboRunner extends IsolateDownloadRunner {
  _DualProgressTurboRunner({
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
      await File(destinationPath).parent.create(recursive: true);
      if (url.contains('video')) {
        callbacks?.onProgress?.call(const EngineProgressSnapshot(
          downloadedBytes: 500,
          totalBytes: 1000,
          speedBytesPerSec: 250,
          etaSeconds: 2,
          activeWorkers: 2,
          status: DownloadStatus.downloading,
          chunks: [],
        ));
        await File(destinationPath).writeAsBytes(List<int>.filled(1000, 7));
        callbacks?.onComplete?.call(destinationPath, 1000, 0.2);
      } else {
        callbacks?.onProgress?.call(const EngineProgressSnapshot(
          downloadedBytes: 100,
          totalBytes: 250,
          speedBytesPerSec: 125,
          etaSeconds: 1,
          activeWorkers: 1,
          status: DownloadStatus.downloading,
          chunks: [],
        ));
        await File(destinationPath).writeAsBytes(List<int>.filled(250, 9));
        callbacks?.onComplete?.call(destinationPath, 250, 0.1);
      }
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
    tempDir = await Directory.systemTemp.createTemp('fd_b13_test_');
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

  group('Batch 13 startup speed, size accuracy, vp09 & codec fallback', () {
    test('1) HttpClientFactory.preferredAddressTypeForUri handles IPv4, IPv6, non-googlevideo, loopback & missing ip', () async {
      expect(
        HttpClientFactory.preferredAddressTypeForUri(
          Uri.parse('https://rr1---sn.googlevideo.com/videoplayback?ip=203.0.113.5&itag=137'),
        ),
        InternetAddressType.IPv4,
      );
      expect(
        HttpClientFactory.preferredAddressTypeForUri(
          Uri.parse('https://rr1---sn.googlevideo.com/videoplayback?ip=2001:db8::1&itag=137'),
        ),
        InternetAddressType.IPv6,
      );
      expect(
        HttpClientFactory.preferredAddressTypeForUri(
          Uri.parse('https://cdn.example.com/videoplayback?ip=203.0.113.5'),
        ),
        isNull,
      );
      expect(
        HttpClientFactory.preferredAddressTypeForUri(
          Uri.parse('http://127.0.0.1:8080/googlevideo.com/videoplayback?ip=203.0.113.5'),
        ),
        isNull,
      );
      expect(
        HttpClientFactory.preferredAddressTypeForUri(
          Uri.parse('http://localhost/googlevideo.com?ip=203.0.113.5'),
        ),
        isNull,
      );
      expect(
        HttpClientFactory.preferredAddressTypeForUri(
          Uri.parse('https://rr1---sn.googlevideo.com/videoplayback?itag=137'),
        ),
        isNull,
      );
      expect(
        HttpClientFactory.preferredAddressTypeForUri(
          Uri.parse('https://rr1---sn.googlevideo.com/videoplayback?ip='),
        ),
        isNull,
      );

      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          req.response.write('ok');
          await req.response.close();
        });
        final client = HttpClientFactory.create(connectionTimeout: const Duration(seconds: 5));
        addTearDown(() => client.close(force: true));
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/ping'));
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.ok);
        expect(await utf8.decodeStream(resp), 'ok');
      });
    });

    test('1b) HttpClientFactory.create sends TLS ClientHello (0x16 0x03) for HTTPS and plaintext HTTP for http://', () async {
      await runWithRealHttp(() async {
        final rawServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => rawServer.close());
        final firstPacket = Completer<List<int>>();

        final sub = rawServer.listen((socket) {
          socket.listen(
            (data) {
              if (!firstPacket.isCompleted) firstPacket.complete(data);
              socket.destroy();
            },
            onError: (_) {},
            onDone: () {
              if (!firstPacket.isCompleted) firstPacket.complete(const <int>[]);
            },
          );
        });
        addTearDown(() => sub.cancel());

        final httpsClient = HttpClientFactory.create(connectionTimeout: const Duration(seconds: 5));
        addTearDown(() => httpsClient.close(force: true));

        final reqFuture = httpsClient
            .getUrl(Uri.parse('https://127.0.0.1:${rawServer.port}/tls-check'))
            .then((req) => req.close())
            .then<void>((_) {}, onError: (_) {});

        final bytes = await firstPacket.future.timeout(const Duration(seconds: 5));
        await reqFuture;

        expect(bytes.length, greaterThanOrEqualTo(2));
        expect(bytes.sublist(0, 2), <int>[0x16, 0x03]);
        expect(bytes.sublist(0, 2), isNot(<int>[0x47, 0x45]));
      });

      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          if (req.uri.path == '/plain-check') {
            req.response.write('plain-ok');
          } else {
            req.response.statusCode = HttpStatus.notFound;
          }
          await req.response.close();
        });

        final plainClient = HttpClientFactory.create(connectionTimeout: const Duration(seconds: 5));
        addTearDown(() => plainClient.close(force: true));
        final req = await plainClient.getUrl(Uri.parse('http://127.0.0.1:${server.port}/plain-check'));
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.ok);
        expect(await utf8.decodeStream(resp), 'plain-ok');
      });
    });

    test('2) InnerTube & resolveFormatFilesize fall back to clen= and prefer averageBitrate over bitrate', () {
      final extractor = YouTubeInnerTubeExtractor();
      final info = extractor.parsePlayerResponse(<String, dynamic>{
        'playabilityStatus': <String, dynamic>{'status': 'OK'},
        'videoDetails': <String, dynamic>{
          'videoId': 'dQw4w9WgXcQ',
          'title': 'Size Accuracy',
          'lengthSeconds': '100',
        },
        'streamingData': <String, dynamic>{
          'adaptiveFormats': <Map<String, dynamic>>[
            <String, dynamic>{
              'itag': 137,
              'url': 'https://rr1.googlevideo.com/videoplayback?clen=39845888&itag=137',
              'mimeType': 'video/mp4; codecs="avc1.640028"',
              'width': 1920,
              'height': 1080,
              'averageBitrate': 3187000,
              'bitrate': 7500000,
            },
            <String, dynamic>{
              'itag': 140,
              'url': 'https://rr1.googlevideo.com/videoplayback?clen=1600000&itag=140',
              'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
              'averageBitrate': 128000,
              'bitrate': 256000,
            },
          ],
        },
      }, 'dQw4w9WgXcQ');

      expect(info, isNotNull);
      final vid = info!.videoFormats.single;
      expect(vid.filesizeApprox, 39845888);
      expect(vid.tbrKbps, closeTo(3187.0, 0.01));
      expect(info.audioTracks.single.filesize, 1600000);
      expect(info.audioTracks.single.bitrateKbps, 128);

      expect(
        resolveFormatFilesize(
          <String, dynamic>{
            'url': 'https://rr2.googlevideo.com/videoplayback?itag=248&clen=41234567',
          },
          rootDuration: 120,
          tbrKbps: 6000,
        ),
        41234567,
      );
      expect(
        resolveFormatFilesize(
          <String, dynamic>{
            'filesize': 50000,
            'url': 'https://rr2.googlevideo.com/videoplayback?clen=99999',
          },
          rootDuration: 120,
          tbrKbps: 6000,
        ),
        50000,
      );
    });

    test('3) vp09 recognized in FormatRanker, YtDlpProgressParser, and MediaPostPipeline', () async {
      const avc = VideoFormatOption(formatId: '137', resolutionLabel: '1080p', ext: 'mp4', vcodec: 'avc1.640028', tbrKbps: 2500);
      const vp09 = VideoFormatOption(formatId: '248', resolutionLabel: '1080p', ext: 'webm', vcodec: 'vp09.00.40.08', tbrKbps: 2500);
      const av01 = VideoFormatOption(formatId: '399', resolutionLabel: '1080p', ext: 'mp4', vcodec: 'av01.0.08M.08', tbrKbps: 2500);

      expect(scoreVideoOption(avc), greaterThan(scoreVideoOption(vp09)));
      expect(scoreVideoOption(vp09), greaterThan(scoreVideoOption(av01)));
      expect(YtDlpProgressParser.mergeOutputFormatFor(vp09), 'mkv');

      const ranker = FormatRanker();
      final ranked = ranker.parse(<String, dynamic>{
        'id': 'vp09_win',
        'title': 'High Res',
        'formats': <Map<String, dynamic>>[
          <String, dynamic>{'format_id': '399', 'height': 1440, 'ext': 'mp4', 'vcodec': 'av01.0.12M.08', 'acodec': 'none', 'tbr': 8000.0, 'url': 'https://cdn.example.com/av01.mp4'},
          <String, dynamic>{'format_id': '271', 'height': 1440, 'ext': 'mp4', 'vcodec': 'vp09.00.51.08', 'acodec': 'none', 'tbr': 6000.0, 'url': 'https://cdn.example.com/vp09.mp4'},
        ],
      });
      expect(ranked.videoFormats.single.formatId, '271');

      final jobDir = p.join(tempDir.path, 'vp09_mux');
      await Directory(jobDir).create(recursive: true);
      final rawVid = File(p.join(jobDir, 'raw_video.mp4'))..writeAsBytesSync(<int>[1, 2]);
      final rawAud = File(p.join(jobDir, 'raw_audio.m4a'))..writeAsBytesSync(<int>[3, 4]);
      final ffmpeg = _FakeFfmpegMux();
      final pipeline = MediaPostPipeline(
        ffmpeg: ffmpeg,
        subtitleProcessor: SubtitleProcessor(),
        fontProvisioner: SubtitleFontProvisioner(),
      );
      final res = await pipeline.process(
        request: const DownloadJobRequest(
          id: 'vp09_pipe',
          url: 'https://youtube.com/watch?v=dQw4w9WgXcQ',
          title: 'VP09',
          selectedVideoFormat: VideoFormatOption(formatId: '271', resolutionLabel: '1440p', ext: 'mp4', vcodec: 'vp09.00.51.08'),
        ),
        jobDir: jobDir,
        workDir: tempDir.path,
        rawVideoPath: rawVid.path,
        rawAudioPath: rawAud.path,
        isCancelled: () => false,
        onPhase: (_, {progress}) {},
        onTrackProcess: (_) {},
      );
      expect(ffmpeg.muxOutputs.single, endsWith('stage_mux.mkv'));
      expect(res.ext, 'mkv');
    });

    test('4) MediaStreamHelpers.pickInnerTubeFormat preserves formatId/codec and combineDualStreamSnapshot keeps total steady', () async {
      const info = YouTubeStreamInfo(
        videoId: 'v1',
        title: 'Codec Match',
        cleanFilename: 'Codec_Match',
        isProgressive: false,
        webpageUrl: 'https://youtube.com/watch?v=v1',
        videoUrl: 'https://cdn.example.com/1080_av01.mp4',
        videoFormats: <VideoFormatOption>[
          VideoFormatOption(formatId: '399', resolutionLabel: '1080p', height: 1080, vcodec: 'av01.0.08M.08', videoUrl: 'https://cdn.example.com/1080_av01.mp4'),
          VideoFormatOption(formatId: '248', resolutionLabel: '1080p', height: 1080, vcodec: 'vp09.00.40.08', videoUrl: 'https://cdn.example.com/1080_vp09.webm'),
          VideoFormatOption(formatId: '136', resolutionLabel: '720p', height: 720, vcodec: 'avc1.4d401f', videoUrl: 'https://cdn.example.com/720_avc1.mp4'),
        ],
      );

      expect(
        MediaStreamHelpers.pickInnerTubeFormat(info, 1080, preferredFormatId: '248')?.formatId,
        '248',
      );
      expect(
        MediaStreamHelpers.pickInnerTubeFormat(info, 1080, preferredFormatId: '999', preferredVcodec: 'vp09.00.40.08')?.formatId,
        '248',
      );
      expect(
        MediaStreamHelpers.pickInnerTubeFormat(info, 1080, preferredFormatId: '999', preferredVcodec: 'avc1.640028')?.formatId,
        '136',
      );

      final jobDir = p.join(tempDir.path, 'dual_prog');
      await Directory(jobDir).create(recursive: true);
      final snapshots = <({DownloadPhase phase, int dl, int total})>[];

      final acquirer = MediaStreamAcquirer(
        youtubeDl: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
        runnerFactory: ({
          required url,
          required destinationPath,
          headers = const <String, String>{},
          maxConnections = 8,
          speedLimitBytesPerSec = 0.0,
          callbacks,
        }) =>
            _DualProgressTurboRunner(
          url: url,
          destinationPath: destinationPath,
          headers: headers,
          maxConnections: maxConnections,
          speedLimitBytesPerSec: speedLimitBytesPerSec,
          callbacks: callbacks,
        ),
      );

      await acquirer.acquireMedia(
        request: const DownloadJobRequest(
          id: 'dual_1',
          url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          title: 'Dual',
          selectedVideoFormat: VideoFormatOption(
            formatId: '137',
            resolutionLabel: '1080p',
            height: 1080,
            filesizeApprox: 1000,
            audioSize: 250,
            videoUrl: 'https://cdn.example.com/video.mp4',
            audioUrl: 'https://cdn.example.com/audio.m4a',
          ),
        ),
        jobDir: jobDir,
        speedLimitBytesPerSec: 0,
        isCancelled: () => false,
        isPaused: () => false,
        setActiveRunner: (_) {},
        setActiveProcessId: (_) {},
        setActivePhase: (_) {},
        onTurboProgress: (phase, snap) {
          snapshots.add((phase: phase, dl: snap.downloadedBytes, total: snap.totalBytes));
        },
        onYtDlpProgress: (_, _, _, _, _, _) {},
      );

      expect(snapshots.length, 2);
      expect(snapshots[0], (phase: DownloadPhase.downloadingVideo, dl: 500, total: 1250));
      expect(snapshots[1], (phase: DownloadPhase.downloadingAudio, dl: 1100, total: 1250));
    });

    test('5) YtDlpStreamDownloader.buildSelector adds codec-matching fallback layer before general fallback', () {
      final selAv01 = YtDlpStreamDownloader.buildSelector(
        const DownloadJobRequest(id: 's1', url: 'https://youtube.com/watch?v=dQw4w9WgXcQ', title: 'T'),
        const VideoFormatOption(formatId: '399', resolutionLabel: '1080p', height: 1080, vcodec: 'av01.0.08M.08'),
        const AudioTrack(trackId: 'a1', formatId: '140', language: 'en', label: 'EN', url: 'u', isOriginal: true),
      );
      expect(
        selAv01,
        '399+140/bestvideo[height<=1080][vcodec^=av01]+bestaudio/bestvideo[height<=1080]+bestaudio/best[height<=1080]/best',
      );

      final selVp09 = YtDlpStreamDownloader.buildSelector(
        const DownloadJobRequest(id: 's2', url: 'https://youtube.com/watch?v=dQw4w9WgXcQ', title: 'T'),
        const VideoFormatOption(formatId: '248', resolutionLabel: '1080p', height: 1080, vcodec: 'vp09.00.40.08'),
        null,
      );
      expect(
        selVp09,
        '248+bestaudio/bestvideo[height<=1080][vcodec^=vp9]+bestaudio/bestvideo[height<=1080]+bestaudio/best[height<=1080]/best',
      );

      final selAvc1 = YtDlpStreamDownloader.buildSelector(
        const DownloadJobRequest(id: 's3', url: 'https://youtube.com/watch?v=dQw4w9WgXcQ', title: 'T'),
        const VideoFormatOption(formatId: '137', resolutionLabel: '1080p', height: 1080, vcodec: 'avc1.640028'),
        null,
      );
      expect(
        selAvc1,
        '137+bestaudio/bestvideo[height<=1080][vcodec^=avc1]+bestaudio/bestvideo[height<=1080]+bestaudio/best[height<=1080]/best',
      );
    });

    test('6) YtDlpProgressParser & YtDlpStreamDownloader guard ~ HLS estimate spikes and use android_vr,ios first', () async {
      final approxSample = YtDlpStreamDownloader.parseProgressLine(
        '[download]   1.2% of ~  95.00MiB at    1.00MiB/s ETA 01:30',
      );
      expect(approxSample.isTotalApproximate, isTrue);
      expect(approxSample.totalBytes, (95.0 * 1024 * 1024).round());

      final exactSample = YtDlpStreamDownloader.parseProgressLine(
        '[download]  10.0% of   38.50MiB at    2.00MiB/s ETA 00:15',
      );
      expect(exactSample.isTotalApproximate, isFalse);

      final jobDir = p.join(tempDir.path, 'approx_guard');
      await Directory(jobDir).create(recursive: true);
      final seenStrategies = <Object?>[];

      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'downloadMedia') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          seenStrategies.add(args['extractorArgs']);
          final pid = args['processId'].toString();
          for (final payload in <Map<String, Object?>>[
            <String, Object?>{
              'type': 'progress',
              'processId': pid,
              'progress': 1.2,
              'etaSeconds': 90,
              'line': '[download]   1.2% of ~  95.00MiB at    1.00MiB/s ETA 01:30',
            },
            <String, Object?>{
              'type': 'progress',
              'processId': pid,
              'progress': 20.0,
              'etaSeconds': 30,
              'line': '[download]  20.0% of ~  40.00MiB at    2.00MiB/s ETA 00:30',
            },
            <String, Object?>{
              'type': 'progress',
              'processId': pid,
              'progress': 25.0,
              'etaSeconds': 20,
              'line': '[download]  25.0% of   39.00MiB at    2.00MiB/s ETA 00:20',
            },
          ]) {
            await messenger.handlePlatformMessage(
              ChannelNames.youtubeDlEvents,
              const StandardMethodCodec().encodeSuccessEnvelope(payload),
              (_) {},
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await File(p.join(jobDir, 'ytdlp_out.mp4')).writeAsBytes(<int>[1, 2, 3]);
          return <String, Object?>{'exitCode': 0, 'stdout': 'ok', 'stderr': ''};
        }
        return null;
      });

      final recordedTotals = <int>[];
      final dl = YtDlpStreamDownloader(
        YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
      );
      await dl.download(
        request: const DownloadJobRequest(
          id: 'approx_1',
          url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          title: 'Approx Guard',
          selectedVideoFormat: VideoFormatOption(
            formatId: '137',
            resolutionLabel: '1080p',
            height: 1080,
            filesizeApprox: 38 * 1024 * 1024,
            audioSize: 2 * 1024 * 1024,
          ),
        ),
        jobDir: jobDir,
        formatOption: const VideoFormatOption(
          formatId: '137',
          resolutionLabel: '1080p',
          height: 1080,
          filesizeApprox: 38 * 1024 * 1024,
          audioSize: 2 * 1024 * 1024,
        ),
        audioOption: null,
        isCancelled: () => false,
        setActiveProcessId: (_) {},
        setActivePhase: (_) {},
        onProgress: (_, _, _, _, total, _) => recordedTotals.add(total),
      );

      expect(seenStrategies, <Object?>['youtube:player_client=android_vr,ios']);
      expect(recordedTotals, <int>[
        40 * 1024 * 1024, // initial
        40 * 1024 * 1024, // 1.2% ~95MiB ignored!
        (40.0 * 1024 * 1024).round(), // 20% ~40MiB accepted
        (39.0 * 1024 * 1024).round(), // exact 39MiB accepted
      ]);
    });

    test('7) concurrent _tryAutoUpdateOnce() calls share in-flight update in YtDlpStreamDownloader and MediaExtractorService', () async {
      final jobDir1 = p.join(tempDir.path, 'upd_1');
      final jobDir2 = p.join(tempDir.path, 'upd_2');
      await Directory(jobDir1).create(recursive: true);
      await Directory(jobDir2).create(recursive: true);

      var updateCalls = 0;
      final updateCompleter = Completer<Map<String, Object?>>();
      var updated = false;

      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'updateYoutubeDL') {
          updateCalls++;
          final res = await updateCompleter.future;
          updated = true;
          return res;
        }
        if (call.method == 'downloadMedia') {
          final opts = Map<Object?, Object?>.from((call.arguments as Map)['options'] as Map);
          final dir = File(opts['-o'].toString()).parent.path;
          if (!updated) {
            return <String, Object?>{'exitCode': 1, 'stdout': '', 'stderr': 'ERROR: HTTP Error 403'};
          }
          await File(p.join(dir, 'ytdlp_ok.mp4')).writeAsBytes(<int>[1, 2]);
          return <String, Object?>{'exitCode': 0, 'stdout': 'ok', 'stderr': ''};
        }
        return null;
      });

      final dl = YtDlpStreamDownloader(
        YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
      );
      final f1 = dl.download(
        request: const DownloadJobRequest(id: 'u1', url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', title: 'U1'),
        jobDir: jobDir1,
        formatOption: null,
        audioOption: null,
        isCancelled: () => false,
        setActiveProcessId: (_) {},
        setActivePhase: (_) {},
        onProgress: (_, _, _, _, _, _) {},
      );
      final f2 = dl.download(
        request: const DownloadJobRequest(id: 'u2', url: 'https://www.youtube.com/watch?v=9bZkp7q19f0', title: 'U2'),
        jobDir: jobDir2,
        formatOption: null,
        audioOption: null,
        isCancelled: () => false,
        setActiveProcessId: (_) {},
        setActivePhase: (_) {},
        onProgress: (_, _, _, _, _, _) {},
      );

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(updateCalls, 1);
      updateCompleter.complete(<String, Object?>{'status': 'DONE', 'ytdlpVersion': '2026.12.01'});

      final outs = await Future.wait(<Future<String>>[f1, f2]);
      expect(outs[0], endsWith('ytdlp_ok.mp4'));
      expect(outs[1], endsWith('ytdlp_ok.mp4'));
      expect(updateCalls, 1);

      // Same concurrent behavior in MediaExtractorService:
      var extUpdateCalls = 0;
      final extCompleter = Completer<Map<String, Object?>>();
      var extUpdated = false;
      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'updateYoutubeDL') {
          extUpdateCalls++;
          final res = await extCompleter.future;
          extUpdated = true;
          return res;
        }
        if (call.method == 'extractInfo') {
          if (!extUpdated) {
            throw PlatformException(code: 'YOUTUBEDL_ERROR', message: 'HTTP Error 403');
          }
          return jsonEncode(<String, dynamic>{
            'id': 'ext_ok',
            'title': 'Concurrent OK',
            'formats': <Map<String, dynamic>>[
              <String, dynamic>{'format_id': '18', 'url': 'https://cdn.example.com/ok.mp4', 'ext': 'mp4', 'vcodec': 'avc1', 'acodec': 'mp4a', 'height': 360},
            ],
          });
        }
        return null;
      });

      final extractor = MediaExtractorService(
        channel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
        innerTubeExtractor: _NullInnerTubeExtractor(),
      );
      final ef1 = extractor.extractInfo('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      final ef2 = extractor.extractInfo('https://www.youtube.com/watch?v=9bZkp7q19f0');

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(extUpdateCalls, 1);
      extCompleter.complete(<String, Object?>{'status': 'DONE', 'ytdlpVersion': '2026.12.01'});

      final einfo = await Future.wait(<Future<YouTubeStreamInfo>>[ef1, ef2]);
      expect(einfo[0].title, 'Concurrent OK');
      expect(einfo[1].title, 'Concurrent OK');
      expect(extUpdateCalls, 1);
    });
  });
}
