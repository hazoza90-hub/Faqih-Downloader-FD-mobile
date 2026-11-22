import 'package:flutter/material.dart';

import '../../core/i18n/translator.dart';
import '../../core/utils/size_formatter.dart';
import '../../services/updater/github_release_updater.dart';

/// Displays an interactive GitHub APK release update dialog with mounted guards and error handling.
Future<void> showReleaseUpdateDialog({
  required BuildContext context,
  required AppTranslator translator,
  required GitHubReleaseUpdater updater,
  required ReleaseUpdateInfo info,
}) async {
  final tr = translator.tr;
  final messenger = ScaffoldMessenger.maybeOf(context);
  double? downloadProgress;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: Text(
          tr(
            'updater_available_title',
            params: <String, String>{'ver': info.latestVersion},
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              tr('updater_changelog'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              info.releaseNotes.isEmpty ? '-' : info.releaseNotes,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            ),
            if (info.apkSizeBytes > 0) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '${info.apkName} • ${formatFileSize(info.apkSizeBytes)}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
            if (downloadProgress != null) ...<Widget>[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: downloadProgress),
              const SizedBox(height: 4),
              Text(
                tr(
                  'updater_downloading',
                  params: <String, String>{
                    'pct': '${(downloadProgress! * 100).round()}',
                  },
                ),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(tr('btn_close')),
          ),
          ElevatedButton(
            key: const Key('updater_install_button'),
            onPressed: info.apkUrl.isEmpty || downloadProgress != null
                ? null
                : () async {
                    setDialogState(() => downloadProgress = 0.0);
                    try {
                      await updater.downloadAndInstallUpdate(
                        info,
                        onProgress: (p) {
                          if (ctx.mounted) {
                            setDialogState(() => downloadProgress = p);
                          }
                        },
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    } catch (e) {
                      if (ctx.mounted) {
                        setDialogState(() => downloadProgress = null);
                      }
                      messenger?.showSnackBar(
                        SnackBar(
                          content: Text(
                            tr('updater_failed', params: <String, String>{'err': '$e'}),
                          ),
                        ),
                      );
                    }
                  },
            child: Text(tr('btn_install_update')),
          ),
        ],
      ),
    ),
  );
}
