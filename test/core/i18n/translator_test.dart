import 'package:faqih_downloader_mobile/core/config/settings_repository.dart';
import 'package:faqih_downloader_mobile/core/i18n/app_locale.dart';
import 'package:faqih_downloader_mobile/core/i18n/strings_ar.dart';
import 'package:faqih_downloader_mobile/core/i18n/strings_en.dart';
import 'package:faqih_downloader_mobile/core/i18n/translator.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AppLocale & Localization Strings', () {
    test('stringsAr and stringsEn have identical key sets', () {
      expect(stringsAr.keys.toSet(), equals(stringsEn.keys.toSet()));
    });

    test('detects RTL for Arabic and LTR for English', () {
      expect(AppLocale.isRtl('ar'), isTrue);
      expect(AppLocale.textDirectionOf('ar'), TextDirection.rtl);
      expect(AppLocale.isRtl('en'), isFalse);
      expect(AppLocale.textDirectionOf('en'), TextDirection.ltr);
      expect(AppLocale.normalizeCode('unknown'), 'ar');
    });
  });

  group('AppTranslator', () {
    test('translates keys, substitutes params, and supports fallback', () {
      final translator = AppTranslator(initialLanguage: 'ar');
      expect(translator.tr('tab_staged'), 'التحضير');
      expect(translator.tr('tab_active'), 'قيد التحميل');
      expect(translator.tr('tab_vault'), 'المكتمل');
      expect(
        translator.tr('msg_url_queued', params: <String, String>{'url': 'https://x.com'}),
        contains('https://x.com'),
      );
      expect(
        translator.tr('missing_custom_key', fallback: 'Fallback Value'),
        'Fallback Value',
      );
    });

    test('toggles language and persists via SettingsRepository', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final repo = await SettingsRepository.create();
      final translator = AppTranslator(
        initialLanguage: 'ar',
        repository: repo,
      );

      var notifications = 0;
      translator.addListener(() => notifications++);

      await translator.toggleLanguage();
      expect(translator.languageCode, 'en');
      expect(translator.isRtl, isFalse);
      expect(translator.tr('tab_staged'), 'Staged');
      expect(notifications, 1);
      expect(repo.load().language, 'en');

      await translator.setLanguage('ar');
      expect(translator.languageCode, 'ar');
      expect(translator.isRtl, isTrue);
      expect(repo.load().language, 'ar');
    });
  });
}
