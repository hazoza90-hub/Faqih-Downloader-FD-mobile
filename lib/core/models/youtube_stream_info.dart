import 'package:flutter/foundation.dart';

import '../config/app_constants.dart';
import 'audio_track.dart';
import 'clip_range.dart';
import 'subtitle_track.dart';
import 'video_format_option.dart';

/// Resolved metadata and stream descriptors for YouTube and social media videos.
@immutable
class YouTubeStreamInfo {
  const YouTubeStreamInfo({
    required this.videoId,
    required this.title,
    required this.cleanFilename,
    required this.isProgressive,
    required this.videoUrl,
    this.videoHeaders = const <String, String>{},
    this.videoExt = 'mp4',
    this.videoResolution = '720p',
    this.videoSize = 0,
    this.audioUrl,
    this.audioHeaders = const <String, String>{},
    this.audioExt = 'm4a',
    this.audioSize = 0,
    this.durationSec = 0,
    this.thumbnailUrl = '',
    this.isAudioOnly = false,
    this.platform = 'YouTube',
    this.webpageUrl = '',
    this.audioFormatId = '',
    this.audioLanguage,
    this.selectedAudioTrack,
    this.selectedSubtitleTrack,
    this.subtitleEmbedMode = AppConstants.subtitleModeSoftMux,
    this.clipRange,
    this.externalSubtitleTracks = const <SubtitleTrack>[],
    this.videoFormats = const <VideoFormatOption>[],
    this.audioTracks = const <AudioTrack>[],
    this.subtitleTracks = const <SubtitleTrack>[],
    this.playlistEntries = const <YouTubeStreamInfo>[],
    this.isPlaylist = false,
  });

  final String videoId;
  final String title;
  final String cleanFilename;
  final bool isProgressive;
  final String videoUrl;
  final Map<String, String> videoHeaders;
  final String videoExt;
  final String videoResolution;
  final int videoSize;
  final String? audioUrl;
  final Map<String, String> audioHeaders;
  final String audioExt;
  final int audioSize;
  final int durationSec;
  final String thumbnailUrl;
  final bool isAudioOnly;
  final String platform;
  final String webpageUrl;
  final String audioFormatId;
  final String? audioLanguage;
  final AudioTrack? selectedAudioTrack;
  final SubtitleTrack? selectedSubtitleTrack;
  final String subtitleEmbedMode;
  final ClipRange? clipRange;
  final List<SubtitleTrack> externalSubtitleTracks;
  final List<VideoFormatOption> videoFormats;
  final List<AudioTrack> audioTracks;
  final List<SubtitleTrack> subtitleTracks;
  final List<YouTubeStreamInfo> playlistEntries;
  final bool isPlaylist;

  bool get isDualStream =>
      !isProgressive && !isAudioOnly && (audioUrl?.isNotEmpty ?? false);

  int get estimatedTotalSize {
    if (isAudioOnly) return audioSize > 0 ? audioSize : videoSize;
    if (isDualStream) return videoSize + audioSize;
    return videoSize;
  }

  YouTubeStreamInfo copyWith({
    String? videoId,
    String? title,
    String? cleanFilename,
    bool? isProgressive,
    String? videoUrl,
    Map<String, String>? videoHeaders,
    String? videoExt,
    String? videoResolution,
    int? videoSize,
    String? audioUrl,
    bool clearAudioUrl = false,
    Map<String, String>? audioHeaders,
    String? audioExt,
    int? audioSize,
    int? durationSec,
    String? thumbnailUrl,
    bool? isAudioOnly,
    String? platform,
    String? webpageUrl,
    String? audioFormatId,
    String? audioLanguage,
    AudioTrack? selectedAudioTrack,
    bool clearAudioTrack = false,
    SubtitleTrack? selectedSubtitleTrack,
    bool clearSubtitleTrack = false,
    String? subtitleEmbedMode,
    ClipRange? clipRange,
    bool clearClipRange = false,
    List<SubtitleTrack>? externalSubtitleTracks,
    List<VideoFormatOption>? videoFormats,
    List<AudioTrack>? audioTracks,
    List<SubtitleTrack>? subtitleTracks,
    List<YouTubeStreamInfo>? playlistEntries,
    bool? isPlaylist,
  }) {
    return YouTubeStreamInfo(
      videoId: videoId ?? this.videoId,
      title: title ?? this.title,
      cleanFilename: cleanFilename ?? this.cleanFilename,
      isProgressive: isProgressive ?? this.isProgressive,
      videoUrl: videoUrl ?? this.videoUrl,
      videoHeaders: Map<String, String>.unmodifiable(
        videoHeaders ?? this.videoHeaders,
      ),
      videoExt: videoExt ?? this.videoExt,
      videoResolution: videoResolution ?? this.videoResolution,
      videoSize: videoSize ?? this.videoSize,
      audioUrl: clearAudioUrl ? null : (audioUrl ?? this.audioUrl),
      audioHeaders: Map<String, String>.unmodifiable(
        audioHeaders ?? this.audioHeaders,
      ),
      audioExt: audioExt ?? this.audioExt,
      audioSize: audioSize ?? this.audioSize,
      durationSec: durationSec ?? this.durationSec,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      isAudioOnly: isAudioOnly ?? this.isAudioOnly,
      platform: platform ?? this.platform,
      webpageUrl: webpageUrl ?? this.webpageUrl,
      audioFormatId: audioFormatId ?? this.audioFormatId,
      audioLanguage: audioLanguage ?? this.audioLanguage,
      selectedAudioTrack:
          clearAudioTrack ? null : (selectedAudioTrack ?? this.selectedAudioTrack),
      selectedSubtitleTrack: clearSubtitleTrack
          ? null
          : (selectedSubtitleTrack ?? this.selectedSubtitleTrack),
      subtitleEmbedMode: subtitleEmbedMode ?? this.subtitleEmbedMode,
      clipRange: clearClipRange ? null : (clipRange ?? this.clipRange),
      externalSubtitleTracks: List<SubtitleTrack>.unmodifiable(
        externalSubtitleTracks ?? this.externalSubtitleTracks,
      ),
      videoFormats: List<VideoFormatOption>.unmodifiable(
        videoFormats ?? this.videoFormats,
      ),
      audioTracks: List<AudioTrack>.unmodifiable(audioTracks ?? this.audioTracks),
      subtitleTracks: List<SubtitleTrack>.unmodifiable(
        subtitleTracks ?? this.subtitleTracks,
      ),
      playlistEntries: List<YouTubeStreamInfo>.unmodifiable(
        playlistEntries ?? this.playlistEntries,
      ),
      isPlaylist: isPlaylist ?? this.isPlaylist,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'videoId': videoId,
        'title': title,
        'cleanFilename': cleanFilename,
        'isProgressive': isProgressive,
        'videoUrl': videoUrl,
        'videoHeaders': videoHeaders,
        'videoExt': videoExt,
        'videoResolution': videoResolution,
        'videoSize': videoSize,
        'audioUrl': audioUrl,
        'audioHeaders': audioHeaders,
        'audioExt': audioExt,
        'audioSize': audioSize,
        'durationSec': durationSec,
        'thumbnailUrl': thumbnailUrl,
        'isAudioOnly': isAudioOnly,
        'platform': platform,
        'webpageUrl': webpageUrl,
        'audioFormatId': audioFormatId,
        'audioLanguage': audioLanguage,
        'selectedAudioTrack': selectedAudioTrack?.toJson(),
        'selectedSubtitleTrack': selectedSubtitleTrack?.toJson(),
        'subtitleEmbedMode': subtitleEmbedMode,
        'clipRange': clipRange?.toJson(),
        'externalSubtitleTracks':
            externalSubtitleTracks.map((t) => t.toJson()).toList(growable: false),
        'videoFormats':
            videoFormats.map((f) => f.toJson()).toList(growable: false),
        'audioTracks': audioTracks.map((a) => a.toJson()).toList(growable: false),
        'subtitleTracks':
            subtitleTracks.map((s) => s.toJson()).toList(growable: false),
        'playlistEntries':
            playlistEntries.map((e) => e.toJson()).toList(growable: false),
        'isPlaylist': isPlaylist,
      };

  factory YouTubeStreamInfo.fromJson(Map<String, dynamic> json) {
    return YouTubeStreamInfo(
      videoId: json['videoId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      cleanFilename: json['cleanFilename']?.toString() ?? '',
      isProgressive: json['isProgressive'] == true,
      videoUrl: json['videoUrl']?.toString() ?? '',
      videoHeaders: _toStringMap(json['videoHeaders']),
      videoExt: json['videoExt']?.toString() ?? 'mp4',
      videoResolution: json['videoResolution']?.toString() ?? '720p',
      videoSize: _toInt(json['videoSize']),
      audioUrl: json['audioUrl']?.toString(),
      audioHeaders: _toStringMap(json['audioHeaders']),
      audioExt: json['audioExt']?.toString() ?? 'm4a',
      audioSize: _toInt(json['audioSize']),
      durationSec: _toInt(json['durationSec']),
      thumbnailUrl: json['thumbnailUrl']?.toString() ?? '',
      isAudioOnly: json['isAudioOnly'] == true,
      platform: json['platform']?.toString() ?? 'YouTube',
      webpageUrl: json['webpageUrl']?.toString() ?? '',
      audioFormatId: json['audioFormatId']?.toString() ?? '',
      audioLanguage: json['audioLanguage']?.toString(),
      selectedAudioTrack: _parseMap(json['selectedAudioTrack'], AudioTrack.fromJson),
      selectedSubtitleTrack:
          _parseMap(json['selectedSubtitleTrack'], SubtitleTrack.fromJson),
      subtitleEmbedMode:
          json['subtitleEmbedMode']?.toString() ?? AppConstants.subtitleModeSoftMux,
      clipRange: _parseMap(json['clipRange'], ClipRange.fromJson),
      externalSubtitleTracks:
          _parseList(json['externalSubtitleTracks'], SubtitleTrack.fromJson),
      videoFormats: _parseList(json['videoFormats'], VideoFormatOption.fromJson),
      audioTracks: _parseList(json['audioTracks'], AudioTrack.fromJson),
      subtitleTracks: _parseList(json['subtitleTracks'], SubtitleTrack.fromJson),
      playlistEntries:
          _parseList(json['playlistEntries'], YouTubeStreamInfo.fromJson),
      isPlaylist: json['isPlaylist'] == true,
    );
  }

  static List<T> _parseList<T>(
    Object? raw,
    T Function(Map<String, dynamic>) parser,
  ) {
    if (raw is! List) return <T>[];
    return List<T>.unmodifiable(
      raw.whereType<Map>().map((m) => parser(Map<String, dynamic>.from(m))),
    );
  }

  static T? _parseMap<T>(Object? raw, T Function(Map<String, dynamic>) parser) {
    if (raw is! Map) return null;
    return parser(Map<String, dynamic>.from(raw));
  }

  static int _toInt(Object? raw) =>
      raw is int ? raw : (raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0);

  static Map<String, String> _toStringMap(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    return Map<String, String>.unmodifiable(<String, String>{
      for (final e in raw.entries) e.key.toString(): e.value?.toString() ?? '',
    });
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is YouTubeStreamInfo &&
          other.videoId == videoId &&
          other.title == title &&
          other.cleanFilename == cleanFilename &&
          other.isProgressive == isProgressive &&
          other.videoUrl == videoUrl &&
          mapEquals(other.videoHeaders, videoHeaders) &&
          other.videoExt == videoExt &&
          other.videoResolution == videoResolution &&
          other.videoSize == videoSize &&
          other.audioUrl == audioUrl &&
          mapEquals(other.audioHeaders, audioHeaders) &&
          other.audioExt == audioExt &&
          other.audioSize == audioSize &&
          other.durationSec == durationSec &&
          other.thumbnailUrl == thumbnailUrl &&
          other.isAudioOnly == isAudioOnly &&
          other.platform == platform &&
          other.webpageUrl == webpageUrl &&
          other.audioFormatId == audioFormatId &&
          other.audioLanguage == audioLanguage &&
          other.selectedAudioTrack == selectedAudioTrack &&
          other.selectedSubtitleTrack == selectedSubtitleTrack &&
          other.subtitleEmbedMode == subtitleEmbedMode &&
          other.clipRange == clipRange &&
          listEquals(other.externalSubtitleTracks, externalSubtitleTracks) &&
          listEquals(other.videoFormats, videoFormats) &&
          listEquals(other.audioTracks, audioTracks) &&
          listEquals(other.subtitleTracks, subtitleTracks) &&
          listEquals(other.playlistEntries, playlistEntries) &&
          other.isPlaylist == isPlaylist);

  @override
  int get hashCode => Object.hashAll(<Object?>[
        videoId, title, cleanFilename, isProgressive, videoUrl,
        _mapHash(videoHeaders), videoExt, videoResolution, videoSize,
        audioUrl, _mapHash(audioHeaders), audioExt, audioSize, durationSec,
        thumbnailUrl, isAudioOnly, platform, webpageUrl, audioFormatId,
        audioLanguage, selectedAudioTrack, selectedSubtitleTrack,
        subtitleEmbedMode, clipRange, Object.hashAll(externalSubtitleTracks),
        Object.hashAll(videoFormats), Object.hashAll(audioTracks),
        Object.hashAll(subtitleTracks), Object.hashAll(playlistEntries),
        isPlaylist,
      ]);

  static int _mapHash(Map<String, String> map) => Object.hashAllUnordered(
        map.entries.map((e) => Object.hash(e.key, e.value)),
      );
}
