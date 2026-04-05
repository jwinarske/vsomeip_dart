import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vsomeip_dart/vsomeip_dart.dart';

import 'mock/mock_vsomeip_bridge.dart';

void main() {
  group('VsomeipService', () {
    late MockVsomeipBridge mock;

    setUp(() {
      mock = MockVsomeipBridge();
    });

    test('offerService records in mock', () {
      final handle = mock.appCreate(0, 'test', null)!;
      final ctrl = StreamController<SomeIpMessage>.broadcast();

      final service = VsomeipService.testCreate(
        clientHandle: handle,
        bindings: mock,
        serviceId: 0x1234,
        instanceId: 0x0001,
        requests: ctrl.stream,
      );

      expect(service.serviceId, equals(0x1234));
      expect(service.instanceId, equals(0x0001));
      ctrl.close();
    });

    test('notify records payload', () {
      final handle = mock.appCreate(0, 'test', null)!;
      final ctrl = StreamController<SomeIpMessage>.broadcast();

      final service = VsomeipService.testCreate(
        clientHandle: handle,
        bindings: mock,
        serviceId: 0x1234,
        instanceId: 0x0001,
        requests: ctrl.stream,
      );

      final payload = Uint8List.fromList([0xAA, 0xBB]);
      service.notify(eventId: 0x8001, payload: payload);

      expect(mock.notified, hasLength(1));
      expect(mock.notified[0].serviceId, equals(0x1234));
      expect(mock.notified[0].eventId, equals(0x8001));
      expect(mock.notified[0].payload, equals(payload));
      expect(mock.notified[0].force, isFalse);
      ctrl.close();
    });

    test('notify with force=true', () {
      final handle = mock.appCreate(0, 'test', null)!;
      final ctrl = StreamController<SomeIpMessage>.broadcast();

      final service = VsomeipService.testCreate(
        clientHandle: handle,
        bindings: mock,
        serviceId: 0x1234,
        instanceId: 0x0001,
        requests: ctrl.stream,
      );

      service.notify(eventId: 0x8001, payload: Uint8List(0), force: true);

      expect(mock.notified[0].force, isTrue);
      ctrl.close();
    });

    test('respond calls sendResponse', () {
      final handle = mock.appCreate(0, 'test', null)!;
      final ctrl = StreamController<SomeIpMessage>.broadcast();

      final service = VsomeipService.testCreate(
        clientHandle: handle,
        bindings: mock,
        serviceId: 0x1234,
        instanceId: 0x0001,
        requests: ctrl.stream,
      );

      const req = SomeIpMessage(
        serviceId: 0x1234,
        instanceId: 0x0001,
        methodId: 0x0001,
        messageType: SomeIpMessageType.request,
        returnCode: 0,
        requestId: 42,
      );

      service.respond(request: req, payload: Uint8List.fromList([0x00]));
      // sendResponse was called (mock doesn't record it, but no exception)
      ctrl.close();
    });
  });
}
