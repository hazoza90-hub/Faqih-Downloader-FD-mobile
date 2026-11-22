/// Classified failure categories for media extraction and FFmpeg processing.
enum MediaErrorKind {
  unsupportedUrl,
  loginRequired,
  geoBlocked,
  linkExpired,
  networkError,
  cancelled,
  ffmpegFailed,
  unknown,
}

/// Exception thrown when extracting media metadata or formats fails.
class MediaExtractionException implements Exception {
  const MediaExtractionException({
    required this.kind,
    required this.message,
    this.rawDetails = '',
  });

  final MediaErrorKind kind;
  final String message;
  final String rawDetails;

  @override
  String toString() => 'MediaExtractionException($kind: $message)';
}

/// Exception thrown when post-download FFmpeg or subtitle processing fails.
class MediaProcessingException implements Exception {
  const MediaProcessingException({
    required this.kind,
    required this.message,
    this.rawDetails = '',
    this.exitCode,
  });

  final MediaErrorKind kind;
  final String message;
  final String rawDetails;
  final int? exitCode;

  @override
  String toString() =>
      'MediaProcessingException($kind, exitCode=$exitCode: $message)';
}
