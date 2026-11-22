import 'package:flutter/material.dart';

import '../../core/config/app_constants.dart';
import '../../core/config/app_settings.dart';
import '../../core/i18n/translator.dart';

/// Settings card configuring preferred video quality, audio/dubbing language, and burned subtitle styling.
class SettingsMediaPrefsSection extends StatelessWidget {
  const SettingsMediaPrefsSection({
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
            Text(tr('lbl_pref_quality'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: AppSettings.supportedVideoHeights.map((h) {
                final label = h == 0 ? tr('pref_quality_best') : '${h}p';
                return ChoiceChip(
                  key: Key('pref_height_$h'),
                  label: Text(label),
                  selected: settings.preferredVideoHeight == h,
                  onSelected: (_) => onChanged(settings.copyWith(preferredVideoHeight: h)),
                );
              }).toList(growable: false),
            ),
            const SizedBox(height: 12),
            Text(tr('lbl_pref_audio'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: <String>['original', 'ar', 'en'].map((lang) {
                final label = lang == 'original' ? tr('pref_audio_original') : lang.toUpperCase();
                return ChoiceChip(
                  key: Key('pref_audio_$lang'),
                  label: Text(label),
                  selected: settings.preferredAudioLang == lang,
                  onSelected: (_) => onChanged(settings.copyWith(preferredAudioLang: lang)),
                );
              }).toList(growable: false),
            ),
            const SizedBox(height: 12),
            Text(tr('lbl_pref_subtitle'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: <String>['none', 'ar', 'en'].map((lang) {
                final label = lang == 'none' ? tr('lbl_no_subtitle') : lang.toUpperCase();
                return ChoiceChip(
                  key: Key('pref_sub_lang_$lang'),
                  label: Text(label),
                  selected: settings.preferredSubtitleLang == lang,
                  onSelected: (_) => onChanged(settings.copyWith(preferredSubtitleLang: lang)),
                );
              }).toList(growable: false),
            ),
            const SizedBox(height: 12),
            Text(tr('lbl_subtitle_mode'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: <String>[AppConstants.subtitleModeSoftMux, AppConstants.subtitleModeHardBurn].map((mode) {
                final label = mode == AppConstants.subtitleModeHardBurn
                    ? tr('sub_mode_hard')
                    : tr('sub_mode_soft');
                return ChoiceChip(
                  key: Key('pref_sub_mode_$mode'),
                  label: Text(label),
                  selected: settings.subtitleEmbedMode == mode,
                  onSelected: (_) => onChanged(settings.copyWith(subtitleEmbedMode: mode)),
                );
              }).toList(growable: false),
            ),
            const SizedBox(height: 12),
            Text(tr('lbl_sub_position'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: <String>['bottom', 'middle', 'top'].map((pos) {
                return ChoiceChip(
                  key: Key('pref_sub_pos_$pos'),
                  label: Text(tr('sub_pos_$pos')),
                  selected: settings.subtitlePosition == pos,
                  onSelected: (_) => onChanged(settings.copyWith(subtitlePosition: pos)),
                );
              }).toList(growable: false),
            ),
            const SizedBox(height: 10),
            Text('${tr('lbl_sub_font_size')}: ${settings.subtitleFontSize}'),
            Slider(
              key: const Key('pref_sub_font_slider'),
              min: 14,
              max: 32,
              divisions: 18,
              value: settings.subtitleFontSize.toDouble(),
              onChanged: (v) => onChanged(settings.copyWith(subtitleFontSize: v.round())),
            ),
          ],
        ),
      ),
    );
  }
}
