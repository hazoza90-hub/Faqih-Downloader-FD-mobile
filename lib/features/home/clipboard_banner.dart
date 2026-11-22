import 'package:flutter/material.dart';

import '../../core/i18n/translator.dart';
import '../../core/theme/app_colors.dart';

/// Compact smart banner surfaced when [ClipboardSnifferService] detects a supported URL.
class ClipboardSnifferBanner extends StatelessWidget {
  const ClipboardSnifferBanner({
    super.key,
    required this.translator,
    required this.detectedUrl,
    required this.onAnalyze,
    required this.onStage,
    required this.onDismiss,
  });

  final AppTranslator translator;
  final String detectedUrl;
  final VoidCallback onAnalyze;
  final VoidCallback onStage;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final tr = translator.tr;
    return Card(
      key: const Key('clipboard_sniffer_banner'),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      color: AppColors.accent.withValues(alpha: 0.1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.accent.withValues(alpha: 0.45)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.link_rounded, size: 16, color: AppColors.accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    tr('sniffer_detected_title'),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  key: const Key('sniffer_dismiss_btn'),
                  visualDensity: VisualDensity.compact,
                  tooltip: tr('sniffer_dismiss'),
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ],
            ),
            Text(
              detectedUrl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                FilledButton.tonalIcon(
                  key: const Key('sniffer_analyze_btn'),
                  onPressed: onAnalyze,
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: Text(tr('btn_analyze')),
                ),
                OutlinedButton(
                  key: const Key('sniffer_stage_btn'),
                  onPressed: onStage,
                  child: Text(tr('btn_stage_for_later')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
