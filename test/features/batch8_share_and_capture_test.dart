import 'dart:convert';
import 'dart:io';

import 'package:faqih_downloader_mobile/app/app_controller.dart';
import 'package:faqih_downloader_mobile/app/faqih_app.dart';
import 'package:faqih_downloader_mobile/core/config/app_settings.dart';
import 'package:faqih_downloader_mobile/core/config/settings_repository.dart';
import 'package:faqih_downloader_mobile/core/i18n/translator.dart';
import 'package:faqih_downloader_mobile/features/settings/settings_screen.dart';
import 'package:faqih_downloader_mobile/platform/background_capture_channel.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/foreground_service_channel.dart';
import 'package:faqih_downloader_mobile/platform/media_store_channel.dart';
import 'package:faqih_downloader_mobile/platform/share_intent_channel.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
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

class _NoopCoordinator extends StreamDownloadCoordinator {
  _NoopCoordinator({
    required super.request,
    required this.onEmit,
    required MethodChannel mediaChannel,
  }) : super(mediaStoreChannel: MediaStoreChannel(methodChannel: mediaChannel));

  final void Function(DownloadJobState state) onEmit;

  @override
  Future<DownloadJobState> start() async {
    final done = state.copyWith(
      phase: DownloadPhase.completed,
      progress: 1.0,
      downloadedBytes: 1000,
      totalBytes: 1000,
    );
    onEmit(done);
    return done;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ytdlMethod = MethodChannel(ChannelNames.youtubeDl);
  const ytdlEvents = EventChannel(ChannelNames.youtubeDlEvents);
  const fgMethod = MethodChannel(ChannelNames.foregroundService);
  const fgEvents = EventChannel(ChannelNames.serviceEvents);
  const mediaMethod = MethodChannel(ChannelNames.mediaStore);
  const shareMethod = MethodChannel(ChannelNames.shareIntent);
  const shareEvents = EventChannel(ChannelNames.shareEvents);
  const bgMethod = MethodChannel(ChannelNames.backgroundCapture);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = await Directory.systemTemp.createTemp('fd_batch8_test_');
    messenger.setMockMethodCallHandler(fgMethod, (_) async => true);
    messenger.setMockStreamHandler(fgEvents, MockStreamHandler.inline(onListen: (_, _) {}));
    messenger.setMockMethodCallHandler(mediaMethod, (call) async {
      if (call.method == 'getAppWorkDir') return tempDir.path;
      return true;
    });
    messenger.setMockStreamHandler(ytdlEvents, MockStreamHandler.inline(onListen: (_, _) {}));
    messenger.setMockMethodCallHandler(shareMethod, (_) async => null);
    messenger.setMockStreamHandler(shareEvents, MockStreamHandler.inline(onListen: (_, _) {}));
    messenger.setMockMethodCallHandler(bgMethod, (_) async => true);
  });

  tearDown(() async {
    for (final ch in <MethodChannel>[ytdlMethod, fgMethod, mediaMethod, shareMethod, bgMethod]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    for (final ev in <EventChannel>[ytdlEvents, fgEvents, shareEvents]) {
      messenger.setMockStreamHandler(ev, null);
    }
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  testWidgets('cold-start Share URL starts instant extraction and opens MediaOptionsSheet instead of hiding in Staged', (tester) async {
    var pendingShare = 'Shared from YouTube: https://www.youtube.com/watch?v=dQw4w9WgXcQ';
    var extractedUrl = '';
    messenger.setMockMethodCallHandler(shareMethod, (call) async {
      if (call.method == 'consumeInitialSharedText') {
        final out = pendingShare;
        pendingShare = '';
        return out;
      }
      return false;
    });
    messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
      if (call.method == 'extractInfo') {
        extractedUrl = (call.arguments as Map)['url'].toString();
        return jsonEncode(<String, dynamic>{
          'id': 'dQw4w9WgXcQ',
          'title': 'Cold Start Shared Video',
          'duration': 95,
          'formats': <Map<String, dynamic>>[
            <String, dynamic>{
              'format_id': '22',
              'url': 'https://cdn.example.com/cold_720.mp4',
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

    late SettingsRepository repo;
    late AppTranslator translator;
    late AppController controller;
    await tester.runAsync(() async {
      repo = await SettingsRepository.create();
      translator = AppTranslator(initialLanguage: 'en', repository: repo);
      controller = AppController(
        translator: translator,
        settingsRepository: repo,
        historyManager: DownloadHistoryManager(
          storage: HistoryStorage(p.join(tempDir.path, 'hist_cold.json')),
        ),
        youtubeDlChannel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
        shareIntentChannel: ShareIntentChannel(methodChannel: shareMethod, eventChannel: shareEvents),
        mediaStoreChannel: MediaStoreChannel(methodChannel: mediaMethod),
        foregroundServiceChannel: ForegroundServiceChannel(methodChannel: fgMethod, eventChannel: fgEvents),
        backgroundCaptureChannel: BackgroundCaptureChannel(methodChannel: bgMethod),
        autoInitNative: false,
      );
      await controller.initialize();
    });

    // Not silently hidden in Staged:
    expect(controller.stagedUrls, isEmpty);

    await tester.pumpWidget(FaqihDownloaderApp(translator: translator, controller: controller));
    await tester.pumpAndSettle();

    expect(extractedUrl, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    expect(find.text('Cold Start Shared Video'), findsOneWidget);
    expect(controller.consumePendingSharedUrls(), isEmpty);

    controller.dispose();
  });

  testWidgets('warm-start Share URL extracts immediately and SnackBar offers moveTaskToBack action', (tester) async {
    late MockStreamHandlerEventSink shareEventSink;
    var moveBackCalled = false;
    messenger.setMockStreamHandler(
      shareEvents,
      MockStreamHandler.inline(
        onListen: (_, events) {
          shareEventSink = events;
        },
      ),
    );
    messenger.setMockMethodCallHandler(shareMethod, (call) async {
      if (call.method == 'moveTaskToBack') {
        moveBackCalled = true;
        return true;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
      if (call.method == 'extractInfo') {
        return jsonEncode(<String, dynamic>{
          'id': 'tt99',
          'title': 'Warm TikTok Clip',
          'duration': 30,
          'formats': <Map<String, dynamic>>[
            <String, dynamic>{
              'format_id': 'hd',
              'url': 'https://cdn.example.com/warm_tt.mp4',
              'ext': 'mp4',
              'vcodec': 'h264',
              'acodec': 'mp4a',
              'height': 1080,
            },
          ],
        });
      }
      return null;
    });

    late SettingsRepository repo;
    late AppTranslator translator;
    late DownloadQueueManager queue;
    late AppController controller;
    await tester.runAsync(() async {
      repo = await SettingsRepository.create();
      translator = AppTranslator(initialLanguage: 'en', repository: repo);
      queue = DownloadQueueManager(
        foregroundService: ForegroundServiceChannel(methodChannel: fgMethod, eventChannel: fgEvents),
        coordinatorFactory: (req, {required onStateChanged}) => _NoopCoordinator(
          request: req,
          onEmit: onStateChanged,
          mediaChannel: mediaMethod,
        ),
      );
      controller = AppController(
        translator: translator,
        settingsRepository: repo,
        historyManager: DownloadHistoryManager(
          storage: HistoryStorage(p.join(tempDir.path, 'hist_warm.json')),
        ),
        queueManager: queue,
        youtubeDlChannel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
        shareIntentChannel: ShareIntentChannel(methodChannel: shareMethod, eventChannel: shareEvents),
        mediaStoreChannel: MediaStoreChannel(methodChannel: mediaMethod),
        foregroundServiceChannel: ForegroundServiceChannel(methodChannel: fgMethod, eventChannel: fgEvents),
        backgroundCaptureChannel: BackgroundCaptureChannel(methodChannel: bgMethod),
        autoInitNative: false,
      );
      await controller.initialize();
    });

    await tester.pumpWidget(FaqihDownloaderApp(translator: translator, controller: controller));
    await tester.pumpAndSettle();

    shareEventSink.success('Check this out https://www.tiktok.com/@demo/video/1234567890');
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(find.text('Warm TikTok Clip'), findsOneWidget);
    final downloadBtn = find.byKey(const Key('sheet_download_button'));
    await tester.ensureVisible(downloadBtn);
    await tester.tap(downloadBtn);
    await tester.pumpAndSettle();

    final returnBtn = find.text(translator.tr('btn_return_previous_app'));
    expect(returnBtn, findsOneWidget);
    await tester.ensureVisible(returnBtn);
    await tester.tap(returnBtn);
    await tester.pumpAndSettle();
    expect(moveBackCalled, isTrue);

    await queue.cancelAll();
    controller.dispose();
  });

  test('AppSettings serializes Batch 8 fields with backward-compatible defaults', () {
    const def = AppSettings();
    expect(def.backgroundAutoSnifferEnabled, isFalse);
    expect(def.quickTileEnabled, isTrue);
    expect(def.quickTilePrompted, isFalse);

    final legacy = AppSettings.fromJson(const <String, dynamic>{'language': 'en'});
    expect(legacy.backgroundAutoSnifferEnabled, isFalse);
    expect(legacy.quickTileEnabled, isTrue);
    expect(legacy.quickTilePrompted, isFalse);

    final modified = def.copyWith(
      backgroundAutoSnifferEnabled: true,
      quickTileEnabled: false,
      quickTilePrompted: true,
    );
    final decoded = AppSettings.fromJson(modified.toJson());
    expect(decoded, equals(modified));
    expect(decoded.hashCode, modified.hashCode);
  });

  testWidgets('SettingsScreen manages Quick Tile toggle, Accessibility dialog, and lifecycle resume sync', (tester) async {
    var a11yGranted = false;
    var openedA11y = false;
    var openedAppInfo = false;
    bool? lastTileEnabled;
    bool? lastSyncedAutoSniffer;

    messenger.setMockMethodCallHandler(bgMethod, (call) async {
      switch (call.method) {
        case 'isAccessibilityServiceEnabled':
          return a11yGranted;
        case 'openAccessibilitySettings':
          openedA11y = true;
          return true;
        case 'openAppDetailsSettings':
          openedAppInfo = true;
          return true;
        case 'setQuickTileEnabled':
          lastTileEnabled = (call.arguments as Map)['enabled'] as bool?;
          return true;
        case 'setAutoSnifferConfig':
          lastSyncedAutoSniffer = (call.arguments as Map)['enabled'] as bool?;
          return true;
      }
      return true;
    });

    late SettingsRepository repo;
    late AppTranslator translator;
    late AppController controller;
    await tester.runAsync(() async {
      repo = await SettingsRepository.create();
      translator = AppTranslator(initialLanguage: 'en', repository: repo);
      controller = AppController(
        translator: translator,
        settingsRepository: repo,
        historyManager: DownloadHistoryManager(
          storage: HistoryStorage(p.join(tempDir.path, 'hist_set.json')),
        ),
        shareIntentChannel: ShareIntentChannel(methodChannel: shareMethod, eventChannel: shareEvents),
        mediaStoreChannel: MediaStoreChannel(methodChannel: mediaMethod),
        backgroundCaptureChannel: BackgroundCaptureChannel(methodChannel: bgMethod),
        autoInitNative: false,
      );
      await controller.initialize();
    });

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(translator: translator, controller: controller)),
    );
    await tester.pumpAndSettle();

    // 1. Toggle Quick Tile off:
    final tileSwitch = find.byKey(const Key('settings_quick_tile_switch'));
    await tester.scrollUntilVisible(tileSwitch, 200, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(tileSwitch);
    await tester.pumpAndSettle();
    await tester.tap(tileSwitch);
    await tester.pumpAndSettle();
    expect(lastTileEnabled, isFalse);
    expect(controller.settings.quickTileEnabled, isFalse);

    // 2. Toggle Background Auto-Sniffer when Accessibility is NOT granted -> opens guide dialog:
    final autoSwitch = find.byKey(const Key('settings_bg_auto_sniffer_switch'));
    await tester.scrollUntilVisible(autoSwitch, 200, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(autoSwitch);
    await tester.pumpAndSettle();
    await tester.tap(autoSwitch);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('accessibility_permission_dialog')), findsOneWidget);
    expect(controller.settings.backgroundAutoSnifferEnabled, isFalse);

    await tester.tap(find.byKey(const Key('btn_open_app_info')));
    await tester.pumpAndSettle();
    expect(openedAppInfo, isTrue);

    await tester.tap(autoSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn_open_accessibility_settings')));
    await tester.pumpAndSettle();
    expect(openedA11y, isTrue);

    // 3. Simulate granting Accessibility in Settings and returning to app:
    a11yGranted = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(controller.settings.backgroundAutoSnifferEnabled, isTrue);
    expect(lastSyncedAutoSniffer, isTrue);

    controller.dispose();
  });
}
