import 'package:flutter/material.dart';

import '../../core/i18n/translator.dart';
import '../../core/theme/app_colors.dart';

/// Compact single-line top URL input bar with clipboard paste, add action, and extraction progress.
class UrlInputBar extends StatelessWidget {
  const UrlInputBar({
    super.key,
    required this.controller,
    required this.translator,
    required this.isExtracting,
    required this.onPaste,
    required this.onSubmit,
    required this.onCancelExtract,
  });

  final TextEditingController controller;
  final AppTranslator translator;
  final bool isExtracting;
  final VoidCallback onPaste;
  final VoidCallback onSubmit;
  final VoidCallback onCancelExtract;

  @override
  Widget build(BuildContext context) {
    final tr = translator.tr;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(
                  Icons.link_rounded,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    key: const Key('url_input_field'),
                    controller: controller,
                    minLines: 1,
                    maxLines: 1,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => onSubmit(),
                    style: const TextStyle(fontSize: 13.5),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      hintText: tr('url_input_hint'),
                      hintMaxLines: 1,
                      hintStyle: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('url_paste_button'),
                  tooltip: tr('btn_paste'),
                  onPressed: onPaste,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  icon: const Icon(
                    Icons.content_paste_rounded,
                    size: 19,
                    color: AppColors.accent,
                  ),
                ),
                const SizedBox(width: 4),
                ElevatedButton.icon(
                  key: const Key('url_submit_button'),
                  onPressed: isExtracting ? null : onSubmit,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: Text(
                    tr('btn_add'),
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (isExtracting) ...<Widget>[
              const SizedBox(height: 6),
              const LinearProgressIndicator(minHeight: 3),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      tr('msg_extracting'),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onCancelExtract,
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: Text(tr('btn_cancel')),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
