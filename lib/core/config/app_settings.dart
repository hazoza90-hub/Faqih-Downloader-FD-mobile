import 'package:flutter/foundation.dart';

import 'app_constants.dart';

/// Immutable user preferences for Faqih Downloader Mobile.
@immutable
class AppSettings {
  static const Map<String, bool> defaultSnifferPlatforms = <String, bool>{
    'youtube': true,
    'tiktok': true,
    'instagram': true,
    'facebook': true,
    'twitter': true,
    'direct': true,
  };

  static const List<int> supportedVideoHeights = <int>[0, 1080, 720, 480, 360];

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
    this.clipboardSnifferActive = true,
    this.clipboardAutoAnalyze = false,
    Map<String, bool>? snifferPlatforms,
    this.customSaveTreeUri = '',
    this.customSaveDisplayLabel = '',
    this.preferredVideoHeight = 0,
    this.preferredAudioLang = 'original',
    this.subtitlePosition = 'bottom',
    this.subtitleFontSize = 20,
    this.cookiesFilePath = '',
  }) : snifferPlatforms = snifferPlatforms ?? defaultSnifferPlatforms;

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
  final bool clipboardSnifferActive;
  final bool clipboardAutoAnalyze;
  final Map<String, bool> snifferPlatforms;
  final String customSaveTreeUri;
  final String customSaveDisplayLabel;
  final int preferredVideoHeight;
  final String preferredAudioLang;
  final String subtitlePosition;
  final int subtitleFontSize;
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
    bool? clipboardSnifferActive,
    bool? clipboardAutoAnalyze,
    Map<String, bool>? snifferPlatforms,
    String? customSaveTreeUri,
    String? customSaveDisplayLabel,
    int? preferredVideoHeight,
    String? preferredAudioLang,
    String? subtitlePosition,
    int? subtitleFontSize,
    String? cookiesFilePath,
  }) {
    return AppSettings(
      language: _normalizeLanguage(language ?? this.language),
      themeMode: _normalizeThemeMode(themeMode ?? this.themeMode),
      maxConnections: AppConstants.clampConnections(maxConnections ?? this.maxConnections),
      maxConcurrentDownloads: AppConstants.clampConcurrentDownloads(
        maxConcurrentDownloads ?? this.maxConcurrentDownloads,
      ),
      speedLimitBytesPerSec: _clampSpeed(speedLimitBytesPerSec ?? this.speedLimitBytesPerSec),
      autoCategorizeFolders: autoCategorizeFolders ?? this.autoCategorizeFolders,
      defaultQuality: _parseNonEmptyString(defaultQuality ?? this.defaultQuality, AppConstants.defaultQuality),
      preferredSubtitleLang: _parseNonEmptyString(preferredSubtitleLang ?? this.preferredSubtitleLang, 'none'),
      subtitleEmbedMode: _normalizeSubtitleMode(subtitleEmbedMode ?? this.subtitleEmbedMode),
      wifiOnlyDownloads: wifiOnlyDownloads ?? this.wifiOnlyDownloads,
      clipboardAutoCheck: clipboardAutoCheck ?? this.clipboardAutoCheck,
      clipboardSnifferActive: clipboardSnifferActive ?? this.clipboardSnifferActive,
      clipboardAutoAnalyze: clipboardAutoAnalyze ?? this.clipboardAutoAnalyze,
      snifferPlatforms: _normalizePlatforms(snifferPlatforms ?? this.snifferPlatforms),
      customSaveTreeUri: (customSaveTreeUri ?? this.customSaveTreeUri).trim(),
      customSaveDisplayLabel: (customSaveDisplayLabel ?? this.customSaveDisplayLabel).trim(),
      preferredVideoHeight: _normalizeVideoHeight(preferredVideoHeight ?? this.preferredVideoHeight),
      preferredAudioLang: _normalizeAudioLang(preferredAudioLang ?? this.preferredAudioLang),
      subtitlePosition: _normalizeSubPos(subtitlePosition ?? this.subtitlePosition),
      subtitleFontSize: _clampSubFontSize(subtitleFontSize ?? this.subtitleFontSize),
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
      'clipboardSnifferActive': clipboardSnifferActive,
      'clipboardAutoAnalyze': clipboardAutoAnalyze,
      'snifferPlatforms': snifferPlatforms,
      'customSaveTreeUri': customSaveTreeUri,
      'customSaveDisplayLabel': customSaveDisplayLabel,
      'preferredVideoHeight': preferredVideoHeight,
      'preferredAudioLang': preferredAudioLang,
      'subtitlePosition': subtitlePosition,
      'subtitleFontSize': subtitleFontSize,
      'cookiesFilePath': cookiesFilePath,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final legacyCheck = _parseBool(json['clipboardAutoCheck'], true);
    return AppSettings(
      language: _normalizeLanguage(json['language']?.toString()),
      themeMode: _normalizeThemeMode(json['themeMode']?.toString()),
      maxConnections: AppConstants.clampConnections(
        _parseInt(json['maxConnections'], AppConstants.defaultMaxConnections),
      ),
      maxConcurrentDownloads: AppConstants.clampConcurrentDownloads(
        _parseInt(json['maxConcurrentDownloads'], AppConstants.defaultMaxConcurrentDownloads),
      ),
      speedLimitBytesPerSec: _clampSpeed(_parseInt(json['speedLimitBytesPerSec'], 0)),
      autoCategorizeFolders: _parseBool(json['autoCategorizeFolders'], true),
      defaultQuality: _parseNonEmptyString(json['defaultQuality'], AppConstants.defaultQuality),
      preferredSubtitleLang: _parseNonEmptyString(json['preferredSubtitleLang'], 'none'),
      subtitleEmbedMode: _normalizeSubtitleMode(json['subtitleEmbedMode']?.toString()),
      wifiOnlyDownloads: _parseBool(json['wifiOnlyDownloads'], false),
      clipboardAutoCheck: legacyCheck,
      clipboardSnifferActive: _parseBool(json['clipboardSnifferActive'], legacyCheck),
      clipboardAutoAnalyze: _parseBool(json['clipboardAutoAnalyze'], false),
      snifferPlatforms: _normalizePlatforms(json['snifferPlatforms']),
      customSaveTreeUri: (json['customSaveTreeUri']?.toString() ?? '').trim(),
      customSaveDisplayLabel: (json['customSaveDisplayLabel']?.toString() ?? '').trim(),
      preferredVideoHeight: _normalizeVideoHeight(_parseInt(json['preferredVideoHeight'], 0)),
      preferredAudioLang: _normalizeAudioLang(json['preferredAudioLang']?.toString()),
      subtitlePosition: _normalizeSubPos(json['subtitlePosition']?.toString()),
      subtitleFontSize: _clampSubFontSize(_parseInt(json['subtitleFontSize'], 20)),
      cookiesFilePath: (json['cookiesFilePath']?.toString() ?? '').trim(),
    );
  }

  static Map<String, bool> _normalizePlatforms(Object? raw) {
    final result = Map<String, bool>.from(defaultSnifferPlatforms);
    if (raw is Map) {
      for (final entry in raw.entries) {
        final key = entry.key.toString().trim().toLowerCase();
        if (result.containsKey(key)) {
          result[key] = _parseBool(entry.value, result[key]!);
        }
      }
    }
    return Map<String, bool>.unmodifiable(result);
  }

  static String _normalizeLanguage(String? raw) =>
      (raw ?? 'ar').trim().toLowerCase() == 'en' ? 'en' : 'ar';

  static String _normalizeThemeMode(String? raw) {
    final mode = (raw ?? 'dark').trim().toLowerCase();
    return (mode == 'light' || mode == 'system') ? mode : 'dark';
  }

  static String _normalizeSubtitleMode(String? raw) =>
      (raw ?? AppConstants.subtitleModeSoftMux).trim().toLowerCase() ==
              AppConstants.subtitleModeHardBurn
          ? AppConstants.subtitleModeHardBurn
          : AppConstants.subtitleModeSoftMux;

  static int _normalizeVideoHeight(int value) =>
      supportedVideoHeights.contains(value) ? value : 0;

  static String _normalizeAudioLang(String? raw) {
    final v = (raw ?? 'original').trim().toLowerCase();
    return (v == 'ar' || v == 'en') ? v : 'original';
  }

  static String _normalizeSubPos(String? raw) {
    final v = (raw ?? 'bottom').trim().toLowerCase();
    return (v == 'top' || v == 'middle') ? v : 'bottom';
  }

  static int _clampSubFontSize(int value) => value.clamp(14, 32);

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
        other.clipboardSnifferActive == clipboardSnifferActive &&
        other.clipboardAutoAnalyze == clipboardAutoAnalyze &&
        mapEquals(other.snifferPlatforms, snifferPlatforms) &&
        other.customSaveTreeUri == customSaveTreeUri &&
        other.customSaveDisplayLabel == customSaveDisplayLabel &&
        other.preferredVideoHeight == preferredVideoHeight &&
        other.preferredAudioLang == preferredAudioLang &&
        other.subtitlePosition == subtitlePosition &&
        other.subtitleFontSize == subtitleFontSize &&
        other.cookiesFilePath == cookiesFilePath;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
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
    clipboardSnifferActive,
    clipboardAutoAnalyze,
    ...snifferPlatforms.entries.map((e) => Object.hash(e.key, e.value)),
    customSaveTreeUri,
    customSaveDisplayLabel,
    preferredVideoHeight,
    preferredAudioLang,
    subtitlePosition,
    subtitleFontSize,
    cookiesFilePath,
  ]);
}
