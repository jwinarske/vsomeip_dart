// Demonstrates that a 1000 msg/s SOME/IP event does NOT cause UI jank
// when throttled to 60 Hz by the worker isolate.
//
// This example shows the throttle configuration for high-frequency
// automotive signals like radar object lists, accelerometer data,
// or CAN bus signals that fire at 100-1000 Hz.
//
// In production with a real vsomeip connection:
//   - The C++ bridge delivers 1000 messages/second to the worker isolate
//   - SignalThrottle drops ~940 messages/second (at 60 Hz cap)
//   - Only ~60 messages/second reach the main (UI) isolate
//   - Flutter renders at 60 fps with zero jank

// ignore_for_file: avoid_print

import 'package:vsomeip_dart/vsomeip_dart.dart';

const _sensorService = 0xAABB;
const _sensorInstance = 0x0001;
const _sensorEvent = 0x9001;

void main() {
  print('vsomeip_dart high_frequency example');
  print('');
  print(
    'Signal: 0x${_sensorService.toRadixString(16)}'
    '.0x${_sensorInstance.toRadixString(16)}'
    ' event 0x${_sensorEvent.toRadixString(16)}',
  );
  print('');

  // Demonstrate throttle math
  const rawHz = 1000.0;
  const uiHz = 60.0;
  final dropped = ((1 - uiHz / rawHz) * 100).toStringAsFixed(1);

  print('Raw signal rate:  ${rawHz.toInt()} Hz');
  print('UI throttle cap:  ${uiHz.toInt()} Hz');
  print('Messages dropped: $dropped% (by worker isolate)');
  print('');

  // Show how SignalThrottle works
  final clock = _FakeClock();
  final throttle = SignalThrottle(maxHz: uiHz, clock: () => clock.nowUs);

  var forwarded = 0;
  var total = 0;

  // Simulate 1 second of 1 kHz signals
  for (var i = 0; i < 1000; i++) {
    total++;
    if (throttle.shouldForward()) forwarded++;
    clock.advanceUs(1000); // 1 ms between messages
  }

  print('Simulation: $total messages in 1 second');
  print('Forwarded to UI: $forwarded');
  print('Dropped by throttle: ${total - forwarded}');
  print('Effective UI rate: $forwarded Hz');
}

class _FakeClock {
  int nowUs = 0;
  void advanceUs(int us) => nowUs += us;
}
