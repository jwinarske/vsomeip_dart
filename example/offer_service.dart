// Act as a SOME/IP service — offer a method and a cyclic event.

// ignore_for_file: avoid_print

import 'dart:typed_data';

// ignore: unused_import
import 'package:vsomeip_dart/vsomeip_dart.dart';

Future<void> main() async {
  print('vsomeip_dart offer_service example');
  print('');
  print('In production, this would:');
  print('  1. Create a vsomeip client');
  print('  2. Offer service 0x1234.0x0001');
  print('  3. Offer event 0x8001 in eventgroup 0x0001');
  print('  4. Listen for incoming requests and respond');
  print('  5. Publish cyclic notifications every 100 ms');
  print('');

  // Example of building a notification payload
  var counter = 0;
  final payload = Uint8List(4)
    ..buffer.asByteData().setUint32(0, counter++, Endian.big);
  print('Example notification payload: ${payload.length} bytes');

  // Example of building a response
  final responsePayload = Uint8List.fromList([0x00, 0x00, 0x00, 0x00]);
  print('Example response payload: ${responsePayload.length} bytes');
}
