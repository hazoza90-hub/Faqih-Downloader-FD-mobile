import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/i18n/translator.dart';
import '../../core/models/clip_range.dart';
import '../../core/models/youtube_stream_info.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/size_formatter.dart';

/// Explicit wrapper so cancelling returns `null` while applying Reset returns `ClipperResult(range: null)`.
class ClipperResult {
  const ClipperResult({this.range});

  final ClipRange? range;
}

/// Interactive video preview and dual-handle range trimming sheet.
class ClipperStudioSheet extends StatefulWidget {
  const ClipperStudioSheet({
    super.key,
    required this.streamInfo,
    required this.translator,
    this.initialRange,
    this.enableVideoPlayer = true,
  });

  final YouTubeStreamInfo streamInfo;
  final AppTranslator translator;
  final ClipRange? initialRange;
  final bool enableVideoPlayer;

  @override
  State<ClipperStudioSheet> createState() => _ClipperStudioSheetState();
}

class _ClipperStudioSheetState extends State<ClipperStudioSheet> {
  VideoPlayerController? _videoController;
  bool _previewReady = false;
  bool _previewFailed = false;
  bool _isMuted = false;
  late double _maxSec;
  late double _startSec;
  late double _endSec;

  @override
  void initState() {
    super.initState();
    _maxSec = widget.streamInfo.durationSec > 0
        ? math.max(1.0, widget.streamInfo.durationSec.toDouble())
        : 120.0;
    final rawStart = widget.initialRange?.startSec ?? 0.0;
    final maxStartBound = math.max(0.0, _maxSec - 1.0);
    _startSec = rawStart.clamp(0.0, maxStartBound);
    final minEndBound = math.min(_maxSec, _startSec + 1.0);
    final rawEnd = (widget.initialRange?.endSec ?? 0.0) > rawStart
        ? widget.initialRange!.endSec.clamp(minEndBound, _maxSec)
        : _maxSec;
    _endSec = rawEnd.clamp(minEndBound, _maxSec);

    if (widget.enableVideoPlayer && widget.streamInfo.videoUrl.isNotEmpty) {
      unawaited(_initPlayer());
    } else {
      _previewFailed = true;
    }
  }

  Future<void> _initPlayer() async {
    try {
      final ctrl = VideoPlayerController.networkUrl(
        Uri.parse(widget.streamInfo.videoUrl),
        httpHeaders: widget.streamInfo.videoHeaders,
      );
      _videoController = ctrl;
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      final dur = ctrl.value.duration.inSeconds.toDouble();
      if (dur > 1.0 && widget.streamInfo.durationSec <= 0) {
        _maxSec = math.max(1.0, dur);
        final maxStartBound = math.max(0.0, _maxSec - 1.0);
        _startSec = _startSec.clamp(0.0, maxStartBound);
        final minEndBound = math.min(_maxSec, _startSec + 1.0);
        _endSec = (_endSec > _maxSec || _endSec == 120.0)
            ? _maxSec
            : _endSec.clamp(minEndBound, _maxSec);
      }
      setState(() => _previewReady = true);
    } catch (_) {
      if (mounted) setState(() => _previewFailed = true);
    }
  }

  @override
  void dispose() {
    unawaited(_videoController?.dispose());
    super.dispose();
  }

  void _setStartFromCurrent() {
    final pos = _videoController?.value.position.inSeconds.toDouble() ?? _startSec;
    final maxStart = math.max(0.0, _endSec - 1.0);
    setState(() {
      _startSec = pos.clamp(0.0, maxStart);
    });
  }

  void _setEndFromCurrent() {
    final pos = _videoController?.value.position.inSeconds.toDouble() ?? _endSec;
    final minEnd = math.min(_maxSec, _startSec + 1.0);
    setState(() {
      _endSec = pos.clamp(minEnd, _maxSec);
    });
  }

  void _resetRange() {
    setState(() {
      _startSec = 0.0;
      _endSec = _maxSec;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.translator.tr;
    final ctrl = _videoController;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                tr('clipper_title'),
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Theme.of(context).dividerColor),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _previewReady && ctrl != null
                      ? VideoPlayer(ctrl)
                      : Center(
                          child: _previewFailed
                              ? Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    tr('clipper_preview_unavailable'),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                )
                              : const CircularProgressIndicator(),
                        ),
                ),
              ),
              if (_previewReady && ctrl != null) ...<Widget>[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    IconButton(
                      tooltip: tr('btn_play'),
                      onPressed: () {
                        setState(() {
                          if (ctrl.value.isPlaying) {
                            ctrl.pause();
                          } else {
                            ctrl.play();
                          }
                        });
                      },
                      icon: Icon(
                        ctrl.value.isPlaying
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_fill_rounded,
                        size: 32,
                        color: AppColors.accent,
                      ),
                    ),
                    IconButton(
                      tooltip: tr('btn_mute'),
                      onPressed: () {
                        setState(() {
                          _isMuted = !_isMuted;
                          ctrl.setVolume(_isMuted ? 0.0 : 1.0);
                        });
                      },
                      icon: Icon(
                        _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text(
                    tr('clipper_start', params: <String, String>{
                      'time': formatDuration(_startSec.round()),
                    }),
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  Text(
                    tr('clipper_end', params: <String, String>{
                      'time': formatDuration(_endSec.round()),
                    }),
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ],
              ),
              RangeSlider(
                key: const Key('clipper_range_slider'),
                min: 0.0,
                max: _maxSec,
                values: RangeValues(_startSec, _endSec),
                onChanged: (values) {
                  final maxStart = math.max(0.0, _maxSec - 1.0);
                  final nextStart = values.start.clamp(0.0, maxStart);
                  final minEnd = math.min(_maxSec, nextStart + 1.0);
                  final nextEnd = values.end <= minEnd
                      ? minEnd
                      : values.end.clamp(minEnd, _maxSec);
                  setState(() {
                    _startSec = nextStart;
                    _endSec = nextEnd;
                  });
                },
              ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: <Widget>[
                  OutlinedButton(
                    onPressed: _setStartFromCurrent,
                    child: Text(tr('clipper_set_start')),
                  ),
                  OutlinedButton(
                    onPressed: _setEndFromCurrent,
                    child: Text(tr('clipper_set_end')),
                  ),
                  TextButton(
                    key: const Key('clipper_reset_button'),
                    onPressed: _resetRange,
                    child: Text(tr('btn_reset')),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('clipper_cancel_button'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(tr('btn_cancel')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      key: const Key('clipper_apply_button'),
                      onPressed: () {
                        final isFull = _startSec <= 0.1 && (_maxSec - _endSec) <= 0.5;
                        Navigator.of(context).pop(
                          ClipperResult(
                            range: isFull
                                ? null
                                : ClipRange(startSec: _startSec, endSec: _endSec),
                          ),
                        );
                      },
                      child: Text(tr('btn_apply')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
