import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/i18n/translator.dart';
import '../../core/models/history_entry.dart';
import '../media_sheet/media_options_sheet.dart';
import '../media_sheet/playlist_picker_sheet.dart';

/// Analyzes an incoming URL and routes playlists, media, or resolved direct downloads to the board.
Future<void> analyzeAndRouteUrl({
  required BuildContext context,
  required bool Function() isMounted,
  required AppController controller,
  required AppTranslator translator,
  required String url,
  required void Function(int columnIndex) onSelectColumn,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final tr = translator.tr;

  try {
    final result = await controller.analyzeUrl(url);
    if (!isMounted()) return;
    if (result.isMedia && result.mediaInfo != null) {
      final info = result.mediaInfo!;
      if (info.isPlaylist && info.playlistEntries.isNotEmpty) {
        if (!context.mounted) return;
        final pick = await showModalBottomSheet<PlaylistPickerResult>(
          context: context,
          isScrollControlled: true,
          builder: (_) =>
              PlaylistPickerSheet(playlistInfo: info, translator: translator),
        );
        if (!isMounted() || pick == null || pick.selectedItems.isEmpty) return;
        if (pick.action == PlaylistSheetAction.stageSelected) {
          controller.stageUrls(pick.selectedUrls);
          onSelectColumn(0);
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                tr('msg_playlist_staged',
                    params: <String, String>{'count': '${pick.selectedUrls.length}'}),
              ),
            ),
          );
        } else {
          for (final item in pick.selectedItems) {
            final u = item.webpageUrl.isNotEmpty ? item.webpageUrl : item.videoUrl;
            if (u.isNotEmpty) {
              controller.enqueueSmartDownload(
                u,
                customTitle: item.title,
                durationSec: item.durationSec,
              );
            }
          }
          onSelectColumn(1);
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                tr('msg_playlist_queued',
                    params: <String, String>{'count': '${pick.selectedItems.length}'}),
              ),
            ),
          );
        }
        return;
      }

      if (!context.mounted) return;
      final sheetResult = await showModalBottomSheet<MediaSheetResult>(
        context: context,
        isScrollControlled: true,
        builder: (_) => MediaOptionsSheet(
          streamInfo: info,
          translator: translator,
          settings: controller.settings,
          onPickExternalSubtitle: controller.pickExternalSubtitleFile,
        ),
      );
      if (!isMounted() || sheetResult == null) return;
      if (sheetResult.action == MediaSheetAction.startDownload &&
          sheetResult.request != null) {
        controller.enqueueMediaJob(sheetResult.request!);
        onSelectColumn(1);
      } else if (sheetResult.action == MediaSheetAction.stageForLater) {
        controller.stageUrl(sheetResult.url);
        onSelectColumn(0);
      }
      return;
    }

    controller.enqueueDirectDownload(
      result.url,
      customTitle: result.resolvedFilename,
      headers: result.resolvedHeaders,
    );
    onSelectColumn(1);
    messenger.showSnackBar(
      SnackBar(
        content: Text(tr('msg_url_queued', params: <String, String>{'url': result.url})),
      ),
    );
  } catch (e) {
    if (!isMounted()) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(tr('msg_extraction_failed', params: <String, String>{'err': '$e'})),
      ),
    );
  }
}

/// Opens a vault file with native Intent/MediaStore handling and shows localized feedback.
Future<void> handleOpenVaultEntry({
  required BuildContext context,
  required bool Function() isMounted,
  required AppController? controller,
  required AppTranslator translator,
  required HistoryEntry entry,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final tr = translator.tr;
  try {
    final ok = await controller?.openVaultEntry(entry) ?? false;
    if (!isMounted()) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? tr('msg_file_opened')
              : tr('msg_open_failed', params: const <String, String>{'err': ''}),
        ),
      ),
    );
  } catch (err) {
    if (!isMounted()) return;
    messenger.showSnackBar(
      SnackBar(content: Text(tr('msg_open_failed', params: <String, String>{'err': '$err'}))),
    );
  }
}

/// Shares a vault file with native Share sheet and surfaces failure if needed.
Future<void> handleShareVaultEntry({
  required BuildContext context,
  required bool Function() isMounted,
  required AppController? controller,
  required AppTranslator translator,
  required HistoryEntry entry,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final tr = translator.tr;
  try {
    final ok = await controller?.shareVaultEntry(entry) ?? false;
    if (!ok && isMounted()) {
      messenger.showSnackBar(
        SnackBar(content: Text(tr('msg_share_failed', params: const <String, String>{'err': ''}))),
      );
    }
  } catch (err) {
    if (!isMounted()) return;
    messenger.showSnackBar(
      SnackBar(content: Text(tr('msg_share_failed', params: <String, String>{'err': '$err'}))),
    );
  }
}
