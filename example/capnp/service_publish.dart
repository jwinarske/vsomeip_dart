// Zero-copy send: build a Cap'n Proto payload and publish as notification.
//
// Demonstrates using VehicleSpeedBuilder to construct a payload that
// matches the Cap'n Proto data section layout, then publishing it
// via the service notify API.

// ignore_for_file: avoid_print

import 'package:vsomeip_dart/vsomeip_dart.dart';

void main() {
  print('Cap\'n Proto zero-copy send example');
  print('');

  // Build payloads for different vehicle signals
  final speedPayload = VehicleSpeedBuilder.build(
    speedKmh: 87.3,
    timestamp: DateTime.now().microsecondsSinceEpoch,
    sensorId: 0x0001,
    qualityFlag: 0,
  );
  print('VehicleSpeed payload: ${speedPayload.length} bytes');

  // Verify round-trip: build → read
  final reader = VehicleSpeedReader(speedPayload);
  print('  speedKmh:    ${reader.speedKmh.toStringAsFixed(1)}');
  print('  timestamp:   ${reader.timestamp}');
  print('  sensorId:    0x${reader.sensorId.toRadixString(16)}');
  print('  qualityFlag: ${reader.qualityFlag}');
  print('');
  print('In production:');
  print('  service.notify(eventId: 0x8001, payload: speedPayload);');
  print('');
  print('The C++ bridge uses FlatMessageBuilder to write directly');
  print('into the vsomeip payload buffer — zero intermediate copies.');
}
