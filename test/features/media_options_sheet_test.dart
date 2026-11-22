import 'package:faqih_downloader_mobile/core/i18n/translator.dart';
import 'package:faqih_downloader_mobile/core/models/audio_track.dart';
import 'package:faqih_downloader_mobile/core/models/clip_range.dart';
import 'package:faqih_downloader_mobile/core/models/subtitle_track.dart';
import 'package:faqih_downloader_mobile/core/models/video_format_option.dart';
import 'package:faqih_downloader_mobile/core/models/youtube_stream_info.dart';
import 'package:faqih_downloader_mobile/features/media_sheet/clipper_studio_sheet.dart';
import 'package:faqih_downloader_mobile/features/media_sheet/media_options_sheet.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_job_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('MediaOptionsSheet selects quality, Arabic dubbing, hardBurn subtitle, and returns DownloadJobRequest', (tester) async {
    final translator = AppTranslator(initialLanguage: 'en');
    const info = YouTubeStreamInfo(
      videoId: 'v123',
      title: 'Deep Dive Course',
      cleanFilename: 'Deep Dive Course.mp4',
      isProgressive: false,
      videoUrl: 'https://cdn.example.com/1080.mp4',
      durationSec: 120,
      videoFormats: <VideoFormatOption>[
        VideoFormatOption(
          formatId: '313',
          resolutionLabel: '2160p (4K)',
          height: 2160,
          ext: 'mp4',
          filesizeApprox: 500000000,
          videoUrl: 'https://cdn.example.com/2160.mp4',
        ),
        VideoFormatOption(
          formatId: '137',
          resolutionLabel: '1080p',
          height: 1080,
          ext: 'mp4',
          filesizeApprox: 150000000,
          videoUrl: 'https://cdn.example.com/1080.mp4',
        ),
      ],
      audioTracks: <AudioTrack>[
        AudioTrack(
          trackId: 'en_orig',
          formatId: '140-en',
          language: 'en',
          label: 'English (Original)',
          url: 'https://cdn.example.com/en.m4a',
          bitrateKbps: 128,
          isOriginal: true,
        ),
        AudioTrack(
          trackId: 'ar_dub',
          formatId: '140-ar',
          language: 'ar',
          label: 'Arabic (Dubbed)',
          url: 'https://cdn.example.com/ar.m4a',
          bitrateKbps: 128,
          isOriginal: false,
        ),
      ],
      subtitleTracks: <SubtitleTrack>[
        SubtitleTrack(
          subId: 'sub_ar',
          language: 'ar',
          label: 'Arabic',
          url: 'https://cdn.example.com/ar.vtt',
        ),
      ],
    );

    MediaSheetResult? captured;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                captured = await showModalBottomSheet<MediaSheetResult>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => MediaOptionsSheet(
                    streamInfo: info,
                    translator: translator,
                    enableVideoPlayerPreview: false,
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('quality_opt_137')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('audio_track_ar_dub')));
    await tester.tap(find.byKey(const Key('audio_track_ar_dub')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('sub_track_sub_ar')));
    await tester.tap(find.byKey(const Key('sub_track_sub_ar')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('sub_mode_hard')));
    await tester.tap(find.byKey(const Key('sub_mode_hard')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('sheet_download_button')));
    await tester.tap(find.byKey(const Key('sheet_download_button')));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.action, MediaSheetAction.startDownload);
    expect(captured!.request!.selectedVideoFormat!.formatId, '137');
    expect(captured!.request!.selectedAudioTrack!.language, 'ar');
    expect(captured!.request!.selectedAudioTrack!.isOriginal, isFalse);
    expect(captured!.request!.selectedSubtitle!.subId, 'sub_ar');
    expect(captured!.request!.subtitleMode, SubtitleMode.hardBurn);
  });

  testWidgets('ClipperStudioSheet returns initial ClipRange cleanly in fallback mode', (tester) async {
    final translator = AppTranslator(initialLanguage: 'en');
    const info = YouTubeStreamInfo(
      videoId: 'v1',
      title: 'Clip Test',
      cleanFilename: 'Clip Test.mp4',
      isProgressive: true,
      videoUrl: 'https://cdn.example.com/v.mp4',
      durationSec: 100,
    );

    ClipRange? clipped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                clipped = await showModalBottomSheet<ClipRange?>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => ClipperStudioSheet(
                    streamInfo: info,
                    translator: translator,
                    initialRange: const ClipRange(startSec: 15, endSec: 60),
                    enableVideoPlayer: false,
                  ),
                );
              },
              child: const Text('OpenClipper'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('OpenClipper'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clipper_apply_button')));
    await tester.pumpAndSettle();

    expect(clipped, equals(const ClipRange(startSec: 15, endSec: 60)));
  });
}
