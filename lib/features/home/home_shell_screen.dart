import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/i18n/translator.dart';
import '../../core/models/history_entry.dart';
import '../../core/utils/url_detector.dart';
import '../../services/clipboard/clipboard_sniffer_service.dart';
import '../../services/coordinator/download_job_models.dart';
import '../../services/history/history_manager.dart';
import '../media_sheet/media_options_sheet.dart';
import '../media_sheet/playlist_picker_sheet.dart';
import '../settings/cookies_login_screen.dart';
import '../settings/settings_screen.dart';
import 'active_tab.dart';
import 'clipboard_banner.dart';
import 'home_app_bar.dart';
import 'staged_tab.dart';
import 'url_input_bar.dart';
import 'vault_tab.dart';

/// Main 3-tab Kanban mobile shell wired to [AppController], clipboard sniffer, media sheets, and settings.
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
  ClipboardSnifferService? _sniffer;
  String? _snifferBannerUrl;

  @override
  void initState() {
    super.initState();
    final ctrl = widget.controller;
    if (ctrl != null) {
      unawaited(ctrl.requestNotificationPermissionOnce());
      _shareSub = ctrl.sharedUrlsStream.listen((url) {
        if (!mounted) return;
        _urlController.text = url;
        _sniffer?.markSeen(url);
        _showSnack(ScaffoldMessenger.of(context), widget.translator.tr('msg_shared_url_received', params: <String, String>{'url': url}));
        unawaited(_analyzeAndRoute(url));
      });
      _sniffer = ClipboardSnifferService(
        settingsProvider: () => ctrl.settings,
        onUrlDetected: _handleClipboardDetected,
      )..start(checkImmediately: true);
    }
  }

  @override
  void dispose() {
    _sniffer?.dispose();
    unawaited(_shareSub?.cancel());
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _handleClipboardDetected(String url) async {
    if (!mounted) return;
    final ctrl = widget.controller;
    if (ctrl != null && ctrl.settings.clipboardAutoAnalyze) {
      setState(() => _snifferBannerUrl = null);
      await _analyzeAndRoute(url);
      return;
    }
    setState(() => _snifferBannerUrl = url);
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    final tr = widget.translator.tr;
    final messenger = ScaffoldMessenger.of(context);
    if (text.isEmpty) {
      _showSnack(messenger, tr('msg_clipboard_empty'));
      return;
    }
    final urls = UrlDetector.extractUrls(text);
    if (urls.length > 1) {
      _stageMultipleUrls(urls);
      return;
    }
    _urlController.text = text;
    if (urls.length == 1) _sniffer?.markSeen(urls.first);
    _showSnack(messenger, tr('msg_pasted'));
  }

  void _stageMultipleUrls(List<String> urls) {
    for (final u in urls) {
      _sniffer?.markSeen(u);
    }
    final ctrl = widget.controller;
    final added = ctrl != null ? ctrl.stageUrls(urls) : _stageFallbackUrls(urls);
    _urlController.clear();
    setState(() {
      _snifferBannerUrl = null;
      _selectedTabIndex = 0;
    });
    _showSnack(
      ScaffoldMessenger.of(context),
      widget.translator.tr('msg_multi_urls_staged', params: <String, String>{'count': '${added > 0 ? added : urls.length}'}),
    );
  }

  int _stageFallbackUrls(List<String> urls) {
    var count = 0;
    for (final u in urls) {
      if (!_fallbackStagedUrls.contains(u)) {
        _fallbackStagedUrls.insert(0, u);
        count++;
      }
    }
    return count;
  }

  Future<void> _handleSubmitUrl() async {
    final rawText = _urlController.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    final tr = widget.translator.tr;
    messenger.hideCurrentSnackBar();

    final multi = UrlDetector.extractUrls(rawText);
    if (multi.length > 1) {
      _stageMultipleUrls(multi);
      return;
    }
    final url = multi.isNotEmpty ? multi.first : rawText;
    if (!isHttpUrl(url)) {
      messenger.showSnackBar(SnackBar(content: Text(tr('msg_invalid_url'))));
      return;
    }

    _sniffer?.markSeen(url);
    _urlController.clear();
    widget.onUrlSubmitted?.call(url);

    if (widget.controller == null) {
      setState(() => _fallbackStagedUrls.insert(0, url));
      messenger.showSnackBar(SnackBar(content: Text(tr('msg_url_queued', params: <String, String>{'url': url}))));
      return;
    }
    await _analyzeAndRoute(url);
  }

  void _showSnack(ScaffoldMessengerState messenger, String msg) =>
      messenger.showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _analyzeAndRoute(String url) async {
    final ctrl = widget.controller;
    if (ctrl == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final tr = widget.translator.tr;

    try {
      final result = await ctrl.analyzeUrl(url);
      if (!mounted) return;
      if (result.isMedia && result.mediaInfo != null) {
        final info = result.mediaInfo!;
        if (info.isPlaylist && info.playlistEntries.isNotEmpty) {
          final pick = await showModalBottomSheet<PlaylistPickerResult>(
            context: context,
            isScrollControlled: true,
            builder: (_) => PlaylistPickerSheet(playlistInfo: info, translator: widget.translator),
          );
          if (!mounted || pick == null || pick.selectedItems.isEmpty) return;
          if (pick.action == PlaylistSheetAction.stageSelected) {
            ctrl.stageUrls(pick.selectedUrls);
            setState(() => _selectedTabIndex = 0);
            _showSnack(messenger, tr('msg_playlist_staged', params: <String, String>{'count': '${pick.selectedUrls.length}'}));
          } else {
            for (final item in pick.selectedItems) {
              final u = item.webpageUrl.isNotEmpty ? item.webpageUrl : item.videoUrl;
              if (u.isNotEmpty) {
                ctrl.enqueueSmartDownload(u, customTitle: item.title, durationSec: item.durationSec);
              }
            }
            setState(() => _selectedTabIndex = 1);
            _showSnack(messenger, tr('msg_playlist_queued', params: <String, String>{'count': '${pick.selectedItems.length}'}));
          }
          return;
        }
        final sheetResult = await showModalBottomSheet<MediaSheetResult>(
          context: context,
          isScrollControlled: true,
          builder: (_) => MediaOptionsSheet(
            streamInfo: info,
            translator: widget.translator,
            settings: ctrl.settings,
            onPickExternalSubtitle: ctrl.pickExternalSubtitleFile,
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
      messenger.showSnackBar(SnackBar(content: Text(tr('msg_url_queued', params: <String, String>{'url': url}))));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(tr('msg_extraction_failed', params: <String, String>{'err': '$e'}))));
    }
  }

  void _openSettings() {
    final ctrl = widget.controller;
    if (ctrl == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SettingsScreen(translator: widget.translator, controller: ctrl)),
    );
  }

  void _openCookies() {
    final ctrl = widget.controller;
    if (ctrl == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => CookiesLoginScreen(translator: widget.translator, controller: ctrl)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final listenable = ctrl == null ? widget.translator : Listenable.merge(<Listenable>[widget.translator, ctrl]);

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
        final vaultEntries = ctrl?.historyManager?.query(bucket: KanbanBucket.vault) ?? const <HistoryEntry>[];

        return Scaffold(
          appBar: HomeAppBar(
            translator: widget.translator,
            controller: ctrl,
            onOpenCookies: _openCookies,
            onOpenSettings: _openSettings,
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
              if (_snifferBannerUrl != null)
                ClipboardSnifferBanner(
                  translator: widget.translator,
                  detectedUrl: _snifferBannerUrl!,
                  onAnalyze: () {
                    final u = _snifferBannerUrl!;
                    setState(() => _snifferBannerUrl = null);
                    unawaited(_analyzeAndRoute(u));
                  },
                  onStage: () {
                    final u = _snifferBannerUrl!;
                    ctrl?.stageUrl(u);
                    setState(() {
                      _snifferBannerUrl = null;
                      _selectedTabIndex = 0;
                    });
                  },
                  onDismiss: () => setState(() => _snifferBannerUrl = null),
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
                        ctrl?.enqueueSmartDownload(u);
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
                        try {
                          final ok = await ctrl?.openVaultEntry(e) ?? false;
                          if (!mounted) return;
                          _showSnack(messenger, ok ? tr('msg_file_opened') : tr('msg_open_failed', params: const <String, String>{'err': ''}));
                        } catch (err) {
                          if (!mounted) return;
                          _showSnack(messenger, tr('msg_open_failed', params: <String, String>{'err': '$err'}));
                        }
                      },
                      onShareEntry: (e) async {
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          final ok = await ctrl?.shareVaultEntry(e) ?? false;
                          if (!ok && mounted) {
                            _showSnack(messenger, tr('msg_share_failed', params: const <String, String>{'err': ''}));
                          }
                        } catch (err) {
                          if (!mounted) return;
                          _showSnack(messenger, tr('msg_share_failed', params: <String, String>{'err': '$err'}));
                        }
                      },
                      onRetryEntry: (e) => unawaited(_analyzeAndRoute(e.url)),
                      onDeleteEntry: (e, {required deleteFile}) =>
                          unawaited(ctrl?.deleteVaultEntry(e, deleteFile: deleteFile)),
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
                icon: Badge(isLabelVisible: staged.isNotEmpty, label: Text('${staged.length}'), child: const Icon(Icons.inventory_2_outlined)),
                label: tr('tab_staged'),
              ),
              NavigationDestination(
                key: const Key('tab_active'),
                icon: Badge(isLabelVisible: activeJobs.isNotEmpty, label: Text('${activeJobs.length}'), child: const Icon(Icons.bolt_rounded)),
                label: tr('tab_active'),
              ),
              NavigationDestination(
                key: const Key('tab_vault'),
                icon: Badge(isLabelVisible: vaultEntries.isNotEmpty, label: Text('${vaultEntries.length}'), child: const Icon(Icons.folder_zip_outlined)),
                label: tr('tab_vault'),
              ),
            ],
          ),
        );
      },
    );
  }
}
