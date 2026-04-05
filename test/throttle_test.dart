import 'package:test/test.dart';
import 'package:vsomeip_dart/vsomeip_dart.dart';

class FakeClock {
  int _nowUs = 0;

  int get nowMicroseconds => _nowUs;
  void advance(Duration d) => _nowUs += d.inMicroseconds;
  void advanceMs(int ms) => _nowUs += ms * 1000;
  void advanceUs(int us) => _nowUs += us;
}

void main() {
  group('SignalThrottle', () {
    test('zero maxHz forwards everything', () {
      final throttle = SignalThrottle(maxHz: 0);
      for (var i = 0; i < 100; i++) {
        expect(throttle.shouldForward(), isTrue);
      }
    });

    test('30 Hz allows one per 33333 us', () {
      final clock = FakeClock();
      final throttle = SignalThrottle(
        maxHz: 30,
        clock: () => clock.nowMicroseconds,
      );

      // First call always forwards
      expect(throttle.shouldForward(), isTrue);

      // 10 ms later — too soon (33.3 ms interval)
      clock.advanceMs(10);
      expect(throttle.shouldForward(), isFalse);

      // 20 ms more (total 30 ms) — still too soon
      clock.advanceMs(20);
      expect(throttle.shouldForward(), isFalse);

      // 4 ms more (total 34 ms) — should forward
      clock.advanceMs(4);
      expect(throttle.shouldForward(), isTrue);
    });

    test('60 Hz allows one per 16667 us', () {
      final clock = FakeClock();
      final throttle = SignalThrottle(
        maxHz: 60,
        clock: () => clock.nowMicroseconds,
      );

      expect(throttle.shouldForward(), isTrue);

      clock.advanceMs(10);
      expect(throttle.shouldForward(), isFalse);

      clock.advanceMs(7); // total 17 ms > 16.667 ms
      expect(throttle.shouldForward(), isTrue);
    });

    test('1 Hz allows one per second', () {
      final clock = FakeClock();
      final throttle = SignalThrottle(
        maxHz: 1,
        clock: () => clock.nowMicroseconds,
      );

      expect(throttle.shouldForward(), isTrue);

      clock.advanceMs(500);
      expect(throttle.shouldForward(), isFalse);

      clock.advanceMs(500); // total 1000 ms
      expect(throttle.shouldForward(), isTrue);
    });

    test('rapid fire only forwards at configured rate', () {
      final clock = FakeClock();
      final throttle = SignalThrottle(
        maxHz: 10,
        clock: () => clock.nowMicroseconds,
      );

      var forwarded = 0;
      // Simulate 1000 messages over 1 second at 1 kHz
      for (var i = 0; i < 1000; i++) {
        if (throttle.shouldForward()) forwarded++;
        clock.advanceMs(1);
      }

      // At 10 Hz over 1 second, expect ~10 forwards
      expect(forwarded, inInclusiveRange(10, 11));
    });

    test('negative maxHz treated as no throttle', () {
      final throttle = SignalThrottle(maxHz: -1);
      expect(throttle.shouldForward(), isTrue);
      expect(throttle.shouldForward(), isTrue);
    });

    test('exact interval boundary forwards', () {
      final clock = FakeClock();
      final throttle = SignalThrottle(
        maxHz: 100,
        clock: () => clock.nowMicroseconds,
      );

      expect(throttle.shouldForward(), isTrue);
      clock.advanceUs(10000); // exactly 10 ms = 100 Hz interval
      expect(throttle.shouldForward(), isTrue);
    });
  });
}
