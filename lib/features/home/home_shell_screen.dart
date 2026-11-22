import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/i18n/translator.dart';
import '../../core/models/history_entry.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/url_detector.dart';
import '../../services/coordinator/download_job_models.dart';
import '../../services/history/history_manager.dart';
import '../media_sheet/media_options_sheet.dart';
import '../settings/cookies_login_screen.dart';
import '../settings/settings_screen.dart';
import 'active_tab.dart';
import 'staged_tab.dart';
import 'url_input_bar.dart';
import 'vault_tab.dart';

/// Main 3-tab Kanban mobile shell wired to [AppController], media sheet, and settings.
class HomeShellScreen extends StatefulWidget {
  const HomeShellScreen({
    super.key,
    required this.translator,
    this.controller,
    this.onUrlSubmitted,
  });

  final AppTranslator translator;
  final AppController? controller;
  final void Function(String url)? onUrlSubmitted;

  @override
  State<HomeShellScreen> createState() => _HomeShellScreenState();
}

class _HomeShellScreenState extends State<HomeShellScreen> {
  final TextEditingController _urlController = TextEditingController();
  final List<String> _fallbackStagedUrls = <String>[];
  int _selectedTabIndex = 0;
  StreamSubscription<String>? _shareSub;

  @override
  void initState() {
    super.initState();
    _shareSub = widget.controller?.sharedUrlsStream.listen((url) {
      if (!mounted) return;
      _urlController.text = url;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.translator.tr('msg_shared_url_received', params: <String, String>{'url': url}),
          ),
        ),
      );
      unawaited(_analyzeAndRoute(url));
    });
  }

  @override
  void dispose() {
    unawaited(_shareSub?.cancel());
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    final tr = widget.translator.tr;
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('msg_clipboard_empty'))));
      return;
    }
    _urlController.text = text;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('msg_pasted'))));
  }

  Future<void> _handleSubmitUrl() async {
    final url = _urlController.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    final tr = widget.translator.tr;
    messenger.hideCurrentSnackBar();

    if (!isHttpUrl(url)) {
      messenger.showSnackBar(SnackBar(content: Text(tr('msg_invalid_url'))));
      return;
    }

    _urlController.clear();
    widget.onUrlSubmitted?.call(url);

    if (widget.controller == null) {
      setState(() => _fallbackStagedUrls.insert(0, url));
      messenger.showSnackBar(
        SnackBar(content: Text(tr('msg_url_queued', params: <String, String>{'url': url}))),
      );
      return;
    }

    await _analyzeAndRoute(url);
  }

  Future<void> _analyzeAndRoute(String url) async {
    final ctrl = widget.controller;
    if (ctrl == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final tr = widget.translator.tr;

    try {
      final result = await ctrl.analyzeUrl(url);
      if (!mounted) return;
      if (result.isMedia && result.mediaInfo != null) {
        final sheetResult = await showModalBottomSheet<MediaSheetResult>(
          context: context,
          isScrollControlled: true,
          builder: (_) => MediaOptionsSheet(
            streamInfo: result.mediaInfo!,
            translator: widget.translator,
          ),
        );
        if (!mounted || sheetResult == null) return;
        if (sheetResult.action == MediaSheetAction.startDownload && sheetResult.request != null) {
          ctrl.enqueueMediaJob(sheetResult.request!);
          setState(() => _selectedTabIndex = 1);
        } else if (sheetResult.action == MediaSheetAction.stageForLater) {
          ctrl.stageUrl(sheetResult.url);
          setState(() => _selectedTabIndex = 0);
        }
        return;
      }

      ctrl.enqueueDirectDownload(url);
      setState(() => _selectedTabIndex = 1);
      messenger.showSnackBar(
        SnackBar(content: Text(tr('msg_url_queued', params: <String, String>{'url': url}))),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(tr('msg_extraction_failed', params: <String, String>{'err': '$e'}))),
      );
    }
  }

  void _openSettings() {
    final ctrl = widget.controller;
    if (ctrl == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(translator: widget.translator, controller: ctrl),
      ),
    );
  }

  void _openCookies() {
    final ctrl = widget.controller;
    if (ctrl == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CookiesLoginScreen(translator: widget.translator, controller: ctrl),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final listenable = ctrl == null
        ? widget.translator
        : Listenable.merge(<Listenable>[widget.translator, ctrl]);

    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final tr = widget.translator.tr;
        final staged = ctrl?.stagedUrls ?? _fallbackStagedUrls;
        final queue = ctrl?.queueManager;
        final activeJobs = <DownloadJobState>[
          if (queue != null) ...queue.queuedJobs,
          if (queue != null) ...queue.activeJobs,
        ];
        final vaultEntries =
            ctrl?.historyManager?.query(bucket: KanbanBucket.vault) ?? const <HistoryEntry>[];

        return Scaffold(
          appBar: AppBar(
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
                    unawaited(widget.translator.toggleLanguage());
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
                  onPressed: _openCookies,
                  icon: Icon(
                    Icons.cookie_outlined,
                    color: ctrl.settings.cookiesFilePath.isNotEmpty
                        ? AppColors.success
                        : null,
                  ),
                ),
                IconButton(
                  key: const Key('open_settings_button'),
                  tooltip: tr('btn_settings'),
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ],
          ),
          body: Column(
            children: <Widget>[
              UrlInputBar(
                controller: _urlController,
                translator: widget.translator,
                isExtracting: ctrl?.isExtracting ?? false,
                onPaste: _pasteFromClipboard,
                onSubmit: _handleSubmitUrl,
                onCancelExtract: () => unawaited(ctrl?.cancelActiveExtraction()),
              ),
              Expanded(
                child: IndexedStack(
                  index: _selectedTabIndex,
                  children: <Widget>[
                    StagedTab(
                      translator: widget.translator,
                      stagedUrls: staged,
                      onAnalyzeUrl: _analyzeAndRoute,
                      onStartUrl: (u) {
                        ctrl?.enqueueDirectDownload(u);
                        setState(() => _selectedTabIndex = 1);
                      },
                      onRemoveUrl: (u) {
                        if (ctrl != null) {
                          ctrl.removeStagedUrl(u);
                        } else {
                          setState(() => _fallbackStagedUrls.remove(u));
                        }
                      },
                      onStartAll: () {
                        unawaited(ctrl?.startAllStaged());
                        setState(() => _selectedTabIndex = 1);
                      },
                    ),
                    ActiveTab(
                      translator: widget.translator,
                      jobs: activeJobs,
                      onPauseJob: (id) => unawaited(queue?.pause(id)),
                      onResumeJob: (id) => unawaited(queue?.resume(id)),
                      onCancelJob: (id) => unawaited(queue?.cancel(id)),
                      onPauseAll: () => unawaited(queue?.pauseAll()),
                      onCancelAll: () => unawaited(queue?.cancelAll()),
                    ),
                    VaultTab(
                      translator: widget.translator,
                      entries: vaultEntries,
                      onOpenEntry: (e) async {
                        final messenger = ScaffoldMessenger.of(context);
                        final ok = await ctrl?.openVaultEntry(e) ?? false;
                        if (!mounted) return;
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              ok
                                  ? tr('msg_file_opened')
                                  : tr('msg_open_failed', params: const <String, String>{'err': ''}),
                            ),
                          ),
                        );
                      },
                      onRetryEntry: (e) => unawaited(_analyzeAndRoute(e.url)),
                      onDeleteEntry: (e) => unawaited(ctrl?.removeHistoryEntry(e.id)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _selectedTabIndex,
            onDestinationSelected: (i) => setState(() => _selectedTabIndex = i),
            destinations: <NavigationDestination>[
              NavigationDestination(
                key: const Key('tab_staged'),
                icon: Badge(
                  isLabelVisible: staged.isNotEmpty,
                  label: Text('${staged.length}'),
                  child: const Icon(Icons.inventory_2_outlined),
                ),
                label: tr('tab_staged'),
              ),
              NavigationDestination(
                key: const Key('tab_active'),
                icon: Badge(
                  isLabelVisible: activeJobs.isNotEmpty,
                  label: Text('${activeJobs.length}'),
                  child: const Icon(Icons.bolt_rounded),
                ),
                label: tr('tab_active'),
              ),
              NavigationDestination(
                key: const Key('tab_vault'),
                icon: Badge(
                  isLabelVisible: vaultEntries.isNotEmpty,
                  label: Text('${vaultEntries.length}'),
                  child: const Icon(Icons.folder_zip_outlined),
                ),
                label: tr('tab_vault'),
              ),
            ],
          ),
        );
      },
    );
  }
}
