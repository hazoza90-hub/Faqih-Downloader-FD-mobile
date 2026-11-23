import 'package:flutter/material.dart';

import '../../core/i18n/translator.dart';
import '../../core/theme/app_colors.dart';

/// Responsive 3-column Kanban board matching desktop `panel.py` (Staged | Active | Vault).
class KanbanBoardView extends StatefulWidget {
  const KanbanBoardView({
    super.key,
    required this.translator,
    required this.selectedColumn,
    required this.onSelectColumn,
    required this.stagedCount,
    required this.activeCount,
    required this.vaultCount,
    required this.stagedChild,
    required this.activeChild,
    required this.vaultChild,
  });

  final AppTranslator translator;
  final int selectedColumn;
  final ValueChanged<int> onSelectColumn;
  final int stagedCount;
  final int activeCount;
  final int vaultCount;
  final Widget stagedChild;
  final Widget activeChild;
  final Widget vaultChild;

  @override
  State<KanbanBoardView> createState() => _KanbanBoardViewState();
}

class _KanbanBoardViewState extends State<KanbanBoardView> {
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      viewportFraction: 0.88,
      initialPage: widget.selectedColumn.clamp(0, 2),
    );
  }

  @override
  void didUpdateWidget(covariant KanbanBoardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedColumn != widget.selectedColumn &&
        _pageController.hasClients) {
      final target = widget.selectedColumn.clamp(0, 2);
      if ((_pageController.page?.round() ?? -1) != target) {
        _pageController.animateToPage(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.translator.tr;
    final cols = <_KanbanColSpec>[
      _KanbanColSpec(
        index: 0,
        tabKey: const Key('tab_staged'),
        shortLabel: tr('tab_staged'),
        fullLabel: tr('kanban_col_staged'),
        count: widget.stagedCount,
        icon: Icons.inventory_2_outlined,
        accent: AppColors.accent,
        flex: 30,
        child: widget.stagedChild,
      ),
      _KanbanColSpec(
        index: 1,
        tabKey: const Key('tab_active'),
        shortLabel: tr('tab_active'),
        fullLabel: tr('kanban_col_active'),
        count: widget.activeCount,
        icon: Icons.bolt_rounded,
        accent: AppColors.warning,
        flex: 40,
        child: widget.activeChild,
      ),
      _KanbanColSpec(
        index: 2,
        tabKey: const Key('tab_vault'),
        shortLabel: tr('tab_vault'),
        fullLabel: tr('kanban_col_vault'),
        count: widget.vaultCount,
        icon: Icons.folder_zip_outlined,
        accent: AppColors.success,
        flex: 30,
        child: widget.vaultChild,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 760) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (var i = 0; i < cols.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    flex: cols[i].flex,
                    child: _KanbanColumnCard(
                      spec: cols[i],
                      selected: widget.selectedColumn == i,
                      titleText: cols[i].shortLabel,
                      headerKey: cols[i].tabKey,
                      onHeaderTap: () => widget.onSelectColumn(i),
                    ),
                  ),
                ],
              ],
            ),
          );
        }

        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: Row(
                children: <Widget>[
                  for (var i = 0; i < cols.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(
                      child: _KanbanJumpChip(
                        spec: cols[i],
                        selected: widget.selectedColumn == i,
                        onTap: () => _jumpToColumn(i),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                key: const Key('kanban_portrait_pageview'),
                controller: _pageController,
                itemCount: cols.length,
                onPageChanged: widget.onSelectColumn,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                  child: _KanbanColumnCard(
                    spec: cols[i],
                    selected: widget.selectedColumn == i,
                    titleText: cols[i].fullLabel,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _jumpToColumn(int index) {
    widget.onSelectColumn(index);
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }
}

class _KanbanColSpec {
  const _KanbanColSpec({
    required this.index,
    required this.tabKey,
    required this.shortLabel,
    required this.fullLabel,
    required this.count,
    required this.icon,
    required this.accent,
    required this.flex,
    required this.child,
  });

  final int index;
  final Key tabKey;
  final String shortLabel;
  final String fullLabel;
  final int count;
  final IconData icon;
  final Color accent;
  final int flex;
  final Widget child;
}

class _KanbanJumpChip extends StatelessWidget {
  const _KanbanJumpChip({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  final _KanbanColSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = selected
        ? spec.accent.withValues(alpha: 0.16)
        : (Theme.of(context).cardTheme.color ?? AppColors.bgCard);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: spec.tabKey,
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? spec.accent.withValues(alpha: 0.7)
                  : Theme.of(context).dividerColor,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(spec.icon, size: 15, color: spec.accent),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  spec.shortLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: spec.accent.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${spec.count}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: spec.accent,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KanbanColumnCard extends StatelessWidget {
  const _KanbanColumnCard({
    required this.spec,
    required this.selected,
    required this.titleText,
    this.headerKey,
    this.onHeaderTap,
  });

  final _KanbanColSpec spec;
  final bool selected;
  final String titleText;
  final Key? headerKey;
  final VoidCallback? onHeaderTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected
        ? spec.accent.withValues(alpha: 0.6)
        : Theme.of(context).dividerColor;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color?.withValues(alpha: 0.5) ??
            AppColors.bgCard.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: selected ? 1.4 : 1.0),
      ),
      child: Column(
        children: <Widget>[
          InkWell(
            key: headerKey,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(13)),
            onTap: onHeaderTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: spec.accent.withValues(alpha: 0.09),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(13)),
                border: Border(
                  bottom: BorderSide(color: spec.accent.withValues(alpha: 0.25)),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Icon(spec.icon, size: 17, color: spec.accent),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      titleText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: spec.accent.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${spec.count}',
                      style: TextStyle(
                        color: spec.accent,
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: spec.child),
        ],
      ),
    );
  }
}
