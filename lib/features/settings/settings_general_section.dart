import 'package:flutter/material.dart';

import '../../core/config/app_settings.dart';
import '../../core/i18n/translator.dart';

/// General app appearance card configuring UI language and theme mode.
class SettingsGeneralSection extends StatelessWidget {
  const SettingsGeneralSection({
    super.key,
    required this.translator,
    required this.settings,
    required this.onChanged,
  });

  final AppTranslator translator;
  final AppSettings settings;
  final void Function(AppSettings next) onChanged;

  @override
  Widget build(BuildContext context) {
    final tr = translator.tr;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(tr('lbl_language'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: <Widget>[
                ChoiceChip(
                  key: const Key('settings_lang_ar'),
                  label: Text(tr('lbl_lang_ar')),
                  selected: settings.language == 'ar',
                  onSelected: (_) => onChanged(settings.copyWith(language: 'ar')),
                ),
                ChoiceChip(
                  key: const Key('settings_lang_en'),
                  label: Text(tr('lbl_lang_en')),
                  selected: settings.language == 'en',
                  onSelected: (_) => onChanged(settings.copyWith(language: 'en')),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(tr('lbl_theme'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: <String>['dark', 'light', 'system'].map((mode) {
                return ChoiceChip(
                  key: Key('settings_theme_$mode'),
                  label: Text(tr('theme_$mode')),
                  selected: settings.themeMode == mode,
                  onSelected: (_) => onChanged(settings.copyWith(themeMode: mode)),
                );
              }).toList(growable: false),
            ),
          ],
        ),
      ),
    );
  }
}
