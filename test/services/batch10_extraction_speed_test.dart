import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:faqih_downloader_mobile/app/app_controller.dart';
import 'package:faqih_downloader_mobile/core/i18n/translator.dart';
import 'package:faqih_downloader_mobile/core/models/youtube_stream_info.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/youtube_dl_channel.dart';
import 'package:faqih_downloader_mobile/services/media/format_ranker.dart';
import 'package:faqih_downloader_mobile/services/media/media_exceptions.dart';
import 'package:faqih_downloader_mobile/services/media/media_extractor_service.dart';
import 'package:faqih_downloader_mobile/services/media/youtube_innertube_extractor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _NullInnerTubeExtractor extends YouTubeInnerTubeExtractor {
  _NullInnerTubeExtractor();
  int calls = 0;

  @override
  Future<YouTubeStreamInfo?> extract(
    String url, {
    void Function(void Function() aborter)? onRegisterAbort,
    int startProfileIndex = 0,
  }) async {
    calls++;
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ytdlMethod = MethodChannel(ChannelNames.youtubeDl);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(ytdlMethod, null));

  Future<T> runWithRealHttp<T>(Future<T> Function() fn) =>
      HttpOverrides.runZoned(fn, createHttpClient: (ctx) => _RealHttpOverrides().createHttpClient(ctx));

  group('Batch 10 extraction speed & resilience', () {
    test('1) YouTubeInnerTubeExtractor parses ANDROID_VR formats, dubbing, captions, and guards failures', () async {
      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        var mode = 'ok';
        Map<String, dynamic>? receivedBody;
        String? receivedClientName;

        server.listen((req) async {
          receivedClientName = req.headers.value('x-youtube-client-name');
          final raw = await utf8.decoder.bind(req).join();
          if (raw.isNotEmpty) {
            receivedBody = Map<String, dynamic>.from(jsonDecode(raw) as Map);
          }
          if (mode == 'error500') {
            req.response.statusCode = HttpStatus.internalServerError;
            await req.response.close();
            return;
          }
          if (mode == 'login_required') {
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode(<String, dynamic>{
              'playabilityStatus': <String, dynamic>{'status': 'LOGIN_REQUIRED'},
            }));
            await req.response.close();
            return;
          }
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, dynamic>{
            'playabilityStatus': <String, dynamic>{'status': 'OK'},
            'videoDetails': <String, dynamic>{
              'videoId': 'dQw4w9WgXcQ',
              'title': 'InnerTube VR Video',
              'lengthSeconds': '213',
              'thumbnail': <String, dynamic>{
                'thumbnails': <Map<String, dynamic>>[
                  <String, dynamic>{'url': 'https://i.ytimg.com/small.jpg', 'width': 120},
                  <String, dynamic>{'url': 'https://i.ytimg.com/max.jpg', 'width': 1280},
                ],
              },
            },
            'streamingData': <String, dynamic>{
              'formats': <Map<String, dynamic>>[
                <String, dynamic>{
                  'itag': 18,
                  'url': 'https://cdn.example.com/prog360.mp4',
                  'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
                  'width': 640,
                  'height': 360,
                  'fps': 30,
                  'bitrate': 500000,
                  'contentLength': '123456',
                  'qualityLabel': '360p',
                },
                <String, dynamic>{
                  'itag': 22,
                  'signatureCipher': 's=enc&sp=sig&url=https://blocked.example.com/cipher.mp4',
                  'mimeType': 'video/mp4; codecs="avc1.64001F, mp4a.40.2"',
                  'height': 720,
                },
              ],
              'adaptiveFormats': <Map<String, dynamic>>[
                <String, dynamic>{
                  'itag': 137,
                  'url': 'https://cdn.example.com/v1080.mp4',
                  'mimeType': 'video/mp4; codecs="avc1.640028"',
                  'width': 1920,
                  'height': 1080,
                  'fps': 60,
                  'bitrate': 4000000,
                  'contentLength': '999999',
                  'qualityLabel': '1080p60',
                },
                <String, dynamic>{
                  'itag': 140,
                  'url': 'https://cdn.example.com/audio_en.m4a',
                  'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                  'bitrate': 128000,
                  'contentLength': '33333',
                  'audioTrack': <String, dynamic>{
                    'id': 'en.4',
                    'displayName': 'English original',
                    'audioIsDefault': true,
                  },
                },
                <String, dynamic>{
                  'itag': 140,
                  'url': 'https://cdn.example.com/audio_ar.m4a',
                  'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                  'bitrate': 128000,
                  'contentLength': '33300',
                  'audioTrack': <String, dynamic>{
                    'id': 'ar.3',
                    'displayName': 'Arabic',
                    'audioIsDefault': false,
                  },
                },
              ],
            },
            'captions': <String, dynamic>{
              'playerCaptionsTracklistRenderer': <String, dynamic>{
                'captionTracks': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'baseUrl': 'https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&lang=ar',
                    'languageCode': 'ar',
                    'name': <String, dynamic>{'simpleText': 'Arabic'},
                  },
                  <String, dynamic>{
                    'baseUrl': 'https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&lang=en',
                    'languageCode': 'en',
                    'kind': 'asr',
                    'name': <String, dynamic>{
                      'runs': <Map<String, dynamic>>[
                        <String, dynamic>{'text': 'English (auto)'},
                      ],
                    },
                  },
                ],
              },
            },
          }));
          await req.response.close();
        });

        final extractor = YouTubeInnerTubeExtractor(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}/youtubei/v1/player'),
        );
        final ok = await extractor.extract('https://youtu.be/dQw4w9WgXcQ');
        expect(ok, isNotNull);
        expect(receivedClientName, '28');
        expect(receivedBody?['context']?['client']?['clientName'], 'ANDROID_VR');
        expect(ok!.title, 'InnerTube VR Video');
        expect(ok.durationSec, 213);
        expect(ok.thumbnailUrl, 'https://i.ytimg.com/max.jpg');
        expect(ok.videoFormats.any((f) => f.height == 720), isFalse);
        expect(ok.videoFormats.first.height, 1080);
        expect(ok.audioTracks.length, 2);
        expect(ok.audioTracks.any((a) => a.language == 'ar' && !a.isOriginal), isTrue);
        expect(ok.subtitleTracks.length, 2);
        expect(ok.subtitleTracks.first.url, contains('fmt=vtt'));

        expect(await extractor.extract('https://www.youtube.com/playlist?list=PL123456'), isNull);

        mode = 'login_required';
        expect(await extractor.extract('https://www.youtube.com/watch?v=dQw4w9WgXcQ'), isNull);

        mode = 'error500';
        expect(await extractor.extract('https://www.youtube.com/watch?v=dQw4w9WgXcQ'), isNull);
      });
    });

    test('2) MediaExtractorService prefers InnerTube and falls back with deduplicated cookie retry and 15s timeout', () async {
      await runWithRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, dynamic>{
            'playabilityStatus': <String, dynamic>{'status': 'OK'},
            'videoDetails': <String, dynamic>{'videoId': 'vidFast0001', 'title': 'Fast Video'},
            'streamingData': <String, dynamic>{
              'formats': <Map<String, dynamic>>[
                <String, dynamic>{
                  'itag': 18,
                  'url': 'https://cdn.example.com/fast.mp4',
                  'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
                  'height': 360,
                },
              ],
            },
          }));
          await req.response.close();
        });

        var ytdlCalls = 0;
        messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
          ytdlCalls++;
          return '{}';
        });

        final fastExtractor = MediaExtractorService(
          channel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: const EventChannel(ChannelNames.youtubeDlEvents)),
          innerTubeExtractor: YouTubeInnerTubeExtractor(
            endpoint: Uri.parse('http://127.0.0.1:${server.port}/player'),
          ),
        );
        final fastResult = await fastExtractor.extractInfo('https://www.youtube.com/watch?v=vidFast0001');
        expect(fastResult.title, 'Fast Video');
        expect(ytdlCalls, 0);
      });

      final seenCalls = <({String? strategy, String? cookies, int? timeout})>[];
      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'extractInfo') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          seenCalls.add((
            strategy: args['extractorArgs'] as String?,
            cookies: args['cookiesFile'] as String?,
            timeout: args['timeoutSeconds'] as int?,
          ));
          if (seenCalls.length < 4) {
            throw PlatformException(code: 'YOUTUBEDL_ERROR', message: 'HTTP Error 403: Forbidden');
          }
          return jsonEncode(<String, dynamic>{
            'id': 'yt_cookie_ok',
            'title': 'Fallback Cookie OK',
            'formats': <Map<String, dynamic>>[
              <String, dynamic>{
                'format_id': '18',
                'url': 'https://cdn.example.com/c.mp4',
                'ext': 'mp4',
                'vcodec': 'avc1',
                'acodec': 'mp4a',
                'height': 360,
              },
            ],
          });
        }
        return <String, Object?>{'status': 'ALREADY_UP_TO_DATE', 'ytdlpVersion': '2026.11.24'};
      });

      final fallbackExtractor = MediaExtractorService(
        channel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: const EventChannel(ChannelNames.youtubeDlEvents)),
        innerTubeExtractor: _NullInnerTubeExtractor(),
      );
      final recovered = await fallbackExtractor.extractInfo(
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        cookiesFile: '/tmp/cookies.txt',
      );
      expect(recovered.title, 'Fallback Cookie OK');
      expect(seenCalls.length, 4);
      expect(seenCalls.every((c) => c.timeout == 15), isTrue);
      expect(seenCalls.take(3).map((c) => c.strategy).toList(), <String?>[
        null,
        'youtube:player_client=ios,mweb',
        '',
      ]);
      expect(seenCalls.take(3).every((c) => c.cookies == null), isTrue);
      expect(seenCalls[3].cookies, '/tmp/cookies.txt');
      expect(seenCalls[3].strategy, 'youtube:player_client=mweb,web');
    });

    test('3) In-memory extraction cache hits immediately, expires after 3 minutes, and caps at 25 entries', () async {
      var now = DateTime(2026, 11, 24, 12, 0, 0);
      var ytdlCalls = 0;

      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'extractInfo') {
          ytdlCalls++;
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          final url = args['url'] as String;
          return jsonEncode(<String, dynamic>{
            'id': 'id_$ytdlCalls',
            'title': 'Video $ytdlCalls',
            'webpage_url': url,
            'formats': <Map<String, dynamic>>[
              <String, dynamic>{
                'format_id': '18',
                'url': 'https://cdn.example.com/$ytdlCalls.mp4',
                'ext': 'mp4',
                'vcodec': 'avc1',
                'acodec': 'mp4a',
                'height': 360,
              },
            ],
          });
        }
        return null;
      });

      final service = MediaExtractorService(
        channel: YoutubeDlChannel(methodChannel: ytdlMethod, eventChannel: const EventChannel(ChannelNames.youtubeDlEvents)),
        innerTubeExtractor: _NullInnerTubeExtractor(),
        clock: () => now,
      );

      final first = await service.extractInfo('https://vimeo.com/111111');
      final second = await service.extractInfo('https://vimeo.com/111111');
      expect(first.title, 'Video 1');
      expect(second.title, 'Video 1');
      expect(ytdlCalls, 1);

      now = now.add(const Duration(minutes: 3, seconds: 1));
      final third = await service.extractInfo('https://vimeo.com/111111');
      expect(third.title, 'Video 2');
      expect(ytdlCalls, 2);

      // Fill 25 more distinct URLs to evict https://vimeo.com/111111 from the 25-entry cache.
      for (var i = 0; i < 25; i++) {
        await service.extractInfo('https://vimeo.com/${200000 + i}');
      }
      expect(ytdlCalls, 27);
      await service.extractInfo('https://vimeo.com/111111');
      expect(ytdlCalls, 28);
    });

    test('4) FormatRanker resolves --flat-playlist bare IDs and relative URLs without emitting bogus stream URLs', () {
      const ranker = FormatRanker();
      final playlist = ranker.parse(<String, dynamic>{
        '_type': 'playlist',
        'id': 'PL_TEST_123',
        'title': 'Fast Playlist',
        'webpage_url': 'https://www.youtube.com/playlist?list=PL_TEST_123',
        'entries': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'dQw4w9WgXcQ',
            'url': 'dQw4w9WgXcQ',
            'title': 'Bare ID Video',
            'ie_key': 'Youtube',
          },
          <String, dynamic>{
            'id': '9bZkp7q19f0',
            'url': '/watch?v=9bZkp7q19f0',
            'title': 'Relative Url Video',
          },
        ],
      }, fallbackUrl: 'https://www.youtube.com/playlist?list=PL_TEST_123');

      expect(playlist.isPlaylist, isTrue);
      expect(playlist.playlistEntries.length, 2);
      expect(playlist.playlistEntries[0].webpageUrl, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      expect(playlist.playlistEntries[0].videoUrl, isEmpty);
      expect(playlist.playlistEntries[0].videoFormats, isEmpty);
      expect(playlist.playlistEntries[1].webpageUrl, 'https://www.youtube.com/watch?v=9bZkp7q19f0');
      expect(playlist.playlistEntries[1].videoUrl, isEmpty);
    });

    test('5) AppController shares one MediaExtractorService so cancelActiveExtraction cancels in-flight analyzeUrl', () async {
      final extractStarted = Completer<String>();
      final extractCompleter = Completer<String>();
      String? cancelledPid;

      messenger.setMockMethodCallHandler(ytdlMethod, (call) async {
        if (call.method == 'extractInfo') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          final pid = args['processId'] as String;
          if (!extractStarted.isCompleted) extractStarted.complete(pid);
          return extractCompleter.future;
        }
        if (call.method == 'cancelProcess') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          cancelledPid = args['processId'] as String?;
          if (!extractCompleter.isCompleted) {
            extractCompleter.completeError(
              PlatformException(code: 'CANCELLED', message: 'Process cancelled'),
            );
          }
          return true;
        }
        return null;
      });

      final controller = AppController(
        translator: AppTranslator(),
        youtubeDlChannel: YoutubeDlChannel(
          methodChannel: ytdlMethod,
          eventChannel: const EventChannel(ChannelNames.youtubeDlEvents),
        ),
        autoInitNative: false,
      );
      addTearDown(controller.dispose);

      final analyzeFuture = controller.analyzeUrl('https://vimeo.com/987654');
      final expectCancelled = expectLater(
        analyzeFuture,
        throwsA(
          isA<MediaExtractionException>().having(
            (e) => e.kind,
            'kind',
            MediaErrorKind.cancelled,
          ),
        ),
      );
      final activePid = await extractStarted.future;
      await controller.cancelActiveExtraction();

      expect(cancelledPid, activePid);
      await expectCancelled;
      expect(controller.isExtracting, isFalse);
    });
  });
}
