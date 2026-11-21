/// Lifecycle states for a download task across staging, active transfer, and vault.
enum DownloadStatus {
  staged,
  queued,
  probing,
  downloading,
  paused,
  merging,
  postProcessing,
  completed,
  failed,
  cancelled,
}

extension DownloadStatusX on DownloadStatus {
  bool get isActive {
    return this == DownloadStatus.queued ||
        this == DownloadStatus.probing ||
        this == DownloadStatus.downloading ||
        this == DownloadStatus.merging ||
        this == DownloadStatus.postProcessing;
  }

  bool get isTerminal {
    return this == DownloadStatus.completed ||
        this == DownloadStatus.failed ||
        this == DownloadStatus.cancelled;
  }
}

DownloadStatus parseDownloadStatus(
  String? raw, {
  DownloadStatus fallback = DownloadStatus.staged,
}) {
  if (raw == null || raw.trim().isEmpty) {
    return fallback;
  }
  final normalized = raw.trim().toLowerCase();
  for (final value in DownloadStatus.values) {
    if (value.name.toLowerCase() == normalized) {
      return value;
    }
  }
  return fallback;
}
