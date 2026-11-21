import 'package:faqih_downloader_mobile/core/config/app_constants.dart';
import 'package:faqih_downloader_mobile/core/config/app_settings.dart';
import 'package:faqih_downloader_mobile/core/config/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AppSettings & SettingsRepository', () {
    test('clamps connections, speed limit, and normalizes fields', () {
      final parsed = AppSettings.fromJson(<String, dynamic>{
        'language': 'FR',
        'maxConnections': 99,
        'speedLimitBytesPerSec': -500,
        'subtitleEmbedMode': 'invalid',
        'wifiOnlyDownloads': true,
      });

      expect(parsed.language, 'ar');
      expect(parsed.maxConnections, AppConstants.maxConnectionsLimit);
      expect(parsed.speedLimitBytesPerSec, 0);
      expect(parsed.subtitleEmbedMode, AppConstants.subtitleModeSoftMux);
      expect(parsed.wifiOnlyDownloads, isTrue);

      final updated = parsed.copyWith(
        language: 'en',
        maxConnections: 0,
        speedLimitBytesPerSec: 1024 * 1024,
        subtitleEmbedMode: AppConstants.subtitleModeHardBurn,
      );
      expect(updated.language, 'en');
      expect(updated.maxConnections, AppConstants.minConnections);
      expect(updated.speedLimitBytesPerSec, 1024 * 1024);
      expect(updated.subtitleEmbedMode, AppConstants.subtitleModeHardBurn);
    });

    test('loads defaults and persists settings via SharedPreferences', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final repo = await SettingsRepository.create();

      expect(repo.load(), equals(const AppSettings()));

      const custom = AppSettings(
        language: 'en',
        maxConnections: 12,
        speedLimitBytesPerSec: 2 * 1024 * 1024,
        autoCategorizeFolders: false,
        defaultQuality: '720p',
        preferredSubtitleLang: 'ar',
        subtitleEmbedMode: AppConstants.subtitleModeHardBurn,
        wifiOnlyDownloads: true,
        clipboardAutoCheck: false,
      );
      await repo.save(custom);
      expect(repo.load(), equals(custom));

      await repo.reset();
      expect(repo.load(), equals(const AppSettings()));
    });
  });
}
