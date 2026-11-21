import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';

/// Persistence wrapper loading and saving [AppSettings] in [SharedPreferences].
class SettingsRepository {
  SettingsRepository(this._prefs);

  static const String storageKey = 'faqih_app_settings_v1';

  final SharedPreferences _prefs;

  static Future<SettingsRepository> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsRepository(prefs);
  }

  AppSettings load() {
    final raw = _prefs.getString(storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return const AppSettings();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return AppSettings.fromJson(decoded);
      }
      if (decoded is Map) {
        return AppSettings.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // Corrupted preferences fall back cleanly to default settings.
    }
    return const AppSettings();
  }

  Future<bool> save(AppSettings settings) {
    final encoded = jsonEncode(settings.toJson());
    return _prefs.setString(storageKey, encoded);
  }

  Future<bool> reset() {
    return _prefs.remove(storageKey);
  }
}
