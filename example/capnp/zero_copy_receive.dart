// Path A: Raw zero-copy Cap'n Proto passthrough.
//
// Demonstrates subscribing to a SOME/IP event that carries a Cap'n Proto
// payload. The VehicleSpeedReader reads fields directly from the native
// memory buffer — no parse, no decode, no allocation.

// ignore_for_file: avoid_print

import 'package:vsomeip_dart/vsomeip_dart.dart';

void main() {
  print('Cap\'n Proto zero-copy receive example (Path A)');
  print('');

  // Simulate what the bridge would deliver: a VehicleSpeed payload
  final payload = VehicleSpeedBuilder.build(
    speedKmh: 120.5,
    timestamp: DateTime.now().microsecondsSinceEpoch,
    sensorId: 42,
  );

  print(
    'Built payload: ${payload.length} bytes '
    '(${payload.length ~/ 8} Cap\'n Proto words)',
  );

  // Read fields from the raw bytes — zero decode overhead
  final reader = VehicleSpeedReader(payload);
  print('Speed:     ${reader.speedKmh.toStringAsFixed(1)} km/h');
  print('Timestamp: ${reader.timestamp}');
  print('Sensor ID: ${reader.sensorId}');
  print('');
  print('In production, msg.payload arrives via Dart_PostCObject_DL');
  print('as kExternalTypedData — same native memory, zero copies.');
}
