import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../services/coordinator/download_job_models.dart';

/// Resolves i18n keys and accent colors for [DownloadPhase] and categories.
abstract final class PhaseLabelHelper {
  static const List<String> vaultCategories = <String>[
    'All',
    'Video',
    'Audio',
    'Documents',
    'Compressed',
    'Programs',
    'Images',
    'Other',
  ];

  static String phaseKey(DownloadPhase phase) {
    return switch (phase) {
      DownloadPhase.queued => 'phase_queued',
      DownloadPhase.probing => 'phase_probing',
      DownloadPhase.downloadingDirect => 'phase_downloading_direct',
      DownloadPhase.downloadingVideo => 'phase_downloading_video',
      DownloadPhase.downloadingAudio => 'phase_downloading_audio',
      DownloadPhase.downloadingSubtitle => 'phase_downloading_subtitle',
      DownloadPhase.processingFfmpeg => 'phase_processing_ffmpeg',
      DownloadPhase.exporting => 'phase_exporting',
      DownloadPhase.completed => 'phase_completed',
      DownloadPhase.paused => 'phase_paused',
      DownloadPhase.cancelled => 'phase_cancelled',
      DownloadPhase.failed => 'phase_failed',
    };
  }

  static Color phaseColor(DownloadPhase phase) {
    return switch (phase) {
      DownloadPhase.completed => AppColors.success,
      DownloadPhase.paused => AppColors.warning,
      DownloadPhase.failed || DownloadPhase.cancelled => AppColors.danger,
      DownloadPhase.processingFfmpeg ||
      DownloadPhase.exporting =>
        AppColors.accentDark,
      _ => AppColors.accent,
    };
  }

  static String categoryKey(String category) {
    return switch (category.toLowerCase()) {
      'all' => 'cat_all',
      'video' => 'cat_video',
      'audio' => 'cat_audio',
      'compressed' => 'cat_compressed',
      'documents' => 'cat_documents',
      'programs' => 'cat_programs',
      'images' => 'cat_images',
      _ => 'cat_other',
    };
  }
}
