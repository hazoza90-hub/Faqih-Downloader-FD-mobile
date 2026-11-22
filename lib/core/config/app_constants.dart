/// Core application constants and engine limits for Faqih Downloader Mobile.
abstract final class AppConstants {
  static const String appName = 'Faqih Downloader (FD)';
  static const String appShortName = 'Faqih Downloader';
  static const String appVersion = '0.0.2';
  static const String githubRepoSlug = 'hazoza90-hub/Faqih-Downloader-FD-mobile';

  static const int minConnections = 1;
  static const int defaultMaxConnections = 6;
  static const int maxConnectionsLimit = 16;

  static const int minConcurrentDownloads = 1;
  static const int defaultMaxConcurrentDownloads = 3;
  static const int maxConcurrentDownloadsLimit = 5;

  static const int defaultMinSplitBytes = 128 * 1024;
  static const int defaultBufferBytes = 64 * 1024;

  static const List<int> supportedSpeedPresetsBytesPerSec = <int>[
    0,
    256 * 1024,
    512 * 1024,
    1024 * 1024,
    2 * 1024 * 1024,
    5 * 1024 * 1024,
    10 * 1024 * 1024,
  ];

  static const String subtitleModeSoftMux = 'soft_mux';
  static const String subtitleModeHardBurn = 'hard_burn';
  static const String defaultQuality = '1080p';

  static int clampConnections(int value) {
    if (value < minConnections) {
      return minConnections;
    }
    if (value > maxConnectionsLimit) {
      return maxConnectionsLimit;
    }
    return value;
  }

  static int clampConcurrentDownloads(int value) {
    if (value < minConcurrentDownloads) {
      return minConcurrentDownloads;
    }
    if (value > maxConcurrentDownloadsLimit) {
      return maxConcurrentDownloadsLimit;
    }
    return value;
  }
}
