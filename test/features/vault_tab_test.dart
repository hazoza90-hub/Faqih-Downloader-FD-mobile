import 'package:faqih_downloader_mobile/core/i18n/translator.dart';
import 'package:faqih_downloader_mobile/core/models/download_status.dart';
import 'package:faqih_downloader_mobile/core/models/history_entry.dart';
import 'package:faqih_downloader_mobile/features/home/vault_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('VaultTab displays file path, shares, and confirms delete history vs with file', (tester) async {
    final translator = AppTranslator(initialLanguage: 'en');
    final entry = HistoryEntry(
      id: 'item1',
      url: 'https://cdn.example.com/lesson.mp4',
      filename: 'Lesson 01.mp4',
      filePath: 'Download/FaqihDownloader/Video/Lesson 01.mp4',
      category: 'Video',
      totalSize: 2048000,
      downloadedBytes: 2048000,
      status: DownloadStatus.completed,
      createdAt: DateTime.utc(2026, 11, 22),
      contentUri: 'content://media/external/downloads/55',
    );

    String? sharedId;
    bool? deletedWithFile;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VaultTab(
            translator: translator,
            entries: <HistoryEntry>[entry],
            onOpenEntry: (_) {},
            onShareEntry: (e) => sharedId = e.id,
            onRetryEntry: (_) {},
            onDeleteEntry: (_, {required deleteFile}) => deletedWithFile = deleteFile,
          ),
        ),
      ),
    );

    expect(find.text('Download/FaqihDownloader/Video/Lesson 01.mp4'), findsOneWidget);

    await tester.tap(find.byKey(const Key('vault_share_item1')));
    expect(sharedId, 'item1');

    // Delete history only:
    await tester.tap(find.byKey(const Key('vault_delete_item1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('vault_del_history_item1')));
    await tester.pumpAndSettle();
    expect(deletedWithFile, isFalse);

    // Delete with file:
    await tester.tap(find.byKey(const Key('vault_delete_item1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('vault_del_both_item1')));
    await tester.pumpAndSettle();
    expect(deletedWithFile, isTrue);
  });
}
