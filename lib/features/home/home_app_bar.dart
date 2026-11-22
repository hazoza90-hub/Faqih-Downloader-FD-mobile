import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/i18n/translator.dart';
import '../../core/theme/app_colors.dart';

/// Top application bar with FD logo, yt-dlp engine status, language toggle, cookies, and settings.
class HomeAppBar extends StatelessWidget implements PreferredSizeWidget {
  const HomeAppBar({
    super.key,
    required this.translator,
    required this.controller,
    required this.onOpenCookies,
    required this.onOpenSettings,
  });

  final AppTranslator translator;
  final AppController? controller;
  final VoidCallback onOpenCookies;
  final VoidCallback onOpenSettings;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final tr = translator.tr;
    final ctrl = controller;
    return AppBar(
      title: Row(
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
            ),
            child: const Center(
              child: Text(
                'FD',
                style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w800, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  tr('app_short_name'),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                if (ctrl != null)
                  Text(
                    ctrl.nativeReady
                        ? tr('engine_ready', params: <String, String>{'ver': ctrl.ytdlpVersion})
                        : tr('engine_loading'),
                    key: const Key('ytdlp_status_label'),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: ctrl.nativeReady ? AppColors.success : AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton.icon(
          key: const Key('lang_toggle_button'),
          onPressed: () {
            if (ctrl != null) {
              final nextLang = ctrl.settings.language == 'ar' ? 'en' : 'ar';
              unawaited(ctrl.updateSettings(ctrl.settings.copyWith(language: nextLang)));
            } else {
              unawaited(translator.toggleLanguage());
            }
          },
          icon: const Icon(Icons.translate_rounded, size: 17, color: AppColors.accent),
          label: Text(
            tr('btn_lang_toggle'),
            style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600),
          ),
        ),
        if (ctrl != null) ...<Widget>[
          IconButton(
            key: const Key('open_cookies_button'),
            tooltip: tr('btn_cookies'),
            onPressed: onOpenCookies,
            icon: Icon(
              Icons.cookie_outlined,
              color: ctrl.settings.cookiesFilePath.isNotEmpty ? AppColors.success : null,
            ),
          ),
          IconButton(
            key: const Key('open_settings_button'),
            tooltip: tr('btn_settings'),
            onPressed: onOpenSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ],
    );
  }
}
