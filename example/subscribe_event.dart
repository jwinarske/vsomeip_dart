// Subscribe to a vehicle speed SOME/IP event (simulates 100 Hz CAN signal).
//
// This example shows how to:
//   1. Create a vsomeip client
//   2. Watch for service availability
//   3. Subscribe to an event group
//   4. Decode payload bytes

// ignore_for_file: avoid_print

import 'dart:typed_data';

// ignore: unused_import
import 'package:vsomeip_dart/vsomeip_dart.dart';

const _speedService = 0x1234;
const _speedInstance = 0x0001;
const _speedEventgrp = 0x0001;
const _speedEvent = 0x8001;

Future<void> main() async {
  // In a real application, you would use the native bindings and worker
  // isolate. This example shows the API shape.
  print('vsomeip_dart subscribe_event example');
  print('Service: 0x${_speedService.toRadixString(16)}');
  print('Instance: 0x${_speedInstance.toRadixString(16)}');
  print('Event group: 0x${_speedEventgrp.toRadixString(16)}');
  print('Event: 0x${_speedEvent.toRadixString(16)}');
  print('');
  print('In production, this would connect to the vsomeip routing manager');
  print('and subscribe to the vehicle speed event.');
  print('');

  // Example of decoding a payload (without actual vsomeip connection)
  final examplePayload = ByteData(4)..setFloat32(0, 120.5, Endian.big);
  final speed = ByteData.sublistView(
    examplePayload.buffer.asUint8List(),
  ).getFloat32(0, Endian.big);
  print('Example decoded speed: ${speed.toStringAsFixed(1)} km/h');
}
