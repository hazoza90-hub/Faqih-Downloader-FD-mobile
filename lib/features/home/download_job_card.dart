import 'package:flutter/material.dart';

import '../../core/i18n/translator.dart';
import '../../core/models/download_status.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/size_formatter.dart';
import '../../services/coordinator/download_job_models.dart';
import 'phase_label_helper.dart';

/// Progress card displaying live download phase, speed, ETA, size, and controls.
class DownloadJobCard extends StatelessWidget {
  const DownloadJobCard({
    super.key,
    required this.job,
    required this.translator,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
  });

  final DownloadJobState job;
  final AppTranslator translator;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tr = translator.tr;
    final badgeColor = PhaseLabelHelper.phaseColor(job.phase);
    final pct = (job.progress.clamp(0.0, 1.0) * 100).round();
    final isPaused = job.status == DownloadStatus.paused;
    final indeterminate = job.phase == DownloadPhase.probing ||
        (job.progress <= 0 && job.totalBytes <= 0 && !isPaused);

    return Card(
      key: Key('job_card_${job.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    job.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: badgeColor.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    tr(PhaseLabelHelper.phaseKey(job.phase)),
                    style: TextStyle(
                      color: badgeColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: indeterminate ? null : job.progress.clamp(0.0, 1.0),
                color: badgeColor,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    children: <Widget>[
                      Text(
                        '$pct%',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        job.totalBytes > 0
                            ? '${formatFileSize(job.downloadedBytes)} / ${formatFileSize(job.totalBytes)}'
                            : formatFileSize(job.downloadedBytes),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      Text(
                        formatSpeed(job.speedBytesPerSec),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.accent,
                        ),
                      ),
                      if (job.etaSeconds > 0)
                        Text(
                          formatEta(job.etaSeconds),
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
                if (!job.status.isTerminal) ...<Widget>[
                  IconButton(
                    key: Key(isPaused ? 'job_resume_${job.id}' : 'job_pause_${job.id}'),
                    tooltip: isPaused ? tr('btn_resume') : tr('btn_pause'),
                    onPressed: isPaused ? onResume : onPause,
                    icon: Icon(
                      isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                      color: isPaused ? AppColors.success : AppColors.warning,
                    ),
                  ),
                  IconButton(
                    key: Key('job_cancel_${job.id}'),
                    tooltip: tr('btn_cancel'),
                    onPressed: onCancel,
                    icon: const Icon(Icons.close_rounded, color: AppColors.danger),
                  ),
                ],
              ],
            ),
            if (job.errorMessage != null &&
                job.errorMessage!.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                job.errorMessage!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AppColors.danger),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
