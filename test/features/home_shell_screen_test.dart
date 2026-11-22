import 'dart:async';
import 'dart:io';

import 'package:faqih_downloader_mobile/app/app_controller.dart';
import 'package:faqih_downloader_mobile/app/faqih_app.dart';
import 'package:faqih_downloader_mobile/core/config/settings_repository.dart';
import 'package:faqih_downloader_mobile/core/i18n/translator.dart';
import 'package:faqih_downloader_mobile/core/models/download_status.dart';
import 'package:faqih_downloader_mobile/core/models/history_entry.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/foreground_service_channel.dart';
import 'package:faqih_downloader_mobile/platform/media_store_channel.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_job_models.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_queue_manager.dart';
import 'package:faqih_downloader_mobile/services/coordinator/stream_download_coordinator.dart';
import 'package:faqih_downloader_mobile/services/history/history_manager.dart';
import 'package:faqih_downloader_mobile/services/history/history_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _TestCoordinator extends StreamDownloadCoordinator {
  _TestCoordinator({
    required super.request,
    required this.emit,
    required MethodChannel mediaChannel,
  })  : _emit = emit,
        _current = DownloadJobState.fromRequest(request),
        super(mediaStoreChannel: MediaStoreChannel(methodChannel: mediaChannel));

  final void Function(DownloadJobState state) emit;
  final void Function(DownloadJobState state) _emit;
  final Completer<void> gate = Completer<void>();
  DownloadJobState _current;

  void _push(DownloadJobState next) {
    _current = next;
    _emit(next);
  }

  @override
  Future<DownloadJobState> start() async {
    _push(_current.copyWith(
      phase: DownloadPhase.downloadingDirect,
      progress: 0.5,
      downloadedBytes: 500,
      totalBytes: 1000,
      speedBytesPerSec: 1024 * 1024,
    ));
    await gate.future;
    final done = _current.copyWith(phase: DownloadPhase.cancelled);
    _push(done);
    return done;
  }

  @override
  Future<void> pause() async {
    _push(_current.copyWith(phase: DownloadPhase.paused, speedBytesPerSec: 0));
  }

  @override
  Future<void> resume() async {
    _push(_current.copyWith(
      phase: DownloadPhase.downloadingDirect,
      speedBytesPerSec: 1024 * 1024,
    ));
  }

  @override
  Future<void> cancel() async {
    if (!gate.isCompleted) gate.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fgMethod = MethodChannel(ChannelNames.foregroundService);
  const fgEvents = EventChannel(ChannelNames.serviceEvents);
  const mediaMethod = MethodChannel(ChannelNames.mediaStore);
  const shareMethod = MethodChannel(ChannelNames.shareIntent);
  const shareEvents = EventChannel(ChannelNames.shareEvents);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = await Directory.systemTemp.createTemp('fd_home_test_');
    messenger.setMockMethodCallHandler(fgMethod, (_) async => true);
    messenger.setMockStreamHandler(fgEvents, MockStreamHandler.inline(onListen: (_, _) {}));
    messenger.setMockMethodCallHandler(mediaMethod, (call) async {
      if (call.method == 'getAppWorkDir') return tempDir.path;
      return true;
    });
    messenger.setMockMethodCallHandler(shareMethod, (_) async => null);
    messenger.setMockStreamHandler(shareEvents, MockStreamHandler.inline(onListen: (_, _) {}));
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(fgMethod, null);
    messenger.setMockStreamHandler(fgEvents, null);
    messenger.setMockMethodCallHandler(mediaMethod, null);
    messenger.setMockMethodCallHandler(shareMethod, null);
    messenger.setMockStreamHandler(shareEvents, null);
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  testWidgets('HomeShellScreen handles direct URL download, pause/resume/cancel, vault filter, and RTL/LTR', (tester) async {
    late SettingsRepository repo;
    late AppTranslator translator;
    late DownloadHistoryManager history;
    late DownloadQueueManager queue;
    late AppController controller;

    await tester.runAsync(() async {
      repo = await SettingsRepository.create();
      translator = AppTranslator(initialLanguage: 'ar', repository: repo);
      history = DownloadHistoryManager(
        storage: HistoryStorage(p.join(tempDir.path, 'history.json')),
      );
      await history.upsert(
        HistoryEntry(
          id: 'hist_1',
          url: 'https://cdn.example.com/lecture.mp4',
          filename: 'Lecture.mp4',
          filePath: '/downloads/Lecture.mp4',
          category: 'Video',
          totalSize: 1024000,
          downloadedBytes: 1024000,
          status: DownloadStatus.completed,
          createdAt: DateTime.utc(2026, 11, 22),
        ),
      );

      queue = DownloadQueueManager(
        foregroundService: ForegroundServiceChannel(
          methodChannel: fgMethod,
          eventChannel: fgEvents,
        ),
        coordinatorFactory: (req, {required onStateChanged}) => _TestCoordinator(
          request: req,
          emit: onStateChanged,
          mediaChannel: mediaMethod,
        ),
      );

      controller = AppController(
        translator: translator,
        settingsRepository: repo,
        historyManager: history,
        queueManager: queue,
        mediaStoreChannel: MediaStoreChannel(methodChannel: mediaMethod),
        foregroundServiceChannel: ForegroundServiceChannel(
          methodChannel: fgMethod,
          eventChannel: fgEvents,
        ),
        autoInitNative: false,
      );
      await controller.initialize();
    });

    await tester.pumpWidget(FaqihDownloaderApp(translator: translator, controller: controller));
    await tester.pumpAndSettle();

    expect(Directionality.of(tester.element(find.byKey(const Key('tab_staged')))), TextDirection.rtl);

    // Submit direct HTTP URL:
    await tester.enterText(find.byKey(const Key('url_input_field')), 'https://cdn.example.com/archive.zip');
    await tester.tap(find.byKey(const Key('url_submit_button')));
    await tester.pumpAndSettle();

    // Switched to Active tab & job card visible:
    expect(find.text('archive.zip'), findsOneWidget);
    final pauseBtn = find.byIcon(Icons.pause_rounded).first;
    await tester.tap(pauseBtn);
    await tester.pumpAndSettle();

    // Resume button now shown:
    final resumeBtn = find.byIcon(Icons.play_arrow_rounded).first;
    await tester.tap(resumeBtn);
    await tester.pumpAndSettle();

    // Cancel job:
    final cancelBtn = find.byIcon(Icons.close_rounded).first;
    await tester.tap(cancelBtn);
    await tester.pumpAndSettle();
    expect(controller.queueManager!.activeJobs, isEmpty);

    // Switch to Vault tab and test search + category filter:
    await tester.tap(find.byKey(const Key('tab_vault')));
    await tester.pumpAndSettle();
    expect(find.text('Lecture.mp4'), findsOneWidget);

    await tester.tap(find.byKey(const Key('vault_cat_Documents')));
    await tester.pumpAndSettle();
    expect(find.text('Lecture.mp4'), findsNothing);

    await tester.tap(find.byKey(const Key('vault_cat_Video')));
    await tester.pumpAndSettle();
    expect(find.text('Lecture.mp4'), findsOneWidget);

    // Language toggle switches RTL -> LTR:
    await tester.tap(find.byKey(const Key('lang_toggle_button')));
    await tester.pumpAndSettle();
    expect(Directionality.of(tester.element(find.byKey(const Key('tab_vault')))), TextDirection.ltr);

    controller.dispose();
  });

  test('AppController.openVaultEntry sends contentUri and mimeType to MediaStoreChannel.openFile', () async {
    final openCalls = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(mediaMethod, (call) async {
      if (call.method == 'getAppWorkDir') return tempDir.path;
      if (call.method == 'openFile') {
        openCalls.add(Map<Object?, Object?>.from(call.arguments as Map));
        return true;
      }
      return true;
    });

    final repo = await SettingsRepository.create();
    final controller = AppController(
      translator: AppTranslator(initialLanguage: 'en', repository: repo),
      settingsRepository: repo,
      historyManager: DownloadHistoryManager(
        storage: HistoryStorage(p.join(tempDir.path, 'history.json')),
      ),
      mediaStoreChannel: MediaStoreChannel(methodChannel: mediaMethod),
      foregroundServiceChannel: ForegroundServiceChannel(
        methodChannel: fgMethod,
        eventChannel: fgEvents,
      ),
      autoInitNative: false,
    );
    await controller.initialize();

    final withUri = HistoryEntry(
      id: 'v1',
      url: 'https://example.com/v1.mp4',
      filename: 'lesson.mp4',
      filePath: 'Download/FaqihDownloader/Video/lesson.mp4',
      category: 'Video',
      totalSize: 1000,
      downloadedBytes: 1000,
      status: DownloadStatus.completed,
      createdAt: DateTime.utc(2026, 11, 22),
      contentUri: 'content://media/external/downloads/99',
    );
    expect(await controller.openVaultEntry(withUri), isTrue);
    expect(openCalls.last['pathOrUri'], 'content://media/external/downloads/99');
    expect(openCalls.last['mimeType'], 'video/mp4');

    final legacyNoUri = HistoryEntry(
      id: 'v2',
      url: 'https://example.com/v2.mp3',
      filename: 'audio.mp3',
      filePath: '/storage/emulated/0/Download/audio.mp3',
      category: 'Audio',
      totalSize: 500,
      downloadedBytes: 500,
      status: DownloadStatus.completed,
      createdAt: DateTime.utc(2026, 11, 22),
    );
    expect(await controller.openVaultEntry(legacyNoUri), isTrue);
    expect(openCalls.last['pathOrUri'], '/storage/emulated/0/Download/audio.mp3');
    expect(openCalls.last['mimeType'], 'audio/mpeg');

    controller.dispose();
  });
}
