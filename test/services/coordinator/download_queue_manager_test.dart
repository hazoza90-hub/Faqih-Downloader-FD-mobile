import 'dart:async';
import 'dart:io';

import 'package:faqih_downloader_mobile/core/config/app_settings.dart';
import 'package:faqih_downloader_mobile/platform/channel_names.dart';
import 'package:faqih_downloader_mobile/platform/foreground_service_channel.dart';
import 'package:faqih_downloader_mobile/platform/media_store_channel.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_job_models.dart';
import 'package:faqih_downloader_mobile/services/coordinator/download_queue_manager.dart';
import 'package:faqih_downloader_mobile/services/coordinator/stream_download_coordinator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _ControlledCoordinator extends StreamDownloadCoordinator {
  _ControlledCoordinator({
    required super.request,
    required this.onEmit,
    required Directory workDir,
    required MethodChannel mediaStoreMethod,
  })  : _workDir = workDir,
        _onEmit = onEmit,
        super(
          mediaStoreChannel: MediaStoreChannel(methodChannel: mediaStoreMethod),
        );

  final Directory _workDir;
  final void Function(DownloadJobState state) onEmit;
  final void Function(DownloadJobState state) _onEmit;
  final Completer<void> started = Completer<void>();
  final Completer<void> finishGate = Completer<void>();
  bool paused = false;
  bool cancelled = false;

  @override
  Future<DownloadJobState> start() async {
    if (!started.isCompleted) started.complete();
    _onEmit(state.copyWith(
      phase: DownloadPhase.downloadingDirect,
      progress: 0.4,
      speedBytesPerSec: 1024 * 1024,
    ));
    await finishGate.future;
    if (cancelled) {
      final c = state.copyWith(phase: DownloadPhase.cancelled);
      _onEmit(c);
      return c;
    }
    final done = state.copyWith(
      phase: DownloadPhase.completed,
      progress: 1.0,
      downloadedBytes: 1000,
      totalBytes: 1000,
      exportedUri: 'content://downloads/${request.id}',
      exportedDisplayPath: '${_workDir.path}/${request.title}.mp4',
    );
    _onEmit(done);
    return done;
  }

  @override
  Future<void> pause() async {
    paused = true;
    _onEmit(state.copyWith(phase: DownloadPhase.paused, speedBytesPerSec: 0.0));
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (!finishGate.isCompleted) finishGate.complete();
    _onEmit(state.copyWith(phase: DownloadPhase.cancelled));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fgMethod = MethodChannel(ChannelNames.foregroundService);
  const fgEvents = EventChannel(ChannelNames.serviceEvents);
  const mediaStoreMethod = MethodChannel(ChannelNames.mediaStore);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fd_queue_test_');
    messenger.setMockMethodCallHandler(mediaStoreMethod, (call) async {
      if (call.method == 'getAppWorkDir') return tempDir.path;
      return null;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(fgMethod, null);
    messenger.setMockStreamHandler(fgEvents, null);
    messenger.setMockMethodCallHandler(mediaStoreMethod, null);
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('DownloadQueueManager', () {
    test('enforces maxConcurrentDownloads, manages ForegroundService, and reacts to notification actions', () async {
      final fgMethodsCalled = <String>[];
      final coords = <String, _ControlledCoordinator>{};
      late EventChannelSinkHolder actionEmitter;

      messenger.setMockMethodCallHandler(fgMethod, (call) async {
        fgMethodsCalled.add(call.method);
        return true;
      });

      actionEmitter = EventChannelSinkHolder();
      messenger.setMockStreamHandler(
        fgEvents,
        MockStreamHandler.inline(
          onListen: (_, events) => actionEmitter.sink = events,
          onCancel: (_) => actionEmitter.sink = null,
        ),
      );

      final manager = DownloadQueueManager(
        settings: const AppSettings(maxConcurrentDownloads: 2),
        progressThrottleMs: 0,
        pauseLabel: 'إيقاف الكل',
        cancelLabel: 'إلغاء الكل',
        foregroundService: ForegroundServiceChannel(
          methodChannel: fgMethod,
          eventChannel: fgEvents,
        ),
        coordinatorFactory: (req, {required onStateChanged}) {
          final c = _ControlledCoordinator(
            request: req,
            onEmit: onStateChanged,
            workDir: tempDir,
            mediaStoreMethod: mediaStoreMethod,
          );
          coords[req.id] = c;
          return c;
        },
      );

      manager.enqueue(const DownloadJobRequest(id: 'j1', url: 'https://a.com/1.mp4', title: 'One'));
      manager.enqueue(const DownloadJobRequest(id: 'j2', url: 'https://a.com/2.mp4', title: 'Two'));
      manager.enqueue(const DownloadJobRequest(id: 'j3', url: 'https://a.com/3.mp4', title: 'Three'));

      await coords['j1']!.started.future;
      await coords['j2']!.started.future;
      await Future<void>.delayed(Duration.zero);

      expect(coords['j3']!.started.isCompleted, isFalse);
      expect(manager.queuedJobs.map((j) => j.id), <String>['j3']);
      expect(manager.activeJobs.length, 2);
      expect(fgMethodsCalled, contains('startService'));

      // Notification Pause All button:
      actionEmitter.sink?.success(<String, Object?>{'action': 'pause_all'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(coords['j1']!.paused, isTrue);
      expect(coords['j2']!.paused, isTrue);

      // Finish j1 -> promotes j3 automatically & shows completion notification:
      coords['j1']!.finishGate.complete();
      await coords['j3']!.started.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(manager.completedJobs.map((j) => j.id), <String>['j1']);
      expect(fgMethodsCalled, contains('showCompletedNotification'));

      // Notification Cancel All button:
      actionEmitter.sink?.success(<String, Object?>{'action': 'cancel_all'});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(coords['j2']!.cancelled, isTrue);
      expect(coords['j3']!.cancelled, isTrue);
      expect(manager.activeJobs, isEmpty);
      expect(fgMethodsCalled, contains('stopService'));

      manager.dispose();
    });
  });
}

class EventChannelSinkHolder {
  MockStreamHandlerEventSink? sink;
}
