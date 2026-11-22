import 'package:flutter/material.dart';

import '../../core/i18n/translator.dart';
import '../../core/theme/app_colors.dart';

/// Kanban Tab 1: Staged links awaiting analysis or batch download start.
class StagedTab extends StatelessWidget {
  const StagedTab({
    super.key,
    required this.translator,
    required this.stagedUrls,
    required this.onAnalyzeUrl,
    required this.onStartUrl,
    required this.onRemoveUrl,
    required this.onStartAll,
  });

  final AppTranslator translator;
  final List<String> stagedUrls;
  final void Function(String url) onAnalyzeUrl;
  final void Function(String url) onStartUrl;
  final void Function(String url) onRemoveUrl;
  final VoidCallback onStartAll;

  @override
  Widget build(BuildContext context) {
    final tr = translator.tr;
    if (stagedUrls.isEmpty) {
      return _EmptyState(
        icon: Icons.inbox_outlined,
        title: tr('empty_staged_title'),
        subtitle: tr('empty_staged_subtitle'),
      );
    }

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: Row(
            children: <Widget>[
              Text(
                '${tr('tab_staged')} (${stagedUrls.length})',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                key: const Key('staged_start_all_button'),
                onPressed: onStartAll,
                icon: const Icon(Icons.playlist_play_rounded, size: 18),
                label: Text(tr('btn_start_all')),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 16),
            itemCount: stagedUrls.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final url = stagedUrls[index];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.link_rounded, color: AppColors.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          url,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      IconButton(
                        tooltip: tr('btn_analyze'),
                        onPressed: () => onAnalyzeUrl(url),
                        icon: const Icon(Icons.tune_rounded, color: AppColors.accent),
                      ),
                      IconButton(
                        tooltip: tr('btn_start'),
                        onPressed: () => onStartUrl(url),
                        icon: const Icon(Icons.play_arrow_rounded, color: AppColors.success),
                      ),
                      IconButton(
                        tooltip: tr('btn_delete'),
                        onPressed: () => onRemoveUrl(url),
                        icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Theme.of(context).cardTheme.color ?? AppColors.bgCard,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
              child: Icon(icon, size: 32, color: AppColors.accent),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
