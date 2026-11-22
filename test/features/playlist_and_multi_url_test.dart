import 'package:faqih_downloader_mobile/app/faqih_app.dart';
import 'package:faqih_downloader_mobile/core/config/app_constants.dart';
import 'package:faqih_downloader_mobile/core/config/app_settings.dart';
import 'package:faqih_downloader_mobile/core/i18n/translator.dart';
import 'package:faqih_downloader_mobile/core/models/audio_track.dart';
import 'package:faqih_downloader_mobile/core/models/subtitle_track.dart';
import 'package:faqih_downloader_mobile/core/models/video_format_option.dart';
import 'package:faqih_downloader_mobile/core/models/youtube_stream_info.dart';
import 'package:faqih_downloader_mobile/features/home/clipboard_banner.dart';
import 'package:faqih_downloader_mobile/features/media_sheet/media_options_sheet.dart';
import 'package:faqih_downloader_mobile/features/media_sheet/playlist_picker_sheet.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_job_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('PlaylistPickerSheet selects items, toggles all/none, and returns PlaylistPickerResult', (tester) async {
    final translator = AppTranslator(initialLanguage: 'en');
    const info = YouTubeStreamInfo(
      videoId: 'pl_1',
      title: 'Dart & Flutter Series',
      cleanFilename: 'Dart & Flutter Series',
      isProgressive: true,
      videoUrl: 'https://www.youtube.com/playlist?list=PL123',
      isPlaylist: true,
      playlistEntries: <YouTubeStreamInfo>[
        YouTubeStreamInfo(
          videoId: 'v1',
          title: 'Episode 1',
          cleanFilename: 'Episode 1.mp4',
          isProgressive: true,
          videoUrl: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
          webpageUrl: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
          durationSec: 120,
        ),
        YouTubeStreamInfo(
          videoId: 'v2',
          title: 'Episode 2',
          cleanFilename: 'Episode 2.mp4',
          isProgressive: true,
          videoUrl: 'https://www.youtube.com/watch?v=bbbbbbbbbbb',
          webpageUrl: 'https://www.youtube.com/watch?v=bbbbbbbbbbb',
          durationSec: 240,
        ),
      ],
    );

    PlaylistPickerResult? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                captured = await showModalBottomSheet<PlaylistPickerResult>(
                  context: ctx,
                  isScrollControlled: true,
                  builder: (_) => PlaylistPickerSheet(playlistInfo: info, translator: translator),
                );
              },
              child: const Text('OpenPlaylist'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('OpenPlaylist'));
    await tester.pumpAndSettle();

    // Deselect first item and verify only second item is staged:
    await tester.tap(find.byKey(const Key('playlist_item_0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('playlist_stage_selected')));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.action, PlaylistSheetAction.stageSelected);
    expect(captured!.selectedUrls, ['https://www.youtube.com/watch?v=bbbbbbbbbbb']);
    expect(captured!.selectedItems.single.title, 'Episode 2');
    expect(captured!.selectedItems.single.durationSec, 240);
  });

  testWidgets('HomeShellScreen stages multi-URL batch paste cleanly into Staged tab', (tester) async {
    final translator = AppTranslator(initialLanguage: 'en');
    await tester.pumpWidget(FaqihDownloaderApp(translator: translator));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('url_input_field')),
      'https://cdn.example.com/a.zip\nhttps://cdn.example.com/b.pdf https://cdn.example.com/c.mp4',
    );
    await tester.tap(find.byKey(const Key('url_submit_button')));
    await tester.pumpAndSettle();

    expect(find.text('https://cdn.example.com/a.zip'), findsOneWidget);
    expect(find.text('https://cdn.example.com/b.pdf'), findsOneWidget);
    expect(find.text('https://cdn.example.com/c.mp4'), findsOneWidget);
  });

  testWidgets('MediaOptionsSheet preselects AppSettings defaults and allows picking external subtitle', (tester) async {
    final translator = AppTranslator(initialLanguage: 'en');
    const settings = AppSettings(
      preferredVideoHeight: 720,
      preferredAudioLang: 'ar',
      preferredSubtitleLang: 'en',
      subtitleEmbedMode: AppConstants.subtitleModeHardBurn,
      subtitlePosition: 'top',
      subtitleFontSize: 26,
    );
    const info = YouTubeStreamInfo(
      videoId: 'v9',
      title: 'Lecture',
      cleanFilename: 'Lecture.mp4',
      isProgressive: false,
      videoUrl: 'https://cdn.example.com/720.mp4',
      videoFormats: <VideoFormatOption>[
        VideoFormatOption(formatId: '137', resolutionLabel: '1080p', height: 1080, ext: 'mp4', videoUrl: 'u1080'),
        VideoFormatOption(formatId: '136', resolutionLabel: '720p', height: 720, ext: 'mp4', videoUrl: 'u720'),
      ],
      audioTracks: <AudioTrack>[
        AudioTrack(trackId: 'en', formatId: '140', language: 'en', label: 'EN', url: 'a_en', isOriginal: true),
        AudioTrack(trackId: 'ar', formatId: '140-ar', language: 'ar', label: 'AR', url: 'a_ar', isOriginal: false),
      ],
      subtitleTracks: <SubtitleTrack>[
        SubtitleTrack(subId: 'en', language: 'en', label: 'English', url: 's_en'),
      ],
    );

    MediaSheetResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                result = await showModalBottomSheet<MediaSheetResult>(
                  context: ctx,
                  isScrollControlled: true,
                  builder: (_) => MediaOptionsSheet(
                    streamInfo: info,
                    translator: translator,
                    settings: settings,
                    enableVideoPlayerPreview: false,
                    onPickExternalSubtitle: () async => const SubtitleTrack(
                      subId: 'ext_99',
                      language: 'ar',
                      label: 'custom_ar.srt',
                      url: '/work/custom_ar.srt',
                      isExternal: true,
                      localPath: '/work/custom_ar.srt',
                    ),
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

    final sheetScroll = find.descendant(
      of: find.byType(MediaOptionsSheet),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('pick_external_subtitle_btn')),
      120,
      scrollable: sheetScroll.first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('pick_external_subtitle_btn'))),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick_external_subtitle_btn')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('sheet_download_button')),
      120,
      scrollable: sheetScroll.first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('sheet_download_button'))),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sheet_download_button')));
    await tester.pumpAndSettle();

    expect(result?.request?.selectedVideoFormat?.formatId, '136');
    expect(result?.request?.selectedAudioTrack?.language, 'ar');
    expect(result?.request?.selectedSubtitle?.subId, 'ext_99');
    expect(result?.request?.selectedSubtitle?.isExternal, isTrue);
    expect(result?.request?.subtitleMode, SubtitleMode.hardBurn);
    expect(result?.request?.subtitlePosition, 'top');
    expect(result?.request?.subtitleFontSize, 26);
  });

  testWidgets('ClipboardSnifferBanner triggers analyze, stage, and dismiss', (tester) async {
    final translator = AppTranslator(initialLanguage: 'en');
    var analyzed = false;
    var staged = false;
    var dismissed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClipboardSnifferBanner(
            translator: translator,
            detectedUrl: 'https://youtu.be/dQw4w9WgXcQ',
            onAnalyze: () => analyzed = true,
            onStage: () => staged = true,
            onDismiss: () => dismissed = true,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('sniffer_analyze_btn')));
    await tester.tap(find.byKey(const Key('sniffer_stage_btn')));
    await tester.tap(find.byKey(const Key('sniffer_dismiss_btn')));
    expect(analyzed, isTrue);
    expect(staged, isTrue);
    expect(dismissed, isTrue);
  });
}
