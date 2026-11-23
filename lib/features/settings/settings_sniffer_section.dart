import 'package:flutter/material.dart';

import '../../core/config/app_settings.dart';
import '../../core/i18n/translator.dart';

/// Settings card configuring clipboard auto-sniffer behavior, floating capture bubble, and platforms.
class SettingsSnifferSection extends StatelessWidget {
  const SettingsSnifferSection({
    super.key,
    required this.translator,
    required this.settings,
    required this.onChanged,
    this.onToggleFloatingCapture,
  });

  final AppTranslator translator;
  final AppSettings settings;
  final void Function(AppSettings next) onChanged;
  final ValueChanged<bool>? onToggleFloatingCapture;

  static const List<String> _platformKeys = <String>[
    'youtube',
    'tiktok',
    'instagram',
    'facebook',
    'twitter',
    'direct',
  ];

  @override
  Widget build(BuildContext context) {
    final tr = translator.tr;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SwitchListTile(
              key: const Key('settings_sniffer_active'),
              contentPadding: EdgeInsets.zero,
              title: Text(tr('sniffer_active')),
              value: settings.clipboardSnifferActive,
              onChanged: (v) => onChanged(settings.copyWith(clipboardSnifferActive: v)),
            ),
            SwitchListTile(
              key: const Key('settings_sniffer_auto_analyze'),
              contentPadding: EdgeInsets.zero,
              title: Text(tr('sniffer_auto_analyze')),
              value: settings.clipboardAutoAnalyze,
              onChanged: settings.clipboardSnifferActive
                  ? (v) => onChanged(settings.copyWith(clipboardAutoAnalyze: v))
                  : null,
            ),
            if (onToggleFloatingCapture != null)
              SwitchListTile(
                key: const Key('settings_floating_capture_switch'),
                contentPadding: EdgeInsets.zero,
                title: Text(tr('sniffer_floating_capture')),
                subtitle: Text(
                  tr('sniffer_floating_capture_desc'),
                  style: const TextStyle(fontSize: 11),
                ),
                value: settings.floatingCaptureEnabled,
                onChanged: onToggleFloatingCapture,
              ),
            const SizedBox(height: 6),
            Text(tr('sniffer_platforms'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _platformKeys.map((plat) {
                final enabled = settings.snifferPlatforms[plat] ?? true;
                return FilterChip(
                  key: Key('sniffer_plat_$plat'),
                  label: Text(tr('plat_$plat')),
                  selected: enabled,
                  onSelected: settings.clipboardSnifferActive
                      ? (v) {
                          final next = Map<String, bool>.from(settings.snifferPlatforms);
                          next[plat] = v;
                          onChanged(settings.copyWith(snifferPlatforms: next));
                        }
                      : null,
                );
              }).toList(growable: false),
            ),
          ],
        ),
      ),
    );
  }
}
