import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/media_store_channel.dart';
import 'package:faqih_downloader_mobile/platform/native_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(ChannelNames.mediaStore);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  group('MediaStoreChannel', () {
    test('returns app work dir, exports to Downloads, and opens files', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'getAppWorkDir':
            return '/data/user/0/com.faqihdownloader.mobile/files/downloads_work';
          case 'exportToDownloads':
            return <String, Object?>{
              'uri': 'content://media/external/downloads/99',
              'displayPath': 'Download/FaqihDownloader/Video/clip.mp4',
              'sizeBytes': 2048000,
            };
          case 'openFile':
            return true;
        }
        return null;
      });

      final channel = MediaStoreChannel(methodChannel: methodChannel);

      final workDir = await channel.getAppWorkDir();
      expect(workDir, endsWith('/downloads_work'));

      final exported = await channel.exportToDownloads(
        sourcePath: '$workDir/clip.mp4',
        displayName: 'clip.mp4',
        mimeType: 'video/mp4',
        subFolder: 'Video',
        deleteSource: true,
      );
      expect(exported.uri, 'content://media/external/downloads/99');
      expect(exported.displayPath, 'Download/FaqihDownloader/Video/clip.mp4');
      expect(exported.sizeBytes, 2048000);

      final opened = await channel.openFile(
        pathOrUri: exported.uri,
        mimeType: 'video/mp4',
      );
      expect(opened, isTrue);

      final exportArgs = calls[1].arguments as Map<Object?, Object?>;
      expect(exportArgs['subFolder'], 'Video');
      expect(exportArgs['deleteSource'], isTrue);
    });

    test('wraps PlatformException into NativeBridgeException', () async {
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        throw PlatformException(
          code: 'MEDIA_STORE_ERROR',
          message: 'Permission denied',
        );
      });

      final channel = MediaStoreChannel(methodChannel: methodChannel);
      await expectLater(
        channel.exportToDownloads(
          sourcePath: '/tmp/a.mp4',
          displayName: 'a.mp4',
          mimeType: 'video/mp4',
        ),
        throwsA(
          isA<NativeBridgeException>()
              .having((e) => e.code, 'code', 'MEDIA_STORE_ERROR'),
        ),
      );
    });
  });
}
