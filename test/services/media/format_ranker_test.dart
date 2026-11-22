import 'dart:convert';

import 'package:faqih_downloader_mobile/services/media/format_ranker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const ranker = FormatRanker();

  group('FormatRanker', () {
    test('ranks and deduplicates video formats, dubbing tracks, and subtitles cleanly', () {
      final sampleJson = jsonEncode(<String, Object?>{
        'id': 'vid_4k_dub',
        'title': 'Complex Tech Documentary',
        'duration': 600,
        'language': 'en',
        'extractor_key': 'Youtube',
        'webpage_url': 'https://www.youtube.com/watch?v=vid_4k_dub',
        'thumbnail': 'https://i.ytimg.com/vi/vid_4k_dub/maxres.jpg',
        'http_headers': <String, String>{'User-Agent': 'FD-Test'},
        'formats': <Map<String, Object?>>[
          // Storyboard must be ignored
          <String, Object?>{
            'format_id': 'sb0',
            'ext': 'mhtml',
            'format_note': 'storyboard',
            'url': 'https://cdn.example.com/sb.mhtml',
          },
          // Audio-only: Original English (higher pref) & Opus duplicate
          <String, Object?>{
            'format_id': '140-en',
            'ext': 'm4a',
            'vcodec': 'none',
            'acodec': 'mp4a.40.2',
            'language': 'en',
            'language_preference': 10,
            'format_note': 'English original',
            'abr': 128,
            'url': 'https://cdn.example.com/aud_en.m4a',
          },
          // Arabic dubbed M4A vs lower-priority Opus + HLS
          <String, Object?>{
            'format_id': '140-ar-m4a',
            'ext': 'm4a',
            'vcodec': 'none',
            'acodec': 'mp4a.40.2',
            'language': 'ar',
            'format_note': 'Arabic dubbed',
            'abr': 128,
            'url': 'https://cdn.example.com/aud_ar.m4a',
          },
          <String, Object?>{
            'format_id': '251-ar-opus',
            'ext': 'webm',
            'vcodec': 'none',
            'acodec': 'opus',
            'language': 'ar',
            'format_note': 'Arabic dubbed',
            'abr': 160,
            'url': 'https://cdn.example.com/aud_ar.webm',
          },
          // French dubbed
          <String, Object?>{
            'format_id': '140-fr',
            'ext': 'm4a',
            'vcodec': 'none',
            'acodec': 'mp4a.40.2',
            'language': 'fr',
            'format_note': 'French dubbed',
            'abr': 128,
            'url': 'https://cdn.example.com/aud_fr.m4a',
          },
          // 4K video-only
          <String, Object?>{
            'format_id': '313',
            'ext': 'mp4',
            'width': 3840,
            'height': 2160,
            'fps': 30,
            'vcodec': 'av01.0.12M.08',
            'acodec': 'none',
            'tbr': 14000.0,
            'url': 'https://cdn.example.com/v2160.mp4',
          },
          // 1080p 60fps
          <String, Object?>{
            'format_id': '299',
            'ext': 'mp4',
            'width': 1920,
            'height': 1080,
            'fps': 60,
            'vcodec': 'avc1.64002a',
            'acodec': 'none',
            'tbr': 4500.0,
            'url': 'https://cdn.example.com/v1080p60.mp4',
          },
          // 1080p30 duplicates: HLS m3u8 vs VP9 webm vs direct AVC1 mp4
          <String, Object?>{
            'format_id': '96-hls',
            'ext': 'mp4',
            'height': 1080,
            'fps': 30,
            'vcodec': 'avc1.640028',
            'acodec': 'mp4a.40.2',
            'protocol': 'm3u8_native',
            'tbr': 5000.0,
            'url': 'https://cdn.example.com/master.m3u8',
          },
          <String, Object?>{
            'format_id': '248-vp9',
            'ext': 'webm',
            'height': 1080,
            'fps': 30,
            'vcodec': 'vp9',
            'acodec': 'none',
            'tbr': 3200.0,
            'url': 'https://cdn.example.com/v1080.webm',
          },
          <String, Object?>{
            'format_id': '137-avc1',
            'ext': 'mp4',
            'height': 1080,
            'fps': 30,
            'vcodec': 'avc1.640028',
            'acodec': 'none',
            'tbr': 2800.0,
            'url': 'https://cdn.example.com/v1080_avc.mp4',
          },
          // 720p progressive
          <String, Object?>{
            'format_id': '22',
            'ext': 'mp4',
            'width': 1280,
            'height': 720,
            'fps': 30,
            'vcodec': 'avc1.64001F',
            'acodec': 'mp4a.40.2',
            'tbr': 1500.0,
            'url': 'https://cdn.example.com/v720_prog.mp4',
          },
        ],
        'subtitles': <String, Object?>{
          'en': <Map<String, Object?>>[
            <String, Object?>{'ext': 'srv1', 'url': 'https://cdn.example.com/en.srv1'},
            <String, Object?>{'ext': 'vtt', 'name': 'English', 'url': 'https://cdn.example.com/en.vtt'},
          ],
          'ar': <Map<String, Object?>>[
            <String, Object?>{'ext': 'srt', 'name': 'العربية', 'url': 'https://cdn.example.com/ar.srt'},
            <String, Object?>{'ext': 'vtt', 'name': 'العربية', 'url': 'https://cdn.example.com/ar.vtt'},
          ],
        },
        'automatic_captions': <String, Object?>{
          'ar': <Map<String, Object?>>[
            <String, Object?>{'ext': 'vtt', 'name': 'Arabic Auto', 'url': 'https://cdn.example.com/ar_auto.vtt'},
          ],
        },
      });

      final info = ranker.parseJsonString(sampleJson);

      expect(info.isPlaylist, isFalse);
      expect(info.videoId, 'vid_4k_dub');
      expect(info.videoFormats.map((f) => f.formatId).toList(), <String>[
        '313',
        '299',
        '137-avc1',
        '22',
      ]);

      // 1080p bucket preferred direct AVC1 mp4 ('137-avc1') over HLS ('96-hls') and VP9 ('248-vp9')
      final f1080 = info.videoFormats.firstWhere((f) => f.formatId == '137-avc1');
      expect(f1080.needsAudioMerge, isTrue);
      expect(f1080.isDirectTurboSupported, isTrue);

      // 720p is progressive (needs no merge)
      final f720 = info.videoFormats.firstWhere((f) => f.formatId == '22');
      expect(f720.isProgressive, isTrue);
      expect(f720.needsAudioMerge, isFalse);

      // Audio tracks: original English first, then Arabic dubbed (m4a preferred), then French dubbed
      expect(info.audioTracks.length, 3);
      expect(info.audioTracks[0].isOriginal, isTrue);
      expect(info.audioTracks[0].language, 'en');
      expect(info.audioTracks[1].language, 'ar');
      expect(info.audioTracks[1].formatId, '140-ar-m4a');
      expect(info.audioTracks[1].isOriginal, isFalse);
      expect(info.audioTracks[2].language, 'fr');

      // Subtitles: manual ar, manual en, then auto ar (vtt preferred over srt/srv1)
      expect(info.subtitleTracks.length, 3);
      expect(info.subtitleTracks[0].language, 'ar');
      expect(info.subtitleTracks[0].isAutoGenerated, isFalse);
      expect(info.subtitleTracks[0].ext, 'vtt');
      expect(info.subtitleTracks[1].language, 'en');
      expect(info.subtitleTracks[1].isAutoGenerated, isFalse);
      expect(info.subtitleTracks[2].isAutoGenerated, isTrue);
    });

    test('parses playlist JSON into playlistEntries and identifies HLS formats', () {
      final playlistJson = jsonEncode(<String, Object?>{
        '_type': 'playlist',
        'id': 'PL_123',
        'title': 'Course Playlist',
        'webpage_url': 'https://www.youtube.com/playlist?list=PL_123',
        'entries': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'ep1',
            'title': 'Episode 1',
            'formats': <Map<String, Object?>>[
              <String, Object?>{
                'format_id': 'hls-1080',
                'height': 1080,
                'ext': 'mp4',
                'vcodec': 'avc1',
                'acodec': 'mp4a.40.2',
                'protocol': 'm3u8',
                'url': 'https://cdn.example.com/ep1/master.m3u8',
              },
            ],
          },
          <String, Object?>{
            'id': 'ep2',
            'title': 'Episode 2',
            'formats': <Map<String, Object?>>[
              <String, Object?>{
                'format_id': 'dir-720',
                'height': 720,
                'ext': 'mp4',
                'vcodec': 'avc1',
                'acodec': 'mp4a.40.2',
                'url': 'https://cdn.example.com/ep2/720.mp4',
              },
            ],
          },
        ],
      });

      final info = ranker.parseJsonString(playlistJson);
      expect(info.isPlaylist, isTrue);
      expect(info.playlistEntries.length, 2);
      expect(info.playlistEntries[0].videoFormats.first.isHlsOrDash, isTrue);
      expect(info.playlistEntries[0].videoFormats.first.isDirectTurboSupported, isFalse);
      expect(info.playlistEntries[1].videoFormats.first.isDirectTurboSupported, isTrue);
    });
  });
}
