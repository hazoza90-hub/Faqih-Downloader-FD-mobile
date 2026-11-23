import 'package:flutter/material.dart';

import '../../core/i18n/translator.dart';
import '../../core/theme/app_colors.dart';
import '../../services/coordinator/download_job_models.dart';
import 'download_job_card.dart';

/// Kanban Tab 2: Running, queued, and paused downloads with bulk pause/cancel actions.
class ActiveTab extends StatelessWidget {
  const ActiveTab({
    super.key,
    required this.translator,
    required this.jobs,
    required this.onPauseJob,
    required this.onResumeJob,
    required this.onCancelJob,
    required this.onPauseAll,
    required this.onCancelAll,
  });

  final AppTranslator translator;
  final List<DownloadJobState> jobs;
  final void Function(String id) onPauseJob;
  final void Function(String id) onResumeJob;
  final void Function(String id) onCancelJob;
  final VoidCallback onPauseAll;
  final VoidCallback onCancelAll;

  @override
  Widget build(BuildContext context) {
    final tr = translator.tr;
    if (jobs.isEmpty) {
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
                  color: Theme.of(context).cardTheme.color ?? AppColors.bgCard,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
                child: const Icon(Icons.speed_rounded, size: 32, color: AppColors.accent),
              ),
              const SizedBox(height: 16),
              Text(
                tr('empty_active_title'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                tr('empty_active_subtitle'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: <Widget>[
                Text(
                  '${tr('tab_active')} (${jobs.length})',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Wrap(
                  spacing: 4,
                  children: <Widget>[
                    TextButton.icon(
                      key: const Key('btn_pause_all'),
                      onPressed: onPauseAll,
                      icon: const Icon(Icons.pause_circle_outline_rounded, size: 17),
                      label: Text(tr('btn_pause_all')),
                    ),
                    TextButton.icon(
                      key: const Key('btn_cancel_all'),
                      onPressed: onCancelAll,
                      style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                      icon: const Icon(Icons.cancel_outlined, size: 17),
                      label: Text(tr('btn_cancel_all')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 16),
            itemCount: jobs.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final job = jobs[index];
              return DownloadJobCard(
                job: job,
                translator: translator,
                onPause: () => onPauseJob(job.id),
                onResume: () => onResumeJob(job.id),
                onCancel: () => onCancelJob(job.id),
              );
            },
          ),
        ),
      ],
    );
  }
}
