import 'package:flutter/material.dart';

import '../../core/i18n/translator.dart';
import '../../core/models/youtube_stream_info.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/size_formatter.dart';

enum PlaylistSheetAction { stageSelected, downloadSelected }

class PlaylistPickerResult {
  const PlaylistPickerResult({required this.action, required this.selectedItems});

  final PlaylistSheetAction action;
  final List<YouTubeStreamInfo> selectedItems;

  List<String> get selectedUrls => selectedItems
      .map((e) => e.webpageUrl.isNotEmpty ? e.webpageUrl : e.videoUrl)
      .where((u) => u.isNotEmpty)
      .toList(growable: false);
}

/// Interactive BottomSheet for multi-selecting items from an extracted playlist.
class PlaylistPickerSheet extends StatefulWidget {
  const PlaylistPickerSheet({
    super.key,
    required this.playlistInfo,
    required this.translator,
  });

  final YouTubeStreamInfo playlistInfo;
  final AppTranslator translator;

  @override
  State<PlaylistPickerSheet> createState() => _PlaylistPickerSheetState();
}

class _PlaylistPickerSheetState extends State<PlaylistPickerSheet> {
  late final Set<int> _selectedIndices;

  @override
  void initState() {
    super.initState();
    _selectedIndices = Set<int>.from(
      Iterable<int>.generate(widget.playlistInfo.playlistEntries.length),
    );
  }

  List<YouTubeStreamInfo> get _selectedItems {
    final entries = widget.playlistInfo.playlistEntries;
    final items = <YouTubeStreamInfo>[];
    for (var i = 0; i < entries.length; i++) {
      if (_selectedIndices.contains(i)) {
        final item = entries[i];
        final u = item.webpageUrl.isNotEmpty ? item.webpageUrl : item.videoUrl;
        if (u.isNotEmpty) items.add(item);
      }
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.translator.tr;
    final entries = widget.playlistInfo.playlistEntries;
    final selectedCount = _selectedIndices.length;

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.78,
        minChildSize: 0.45,
        maxChildSize: 0.94,
        builder: (context, scrollCtrl) => Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    widget.playlistInfo.title.isEmpty
                        ? tr('playlist_title')
                        : widget.playlistInfo.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          tr('playlist_count', params: <String, String>{'count': '${entries.length}'}),
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                        ),
                      ),
                      TextButton(
                        key: const Key('playlist_select_all'),
                        onPressed: () => setState(() {
                          _selectedIndices.addAll(Iterable<int>.generate(entries.length));
                        }),
                        child: Text(tr('btn_select_all')),
                      ),
                      TextButton(
                        key: const Key('playlist_deselect_all'),
                        onPressed: () => setState(_selectedIndices.clear),
                        child: Text(tr('btn_deselect_all')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final item = entries[index];
                  final checked = _selectedIndices.contains(index);
                  return CheckboxListTile(
                    key: Key('playlist_item_$index'),
                    value: checked,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selectedIndices.add(index);
                        } else {
                          _selectedIndices.remove(index);
                        }
                      });
                    },
                    title: Text(
                      item.title.isEmpty ? item.videoId : item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    subtitle: item.durationSec > 0
                        ? Text(
                            formatDuration(item.durationSec),
                            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                          )
                        : null,
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('playlist_stage_selected'),
                      onPressed: selectedCount == 0
                          ? null
                          : () => Navigator.of(context).pop(
                                PlaylistPickerResult(
                                  action: PlaylistSheetAction.stageSelected,
                                  selectedItems: _selectedItems,
                                ),
                              ),
                      child: Text(tr('btn_stage_selected', params: <String, String>{'count': '$selectedCount'})),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      key: const Key('playlist_download_selected'),
                      onPressed: selectedCount == 0
                          ? null
                          : () => Navigator.of(context).pop(
                                PlaylistPickerResult(
                                  action: PlaylistSheetAction.downloadSelected,
                                  selectedItems: _selectedItems,
                                ),
                              ),
                      child: Text(tr('btn_download_selected', params: <String, String>{'count': '$selectedCount'})),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
