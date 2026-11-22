import 'package:flutter/foundation.dart';

class NativeBridgeException implements Exception {
  const NativeBridgeException(this.code, this.message, [this.details]);

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'NativeBridgeException($code: $message)';
}

@immutable
class NativeInitStatus {
  const NativeInitStatus({
    required this.initialized,
    required this.ytdlpVersion,
    required this.ffmpegReady,
  });

  final bool initialized;
  final String ytdlpVersion;
  final bool ffmpegReady;

  factory NativeInitStatus.fromMap(Map<Object?, Object?> map) {
    return NativeInitStatus(
      initialized: map['initialized'] == true,
      ytdlpVersion: map['ytdlpVersion']?.toString() ?? 'unknown',
      ffmpegReady: map['ffmpegReady'] == true,
    );
  }
}

@immutable
class NativeUpdateResult {
  const NativeUpdateResult({
    required this.status,
    required this.ytdlpVersion,
  });

  final String status;
  final String ytdlpVersion;

  factory NativeUpdateResult.fromMap(Map<Object?, Object?> map) {
    return NativeUpdateResult(
      status: map['status']?.toString() ?? 'UNKNOWN',
      ytdlpVersion: map['ytdlpVersion']?.toString() ?? 'unknown',
    );
  }
}

@immutable
class NativeCommandResult {
  const NativeCommandResult({
    required this.exitCode,
    required this.output,
    this.stderr = '',
  });

  final int exitCode;
  final String output;
  final String stderr;

  bool get isSuccess => exitCode == 0;

  factory NativeCommandResult.fromMap(Map<Object?, Object?> map) {
    return NativeCommandResult(
      exitCode: (map['exitCode'] as num?)?.toInt() ?? -1,
      output: (map['output'] ?? map['stdout'])?.toString() ?? '',
      stderr: map['stderr']?.toString() ?? '',
    );
  }
}

@immutable
class NativeProgressEvent {
  const NativeProgressEvent({
    required this.type,
    required this.processId,
    this.progress = 0.0,
    this.etaSeconds = -1,
    this.line = '',
  });

  final String type;
  final String processId;
  final double progress;
  final int etaSeconds;
  final String line;

  factory NativeProgressEvent.fromMap(Map<Object?, Object?> map) {
    return NativeProgressEvent(
      type: map['type']?.toString() ?? 'progress',
      processId: map['processId']?.toString() ?? '',
      progress: (map['progress'] as num?)?.toDouble() ?? 0.0,
      etaSeconds: (map['etaSeconds'] as num?)?.toInt() ?? -1,
      line: map['line']?.toString() ?? '',
    );
  }
}

@immutable
class ExportResult {
  const ExportResult({
    required this.uri,
    required this.displayPath,
    required this.sizeBytes,
  });

  final String uri;
  final String displayPath;
  final int sizeBytes;

  factory ExportResult.fromMap(Map<Object?, Object?> map) {
    return ExportResult(
      uri: map['uri']?.toString() ?? '',
      displayPath: map['displayPath']?.toString() ?? '',
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

@immutable
class ForegroundProgressPayload {
  const ForegroundProgressPayload({
    required this.title,
    required this.body,
    this.progress = 0,
    this.indeterminate = false,
    this.pauseLabel,
    this.cancelLabel,
  });

  final String title;
  final String body;
  final int progress;
  final bool indeterminate;
  final String? pauseLabel;
  final String? cancelLabel;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'title': title,
      'body': body,
      'progress': progress.clamp(0, 100),
      'indeterminate': indeterminate,
      'pauseLabel': ?pauseLabel,
      'cancelLabel': ?cancelLabel,
    };
  }
}

enum ServiceNotificationAction {
  pauseAll,
  cancelAll,
  unknown,
}

ServiceNotificationAction parseServiceNotificationAction(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'pause_all':
      return ServiceNotificationAction.pauseAll;
    case 'cancel_all':
      return ServiceNotificationAction.cancelAll;
    default:
      return ServiceNotificationAction.unknown;
  }
}
