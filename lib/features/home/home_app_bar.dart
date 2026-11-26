import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/i18n/translator.dart';
import '../../core/theme/app_colors.dart';

/// Top application bar with FD logo, glowing engine status dot, layout switch, language toggle, cookies, and settings.
class HomeAppBar extends StatelessWidget implements PreferredSizeWidget {
  const HomeAppBar({
    super.key,
    required this.translator,
    required this.controller,
    required this.onOpenCookies,
    required this.onOpenSettings,
    this.isKanbanMode = true,
    this.onToggleLayoutMode,
  });

  final AppTranslator translator;
  final AppController? controller;
  final VoidCallback onOpenCookies;
  final VoidCallback onOpenSettings;
  final bool isKanbanMode;
  final VoidCallback? onToggleLayoutMode;

  @override
  Size get preferredSize => const Size.fromHeight(60);

  @override
  Widget build(BuildContext context) {
    final tr = translator.tr;
    final ctrl = controller;
    final activeLang = ctrl?.settings.language ?? translator.languageCode;
    final dotColor = (ctrl?.nativeReady ?? false)
        ? AppColors.success
        : AppColors.warning;

    return AppBar(
      toolbarHeight: 60,
      backgroundColor: AppColors.bgSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: 12,
      shape: const Border(
        bottom: BorderSide(color: AppColors.border, width: 1),
      ),
      title: Row(
        children: <Widget>[
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: AppColors.accent.withValues(alpha: 0.35),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/app_icon.png',
                key: const Key('app_brand_icon'),
                width: 32,
                height: 32,
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              tr('app_short_name'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15.5,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          if (ctrl != null) ...<Widget>[
            const SizedBox(width: 6),
            Tooltip(
              message: ctrl.nativeReady
                  ? tr('engine_ready', params: <String, String>{'ver': ctrl.ytdlpVersion})
                  : tr('engine_loading'),
              child: Container(
                key: const Key('ytdlp_status_label'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: dotColor.withValues(alpha: 0.55),
                      blurRadius: 5,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        if (onToggleLayoutMode != null) ...<Widget>[
          _actionBox(
            key: const Key('layout_mode_toggle_button'),
            tooltip: tr(isKanbanMode ? 'btn_layout_tabs' : 'btn_layout_kanban'),
            onPressed: onToggleLayoutMode!,
            child: Icon(
              isKanbanMode ? Icons.tab_rounded : Icons.view_column_rounded,
              size: 18,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(width: 6),
        ],
        _actionBox(
          key: const Key('lang_toggle_button'),
          tooltip: tr('btn_lang_toggle'),
          onPressed: () {
            if (ctrl != null) {
              final nextLang = ctrl.settings.language == 'ar' ? 'en' : 'ar';
              unawaited(ctrl.updateSettings(ctrl.settings.copyWith(language: nextLang)));
            } else {
              unawaited(translator.toggleLanguage());
            }
          },
          child: Text(
            activeLang == 'ar' ? 'EN' : 'ع',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppColors.accent,
            ),
          ),
        ),
        if (ctrl != null) ...<Widget>[
          const SizedBox(width: 6),
          _actionBox(
            key: const Key('open_cookies_button'),
            tooltip: tr('btn_cookies'),
            onPressed: onOpenCookies,
            child: Icon(
              Icons.cookie_outlined,
              size: 18,
              color: ctrl.settings.cookiesFilePath.isNotEmpty
                  ? AppColors.success
                  : AppColors.textPrimary,
            ),
          ),
          const SizedBox(width: 6),
          _actionBox(
            key: const Key('open_settings_button'),
            tooltip: tr('btn_settings'),
            onPressed: onOpenSettings,
            child: const Icon(
              Icons.settings_outlined,
              size: 18,
              color: AppColors.textPrimary,
            ),
          ),
        ],
        const SizedBox(width: 10),
      ],
    );
  }

  static Widget _actionBox({
    required Key key,
    required String tooltip,
    required VoidCallback onPressed,
    required Widget child,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AppColors.border),
        ),
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(10),
          onTap: onPressed,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
