import 'package:flutter/material.dart';

import '../../core/config/app_settings.dart';
import '../../core/i18n/translator.dart';
import '../../core/theme/app_colors.dart';

/// Settings card configuring Android SAF save directory and auto-categorized subfolders.
class SettingsStorageSection extends StatelessWidget {
  const SettingsStorageSection({
    super.key,
    required this.translator,
    required this.settings,
    required this.onPickSaveDir,
    required this.onResetSaveDir,
    required this.onChanged,
  });

  final AppTranslator translator;
  final AppSettings settings;
  final VoidCallback onPickSaveDir;
  final VoidCallback onResetSaveDir;
  final void Function(AppSettings next) onChanged;

  @override
  Widget build(BuildContext context) {
    final tr = translator.tr;
    final hasCustom = settings.customSaveTreeUri.isNotEmpty;
    final displayPath = hasCustom && settings.customSaveDisplayLabel.isNotEmpty
        ? settings.customSaveDisplayLabel
        : tr('storage_default_path');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              tr('storage_current_path', params: <String, String>{'path': displayPath}),
              key: const Key('storage_current_path_text'),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: hasCustom ? AppColors.accent : null,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                ElevatedButton.icon(
                  key: const Key('btn_pick_save_dir'),
                  onPressed: onPickSaveDir,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: Text(tr('btn_pick_save_dir')),
                ),
                if (hasCustom)
                  OutlinedButton(
                    key: const Key('btn_reset_save_dir'),
                    onPressed: onResetSaveDir,
                    child: Text(tr('btn_reset_save_dir')),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            SwitchListTile(
              key: const Key('settings_auto_categorize'),
              contentPadding: EdgeInsets.zero,
              title: Text(tr('lbl_auto_categorize')),
              value: settings.autoCategorizeFolders,
              onChanged: (v) => onChanged(settings.copyWith(autoCategorizeFolders: v)),
            ),
          ],
        ),
      ),
    );
  }
}
