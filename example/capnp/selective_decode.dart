// Path B: C++ selective decode — the bridge decodes only UI-relevant fields.
//
// Demonstrates subscribing via subscribeCapnpDecoded(), where the C++ bridge
// reads specific Cap'n Proto fields and posts a compact struct to Dart.
// This path trades one C++ decode + one Dart decode for type safety and
// smaller cross-isolate messages.
//
// Use Path B when:
//   - The schema has many fields but the UI only needs a few
//   - You want type-safe Dart objects instead of raw byte access
//   - The decode cost (< 1 us per message) is acceptable

// ignore_for_file: avoid_print

import 'package:vsomeip_dart/vsomeip_dart.dart';

void main() {
  print('Cap\'n Proto selective decode example (Path B)');
  print('');
  print('Path B flow:');
  print('  1. vsomeip delivers raw Cap\'n Proto payload');
  print('  2. C++ bridge decodes only requested fields');
  print('  3. Posts compact struct to Dart worker isolate');
  print('  4. Worker forwards to main isolate');
  print('  5. Dart receives pre-decoded typed fields');
  print('');
  print('Recommended for:');
  print('  - Dashboard widgets needing 2-3 fields from a 20-field schema');
  print('  - Schemas with variable-length fields (Text, Data)');
  print('  - Cases where type safety > raw throughput');
  print('');

  // Demonstrate the field subset concept
  print('VehicleSpeed schema has 5 fields:');
  print('  speedKmh, timestamp, sensorId, qualityFlag, reserved');
  print('');
  print('Path B selective decode might extract only:');
  print('  speedKmh, timestamp');
  print('  (3 fields skipped = less data across isolate boundary)');
  print('');

  // Show what a decoded payload looks like
  final payload = VehicleSpeedBuilder.build(
    speedKmh: 95.2,
    timestamp: DateTime.now().microsecondsSinceEpoch,
    sensorId: 1,
  );

  final reader = VehicleSpeedReader(payload);
  print(
    'Full read (Path A):  speed=${reader.speedKmh.toStringAsFixed(1)}, '
    'ts=${reader.timestamp}, sensor=${reader.sensorId}',
  );
  print(
    'Selective (Path B):  speed=${reader.speedKmh.toStringAsFixed(1)}, '
    'ts=${reader.timestamp}',
  );
  print('  (sensorId not decoded — saves ~2 bytes per message)');
}
