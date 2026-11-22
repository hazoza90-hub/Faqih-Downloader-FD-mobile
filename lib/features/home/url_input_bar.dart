import 'package:flutter/material.dart';

import '../../core/i18n/translator.dart';
import '../../core/theme/app_colors.dart';

/// Top URL input bar with clipboard paste, submit/analyze action, and extraction progress.
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
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      key: const Key('url_input_field'),
                      controller: controller,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      onSubmitted: (_) => onSubmit(),
                      decoration: InputDecoration(
                        hintText: tr('url_input_hint'),
                        prefixIcon: const Icon(
                          Icons.link_rounded,
                          color: AppColors.textSecondary,
                        ),
                        suffixIcon: IconButton(
                          key: const Key('url_paste_button'),
                          tooltip: tr('btn_paste'),
                          onPressed: onPaste,
                          icon: const Icon(
                            Icons.content_paste_rounded,
                            size: 20,
                            color: AppColors.accent,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    key: const Key('url_submit_button'),
                    onPressed: isExtracting ? null : onSubmit,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(tr('btn_add')),
                  ),
                ],
              ),
              if (isExtracting) ...<Widget>[
                const SizedBox(height: 10),
                const LinearProgressIndicator(minHeight: 3),
                const SizedBox(height: 6),
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
      ),
    );
  }
}
