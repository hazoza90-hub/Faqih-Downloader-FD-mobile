import 'package:flutter/foundation.dart';

/// Selectable audio or dubbed language track associated with a media stream.
@immutable
class AudioTrack {
  const AudioTrack({
    required this.trackId,
    required this.formatId,
    required this.language,
    required this.label,
    required this.url,
    this.ext = 'm4a',
    this.filesize = 0,
    this.isOriginal = false,
    this.httpHeaders = const <String, String>{},
  });

  final String trackId;
  final String formatId;
  final String language;
  final String label;
  final String url;
  final String ext;
  final int filesize;
  final bool isOriginal;
  final Map<String, String> httpHeaders;

  AudioTrack copyWith({
    String? trackId,
    String? formatId,
    String? language,
    String? label,
    String? url,
    String? ext,
    int? filesize,
    bool? isOriginal,
    Map<String, String>? httpHeaders,
  }) {
    return AudioTrack(
      trackId: trackId ?? this.trackId,
      formatId: formatId ?? this.formatId,
      language: language ?? this.language,
      label: label ?? this.label,
      url: url ?? this.url,
      ext: ext ?? this.ext,
      filesize: filesize ?? this.filesize,
      isOriginal: isOriginal ?? this.isOriginal,
      httpHeaders: Map<String, String>.unmodifiable(
        httpHeaders ?? this.httpHeaders,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'trackId': trackId,
      'formatId': formatId,
      'language': language,
      'label': label,
      'url': url,
      'ext': ext,
      'filesize': filesize,
      'isOriginal': isOriginal,
      'httpHeaders': httpHeaders,
    };
  }

  factory AudioTrack.fromJson(Map<String, dynamic> json) {
    return AudioTrack(
      trackId: json['trackId']?.toString() ?? '',
      formatId: json['formatId']?.toString() ?? '',
      language: json['language']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      ext: json['ext']?.toString() ?? 'm4a',
      filesize: _toInt(json['filesize']),
      isOriginal: json['isOriginal'] == true,
      httpHeaders: _toStringMap(json['httpHeaders']),
    );
  }

  static int _toInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? 0;
    return 0;
  }

  static Map<String, String> _toStringMap(Object? raw) {
    if (raw is! Map) {
      return const <String, String>{};
    }
    return Map<String, String>.unmodifiable(<String, String>{
      for (final entry in raw.entries)
        entry.key.toString(): entry.value?.toString() ?? '',
    });
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AudioTrack &&
        other.trackId == trackId &&
        other.formatId == formatId &&
        other.language == language &&
        other.label == label &&
        other.url == url &&
        other.ext == ext &&
        other.filesize == filesize &&
        other.isOriginal == isOriginal &&
        mapEquals(other.httpHeaders, httpHeaders);
  }

  @override
  int get hashCode => Object.hash(
    trackId,
    formatId,
    language,
    label,
    url,
    ext,
    filesize,
    isOriginal,
    Object.hashAllUnordered(
      httpHeaders.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}
