import 'package:flutter/foundation.dart';

import 'app_constants.dart';

/// Immutable user preferences for Faqih Downloader Mobile.
@immutable
class AppSettings {
  const AppSettings({
    this.language = 'ar',
    this.themeMode = 'dark',
    this.maxConnections = AppConstants.defaultMaxConnections,
    this.maxConcurrentDownloads = AppConstants.defaultMaxConcurrentDownloads,
    this.speedLimitBytesPerSec = 0,
    this.autoCategorizeFolders = true,
    this.defaultQuality = AppConstants.defaultQuality,
    this.preferredSubtitleLang = 'none',
    this.subtitleEmbedMode = AppConstants.subtitleModeSoftMux,
    this.wifiOnlyDownloads = false,
    this.clipboardAutoCheck = true,
    this.cookiesFilePath = '',
  });

  final String language;
  final String themeMode;
  final int maxConnections;
  final int maxConcurrentDownloads;
  final int speedLimitBytesPerSec;
  final bool autoCategorizeFolders;
  final String defaultQuality;
  final String preferredSubtitleLang;
  final String subtitleEmbedMode;
  final bool wifiOnlyDownloads;
  final bool clipboardAutoCheck;
  final String cookiesFilePath;

  AppSettings copyWith({
    String? language,
    String? themeMode,
    int? maxConnections,
    int? maxConcurrentDownloads,
    int? speedLimitBytesPerSec,
    bool? autoCategorizeFolders,
    String? defaultQuality,
    String? preferredSubtitleLang,
    String? subtitleEmbedMode,
    bool? wifiOnlyDownloads,
    bool? clipboardAutoCheck,
    String? cookiesFilePath,
  }) {
    return AppSettings(
      language: _normalizeLanguage(language ?? this.language),
      themeMode: _normalizeThemeMode(themeMode ?? this.themeMode),
      maxConnections: AppConstants.clampConnections(
        maxConnections ?? this.maxConnections,
      ),
      maxConcurrentDownloads: AppConstants.clampConcurrentDownloads(
        maxConcurrentDownloads ?? this.maxConcurrentDownloads,
      ),
      speedLimitBytesPerSec: _clampSpeed(
        speedLimitBytesPerSec ?? this.speedLimitBytesPerSec,
      ),
      autoCategorizeFolders:
          autoCategorizeFolders ?? this.autoCategorizeFolders,
      defaultQuality: (defaultQuality ?? this.defaultQuality).trim().isEmpty
          ? AppConstants.defaultQuality
          : (defaultQuality ?? this.defaultQuality).trim(),
      preferredSubtitleLang:
          (preferredSubtitleLang ?? this.preferredSubtitleLang).trim().isEmpty
          ? 'none'
          : (preferredSubtitleLang ?? this.preferredSubtitleLang).trim(),
      subtitleEmbedMode: _normalizeSubtitleMode(
        subtitleEmbedMode ?? this.subtitleEmbedMode,
      ),
      wifiOnlyDownloads: wifiOnlyDownloads ?? this.wifiOnlyDownloads,
      clipboardAutoCheck: clipboardAutoCheck ?? this.clipboardAutoCheck,
      cookiesFilePath: (cookiesFilePath ?? this.cookiesFilePath).trim(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'language': language,
      'themeMode': themeMode,
      'maxConnections': maxConnections,
      'maxConcurrentDownloads': maxConcurrentDownloads,
      'speedLimitBytesPerSec': speedLimitBytesPerSec,
      'autoCategorizeFolders': autoCategorizeFolders,
      'defaultQuality': defaultQuality,
      'preferredSubtitleLang': preferredSubtitleLang,
      'subtitleEmbedMode': subtitleEmbedMode,
      'wifiOnlyDownloads': wifiOnlyDownloads,
      'clipboardAutoCheck': clipboardAutoCheck,
      'cookiesFilePath': cookiesFilePath,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      language: _normalizeLanguage(json['language']?.toString()),
      themeMode: _normalizeThemeMode(json['themeMode']?.toString()),
      maxConnections: AppConstants.clampConnections(
        _parseInt(
          json['maxConnections'],
          AppConstants.defaultMaxConnections,
        ),
      ),
      maxConcurrentDownloads: AppConstants.clampConcurrentDownloads(
        _parseInt(
          json['maxConcurrentDownloads'],
          AppConstants.defaultMaxConcurrentDownloads,
        ),
      ),
      speedLimitBytesPerSec: _clampSpeed(
        _parseInt(json['speedLimitBytesPerSec'], 0),
      ),
      autoCategorizeFolders: _parseBool(json['autoCategorizeFolders'], true),
      defaultQuality: _parseNonEmptyString(
        json['defaultQuality'],
        AppConstants.defaultQuality,
      ),
      preferredSubtitleLang: _parseNonEmptyString(
        json['preferredSubtitleLang'],
        'none',
      ),
      subtitleEmbedMode: _normalizeSubtitleMode(
        json['subtitleEmbedMode']?.toString(),
      ),
      wifiOnlyDownloads: _parseBool(json['wifiOnlyDownloads'], false),
      clipboardAutoCheck: _parseBool(json['clipboardAutoCheck'], true),
      cookiesFilePath: (json['cookiesFilePath']?.toString() ?? '').trim(),
    );
  }

  static String _normalizeLanguage(String? raw) {
    final code = (raw ?? 'ar').trim().toLowerCase();
    return code == 'en' ? 'en' : 'ar';
  }

  static String _normalizeThemeMode(String? raw) {
    final mode = (raw ?? 'dark').trim().toLowerCase();
    if (mode == 'light' || mode == 'system') return mode;
    return 'dark';
  }

  static String _normalizeSubtitleMode(String? raw) {
    final mode = (raw ?? AppConstants.subtitleModeSoftMux).trim().toLowerCase();
    return mode == AppConstants.subtitleModeHardBurn
        ? AppConstants.subtitleModeHardBurn
        : AppConstants.subtitleModeSoftMux;
  }

  static int _clampSpeed(int value) => value < 0 ? 0 : value;

  static int _parseInt(Object? raw, int fallback) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? fallback;
    return fallback;
  }

  static bool _parseBool(Object? raw, bool fallback) {
    if (raw is bool) return raw;
    if (raw is String) {
      final lower = raw.trim().toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
    }
    return fallback;
  }

  static String _parseNonEmptyString(Object? raw, String fallback) {
    final str = raw?.toString().trim() ?? '';
    return str.isEmpty ? fallback : str;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppSettings &&
        other.language == language &&
        other.themeMode == themeMode &&
        other.maxConnections == maxConnections &&
        other.maxConcurrentDownloads == maxConcurrentDownloads &&
        other.speedLimitBytesPerSec == speedLimitBytesPerSec &&
        other.autoCategorizeFolders == autoCategorizeFolders &&
        other.defaultQuality == defaultQuality &&
        other.preferredSubtitleLang == preferredSubtitleLang &&
        other.subtitleEmbedMode == subtitleEmbedMode &&
        other.wifiOnlyDownloads == wifiOnlyDownloads &&
        other.clipboardAutoCheck == clipboardAutoCheck &&
        other.cookiesFilePath == cookiesFilePath;
  }

  @override
  int get hashCode => Object.hash(
    language,
    themeMode,
    maxConnections,
    maxConcurrentDownloads,
    speedLimitBytesPerSec,
    autoCategorizeFolders,
    defaultQuality,
    preferredSubtitleLang,
    subtitleEmbedMode,
    wifiOnlyDownloads,
    clipboardAutoCheck,
    cookiesFilePath,
  );
}
