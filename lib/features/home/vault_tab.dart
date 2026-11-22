import 'package:flutter/material.dart';

import '../../core/i18n/translator.dart';
import '../../core/models/download_status.dart';
import '../../core/models/history_entry.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/size_formatter.dart';
import 'phase_label_helper.dart';

/// Kanban Tab 3: Searchable, categorized completed/failed download history vault.
class VaultTab extends StatefulWidget {
  const VaultTab({
    super.key,
    required this.translator,
    required this.entries,
    required this.onOpenEntry,
    required this.onRetryEntry,
    required this.onDeleteEntry,
  });

  final AppTranslator translator;
  final List<HistoryEntry> entries;
  final void Function(HistoryEntry entry) onOpenEntry;
  final void Function(HistoryEntry entry) onRetryEntry;
  final void Function(HistoryEntry entry) onDeleteEntry;

  @override
  State<VaultTab> createState() => _VaultTabState();
}

class _VaultTabState extends State<VaultTab> {
  String _selectedCategory = 'All';
  String _searchQuery = '';

  List<HistoryEntry> get _filtered {
    final q = _searchQuery.trim().toLowerCase();
    return widget.entries.where((e) {
      if (_selectedCategory != 'All' &&
          e.category.toLowerCase() != _selectedCategory.toLowerCase()) {
        return false;
      }
      if (q.isNotEmpty) {
        final hay = '${e.filename} ${e.platform} ${e.url}'.toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.translator.tr;
    final items = _filtered;

    if (widget.entries.isEmpty) {
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
                child: const Icon(Icons.verified_outlined, size: 32, color: AppColors.accent),
              ),
              const SizedBox(height: 16),
              Text(
                tr('empty_vault_title'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                tr('empty_vault_subtitle'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: TextField(
            key: const Key('vault_search_field'),
            onChanged: (v) => setState(() => _searchQuery = v),
            decoration: InputDecoration(
              hintText: tr('vault_search_hint'),
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              isDense: true,
            ),
          ),
        ),
        SizedBox(
          height: 38,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: PhaseLabelHelper.vaultCategories.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final cat = PhaseLabelHelper.vaultCategories[index];
              final selected = _selectedCategory == cat;
              return FilterChip(
                key: Key('vault_cat_$cat'),
                label: Text(tr(PhaseLabelHelper.categoryKey(cat))),
                selected: selected,
                onSelected: (_) => setState(() => _selectedCategory = cat),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 16),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final entry = items[index];
              final ok = entry.status == DownloadStatus.completed;
              final statusColor = ok ? AppColors.success : AppColors.danger;
              return Card(
                child: ListTile(
                  leading: Icon(
                    ok ? Icons.check_circle_outline : Icons.error_outline,
                    color: statusColor,
                  ),
                  title: Text(
                    entry.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${tr(PhaseLabelHelper.categoryKey(entry.category))} • '
                    '${entry.platform} • ${formatFileSize(entry.totalSize)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (ok)
                        IconButton(
                          key: Key('vault_open_${entry.id}'),
                          tooltip: tr('btn_open'),
                          onPressed: () => widget.onOpenEntry(entry),
                          icon: const Icon(Icons.open_in_new_rounded, color: AppColors.accent),
                        )
                      else
                        IconButton(
                          key: Key('vault_retry_${entry.id}'),
                          tooltip: tr('btn_retry'),
                          onPressed: () => widget.onRetryEntry(entry),
                          icon: const Icon(Icons.refresh_rounded, color: AppColors.warning),
                        ),
                      IconButton(
                        key: Key('vault_delete_${entry.id}'),
                        tooltip: tr('btn_delete'),
                        onPressed: () => widget.onDeleteEntry(entry),
                        icon: const Icon(Icons.delete_outline_rounded, color: AppColors.textSecondary),
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
