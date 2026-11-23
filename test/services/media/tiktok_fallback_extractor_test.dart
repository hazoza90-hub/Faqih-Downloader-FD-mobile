import 'dart:convert';
import 'dart:io';

import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
import 'package:faqih_downloader_mobile/services/media/media_extractor_service.dart';
import 'package:faqih_downloader_mobile/services/media/tiktok_fallback_extractor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttpOverrides extends HttpOverrides {}

HttpClient _realHttpClient() => _RealHttpOverrides().createHttpClient(null);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ytdlMethod = MethodChannel(ChannelNames.youtubeDl);
  const ytdlEvents = EventChannel(ChannelNames.youtubeDlEvents);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(ytdlMethod, null);
    messenger.setMockStreamHandler(ytdlEvents, null);
  });

  group('TikTokFallbackExtractor & cookie retry', () {
    test('extracts __UNIVERSAL_DATA_FOR_REHYDRATION__ with redirects & cookies', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final base = 'http://127.0.0.1:${server.port}';

      server.listen((req) async {
        if (req.uri.path == '/short') {
          req.response.statusCode = HttpStatus.movedTemporarily;
          req.response.cookies.add(Cookie('tt_webid', 'cookie_xyz_77'));
          req.response.headers.set(HttpHeaders.locationHeader, '/@demo/video/987654');
          await req.response.close();
          return;
        }
        final stateJson = jsonEncode(<String, dynamic>{
          '__DEFAULT_SCOPE__': <String, dynamic>{
            'webapp.video-detail': <String, dynamic>{
              'itemInfo': <String, dynamic>{
                'itemStruct': <String, dynamic>{
                  'id': '987654',
                  'desc': 'Sunset Over Nile',
                  'author': <String, dynamic>{'nickname': 'Tester'},
                  'video': <String, dynamic>{
                    'duration': 42,
                    'width': 1080,
                    'height': 1920,
                    'cover': '$base/thumb.jpg',
                    'bitrateInfo': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'GearName': 'normal_1080_0',
                        'Width': 1080,
                        'Height': 1920,
                        'Bitrate': 1800000,
                        'CodecType': 'h264',
                        'PlayAddr': <String, dynamic>{
                          'DataSize': 4500000,
                          'UrlList': <String>['$base/stream_1080.mp4'],
                        },
                      },
                      <String, dynamic>{
                        'GearName': 'lowest_720_0',
                        'Width': 720,
                        'Height': 1280,
                        'Bitrate': 800000,
                        'CodecType': 'h264',
                        'PlayAddr': <String, dynamic>{
                          'DataSize': 2100000,
                          'UrlList': <String>['$base/stream_720.mp4'],
                        },
                      },
                    ],
                    'claInfo': <String, dynamic>{
                      'captionInfos': <Map<String, dynamic>>[
                        <String, dynamic>{'language': 'ar', 'url': '$base/ar.vtt'},
                      ],
                    },
                  },
                  'music': <String, dynamic>{'playUrl': '$base/sound.mp3'},
                },
              },
            },
          },
        });
        req.response.headers.contentType = ContentType.html;
        req.response.write(
          '<html><head><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">$stateJson</script></head></html>',
        );
        await req.response.close();
      });

      final extractor = TikTokFallbackExtractor(
        httpClientFactory: _realHttpClient,
        tikwmBaseUrl: base,
      );
      final info = await extractor.extract('$base/short');

      expect(info, isNotNull);
      expect(info!.title, 'Sunset Over Nile');
      expect(info.durationSec, 42);
      expect(info.videoFormats.length, greaterThanOrEqualTo(2));
      expect(info.videoFormats.first.videoUrl, '$base/stream_1080.mp4');
      expect(info.videoFormats.first.videoHeaders['Cookie'], contains('tt_webid=cookie_xyz_77'));
      expect(info.audioTracks.single.url, '$base/sound.mp3');
      expect(info.subtitleTracks.single.language, 'ar');
    });

    test('falls back to TikWM API when direct TikTok HTML has no video state', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final base = 'http://127.0.0.1:${server.port}';

      server.listen((req) async {
        if (req.uri.path == '/api/') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, dynamic>{
            'code': 0,
            'data': <String, dynamic>{
              'id': '777',
              'title': 'TikWM Clip',
              'duration': 19,
              'origin_cover': '/covers/777.jpg',
              'hdplay': '/video/hd_777.mp4',
              'play': '$base/video/sd_777.mp4',
              'wmplay': '$base/video/wm_777.mp4',
              'music': '/audio/777.mp3',
            },
          }));
          await req.response.close();
          return;
        }
        req.response.headers.contentType = ContentType.html;
        req.response.write('<html><body>blocked challenge</body></html>');
        await req.response.close();
      });

      final extractor = TikTokFallbackExtractor(
        httpClientFactory: _realHttpClient,
        tikwmBaseUrl: base,
      );
      final info = await extractor.extract('$base/video/777');

      expect(info, isNotNull);
      expect(info!.title, 'TikWM Clip');
      expect(info.thumbnailUrl, '$base/covers/777.jpg');
      expect(info.videoFormats.first.videoUrl, '$base/video/hd_777.mp4');
      expect(info.videoFormats.any((f) => f.videoUrl == '$base/video/sd_777.mp4'), isTrue);
      expect(info.audioTracks.single.url, '$base/audio/777.mp3');
    });

    test('MediaExtractorService uses TikTokFallbackExtractor when yt-dlp fails and retries cookies per platform', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final base = 'http://127.0.0.1:${server.port}';

      server.listen((req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{
            'id': 'tt1',
            'title': 'Recovered Clip',
            'duration': 15,
            'hdplay': '$base/clip_hd.mp4',
          },
        }));
        await req.response.close();
      });

      final calls = <String?>[];
      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'extractInfo') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          final cookieArg = args['cookiesFile'] as String?;
          calls.add(cookieArg);
          final url = args['url'].toString();
          if (url.contains('youtube.com')) {
            if (cookieArg == null) {
              throw PlatformException(code: 'YOUTUBEDL_ERROR', message: 'sign in required');
            }
            return jsonEncode(<String, dynamic>{
              'id': 'dQw4w9WgXcQ',
              'title': 'YT OK',
              'formats': <Map<String, dynamic>>[
                <String, dynamic>{
                  'format_id': '22',
                  'url': 'https://cdn.example.com/yt.mp4',
                  'ext': 'mp4',
                  'vcodec': 'avc1',
                  'acodec': 'mp4a',
                  'height': 720,
                },
              ],
            });
          }
          if (url.contains('instagram.com') && cookieArg != null) {
            throw PlatformException(code: 'YOUTUBEDL_ERROR', message: 'bad cookie');
          }
          if (url.contains('instagram.com')) {
            return jsonEncode(<String, dynamic>{
              'id': 'ig1',
              'title': 'IG OK',
              'formats': <Map<String, dynamic>>[
                <String, dynamic>{
                  'format_id': 'mp4',
                  'url': 'https://cdn.example.com/ig.mp4',
                  'ext': 'mp4',
                  'vcodec': 'avc1',
                  'acodec': 'mp4a',
                  'height': 720,
                },
              ],
            });
          }
          throw PlatformException(code: 'YOUTUBEDL_ERROR', message: 'TikTok 403');
        }
        return null;
      });
      messenger.setMockStreamHandler(ytdlEvents, MockStreamHandler.inline(onListen: (_, _) {}));

      final service = MediaExtractorService(
        channel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: ytdlEvents),
        tiktokFallback: TikTokFallbackExtractor(
          httpClientFactory: _realHttpClient,
          tikwmBaseUrl: base,
        ),
      );

      // 1. TikTok fallback recovery
      final ttInfo = await service.extractInfo('https://vt.tiktok.com/ZS999/');
      expect(ttInfo.title, 'Recovered Clip');
      expect(ttInfo.videoUrl, '$base/clip_hd.mp4');

      // 2. YouTube tries cookie-less first, then with cookies
      calls.clear();
      final ytInfo = await service.extractInfo(
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        cookiesFile: '/tmp/cookies.txt',
      );
      expect(ytInfo.title, 'YT OK');
      expect(calls, <String?>[null, '/tmp/cookies.txt']);

      // 3. Non-YouTube tries with cookies first, then falls back to cookie-less
      calls.clear();
      final igInfo = await service.extractInfo(
        'https://www.instagram.com/reel/abc123/',
        cookiesFile: '/tmp/cookies.txt',
      );
      expect(igInfo.title, 'IG OK');
      expect(calls, <String?>['/tmp/cookies.txt', null]);
    });
  });
}
