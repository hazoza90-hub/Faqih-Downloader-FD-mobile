import 'package:faqih_downloader_mobile/core/config/app_settings.dart';
import 'package:faqih_downloader_mobile/services/clipboard/clipboard_sniffer_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClipboardSnifferService', () {
    test('detects new URL, deduplicates repeated clipboard text, and honors active flag', () async {
      var clipboardText = 'Check this https://youtu.be/dQw4w9WgXcQ';
      var settings = const AppSettings();
      final detected = <String>[];

      final sniffer = ClipboardSnifferService(
        settingsProvider: () => settings,
        onUrlDetected: (u) => detected.add(u),
        clipboardReader: () async => clipboardText,
        observeLifecycle: false,
        resumeDelay: Duration.zero,
      );

      // 1. First read detects YouTube URL:
      expect(await sniffer.checkClipboard(), 'https://youtu.be/dQw4w9WgXcQ');
      expect(detected, ['https://youtu.be/dQw4w9WgXcQ']);

      // 2. Repeated read with identical URL is ignored:
      expect(await sniffer.checkClipboard(), isNull);
      expect(detected.length, 1);

      // 3. Disabling sniffer ignores new URL:
      settings = settings.copyWith(clipboardSnifferActive: false);
      clipboardText = 'https://cdn.example.com/archive.zip';
      expect(await sniffer.checkClipboard(), isNull);
      expect(detected.length, 1);
    });

    test('filters detected URLs according to snifferPlatforms map and lifecycle resume', () async {
      var clipboardText = 'https://www.youtube.com/watch?v=abc123def45';
      final settings = const AppSettings().copyWith(
        snifferPlatforms: <String, bool>{
          'youtube': false,
          'tiktok': true,
          'direct': false,
        },
      );
      final detected = <String>[];

      final sniffer = ClipboardSnifferService(
        settingsProvider: () => settings,
        onUrlDetected: (u) => detected.add(u),
        clipboardReader: () async => clipboardText,
        observeLifecycle: false,
        resumeDelay: Duration.zero,
      )..start(checkImmediately: false);

      // YouTube disabled -> suppressed:
      expect(await sniffer.checkClipboard(), isNull);
      expect(detected, isEmpty);

      // Direct links disabled -> suppressed:
      clipboardText = 'https://cdn.example.com/file.pdf';
      expect(await sniffer.checkClipboard(), isNull);
      expect(detected, isEmpty);

      // TikTok enabled -> allowed on resumed lifecycle event:
      clipboardText = 'https://www.tiktok.com/@creator/video/7234567890123456789';
      sniffer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(detected, ['https://www.tiktok.com/@creator/video/7234567890123456789']);
      sniffer.dispose();
    });

    test('waits resumeDelay before reading clipboard and cancels if disposed mid-delay', () async {
      var readCount = 0;
      final detected = <String>[];
      final sniffer = ClipboardSnifferService(
        settingsProvider: () => const AppSettings(),
        onUrlDetected: (u) => detected.add(u),
        clipboardReader: () async {
          readCount++;
          return 'https://youtu.be/dQw4w9WgXcQ';
        },
        observeLifecycle: false,
        resumeDelay: const Duration(milliseconds: 60),
      )..start(checkImmediately: false);

      // 1. Trigger resume and dispose before delay elapses -> aborted cleanly:
      sniffer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(readCount, 0);
      sniffer.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(readCount, 0);
      expect(detected, isEmpty);

      // 2. Active instance waits resumeDelay then reads once:
      final activeSniffer = ClipboardSnifferService(
        settingsProvider: () => const AppSettings(),
        onUrlDetected: (u) => detected.add(u),
        clipboardReader: () async {
          readCount++;
          return 'https://youtu.be/dQw4w9WgXcQ';
        },
        observeLifecycle: false,
        resumeDelay: const Duration(milliseconds: 40),
      )..start(checkImmediately: false);
      activeSniffer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(readCount, 0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(readCount, 1);
      expect(detected, ['https://youtu.be/dQw4w9WgXcQ']);
      activeSniffer.dispose();
    });
  });
}
