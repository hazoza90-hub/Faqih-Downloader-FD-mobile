import 'dart:io';

import 'package:faqih_downloader_mobile/core/models/audio_track.dart';
import 'package:faqih_downloader_mobile/core/models/download_status.dart';
import 'package:faqih_downloader_mobile/core/models/video_format_option.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/media_store_channel.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_job_models.dart';
import 'package:faqih_downloader_mobile/services/coordinator/stream_download_coordinator.dart';
import 'package:faqih_downloader_mobile/services/history/history_manager.dart';
import 'package:faqih_downloader_mobile/services/history/history_storage.dart';
import 'package:faqih_downloader_mobile/services/media/ffmpeg_media_processor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../engine/mock_range_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ytdlMethod = MethodChannel(ChannelNames.youtubeDl);
  const ytdlEvents = EventChannel(ChannelNames.youtubeDlEvents);
  const mediaStoreMethod = MethodChannel(ChannelNames.mediaStore);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempWorkDir;
  late DownloadHistoryManager history;

  setUp(() async {
    tempWorkDir = await Directory.systemTemp.createTemp('fd_coord_test_');
    history = DownloadHistoryManager(
      storage: HistoryStorage(p.join(tempWorkDir.path, 'history.json')),
    );
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(ytdlMethod, null);
    messenger.setMockMethodCallHandler(mediaStoreMethod, null);
    messenger.setMockStreamHandler(ytdlEvents, null);
    if (tempWorkDir.existsSync()) {
      await tempWorkDir.delete(recursive: true);
    }
  });

  group('StreamDownloadCoordinator', () {
    test('downloads direct HTTP file via Turbo engine, exports via MediaStore, and logs history', () async {
      final payload = generateTestPayload(256 * 1024, seed: 7);
      final server = await MockRangeServer.start(payload);
      final capturedExports = <Map<Object?, Object?>>[];

      messenger.setMockMethodCallHandler(mediaStoreMethod, (call) async {
        if (call.method == 'getAppWorkDir') return tempWorkDir.path;
        if (call.method == 'exportToDownloads') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          capturedExports.add(args);
          final srcFile = File(args['sourcePath'].toString());
          expect(srcFile.existsSync(), isTrue);
          expect(sha256HexOf(await srcFile.readAsBytes()), sha256HexOf(payload));
          if (args['deleteSource'] == true) {
            await srcFile.delete();
          }
          return <String, Object?>{
            'uri': 'content://media/external/downloads/101',
            'displayPath': 'Download/FaqihDownloader/${args['subFolder']}/${args['displayName']}',
            'sizeBytes': payload.length,
          };
        }
        return null;
      });

      final coord = StreamDownloadCoordinator(
        request: DownloadJobRequest(
          id: 'job_direct_1',
          url: server.fileUrl('/report.pdf'),
          title: 'Monthly Report',
          maxConnections: 4,
        ),
        mediaStoreChannel: MediaStoreChannel(methodChannel: mediaStoreMethod),
        historyManager: history,
      );

      final result = await coord.start();
      await server.close();

      expect(result.phase, DownloadPhase.completed);
      expect(result.status, DownloadStatus.completed);
      expect(result.downloadedBytes, payload.length);
      expect(result.exportedUri, 'content://media/external/downloads/101');
      expect(capturedExports.single['displayName'], 'Monthly Report.pdf');
      expect(capturedExports.single['subFolder'], 'Documents');
      expect(history.entries.single.status, DownloadStatus.completed);
      expect(Directory(p.join(tempWorkDir.path, 'job_job_direct_1')).existsSync(), isFalse);
    });

    test('downloads dual-stream video + dubbed audio, muxes via FFmpeg, and exports [Dub]', () async {
      final server = await MockRangeServer.start(generateTestPayload(192 * 1024, seed: 11));
      final ffmpegCalls = <List<String>>[];
      String? exportedName;

      messenger.setMockMethodCallHandler(mediaStoreMethod, (call) async {
        if (call.method == 'getAppWorkDir') return tempWorkDir.path;
        if (call.method == 'exportToDownloads') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          exportedName = args['displayName']?.toString();
          return <String, Object?>{
            'uri': 'content://media/external/downloads/202',
            'displayPath': 'Download/FaqihDownloader/Video/$exportedName',
            'sizeBytes': 300000,
          };
        }
        return null;
      });

      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'runFfmpeg') {
          final args = ((call.arguments as Map<Object?, Object?>)['args'] as List<Object?>)
              .map((e) => e.toString())
              .toList();
          ffmpegCalls.add(args);
          final outPath = args.last;
          await File(outPath).writeAsBytes(const <int>[1, 2, 3, 4]);
          return <String, Object?>{'exitCode': 0, 'output': 'muxed'};
        }
        return true;
      });
      messenger.setMockStreamHandler(
        ytdlEvents,
        MockStreamHandler.inline(onListen: (_, events) {}),
      );

      final ytdlChannel = YoutubeDlChannel(
        methodChannel: ytdlMethod,
        eventChannel: ytdlEvents,
      );
      final coord = StreamDownloadCoordinator(
        request: DownloadJobRequest(
          id: 'job_dub_1',
          url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          title: 'Science Explained',
          platform: 'YouTube',
          selectedVideoFormat: VideoFormatOption(
            formatId: '137',
            resolutionLabel: '1080p',
            height: 1080,
            ext: 'mp4',
            isProgressive: false,
            videoUrl: server.fileUrl('/video.mp4'),
          ),
          selectedAudioTrack: AudioTrack(
            trackId: 'ar_dub',
            formatId: '140-ar',
            language: 'ar',
            label: 'Arabic (Dubbed)',
            url: server.fileUrl('/audio_ar.m4a'),
            ext: 'm4a',
            isOriginal: false,
          ),
        ),
        youtubeDlChannel: ytdlChannel,
        ffmpegProcessor: FfmpegMediaProcessor(channel: ytdlChannel),
        mediaStoreChannel: MediaStoreChannel(methodChannel: mediaStoreMethod),
        historyManager: history,
      );

      final result = await coord.start();
      await server.close();

      expect(result.phase, DownloadPhase.completed);
      expect(ffmpegCalls.length, 1);
      expect(ffmpegCalls.single, containsAllInOrder(<String>['-c:v', 'copy', '-c:a', 'copy']));
      expect(exportedName, 'Science Explained [Dub].mp4');
    });

    test('falls back to yt-dlp when Turbo link expires with 403 or for HLS streams', () async {
      final server = await MockRangeServer.start(generateTestPayload(8192))
        ..forceErrorStatus = HttpStatus.forbidden;

      var ytDlpCalled = 0;
      messenger.setMockMethodCallHandler(mediaStoreMethod, (call) async {
        if (call.method == 'getAppWorkDir') return tempWorkDir.path;
        if (call.method == 'exportToDownloads') {
          return <String, Object?>{
            'uri': 'content://media/external/downloads/303',
            'displayPath': 'Download/FaqihDownloader/Video/Expired.mp4',
            'sizeBytes': 4096,
          };
        }
        return null;
      });
      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'downloadMedia') {
          ytDlpCalled++;
          final outTemplate = (call.arguments as Map<Object?, Object?>)['options'] as Map;
          final outputPattern = outTemplate['-o'].toString();
          final jobDir = File(outputPattern).parent;
          await File(p.join(jobDir.path, 'ytdlp_abc.mp4')).writeAsBytes(List<int>.filled(4096, 9));
          return <String, Object?>{'exitCode': 0, 'stdout': 'done', 'stderr': ''};
        }
        return true;
      });
      messenger.setMockStreamHandler(
        ytdlEvents,
        MockStreamHandler.inline(onListen: (_, events) {}),
      );

      final coord = StreamDownloadCoordinator(
        request: DownloadJobRequest(
          id: 'job_403_fallback',
          url: 'https://www.youtube.com/watch?v=expired123',
          title: 'Expired',
          platform: 'YouTube',
          selectedVideoFormat: VideoFormatOption(
            formatId: '22',
            resolutionLabel: '720p',
            isProgressive: true,
            videoUrl: server.fileUrl('/expired.mp4'),
          ),
        ),
        youtubeDlChannel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
        mediaStoreChannel: MediaStoreChannel(methodChannel: mediaStoreMethod),
      );

      final res = await coord.start();
      await server.close();

      expect(res.phase, DownloadPhase.completed);
      expect(ytDlpCalled, 1);
    });

    test('cancels cleanly and removes temporary job directory', () async {
      final server = await MockRangeServer.start(generateTestPayload(512 * 1024))
        ..chunkDelay = const Duration(milliseconds: 25)
        ..streamSliceSize = 8 * 1024;

      messenger.setMockMethodCallHandler(mediaStoreMethod, (call) async {
        if (call.method == 'getAppWorkDir') return tempWorkDir.path;
        return null;
      });

      final coord = StreamDownloadCoordinator(
        request: DownloadJobRequest(
          id: 'job_cancel_clean',
          url: server.fileUrl('/large.bin'),
          title: 'Large File',
        ),
        mediaStoreChannel: MediaStoreChannel(methodChannel: mediaStoreMethod),
        historyManager: history,
      );

      final startFuture = coord.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await coord.cancel();
      final finalState = await startFuture;
      await server.close();

      expect(finalState.phase, DownloadPhase.cancelled);
      expect(finalState.status, DownloadStatus.cancelled);
      expect(Directory(p.join(tempWorkDir.path, 'job_job_cancel_clean')).existsSync(), isFalse);
    });
  });
}
