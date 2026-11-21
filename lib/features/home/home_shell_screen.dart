import 'package:flutter/material.dart';

import '../../core/i18n/translator.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/url_detector.dart';

/// Baseline 3-tab mobile Kanban home screen (Staged / Active / Vault).
class HomeShellScreen extends StatefulWidget {
  const HomeShellScreen({
    super.key,
    required this.translator,
    this.onUrlSubmitted,
  });

  final AppTranslator translator;
  final void Function(String url)? onUrlSubmitted;

  @override
  State<HomeShellScreen> createState() => _HomeShellScreenState();
}

class _HomeShellScreenState extends State<HomeShellScreen> {
  final TextEditingController _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _handleSubmitUrl() {
    final url = _urlController.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();

    if (!isHttpUrl(url)) {
      messenger.showSnackBar(
        SnackBar(content: Text(widget.translator.tr('msg_invalid_url'))),
      );
      return;
    }

    _urlController.clear();
    widget.onUrlSubmitted?.call(url);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          widget.translator.tr('msg_url_queued', params: <String, String>{
            'url': url,
          }),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.translator.tr;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: <Widget>[
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppColors.accent.withValues(alpha: 0.4),
                  ),
                ),
                child: const Icon(
                  Icons.bolt_rounded,
                  color: AppColors.accent,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  tr('app_short_name'),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                  ),
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton.icon(
              key: const Key('lang_toggle_button'),
              onPressed: widget.translator.toggleLanguage,
              icon: const Icon(
                Icons.translate_rounded,
                size: 18,
                color: AppColors.accent,
              ),
              label: Text(
                tr('btn_lang_toggle'),
                style: const TextStyle(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          bottom: TabBar(
            tabs: <Widget>[
              Tab(
                key: const Key('tab_staged'),
                icon: const Icon(Icons.inventory_2_outlined, size: 18),
                text: tr('tab_staged'),
              ),
              Tab(
                key: const Key('tab_active'),
                icon: const Icon(Icons.bolt_rounded, size: 18),
                text: tr('tab_active'),
              ),
              Tab(
                key: const Key('tab_vault'),
                icon: const Icon(Icons.folder_zip_outlined, size: 18),
                text: tr('tab_vault'),
              ),
            ],
          ),
        ),
        body: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          key: const Key('url_input_field'),
                          controller: _urlController,
                          keyboardType: TextInputType.url,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _handleSubmitUrl(),
                          decoration: InputDecoration(
                            hintText: tr('url_input_hint'),
                            prefixIcon: const Icon(
                              Icons.link_rounded,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        key: const Key('url_submit_button'),
                        onPressed: _handleSubmitUrl,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: Text(tr('btn_add')),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: TabBarView(
                children: <Widget>[
                  _KanbanEmptyView(
                    icon: Icons.inbox_outlined,
                    title: tr('empty_staged_title'),
                    subtitle: tr('empty_staged_subtitle'),
                  ),
                  _KanbanEmptyView(
                    icon: Icons.speed_rounded,
                    title: tr('empty_active_title'),
                    subtitle: tr('empty_active_subtitle'),
                  ),
                  _KanbanEmptyView(
                    icon: Icons.verified_outlined,
                    title: tr('empty_vault_title'),
                    subtitle: tr('empty_vault_subtitle'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KanbanEmptyView extends StatelessWidget {
  const _KanbanEmptyView({
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
                color: AppColors.bgCard,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(icon, size: 32, color: AppColors.accent),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
