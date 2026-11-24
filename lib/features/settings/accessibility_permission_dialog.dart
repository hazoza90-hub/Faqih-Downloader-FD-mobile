import 'package:flutter/material.dart';

import '../../core/i18n/translator.dart';
import '../../core/theme/app_colors.dart';

/// Guides the user through enabling silent Accessibility link capture (including Android 13+ Restricted Settings).
Future<void> showAccessibilityPermissionDialog({
  required BuildContext context,
  required AppTranslator translator,
  required VoidCallback onOpenAccessibility,
  required VoidCallback onOpenAppDetails,
}) {
  final tr = translator.tr;
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('accessibility_permission_dialog'),
      title: Row(
        children: <Widget>[
          const Icon(Icons.accessibility_new_rounded, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(tr('dlg_a11y_title'), style: const TextStyle(fontSize: 16)),
          ),
        ],
      ),
      content: Text(tr('dlg_a11y_body'), style: const TextStyle(fontSize: 13.5)),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(tr('btn_cancel')),
        ),
        OutlinedButton(
          key: const Key('btn_open_app_info'),
          onPressed: () {
            Navigator.of(ctx).pop();
            onOpenAppDetails();
          },
          child: Text(tr('btn_open_app_details')),
        ),
        FilledButton(
          key: const Key('btn_open_accessibility_settings'),
          onPressed: () {
            Navigator.of(ctx).pop();
            onOpenAccessibility();
          },
          child: Text(tr('btn_open_accessibility')),
        ),
      ],
    ),
  );
}
