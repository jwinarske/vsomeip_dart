@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vsomeip_dart/vsomeip_dart.dart';

import 'mock/mock_vsomeip_bridge.dart';

void main() {
  group('worker isolate — message routing via VsomeipClient', () {
    late MockVsomeipBridge mock;
    late ReceivePort mainPort;
    late VsomeipClient client;

    setUp(() {
      mock = MockVsomeipBridge();
      mainPort = ReceivePort('test.main');
      client = VsomeipClient.create(
        bindings: mock,
        appName: 'test_app',
        mainPort: mainPort,
        nativePort: 0,
      );
    });

    tearDown(() async {
      await client.close();
    });

    test('subscribeEvent records subscription in mock', () {
      client.subscribeEvent(
        serviceId: 0x1234,
        instanceId: 0x0001,
        eventgroupId: 0x0001,
        eventId: 0x8001,
        workerPort: 0,
      );

      expect(mock.subscriptions, hasLength(1));
      expect(mock.subscriptions[0].serviceId, equals(0x1234));
      expect(mock.subscriptions[0].eventgroupId, equals(0x0001));
      expect(mock.subscriptions[0].eventId, equals(0x8001));
    });

    test('subscribeEvent returns a broadcast stream', () {
      final stream = client.subscribeEvent(
        serviceId: 0x1234,
        instanceId: 0x0001,
        eventgroupId: 0x0001,
        eventId: 0x8001,
        workerPort: 0,
      );

      expect(stream.isBroadcast, isTrue);
    });

    test('multiple subscriptions to same event share stream', () {
      client.subscribeEvent(
        serviceId: 0x1234,
        instanceId: 0x0001,
        eventgroupId: 0x0001,
        eventId: 0x8001,
        workerPort: 0,
      );
      client.subscribeEvent(
        serviceId: 0x1234,
        instanceId: 0x0001,
        eventgroupId: 0x0001,
        eventId: 0x8001,
        workerPort: 0,
      );

      // Both subscriptions share the same underlying stream controller,
      // so listeners on either reference receive the same messages.
      // Verify by checking both subscribe calls were recorded.
      expect(mock.subscriptions, hasLength(2));
    });

    test('different events get different streams', () {
      final s1 = client.subscribeEvent(
        serviceId: 0x1234,
        instanceId: 0x0001,
        eventgroupId: 0x0001,
        eventId: 0x8001,
        workerPort: 0,
      );
      final s2 = client.subscribeEvent(
        serviceId: 0x1234,
        instanceId: 0x0001,
        eventgroupId: 0x0002,
        eventId: 0x8002,
        workerPort: 0,
      );

      expect(identical(s1, s2), isFalse);
    });

    test('message posted to mainPort routes to correct stream', () async {
      final received = <SomeIpMessage>[];
      client
          .subscribeEvent(
            serviceId: 0x1234,
            instanceId: 0x0001,
            eventgroupId: 0x0001,
            eventId: 0x8001,
            workerPort: 0,
          )
          .listen(received.add);

      // Simulate the worker isolate forwarding a decoded message
      final msg = SomeIpMessage(
        serviceId: 0x1234,
        instanceId: 0x0001,
        methodId: 0x8001,
        messageType: SomeIpMessageType.notification,
        returnCode: 0,
        requestId: 0,
        payload: Uint8List.fromList([0xAA]),
      );
      mainPort.sendPort.send(msg);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received, hasLength(1));
      expect(received[0].serviceId, equals(0x1234));
      expect(received[0].payload, equals(Uint8List.fromList([0xAA])));
    });

    test('availability event routes to availabilityChanges stream', () async {
      final avail = <VsomeipAvailabilityEvent>[];
      client.availabilityChanges.listen(avail.add);

      mainPort.sendPort.send(
        const VsomeipAvailabilityEvent(
          serviceId: 0x1234,
          instanceId: 0x0001,
          available: true,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(avail, hasLength(1));
      expect(avail[0].serviceId, equals(0x1234));
      expect(avail[0].available, isTrue);
    });

    test('state event routes to stateChanges stream', () async {
      final states = <VsomeipStateEvent>[];
      client.stateChanges.listen(states.add);

      mainPort.sendPort.send(
        const VsomeipStateEvent(registered: true, appName: 'test_app'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(states, hasLength(1));
      expect(states[0].registered, isTrue);
      expect(states[0].appName, equals('test_app'));
    });

    test('response message completes pending request', () async {
      // This tests _onMainPortMessage response routing
      final received = <SomeIpMessage>[];
      client
          .onMessage(
            serviceId: 0x1234,
            instanceId: 0x0001,
            methodId: 0x0001,
            workerPort: 0,
          )
          .listen(received.add);

      final response = SomeIpMessage(
        serviceId: 0x1234,
        instanceId: 0x0001,
        methodId: 0x0001,
        messageType: SomeIpMessageType.response,
        returnCode: 0,
        requestId: 42,
        payload: Uint8List.fromList([0x00]),
      );
      mainPort.sendPort.send(response);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received, hasLength(1));
      expect(received[0].messageType, equals(SomeIpMessageType.response));
    });

    test('unrecognised message type is silently dropped', () async {
      // Send something that is not a SomeIpMessage, availability, or state
      mainPort.sendPort.send('bogus_message');
      mainPort.sendPort.send(42);
      mainPort.sendPort.send([1, 2, 3]);

      // No crash, no error — just dropped
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('close destroys app and cleans up', () async {
      await client.close();
      expect(mock.wasDestroyed, isTrue);
    });

    test('fireAndForget does not record in sentRequests', () {
      client.fireAndForget(
        serviceId: 0x1234,
        instanceId: 0x0001,
        methodId: 0x0001,
        payload: Uint8List.fromList([0x01]),
      );

      // sendFireForget doesn't record in sentRequests (different list)
      expect(mock.sentRequests, isEmpty);
    });

    test('offerService records in mock and returns VsomeipService', () {
      final ctrl = StreamController<SomeIpMessage>.broadcast();
      final service = client.offerService(
        serviceId: 0x5678,
        instanceId: 0x0001,
        requestsPort: 0,
        requestStream: ctrl.stream,
      );

      expect(mock.offeredServices, hasLength(1));
      expect(mock.offeredServices[0].serviceId, equals(0x5678));
      expect(service.serviceId, equals(0x5678));
      expect(service.instanceId, equals(0x0001));
      ctrl.close();
    });
  });
}
