import 'package:flutter/foundation.dart';

/// Time-range trim window in seconds for media clipping downloads.
@immutable
class ClipRange {
  const ClipRange({
    this.startSec = 0.0,
    this.endSec = 0.0,
  });

  final double startSec;
  final double endSec;

  bool get isValid {
    if (startSec.isNaN || endSec.isNaN || startSec < 0 || endSec < 0) {
      return false;
    }
    return endSec == 0.0 || endSec > startSec;
  }

  bool get isActive => isValid && (startSec > 0.0 || endSec > 0.0);

  double get durationSec {
    if (!isValid || endSec <= startSec) {
      return 0.0;
    }
    return endSec - startSec;
  }

  bool isValidForDuration(double mediaDurationSec) {
    if (!isValid) {
      return false;
    }
    if (!isActive) {
      return true;
    }
    if (mediaDurationSec <= 0 || mediaDurationSec.isNaN) {
      return false;
    }
    if (startSec >= mediaDurationSec) {
      return false;
    }
    return endSec == 0.0 || endSec <= mediaDurationSec;
  }

  ClipRange copyWith({
    double? startSec,
    double? endSec,
  }) {
    return ClipRange(
      startSec: startSec ?? this.startSec,
      endSec: endSec ?? this.endSec,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'startSec': startSec,
      'endSec': endSec,
    };
  }

  factory ClipRange.fromJson(Map<String, dynamic> json) {
    return ClipRange(
      startSec: _toDouble(json['startSec']),
      endSec: _toDouble(json['endSec']),
    );
  }

  static double _toDouble(Object? raw) {
    if (raw is double) return raw;
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw.trim()) ?? 0.0;
    return 0.0;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ClipRange &&
        other.startSec == startSec &&
        other.endSec == endSec;
  }

  @override
  int get hashCode => Object.hash(startSec, endSec);
}
