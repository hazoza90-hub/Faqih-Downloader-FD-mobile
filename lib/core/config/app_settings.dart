import 'package:flutter/foundation.dart';

import 'app_constants.dart';

/// Immutable user preferences for Faqih Downloader Mobile.
@immutable
class AppSettings {
  const AppSettings({
    this.language = 'ar',
    this.maxConnections = AppConstants.defaultMaxConnections,
    this.speedLimitBytesPerSec = 0,
    this.autoCategorizeFolders = true,
    this.defaultQuality = AppConstants.defaultQuality,
    this.preferredSubtitleLang = 'none',
    this.subtitleEmbedMode = AppConstants.subtitleModeSoftMux,
    this.wifiOnlyDownloads = false,
    this.clipboardAutoCheck = true,
  });

  final String language;
  final int maxConnections;
  final int speedLimitBytesPerSec;
  final bool autoCategorizeFolders;
  final String defaultQuality;
  final String preferredSubtitleLang;
  final String subtitleEmbedMode;
  final bool wifiOnlyDownloads;
  final bool clipboardAutoCheck;

  AppSettings copyWith({
    String? language,
    int? maxConnections,
    int? speedLimitBytesPerSec,
    bool? autoCategorizeFolders,
    String? defaultQuality,
    String? preferredSubtitleLang,
    String? subtitleEmbedMode,
    bool? wifiOnlyDownloads,
    bool? clipboardAutoCheck,
  }) {
    return AppSettings(
      language: _normalizeLanguage(language ?? this.language),
      maxConnections: AppConstants.clampConnections(
        maxConnections ?? this.maxConnections,
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
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'language': language,
      'maxConnections': maxConnections,
      'speedLimitBytesPerSec': speedLimitBytesPerSec,
      'autoCategorizeFolders': autoCategorizeFolders,
      'defaultQuality': defaultQuality,
      'preferredSubtitleLang': preferredSubtitleLang,
      'subtitleEmbedMode': subtitleEmbedMode,
      'wifiOnlyDownloads': wifiOnlyDownloads,
      'clipboardAutoCheck': clipboardAutoCheck,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      language: _normalizeLanguage(json['language']?.toString()),
      maxConnections: AppConstants.clampConnections(
        _parseInt(
          json['maxConnections'],
          AppConstants.defaultMaxConnections,
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
    );
  }

  static String _normalizeLanguage(String? raw) {
    final code = (raw ?? 'ar').trim().toLowerCase();
    return code == 'en' ? 'en' : 'ar';
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
        other.maxConnections == maxConnections &&
        other.speedLimitBytesPerSec == speedLimitBytesPerSec &&
        other.autoCategorizeFolders == autoCategorizeFolders &&
        other.defaultQuality == defaultQuality &&
        other.preferredSubtitleLang == preferredSubtitleLang &&
        other.subtitleEmbedMode == subtitleEmbedMode &&
        other.wifiOnlyDownloads == wifiOnlyDownloads &&
        other.clipboardAutoCheck == clipboardAutoCheck;
  }

  @override
  int get hashCode => Object.hash(
    language,
    maxConnections,
    speedLimitBytesPerSec,
    autoCategorizeFolders,
    defaultQuality,
    preferredSubtitleLang,
    subtitleEmbedMode,
    wifiOnlyDownloads,
    clipboardAutoCheck,
  );
}
