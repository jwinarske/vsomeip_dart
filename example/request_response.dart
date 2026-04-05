// Send a SOME/IP request and print the response.
// Demonstrates the async request/response pattern.

// ignore_for_file: avoid_print

import 'dart:typed_data';

import 'package:vsomeip_dart/vsomeip_dart.dart';

Future<void> main() async {
  print('vsomeip_dart request_response example');
  print('');
  print('In production, this would:');
  print('  1. Create a vsomeip client');
  print('  2. Wait for service 0x1234 to become available');
  print('  3. Send a request to method 0x0001');
  print('  4. Await and print the response');
  print('');

  // Example of building a request payload
  final request = Uint8List.fromList([0x01, 0x00, 0x00, 0x00]);
  print('Request payload: ${request.length} bytes');

  // Example of what a response message looks like
  final response = SomeIpMessage(
    serviceId: 0x1234,
    instanceId: 0x0001,
    methodId: 0x0001,
    messageType: SomeIpMessageType.response,
    returnCode: 0,
    requestId: 1,
    payload: Uint8List.fromList([0x00, 0x00, 0x00, 0x00]),
  );
  print('Example response: $response');
}
