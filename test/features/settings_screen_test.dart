import 'dart:io';

import 'package:faqih_downloader_mobile/app/app_controller.dart';
import 'package:faqih_downloader_mobile/core/config/settings_repository.dart';
import 'package:faqih_downloader_mobile/core/i18n/translator.dart';
import 'package:faqih_downloader_mobile/features/settings/settings_screen.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
import 'package:faqih_downloader_mobile/services/history/history_manager.dart';
import 'package:faqih_downloader_mobile/services/history/history_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ytdlMethod = MethodChannel(ChannelNames.youtubeDl);
  const ytdlEvents = EventChannel(ChannelNames.youtubeDlEvents);
  const fgMethod = MethodChannel(ChannelNames.foregroundService);
  const fgEvents = EventChannel(ChannelNames.serviceEvents);
  const shareMethod = MethodChannel(ChannelNames.shareIntent);
  const shareEvents = EventChannel(ChannelNames.shareEvents);
  const mediaMethod = MethodChannel(ChannelNames.mediaStore);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = await Directory.systemTemp.createTemp('fd_settings_test_');
    messenger.setMockMethodCallHandler(fgMethod, (_) async => true);
    messenger.setMockStreamHandler(fgEvents, MockStreamHandler.inline(onListen: (_, _) {}));
    messenger.setMockMethodCallHandler(shareMethod, (_) async => null);
    messenger.setMockStreamHandler(shareEvents, MockStreamHandler.inline(onListen: (_, _) {}));
    messenger.setMockMethodCallHandler(mediaMethod, (call) async {
      if (call.method == 'getAppWorkDir') return tempDir.path;
      return true;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(ytdlMethod, null);
    messenger.setMockStreamHandler(ytdlEvents, null);
    messenger.setMockMethodCallHandler(fgMethod, null);
    messenger.setMockStreamHandler(fgEvents, null);
    messenger.setMockMethodCallHandler(shareMethod, null);
    messenger.setMockStreamHandler(shareEvents, null);
    messenger.setMockMethodCallHandler(mediaMethod, null);
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  testWidgets('SettingsScreen updates language, themeMode, speed limit, and yt-dlp engine', (tester) async {
    var updateCalled = 0;
    messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
      if (call.method == 'updateYoutubeDL') {
        updateCalled++;
        return <String, Object?>{
          'status': 'DONE',
          'ytdlpVersion': '2026.11.22',
        };
      }
      return null;
    });
    messenger.setMockStreamHandler(ytdlEvents, MockStreamHandler.inline(onListen: (_, _) {}));

    late SettingsRepository repo;
    late AppTranslator translator;
    late AppController controller;
    await tester.runAsync(() async {
      repo = await SettingsRepository.create();
      translator = AppTranslator(initialLanguage: 'ar', repository: repo);
      final history = DownloadHistoryManager(
        storage: HistoryStorage(p.join(tempDir.path, 'history.json')),
      );
      controller = AppController(
        translator: translator,
        settingsRepository: repo,
        historyManager: history,
        youtubeDlChannel: YoutubeDlChannel(
          methodChannel: ytdlMethod,
          eventChannel: ytdlEvents,
        ),
        autoInitNative: false,
      );
      await controller.initialize();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(translator: translator, controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    // Change language AR -> EN:
    await tester.tap(find.byKey(const Key('settings_lang_en')));
    await tester.pumpAndSettle();
    expect(controller.settings.language, 'en');
    expect(translator.languageCode, 'en');

    // Change theme dark -> light:
    await tester.tap(find.byKey(const Key('settings_theme_light')));
    await tester.pumpAndSettle();
    expect(controller.settings.themeMode, 'light');
    expect(controller.themeMode, ThemeMode.light);

    // Select 1 MB/s speed limit preset:
    await tester.ensureVisible(find.byKey(const Key('speed_preset_1048576')));
    await tester.tap(find.byKey(const Key('speed_preset_1048576')));
    await tester.pumpAndSettle();
    expect(controller.settings.speedLimitBytesPerSec, 1024 * 1024);

    // Trigger yt-dlp update:
    await tester.ensureVisible(find.byKey(const Key('btn_update_ytdlp')));
    await tester.tap(find.byKey(const Key('btn_update_ytdlp')));
    await tester.pumpAndSettle();
    expect(updateCalled, 1);
    expect(controller.ytdlpVersion, '2026.11.22');

    controller.dispose();
  });
}
