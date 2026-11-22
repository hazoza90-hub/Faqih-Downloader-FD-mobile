import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/app_constants.dart';
import '../../core/i18n/translator.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/size_formatter.dart';
import 'cookies_login_screen.dart';
import 'update_dialog.dart';

/// Application settings screen wiring language, theme, concurrency, cookies, and updaters.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.translator,
    required this.controller,
  });

  final AppTranslator translator;
  final AppController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const List<int> _speedPresets = <int>[
    0,
    500 * 1024,
    1024 * 1024,
    2 * 1024 * 1024,
    5 * 1024 * 1024,
    10 * 1024 * 1024,
  ];

  bool _updatingYtDlp = false;
  bool _checkingAppUpdate = false;

  void _showSnack(ScaffoldMessengerState messenger, String message) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _updateYtDlp() async {
    setState(() => _updatingYtDlp = true);
    final messenger = ScaffoldMessenger.of(context);
    final tr = widget.translator.tr;
    try {
      final res = await widget.controller.updateYtDlpEngine();
      if (!mounted) return;
      final isUpdated = res.status.toUpperCase() == 'DONE';
      _showSnack(
        messenger,
        tr(
          isUpdated ? 'msg_ytdlp_updated' : 'msg_ytdlp_uptodate',
          params: <String, String>{'ver': res.ytdlpVersion},
        ),
      );
    } catch (e) {
      if (mounted) {
        _showSnack(messenger, tr('msg_ytdlp_failed', params: <String, String>{'err': '$e'}));
      }
    } finally {
      if (mounted) setState(() => _updatingYtDlp = false);
    }
  }

  Future<void> _checkAppUpdate() async {
    setState(() => _checkingAppUpdate = true);
    final messenger = ScaffoldMessenger.of(context);
    final tr = widget.translator.tr;
    try {
      final info = await widget.controller.updater.checkForUpdate();
      if (!mounted) return;
      if (!info.hasUpdate) {
        _showSnack(
          messenger,
          tr('updater_up_to_date', params: <String, String>{'ver': info.currentVersion}),
        );
        return;
      }
      await showReleaseUpdateDialog(
        context: context,
        translator: widget.translator,
        updater: widget.controller.updater,
        info: info,
      );
    } catch (e) {
      if (mounted) {
        _showSnack(messenger, tr('updater_failed', params: <String, String>{'err': '$e'}));
      }
    } finally {
      if (mounted) setState(() => _checkingAppUpdate = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final listenable = Listenable.merge(<Listenable>[widget.translator, widget.controller]);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final tr = widget.translator.tr;
        final s = widget.controller.settings;

        return Scaffold(
          appBar: AppBar(title: Text(tr('lbl_settings'))),
          body: ListView(
            padding: const EdgeInsets.all(14),
            children: <Widget>[
              _SectionTitle(tr('settings_general')),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(tr('lbl_language'), style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: <Widget>[
                          ChoiceChip(
                            key: const Key('settings_lang_ar'),
                            label: Text(tr('lbl_lang_ar')),
                            selected: s.language == 'ar',
                            onSelected: (_) => widget.controller.updateSettings(s.copyWith(language: 'ar')),
                          ),
                          ChoiceChip(
                            key: const Key('settings_lang_en'),
                            label: Text(tr('lbl_lang_en')),
                            selected: s.language == 'en',
                            onSelected: (_) => widget.controller.updateSettings(s.copyWith(language: 'en')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(tr('lbl_theme'), style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: <String>['dark', 'light', 'system'].map((mode) {
                          return ChoiceChip(
                            key: Key('settings_theme_$mode'),
                            label: Text(tr('theme_$mode')),
                            selected: s.themeMode == mode,
                            onSelected: (_) => widget.controller.updateSettings(s.copyWith(themeMode: mode)),
                          );
                        }).toList(growable: false),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _SectionTitle(tr('settings_network')),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('${tr('lbl_connections')}: ${s.maxConnections}'),
                      Slider(
                        key: const Key('settings_connections_slider'),
                        min: AppConstants.minConnections.toDouble(),
                        max: AppConstants.maxConnectionsLimit.toDouble(),
                        divisions: AppConstants.maxConnectionsLimit - AppConstants.minConnections,
                        value: s.maxConnections.toDouble(),
                        onChanged: (v) => widget.controller.updateSettings(
                          s.copyWith(maxConnections: v.round()),
                        ),
                      ),
                      Text('${tr('lbl_concurrent_downloads')}: ${s.maxConcurrentDownloads}'),
                      Slider(
                        key: const Key('settings_concurrent_slider'),
                        min: AppConstants.minConcurrentDownloads.toDouble(),
                        max: AppConstants.maxConcurrentDownloadsLimit.toDouble(),
                        divisions: AppConstants.maxConcurrentDownloadsLimit - AppConstants.minConcurrentDownloads,
                        value: s.maxConcurrentDownloads.toDouble(),
                        onChanged: (v) => widget.controller.updateSettings(
                          s.copyWith(maxConcurrentDownloads: v.round()),
                        ),
                      ),
                      Text(tr('lbl_speed_limit'), style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: _speedPresets.map((bytes) {
                          final label = bytes == 0 ? tr('lbl_unlimited') : formatSpeed(bytes.toDouble());
                          return ChoiceChip(
                            key: Key('speed_preset_$bytes'),
                            label: Text(label),
                            selected: s.speedLimitBytesPerSec == bytes,
                            onSelected: (_) => widget.controller.updateSettings(
                              s.copyWith(speedLimitBytesPerSec: bytes),
                            ),
                          );
                        }).toList(growable: false),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr('lbl_wifi_only')),
                        value: s.wifiOnlyDownloads,
                        onChanged: (v) => widget.controller.updateSettings(
                          s.copyWith(wifiOnlyDownloads: v),
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr('lbl_auto_categorize')),
                        value: s.autoCategorizeFolders,
                        onChanged: (v) => widget.controller.updateSettings(
                          s.copyWith(autoCategorizeFolders: v),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _SectionTitle(tr('settings_cookies')),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        s.cookiesFilePath.isNotEmpty ? tr('cookies_active') : tr('cookies_none'),
                        style: TextStyle(
                          color: s.cookiesFilePath.isNotEmpty ? AppColors.success : AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        children: <Widget>[
                          ElevatedButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => CookiesLoginScreen(
                                  translator: widget.translator,
                                  controller: widget.controller,
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.login_rounded, size: 18),
                            label: Text(tr('btn_cookies')),
                          ),
                          if (s.cookiesFilePath.isNotEmpty)
                            OutlinedButton(
                              key: const Key('settings_clear_cookies'),
                              onPressed: () async {
                                final messenger = ScaffoldMessenger.of(context);
                                await widget.controller.clearCookies();
                                if (context.mounted) _showSnack(messenger, tr('msg_cookies_cleared'));
                              },
                              child: Text(tr('btn_clear_cookies')),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _SectionTitle(tr('settings_updates')),
              Card(
                child: Column(
                  children: <Widget>[
                    ListTile(
                      key: const Key('btn_update_ytdlp'),
                      leading: const Icon(Icons.system_update_alt_rounded, color: AppColors.accent),
                      title: Text(tr('btn_update_ytdlp')),
                      subtitle: Text(
                        widget.controller.ytdlpVersion.isNotEmpty
                            ? widget.controller.ytdlpVersion
                            : tr('engine_loading'),
                      ),
                      trailing: _updatingYtDlp
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : null,
                      onTap: _updatingYtDlp ? null : _updateYtDlp,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const Key('btn_check_updates'),
                      leading: const Icon(Icons.new_releases_outlined, color: AppColors.success),
                      title: Text(tr('btn_check_updates')),
                      subtitle: Text(
                        tr('lbl_current_version', params: <String, String>{'ver': AppConstants.appVersion}),
                      ),
                      trailing: _checkingAppUpdate
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : null,
                      onTap: _checkingAppUpdate ? null : _checkAppUpdate,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.accent),
      ),
    );
  }
}
