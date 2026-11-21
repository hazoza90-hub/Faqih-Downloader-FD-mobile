import 'package:flutter/foundation.dart';

import 'audio_track.dart';
import 'clip_range.dart';
import 'subtitle_track.dart';

/// Selectable download quality and format option presented to the user.
@immutable
class VideoFormatOption {
  const VideoFormatOption({
    required this.formatId,
    required this.resolutionLabel,
    this.height = 0,
    this.width = 0,
    this.fps = 30,
    this.ext = 'mp4',
    this.filesizeApprox = 0,
    this.vcodec = '',
    this.acodec = '',
    this.isProgressive = false,
    this.isAudioOnly = false,
    this.videoUrl = '',
    this.videoHeaders = const <String, String>{},
    this.audioUrl,
    this.audioHeaders = const <String, String>{},
    this.audioExt = 'm4a',
    this.audioSize = 0,
    this.note = '',
    this.selectedAudioTrack,
    this.selectedSubtitleTrack,
    this.clipRange,
  });

  final String formatId;
  final String resolutionLabel;
  final int height;
  final int width;
  final int fps;
  final String ext;
  final int filesizeApprox;
  final String vcodec;
  final String acodec;
  final bool isProgressive;
  final bool isAudioOnly;
  final String videoUrl;
  final Map<String, String> videoHeaders;
  final String? audioUrl;
  final Map<String, String> audioHeaders;
  final String audioExt;
  final int audioSize;
  final String note;
  final AudioTrack? selectedAudioTrack;
  final SubtitleTrack? selectedSubtitleTrack;
  final ClipRange? clipRange;

  VideoFormatOption copyWith({
    String? formatId,
    String? resolutionLabel,
    int? height,
    int? width,
    int? fps,
    String? ext,
    int? filesizeApprox,
    String? vcodec,
    String? acodec,
    bool? isProgressive,
    bool? isAudioOnly,
    String? videoUrl,
    Map<String, String>? videoHeaders,
    String? audioUrl,
    bool clearAudioUrl = false,
    Map<String, String>? audioHeaders,
    String? audioExt,
    int? audioSize,
    String? note,
    AudioTrack? selectedAudioTrack,
    bool clearAudioTrack = false,
    SubtitleTrack? selectedSubtitleTrack,
    bool clearSubtitleTrack = false,
    ClipRange? clipRange,
    bool clearClipRange = false,
  }) {
    return VideoFormatOption(
      formatId: formatId ?? this.formatId,
      resolutionLabel: resolutionLabel ?? this.resolutionLabel,
      height: height ?? this.height,
      width: width ?? this.width,
      fps: fps ?? this.fps,
      ext: ext ?? this.ext,
      filesizeApprox: filesizeApprox ?? this.filesizeApprox,
      vcodec: vcodec ?? this.vcodec,
      acodec: acodec ?? this.acodec,
      isProgressive: isProgressive ?? this.isProgressive,
      isAudioOnly: isAudioOnly ?? this.isAudioOnly,
      videoUrl: videoUrl ?? this.videoUrl,
      videoHeaders: Map<String, String>.unmodifiable(
        videoHeaders ?? this.videoHeaders,
      ),
      audioUrl: clearAudioUrl ? null : (audioUrl ?? this.audioUrl),
      audioHeaders: Map<String, String>.unmodifiable(
        audioHeaders ?? this.audioHeaders,
      ),
      audioExt: audioExt ?? this.audioExt,
      audioSize: audioSize ?? this.audioSize,
      note: note ?? this.note,
      selectedAudioTrack: clearAudioTrack
          ? null
          : (selectedAudioTrack ?? this.selectedAudioTrack),
      selectedSubtitleTrack: clearSubtitleTrack
          ? null
          : (selectedSubtitleTrack ?? this.selectedSubtitleTrack),
      clipRange: clearClipRange ? null : (clipRange ?? this.clipRange),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'formatId': formatId,
      'resolutionLabel': resolutionLabel,
      'height': height,
      'width': width,
      'fps': fps,
      'ext': ext,
      'filesizeApprox': filesizeApprox,
      'vcodec': vcodec,
      'acodec': acodec,
      'isProgressive': isProgressive,
      'isAudioOnly': isAudioOnly,
      'videoUrl': videoUrl,
      'videoHeaders': videoHeaders,
      'audioUrl': audioUrl,
      'audioHeaders': audioHeaders,
      'audioExt': audioExt,
      'audioSize': audioSize,
      'note': note,
      'selectedAudioTrack': selectedAudioTrack?.toJson(),
      'selectedSubtitleTrack': selectedSubtitleTrack?.toJson(),
      'clipRange': clipRange?.toJson(),
    };
  }

  factory VideoFormatOption.fromJson(Map<String, dynamic> json) {
    return VideoFormatOption(
      formatId: json['formatId']?.toString() ?? '',
      resolutionLabel: json['resolutionLabel']?.toString() ?? '',
      height: _toInt(json['height']),
      width: _toInt(json['width']),
      fps: _toInt(json['fps'], fallback: 30),
      ext: json['ext']?.toString() ?? 'mp4',
      filesizeApprox: _toInt(json['filesizeApprox']),
      vcodec: json['vcodec']?.toString() ?? '',
      acodec: json['acodec']?.toString() ?? '',
      isProgressive: json['isProgressive'] == true,
      isAudioOnly: json['isAudioOnly'] == true,
      videoUrl: json['videoUrl']?.toString() ?? '',
      videoHeaders: _toStringMap(json['videoHeaders']),
      audioUrl: json['audioUrl']?.toString(),
      audioHeaders: _toStringMap(json['audioHeaders']),
      audioExt: json['audioExt']?.toString() ?? 'm4a',
      audioSize: _toInt(json['audioSize']),
      note: json['note']?.toString() ?? '',
      selectedAudioTrack: json['selectedAudioTrack'] is Map
          ? AudioTrack.fromJson(
              Map<String, dynamic>.from(json['selectedAudioTrack'] as Map),
            )
          : null,
      selectedSubtitleTrack: json['selectedSubtitleTrack'] is Map
          ? SubtitleTrack.fromJson(
              Map<String, dynamic>.from(json['selectedSubtitleTrack'] as Map),
            )
          : null,
      clipRange: json['clipRange'] is Map
          ? ClipRange.fromJson(
              Map<String, dynamic>.from(json['clipRange'] as Map),
            )
          : null,
    );
  }

  static int _toInt(Object? raw, {int fallback = 0}) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? fallback;
    return fallback;
  }

  static Map<String, String> _toStringMap(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    return Map<String, String>.unmodifiable(<String, String>{
      for (final entry in raw.entries)
        entry.key.toString(): entry.value?.toString() ?? '',
    });
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VideoFormatOption &&
        other.formatId == formatId &&
        other.resolutionLabel == resolutionLabel &&
        other.height == height &&
        other.width == width &&
        other.fps == fps &&
        other.ext == ext &&
        other.filesizeApprox == filesizeApprox &&
        other.vcodec == vcodec &&
        other.acodec == acodec &&
        other.isProgressive == isProgressive &&
        other.isAudioOnly == isAudioOnly &&
        other.videoUrl == videoUrl &&
        mapEquals(other.videoHeaders, videoHeaders) &&
        other.audioUrl == audioUrl &&
        mapEquals(other.audioHeaders, audioHeaders) &&
        other.audioExt == audioExt &&
        other.audioSize == audioSize &&
        other.note == note &&
        other.selectedAudioTrack == selectedAudioTrack &&
        other.selectedSubtitleTrack == selectedSubtitleTrack &&
        other.clipRange == clipRange;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    formatId,
    resolutionLabel,
    height,
    width,
    fps,
    ext,
    filesizeApprox,
    vcodec,
    acodec,
    isProgressive,
    isAudioOnly,
    videoUrl,
    Object.hashAllUnordered(
      videoHeaders.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    audioUrl,
    Object.hashAllUnordered(
      audioHeaders.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    audioExt,
    audioSize,
    note,
    selectedAudioTrack,
    selectedSubtitleTrack,
    clipRange,
  ]);
}
