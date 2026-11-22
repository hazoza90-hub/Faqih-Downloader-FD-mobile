import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/cookies_channel.dart';
import 'package:faqih_downloader_mobile/platform/native_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ChannelNames.cookies);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('CookiesChannel', () {
    test('exports Netscape cookies count and clears cookies with file path', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'exportCookiesForUrls') return 7;
        if (call.method == 'clearAllCookies') return true;
        return null;
      });

      final cookies = CookiesChannel(methodChannel: channel);
      final count = await cookies.exportCookiesForUrls(
        urls: const <String>['https://www.youtube.com/', 'https://accounts.google.com/'],
        outputPath: '/data/user/0/app/files/cookies.txt',
      );
      expect(count, 7);

      final cleared = await cookies.clearAllCookies(
        cookiesFilePath: '/data/user/0/app/files/cookies.txt',
      );
      expect(cleared, isTrue);

      expect(calls[0].method, 'exportCookiesForUrls');
      final exportArgs = calls[0].arguments as Map<Object?, Object?>;
      expect((exportArgs['urls'] as List<Object?>).length, 2);
      expect(exportArgs['outputPath'], '/data/user/0/app/files/cookies.txt');

      expect(calls[1].method, 'clearAllCookies');
      expect((calls[1].arguments as Map<Object?, Object?>)['cookiesFilePath'],
          '/data/user/0/app/files/cookies.txt');
    });

    test('wraps PlatformException into NativeBridgeException', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'COOKIES_EXPORT_ERROR', message: 'Denied');
      });

      final cookies = CookiesChannel(methodChannel: channel);
      await expectLater(
        cookies.exportCookiesForUrls(urls: const <String>['https://youtube.com'], outputPath: '/tmp/c.txt'),
        throwsA(isA<NativeBridgeException>().having((e) => e.code, 'code', 'COOKIES_EXPORT_ERROR')),
      );
    });
  });
}
