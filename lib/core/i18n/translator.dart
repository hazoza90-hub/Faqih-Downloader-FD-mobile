import 'package:flutter/widgets.dart';

import '../config/settings_repository.dart';
import 'app_locale.dart';
import 'strings_ar.dart';
import 'strings_en.dart';

/// Reactive localization controller managing AR/EN lookups and directionality.
class AppTranslator extends ChangeNotifier {
  AppTranslator({
    String initialLanguage = AppLocale.arabicCode,
    SettingsRepository? repository,
  })  : _languageCode = AppLocale.normalizeCode(initialLanguage),
        _repository = repository;

  final SettingsRepository? _repository;
  String _languageCode;

  String get languageCode => _languageCode;
  Locale get locale => AppLocale.toLocale(_languageCode);
  bool get isRtl => AppLocale.isRtl(_languageCode);
  TextDirection get textDirection => AppLocale.textDirectionOf(_languageCode);

  String tr(
    String key, {
    String? fallback,
    Map<String, String>? params,
  }) {
    final activeMap = _languageCode == AppLocale.englishCode
        ? stringsEn
        : stringsAr;
    var resolved = activeMap[key] ?? fallback ?? stringsEn[key] ?? key;
    if (params != null && params.isNotEmpty) {
      params.forEach((paramKey, paramValue) {
        resolved = resolved.replaceAll('{$paramKey}', paramValue);
      });
    }
    return resolved;
  }

  Future<void> setLanguage(String code) async {
    final normalized = AppLocale.normalizeCode(code);
    if (normalized == _languageCode) {
      return;
    }
    _languageCode = normalized;
    notifyListeners();

    final repo = _repository;
    if (repo != null) {
      final current = repo.load();
      await repo.save(current.copyWith(language: normalized));
    }
  }

  Future<void> toggleLanguage() {
    final nextCode = _languageCode == AppLocale.arabicCode
        ? AppLocale.englishCode
        : AppLocale.arabicCode;
    return setLanguage(nextCode);
  }
}
