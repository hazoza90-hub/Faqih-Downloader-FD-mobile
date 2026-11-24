import '../core/config/app_settings.dart';
import '../core/i18n/translator.dart';
import '../platform/background_capture_channel.dart';
import '../platform/floating_capture_channel.dart';

/// Encapsulates Floating Bubble, Silent Accessibility Auto-Sniffer, and Quick Settings Tile state.
class CaptureIntegrationsHelper {
  CaptureIntegrationsHelper({
    FloatingCaptureChannel? floatingCapture,
    BackgroundCaptureChannel? backgroundCapture,
    required AppTranslator translator,
    required AppSettings Function() settingsProvider,
    required Future<void> Function(AppSettings next) saveSettings,
  })  : _floating = floatingCapture ?? FloatingCaptureChannel(),
        _background = backgroundCapture ?? BackgroundCaptureChannel(),
        _translator = translator,
        _settingsProvider = settingsProvider,
        _saveSettings = saveSettings;

  final FloatingCaptureChannel _floating;
  final BackgroundCaptureChannel _background;
  final AppTranslator _translator;
  final AppSettings Function() _settingsProvider;
  final Future<void> Function(AppSettings next) _saveSettings;

  Future<bool> setFloatingCaptureEnabled(bool enabled) async {
    if (!enabled) {
      await _floating.stopFloatingCapture().catchError((_) => false);
      await _saveSettings(_settingsProvider().copyWith(floatingCaptureEnabled: false));
      return true;
    }
    final allowed = await _floating.canDrawOverlays();
    if (!allowed) {
      await _floating.requestOverlayPermission();
      return false;
    }
    await _floating.startFloatingCapture(
      title: _translator.tr('notif_capture_title'),
      body: _translator.tr('notif_capture_body'),
      captureLabel: _translator.tr('notif_capture_btn'),
      stopLabel: _translator.tr('notif_capture_stop'),
      emptyClipboardMsg: _translator.tr('msg_capture_no_url'),
    );
    await _saveSettings(_settingsProvider().copyWith(floatingCaptureEnabled: true));
    return true;
  }

  Future<void> syncFloatingCaptureState() async {
    if (!_settingsProvider().floatingCaptureEnabled) return;
    try {
      final running = await _floating.isRunning();
      if (!running && _settingsProvider().floatingCaptureEnabled) {
        await _saveSettings(_settingsProvider().copyWith(floatingCaptureEnabled: false));
      }
    } catch (_) {}
  }

  Future<bool> setBackgroundAutoSnifferEnabled(bool enabled) async {
    if (enabled) {
      var granted = false;
      try {
        granted = await _background.isAccessibilityServiceEnabled();
      } catch (_) {}
      if (!granted) return false;
    }
    await _saveSettings(
      _settingsProvider().copyWith(backgroundAutoSnifferEnabled: enabled),
    );
    await pushAutoSnifferConfig();
    return true;
  }

  Future<bool> syncAccessibilityState({bool enableIfGranted = false}) async {
    final s = _settingsProvider();
    late final bool granted;
    try {
      granted = await _background.isAccessibilityServiceEnabled();
    } catch (_) {
      return s.backgroundAutoSnifferEnabled;
    }
    if (enableIfGranted && granted && !s.backgroundAutoSnifferEnabled) {
      await _saveSettings(s.copyWith(backgroundAutoSnifferEnabled: true));
      await pushAutoSnifferConfig();
    } else if (!granted && s.backgroundAutoSnifferEnabled) {
      await _saveSettings(s.copyWith(backgroundAutoSnifferEnabled: false));
      await pushAutoSnifferConfig();
    } else if (granted && s.backgroundAutoSnifferEnabled) {
      await pushAutoSnifferConfig();
    }
    return granted;
  }

  Future<void> pushAutoSnifferConfig() async {
    final s = _settingsProvider();
    try {
      await _background.setAutoSnifferConfig(
        enabled: s.backgroundAutoSnifferEnabled,
        platforms: s.snifferPlatforms,
        notifTitle: _translator.tr('notif_silent_capture_title'),
        notifActionLabel: _translator.tr('notif_silent_capture_action'),
        emptyClipboardMsg: _translator.tr('msg_capture_no_url'),
      );
    } catch (_) {}
  }

  Future<bool> openAccessibilitySettings() => _background.openAccessibilitySettings();
  Future<bool> openAppDetailsSettings() => _background.openAppDetailsSettings();

  Future<bool> setQuickTileEnabled(bool enabled) async {
    final s = _settingsProvider();
    await _saveSettings(
      s.copyWith(
        quickTileEnabled: enabled,
        quickTilePrompted: enabled ? true : s.quickTilePrompted,
      ),
    );
    await _background.setQuickTileEnabled(enabled);
    if (enabled) {
      await _background.requestAddQuickTile(label: _translator.tr('quick_tile_label'));
    }
    return true;
  }

  Future<bool> promptAddQuickTileOnce() async {
    final s = _settingsProvider();
    if (!s.quickTileEnabled || s.quickTilePrompted) return false;
    final prompted = await _background.requestAddQuickTile(
      label: _translator.tr('quick_tile_label'),
    );
    if (prompted) {
      await _saveSettings(_settingsProvider().copyWith(quickTilePrompted: true));
    }
    return prompted;
  }

  Future<void> syncOnBoot() async {
    final s = _settingsProvider();
    if (s.floatingCaptureEnabled) {
      try {
        if (await _floating.canDrawOverlays()) {
          await _floating.startFloatingCapture(
            title: _translator.tr('notif_capture_title'),
            body: _translator.tr('notif_capture_body'),
            captureLabel: _translator.tr('notif_capture_btn'),
            stopLabel: _translator.tr('notif_capture_stop'),
            emptyClipboardMsg: _translator.tr('msg_capture_no_url'),
          );
        }
      } catch (_) {}
    }
    await pushAutoSnifferConfig();
    await _background.setQuickTileEnabled(s.quickTileEnabled);
  }
}
