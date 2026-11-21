import 'package:faqih_downloader_mobile/engine/speed_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SpeedTracker', () {
    test('computes smoothed sliding-window speed and ETA accurately', () {
      var clock = 0;
      final tracker = SpeedTracker(windowMs: 2000, clockMs: () => clock);

      tracker.start();
      clock = 500;
      tracker.recordBytes(50000);
      clock = 1000;
      tracker.recordBytes(50000);

      final speed = tracker.currentSpeedBytesPerSec();
      expect(speed, closeTo(100000.0, 1.0));
      expect(tracker.estimateEtaSeconds(remainingBytes: 250000), closeTo(2.5, 0.01));
      expect(tracker.elapsedActiveSeconds, closeTo(1.0, 0.001));
    });

    test('excludes paused duration from elapsedActiveSeconds and zeroes speed', () {
      var clock = 0;
      final tracker = SpeedTracker(windowMs: 2000, clockMs: () => clock);

      tracker.start();
      clock = 1500;
      tracker.recordBytes(150000);
      expect(tracker.currentSpeedBytesPerSec(), greaterThan(0));

      tracker.pause();
      expect(tracker.currentSpeedBytesPerSec(), 0.0);
      expect(tracker.estimateEtaSeconds(remainingBytes: 10000), -1.0);

      // Advance clock 10 seconds while paused; active elapsed must stay 1.5s.
      clock = 11500;
      expect(tracker.elapsedActiveSeconds, closeTo(1.5, 0.001));

      tracker.resume();
      clock = 12500;
      expect(tracker.elapsedActiveSeconds, closeTo(2.5, 0.001));
    });
  });
}
