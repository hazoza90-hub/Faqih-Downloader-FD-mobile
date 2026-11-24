import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/i18n/translator.dart';
import '../../core/models/history_entry.dart';
import '../media_sheet/media_options_sheet.dart';
import '../media_sheet/playlist_picker_sheet.dart';

/// Handles cold-start pending share URLs or serializes notification permission + Quick Tile prompt.
Future<void> consumeInitialShareAndQuickTile({
  required AppController controller,
  required bool Function() isMounted,
  required void Function(String url) onSingleSharedUrl,
  required void Function(List<String> urls) onMultipleSharedUrls,
}) async {
  final pending = controller.consumePendingSharedUrls();
  if (pending.isNotEmpty) {
    if (pending.length == 1) {
      onSingleSharedUrl(pending.first);
    } else {
      onMultipleSharedUrls(pending);
    }
    return;
  }
  await controller.requestNotificationPermissionOnce();
  if (!isMounted()) return;
  if (controller.autoInitNative &&
      controller.settings.quickTileEnabled &&
      !controller.settings.quickTilePrompted) {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!isMounted()) return;
    await controller.promptAddQuickTileOnce();
  }
}

/// Analyzes an incoming URL and routes playlists, media, or resolved direct downloads to the board.
Future<void> analyzeAndRouteUrl({
  required BuildContext context,
  required bool Function() isMounted,
  required AppController controller,
  required AppTranslator translator,
  required String url,
  required void Function(int columnIndex) onSelectColumn,
  bool fromExternalShare = false,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final tr = translator.tr;
  void showImmediateSnack(SnackBar bar) {
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(bar);
  }

  final returnAction = fromExternalShare
      ? SnackBarAction(
          label: tr('btn_return_previous_app'),
          onPressed: () => unawaited(controller.moveAppToBack()),
        )
      : null;

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
          showImmediateSnack(
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
          showImmediateSnack(
            SnackBar(
              content: Text(
                tr('msg_playlist_queued',
                    params: <String, String>{'count': '${pick.selectedItems.length}'}),
              ),
              action: returnAction,
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
        if (returnAction != null) {
          showImmediateSnack(
            SnackBar(
              content: Text(tr('msg_url_queued',
                  params: <String, String>{'url': sheetResult.request!.title})),
              action: returnAction,
            ),
          );
        }
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
    showImmediateSnack(
      SnackBar(
        content: Text(tr('msg_url_queued', params: <String, String>{'url': result.url})),
        action: returnAction,
      ),
    );
  } catch (e) {
    if (!isMounted()) return;
    showImmediateSnack(
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

/// Builds the classic 3-tab bottom navigation bar when layout mode is `tabs`.
Widget buildClassicBottomNavBar({
  required AppTranslator translator,
  required int selectedIndex,
  required ValueChanged<int> onDestinationSelected,
  required int stagedCount,
  required int activeCount,
  required int vaultCount,
}) {
  final tr = translator.tr;
  return NavigationBar(
    selectedIndex: selectedIndex,
    onDestinationSelected: onDestinationSelected,
    destinations: <NavigationDestination>[
      NavigationDestination(
        key: const Key('tab_staged'),
        icon: Badge(
          isLabelVisible: stagedCount > 0,
          label: Text('$stagedCount'),
          child: const Icon(Icons.inventory_2_outlined),
        ),
        label: tr('tab_staged'),
      ),
      NavigationDestination(
        key: const Key('tab_active'),
        icon: Badge(
          isLabelVisible: activeCount > 0,
          label: Text('$activeCount'),
          child: const Icon(Icons.bolt_rounded),
        ),
        label: tr('tab_active'),
      ),
      NavigationDestination(
        key: const Key('tab_vault'),
        icon: Badge(
          isLabelVisible: vaultCount > 0,
          label: Text('$vaultCount'),
          child: const Icon(Icons.folder_zip_outlined),
        ),
        label: tr('tab_vault'),
      ),
    ],
  );
}
