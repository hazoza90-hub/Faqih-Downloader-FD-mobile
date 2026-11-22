import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/config/app_settings.dart';
import '../../core/utils/url_detector.dart';

typedef ClipboardTextReader = Future<String?> Function();

/// Monitors app foreground resumes & startup clipboard content for downloadable URLs.
class ClipboardSnifferService with WidgetsBindingObserver {
  ClipboardSnifferService({
    required this.settingsProvider,
    required this.onUrlDetected,
    ClipboardTextReader? clipboardReader,
    this.observeLifecycle = true,
  }) : _clipboardReader = clipboardReader ?? _defaultClipboardReader;

  final AppSettings Function() settingsProvider;
  final FutureOr<void> Function(String url) onUrlDetected;
  final ClipboardTextReader _clipboardReader;
  final bool observeLifecycle;

  bool _started = false;
  String? _lastSeenUrl;

  String? get lastSeenUrl => _lastSeenUrl;

  void start({bool checkImmediately = true}) {
    if (_started) return;
    _started = true;
    if (observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
    }
    if (checkImmediately) {
      unawaited(checkClipboard());
    }
  }

  void dispose() {
    if (_started && observeLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _started = false;
  }

  void markSeen(String url) {
    final trimmed = url.trim();
    if (trimmed.isNotEmpty) _lastSeenUrl = trimmed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(checkClipboard());
    }
  }

  Future<String?> checkClipboard() async {
    final settings = settingsProvider();
    if (!settings.clipboardSnifferActive) return null;

    String? raw;
    try {
      raw = await _clipboardReader();
    } catch (_) {
      return null;
    }
    if (raw == null || raw.trim().isEmpty) return null;

    final urls = UrlDetector.extractUrls(raw);
    if (urls.isEmpty) return null;

    final candidate = urls.first;
    if (candidate == _lastSeenUrl) return null;

    _lastSeenUrl = candidate;
    if (!isPlatformAllowed(candidate, settings.snifferPlatforms)) {
      return null;
    }

    await onUrlDetected(candidate);
    return candidate;
  }

  static bool isPlatformAllowed(String url, Map<String, bool> platforms) {
    final plat = UrlDetector.extractMediaPlatform(url)?.toLowerCase() ?? '';
    if (plat.contains('youtube')) return platforms['youtube'] ?? true;
    if (plat.contains('tiktok')) return platforms['tiktok'] ?? true;
    if (plat.contains('instagram')) return platforms['instagram'] ?? true;
    if (plat.contains('facebook')) return platforms['facebook'] ?? true;
    if (plat.contains('twitter')) return platforms['twitter'] ?? true;
    return platforms['direct'] ?? true;
  }

  static Future<String?> _defaultClipboardReader() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }
}
