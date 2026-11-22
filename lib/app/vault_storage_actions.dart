import 'package:path/path.dart' as p;

import '../core/config/app_settings.dart';
import '../core/models/history_entry.dart';
import '../core/models/subtitle_track.dart';
import '../platform/media_store_channel.dart';
import '../services/coordinator/job_export_helper.dart';
import '../services/history/history_manager.dart';

/// Encapsulates vault open/share/delete, SAF directory selection, external subtitles, and notif permission.
class VaultStorageActions {
  VaultStorageActions({
    required MediaStoreChannel mediaStore,
    required DownloadHistoryManager? Function() historyProvider,
    required AppSettings Function() settingsProvider,
    required Future<void> Function(AppSettings next) saveSettings,
  })  : _mediaStore = mediaStore,
        _historyProvider = historyProvider,
        _settingsProvider = settingsProvider,
        _saveSettings = saveSettings;

  final MediaStoreChannel _mediaStore;
  final DownloadHistoryManager? Function() _historyProvider;
  final AppSettings Function() _settingsProvider;
  final Future<void> Function(AppSettings next) _saveSettings;
  bool _notifRequested = false;

  String resolveTarget(HistoryEntry entry) =>
      (entry.contentUri != null && entry.contentUri!.trim().isNotEmpty)
          ? entry.contentUri!
          : entry.filePath;

  String resolveMime(HistoryEntry entry) => CoordinatorHelpers.mimeTypeForExt(
        p.extension(entry.filename).replaceFirst('.', ''),
      );

  Future<bool> openEntry(HistoryEntry entry) =>
      _mediaStore.openFile(pathOrUri: resolveTarget(entry), mimeType: resolveMime(entry));

  Future<bool> shareEntry(HistoryEntry entry) =>
      _mediaStore.shareFile(pathOrUri: resolveTarget(entry), mimeType: resolveMime(entry));

  Future<void> deleteEntry(HistoryEntry entry, {required bool deleteFile}) async {
    if (deleteFile) {
      await _mediaStore.deleteExportedFile(pathOrUri: resolveTarget(entry));
    }
    await _historyProvider()?.remove(entry.id, deleteFile: deleteFile);
  }

  Future<bool> pickCustomSaveDirectory() async {
    final picked = await _mediaStore.pickSaveDirectory();
    if (picked == null) return false;
    await _saveSettings(
      _settingsProvider().copyWith(
        customSaveTreeUri: picked.treeUri,
        customSaveDisplayLabel: picked.displayName,
      ),
    );
    return true;
  }

  Future<void> resetSaveDirectory() => _saveSettings(
        _settingsProvider().copyWith(customSaveTreeUri: '', customSaveDisplayLabel: ''),
      );

  Future<SubtitleTrack?> pickExternalSubtitleFile() async {
    final picked = await _mediaStore.pickSubtitleFile();
    if (picked == null) return null;
    final ext = p.extension(picked.name).replaceFirst('.', '').toLowerCase();
    final lang = picked.name.toLowerCase().contains('ar') ? 'ar' : 'ext';
    return SubtitleTrack(
      subId: 'ext_${DateTime.now().millisecondsSinceEpoch}',
      language: lang,
      label: picked.name,
      url: picked.path,
      ext: ext == 'vtt' ? 'vtt' : 'srt',
      isExternal: true,
      localPath: picked.path,
    );
  }

  Future<void> requestNotificationPermissionOnce() async {
    if (_notifRequested) return;
    _notifRequested = true;
    await _mediaStore.requestNotificationPermission();
  }
}
