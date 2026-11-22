import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:faqih_downloader_mobile/core/models/download_chunk.dart';
import 'package:faqih_downloader_mobile/core/models/download_status.dart';
import 'package:faqih_downloader_mobile/engine/engine_callbacks.dart';
import 'package:faqih_downloader_mobile/engine/isolate_download_runner.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/media_store_channel.dart';
import 'package:faqih_downloader_mobile/services/updater/github_release_updater.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeRunner extends IsolateDownloadRunner {
  _FakeRunner({
    required super.url,
    required super.destinationPath,
    super.callbacks,
  });

  final Completer<void> _done = Completer<void>();

  @override
  Future<void> start() async {
    await File(destinationPath).writeAsBytes(const <int>[1, 2, 3, 4]);
    callbacks?.onProgress?.call(
      const EngineProgressSnapshot(
        downloadedBytes: 4,
        totalBytes: 4,
        speedBytesPerSec: 1000,
        etaSeconds: 0,
        activeWorkers: 1,
        status: DownloadStatus.downloading,
        chunks: <DownloadChunk>[],
      ),
    );
    callbacks?.onComplete?.call(destinationPath, 4, 0.1);
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get completion => _done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const mediaMethod = MethodChannel(ChannelNames.mediaStore);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(mediaMethod, null);
  });

  group('GitHubReleaseUpdater', () {
    test('compares SemVer tags accurately with v prefix and pre-release suffixes', () {
      expect(GitHubReleaseUpdater.isNewerVersion('v2.0.3', '2.0.2-mobile'), isTrue);
      expect(GitHubReleaseUpdater.isNewerVersion('v2.1.0', '2.0.9'), isTrue);
      expect(GitHubReleaseUpdater.isNewerVersion('v2.0.2', '2.0.2-beta.1'), isTrue);
      expect(GitHubReleaseUpdater.isNewerVersion('v2.0.2-beta.1', '2.0.2'), isFalse);
      expect(GitHubReleaseUpdater.isNewerVersion('v2.0.2', '2.0.2'), isFalse);
      expect(GitHubReleaseUpdater.isNewerVersion('v2.0.1', '2.0.2'), isFalse);
      expect(GitHubReleaseUpdater.isNewerVersion('invalid', '2.0.2'), isFalse);
    });

    test('parses GitHub release JSON, picks best APK asset, and detects up-to-date state', () {
      final updater = GitHubReleaseUpdater(currentVersion: '2.0.2-mobile');

      final newerInfo = updater.parseReleaseJson(
        jsonDecode('''
        {
          "tag_name": "v2.0.3",
          "body": "- Faster FFmpeg pipeline\\n- Bug fixes",
          "published_at": "2026-11-22T06:00:00Z",
          "assets": [
            {
              "name": "checksums.sha256",
              "size": 120,
              "browser_download_url": "https://github.com/org/repo/releases/v2.0.3/checksums.sha256"
            },
            {
              "name": "faqih-universal.apk",
              "size": 25000000,
              "browser_download_url": "https://github.com/org/repo/releases/v2.0.3/faqih-universal.apk"
            },
            {
              "name": "faqih-arm64-v8a.apk",
              "size": 22000000,
              "browser_download_url": "https://github.com/org/repo/releases/v2.0.3/faqih-arm64-v8a.apk"
            }
          ]
        }
        ''') as Map<String, dynamic>,
        preferredAbi: 'arm64-v8a',
      );

      expect(newerInfo.hasUpdate, isTrue);
      expect(newerInfo.latestVersion, '2.0.3');
      expect(newerInfo.apkName, 'faqih-arm64-v8a.apk');
      expect(newerInfo.apkSizeBytes, 22000000);
      expect(newerInfo.releaseNotes, contains('Faster FFmpeg'));

      final sameInfo = updater.parseReleaseJson(const <String, dynamic>{
        'tag_name': 'v2.0.2',
        'body': 'Current build',
        'assets': <Object>[],
      });
      expect(sameInfo.hasUpdate, isFalse);
    });

    test('downloadAndInstallUpdate downloads APK and invokes MediaStore openFile for installer', () async {
      final tempDir = await Directory.systemTemp.createTemp('fd_upd_test_');
      String? openedPath;
      String? openedMime;

      messenger.setMockMethodCallHandler(mediaMethod, (call) async {
        if (call.method == 'getAppWorkDir') return tempDir.path;
        if (call.method == 'openFile') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          openedPath = args['pathOrUri']?.toString();
          openedMime = args['mimeType']?.toString();
          return true;
        }
        return null;
      });

      try {
        final updater = GitHubReleaseUpdater(
          mediaStoreChannel: MediaStoreChannel(methodChannel: mediaMethod),
          runnerFactory: ({
            required url,
            required destinationPath,
            headers = const <String, String>{},
            maxConnections = 4,
            speedLimitBytesPerSec = 0.0,
            callbacks,
          }) =>
              _FakeRunner(
            url: url,
            destinationPath: destinationPath,
            callbacks: callbacks,
          ),
        );

        final progressEvents = <double>[];
        final ok = await updater.downloadAndInstallUpdate(
          const ReleaseUpdateInfo(
            hasUpdate: true,
            currentVersion: '2.0.2',
            latestVersion: '2.0.3',
            apkUrl: 'https://github.com/org/repo/releases/download/v2.0.3/fd.apk',
            apkName: 'fd.apk',
          ),
          onProgress: progressEvents.add,
        );

        expect(ok, isTrue);
        expect(progressEvents, contains(1.0));
        expect(openedPath, p.join(tempDir.path, 'updates', 'fd.apk'));
        expect(openedMime, 'application/vnd.android.package-archive');
      } finally {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      }
    });
  });
}
