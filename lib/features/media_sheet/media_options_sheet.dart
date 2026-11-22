import 'package:flutter/material.dart';

import '../../core/i18n/translator.dart';
import '../../core/models/audio_track.dart';
import '../../core/models/clip_range.dart';
import '../../core/models/subtitle_track.dart';
import '../../core/models/video_format_option.dart';
import '../../core/models/youtube_stream_info.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/size_formatter.dart';
import '../../services/coordinator/download_job_models.dart';
import 'clipper_studio_sheet.dart';
import 'media_track_selectors.dart';

enum MediaSheetAction { startDownload, stageForLater }

class MediaSheetResult {
  const MediaSheetResult({
    required this.action,
    required this.url,
    this.request,
  });

  final MediaSheetAction action;
  final String url;
  final DownloadJobRequest? request;
}

/// Interactive BottomSheet for choosing quality, dubbing track, subtitle mode, and clip range.
class MediaOptionsSheet extends StatefulWidget {
  const MediaOptionsSheet({
    super.key,
    required this.streamInfo,
    required this.translator,
    this.enableVideoPlayerPreview = true,
  });

  final YouTubeStreamInfo streamInfo;
  final AppTranslator translator;
  final bool enableVideoPlayerPreview;

  @override
  State<MediaOptionsSheet> createState() => _MediaOptionsSheetState();
}

class _MediaOptionsSheetState extends State<MediaOptionsSheet> {
  late bool _audioOnly;
  String _audioFormat = 'mp3';
  VideoFormatOption? _selectedFormat;
  AudioTrack? _selectedAudio;
  SubtitleTrack? _selectedSubtitle;
  SubtitleMode _subtitleMode = SubtitleMode.none;
  ClipRange? _clipRange;

  @override
  void initState() {
    super.initState();
    _audioOnly = widget.streamInfo.isAudioOnly || widget.streamInfo.videoFormats.isEmpty;
    if (widget.streamInfo.videoFormats.isNotEmpty) {
      _selectedFormat = widget.streamInfo.videoFormats.first;
    }
    _selectedAudio = widget.streamInfo.selectedAudioTrack ??
        (widget.streamInfo.audioTracks.isNotEmpty
            ? widget.streamInfo.audioTracks.first
            : null);
  }

  Future<void> _openClipper() async {
    final result = await showModalBottomSheet<ClipRange?>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ClipperStudioSheet(
        streamInfo: widget.streamInfo,
        translator: widget.translator,
        initialRange: _clipRange,
        enableVideoPlayer: widget.enableVideoPlayerPreview,
      ),
    );
    if (!mounted) return;
    if (result != null) {
      setState(() => _clipRange = result);
    }
  }

  void _submitStart() {
    final url = widget.streamInfo.webpageUrl.isNotEmpty
        ? widget.streamInfo.webpageUrl
        : widget.streamInfo.videoUrl;
    final req = DownloadJobRequest(
      id: 'media_${DateTime.now().millisecondsSinceEpoch}',
      url: url,
      title: widget.streamInfo.title,
      selectedVideoFormat: _audioOnly ? null : _selectedFormat,
      selectedAudioTrack: _selectedAudio,
      selectedSubtitle: _selectedSubtitle,
      subtitleMode: _selectedSubtitle == null ? SubtitleMode.none : _subtitleMode,
      audioOnly: _audioOnly,
      audioFormat: _audioFormat,
      clipRange: _clipRange,
      headers: widget.streamInfo.videoHeaders,
      platform: widget.streamInfo.platform,
      durationSec: widget.streamInfo.durationSec,
    );
    Navigator.of(context).pop(
      MediaSheetResult(
        action: MediaSheetAction.startDownload,
        url: url,
        request: req,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.translator.tr;
    final info = widget.streamInfo;
    final targetUrl =
        info.webpageUrl.isNotEmpty ? info.webpageUrl : info.videoUrl;

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollCtrl) => ListView(
          controller: scrollCtrl,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          children: <Widget>[
            _HeaderCard(info: info, translator: widget.translator),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: false,
                  icon: const Icon(Icons.videocam_outlined),
                  label: Text(tr('mode_video'), key: const Key('mode_video_chip')),
                ),
                ButtonSegment<bool>(
                  value: true,
                  icon: const Icon(Icons.music_note_outlined),
                  label: Text(tr('mode_audio_only'), key: const Key('mode_audio_chip')),
                ),
              ],
              selected: <bool>{_audioOnly},
              onSelectionChanged: (s) => setState(() => _audioOnly = s.first),
            ),
            if (_audioOnly) ...<Widget>[
              const SizedBox(height: 12),
              Text(tr('lbl_audio_format'), style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: <String>['mp3', 'm4a'].map((fmt) {
                  return ChoiceChip(
                    key: Key('audio_fmt_$fmt'),
                    label: Text(fmt.toUpperCase()),
                    selected: _audioFormat == fmt,
                    onSelected: (_) => setState(() => _audioFormat = fmt),
                  );
                }).toList(growable: false),
              ),
            ] else if (info.videoFormats.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(tr('lbl_quality'), style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              ...info.videoFormats.map((f) {
                final selected = _selectedFormat?.formatId == f.formatId;
                final totalSize = f.filesizeApprox +
                    (f.needsAudioMerge ? (_selectedAudio?.filesize ?? f.audioSize) : 0);
                final sizeStr = totalSize > 0
                    ? formatFileSize(totalSize)
                    : tr('lbl_unknown_size');
                final engineTag =
                    f.isDirectTurboSupported ? tr('badge_turbo') : tr('badge_ytdlp');
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Card(
                    color: selected ? AppColors.accent.withValues(alpha: 0.12) : null,
                    child: ListTile(
                      key: Key('quality_opt_${f.formatId}'),
                      dense: true,
                      leading: Icon(
                        selected ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: selected ? AppColors.accent : AppColors.textSecondary,
                      ),
                      title: Text(
                        '${f.resolutionLabel} • ${f.ext.toUpperCase()}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text('$sizeStr • $engineTag'),
                      onTap: () => setState(() => _selectedFormat = f),
                    ),
                  ),
                );
              }),
            ],
            MediaTrackSelectors(
              translator: widget.translator,
              audioTracks: info.audioTracks,
              selectedAudio: _selectedAudio,
              onAudioSelected: (a) => setState(() => _selectedAudio = a),
              subtitleTracks: info.subtitleTracks,
              selectedSubtitle: _selectedSubtitle,
              subtitleMode: _subtitleMode,
              audioOnly: _audioOnly,
              onSubtitleSelected: (s) {
                setState(() {
                  _selectedSubtitle = s;
                  if (s != null && _subtitleMode == SubtitleMode.none) {
                    _subtitleMode = SubtitleMode.softMux;
                  }
                });
              },
              onSubtitleModeChanged: (m) => setState(() => _subtitleMode = m),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('open_clipper_button'),
              onPressed: _openClipper,
              icon: const Icon(Icons.content_cut_rounded),
              label: Text(
                (_clipRange != null && _clipRange!.isActive)
                    ? tr('lbl_clip_range', params: <String, String>{
                        'start': formatDuration(_clipRange!.startSec.round()),
                        'end': formatDuration(_clipRange!.endSec.round()),
                      })
                    : tr('btn_video_preview_clip'),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    key: const Key('sheet_stage_button'),
                    onPressed: () => Navigator.of(context).pop(
                      MediaSheetResult(
                        action: MediaSheetAction.stageForLater,
                        url: targetUrl,
                      ),
                    ),
                    child: Text(tr('btn_stage_for_later')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    key: const Key('sheet_download_button'),
                    onPressed: _submitStart,
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: Text(tr('btn_start')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.info, required this.translator});
  final YouTubeStreamInfo info;
  final AppTranslator translator;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: info.thumbnailUrl.isNotEmpty
              ? Image.network(
                  info.thumbnailUrl,
                  width: 96,
                  height: 58,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _thumbPlaceholder(),
                )
              : _thumbPlaceholder(),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                info.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                '${info.platform} • ${formatDuration(info.durationSec)}',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _thumbPlaceholder() {
    return Container(
      width: 96,
      height: 58,
      color: AppColors.bgCard,
      child: const Icon(Icons.play_circle_outline, color: AppColors.accent),
    );
  }
}
