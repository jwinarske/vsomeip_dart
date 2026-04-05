@TestOn('vm')
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vsomeip_dart/vsomeip_dart.dart';

import 'mock/mock_vsomeip_bridge.dart';

void main() {
  group('VsomeipClient Cap\'n Proto API', () {
    late MockVsomeipBridge mock;
    late ReceivePort mainPort;
    late VsomeipClient client;

    setUp(() {
      mock = MockVsomeipBridge();
      mainPort = ReceivePort('test.capnp.main');
      client = VsomeipClient.create(
        bindings: mock,
        appName: 'capnp_test',
        mainPort: mainPort,
        nativePort: 0,
      );
    });

    tearDown(() async {
      await client.close();
    });

    test('subscribeCapnp registers schema and subscribes', () {
      final stream = client.subscribeCapnp(
        serviceId: 0x1234,
        instanceId: 0x0001,
        eventgroupId: 0x0001,
        eventId: 0x8001,
        schemaId: 0x0001,
        workerPort: 0,
      );

      expect(stream.isBroadcast, isTrue);
      expect(mock.registeredSchemas, contains(0x0001));
      expect(mock.capnpSubscriptions, hasLength(1));
      expect(mock.capnpSubscriptions[0].serviceId, equals(0x1234));
      expect(mock.capnpSubscriptions[0].eventId, equals(0x8001));
    });

    test('subscribeCapnpDecoded registers schema and subscribes decoded', () {
      client.subscribeCapnpDecoded(
        serviceId: 0x5678,
        instanceId: 0x0002,
        eventgroupId: 0x0002,
        eventId: 0x8002,
        schemaId: 0x0002,
        workerPort: 0,
      );

      expect(mock.registeredSchemas, contains(0x0002));
      expect(mock.capnpSubscriptions, hasLength(1));
      expect(mock.capnpSubscriptions[0].serviceId, equals(0x5678));
    });

    test(
      'subscribeCapnp returns broadcast stream that receives messages',
      () async {
        final received = <SomeIpMessage>[];
        client
            .subscribeCapnp(
              serviceId: 0x1234,
              instanceId: 0x0001,
              eventgroupId: 0x0001,
              eventId: 0x8001,
              schemaId: 0x0001,
              workerPort: 0,
            )
            .listen(received.add);

        // Simulate worker forwarding a decoded capnp message
        final msg = SomeIpMessage(
          serviceId: 0x1234,
          instanceId: 0x0001,
          methodId: 0x8001,
          messageType: SomeIpMessageType.notification,
          returnCode: 0,
          requestId: 0,
          payload: Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]),
        );
        mainPort.sendPort.send(msg);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(received, hasLength(1));
        expect(
          received[0].payload,
          equals(Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF])),
        );
      },
    );

    test('notifyCapnp calls bindings', () {
      client.notifyCapnp(
        serviceId: 0x1234,
        instanceId: 0x0001,
        eventId: 0x8001,
        schemaId: 0x0001,
        fieldsJson: Uint8List.fromList([0x01, 0x02]),
      );

      // capnpNotify was called (mock doesn't record it, but no exception)
    });

    test('multiple schemas can be registered', () {
      client.subscribeCapnp(
        serviceId: 0x1000,
        instanceId: 0x0001,
        eventgroupId: 0x0001,
        eventId: 0x8001,
        schemaId: 0x0001,
        workerPort: 0,
      );
      client.subscribeCapnp(
        serviceId: 0x2000,
        instanceId: 0x0001,
        eventgroupId: 0x0001,
        eventId: 0x8002,
        schemaId: 0x0002,
        workerPort: 0,
      );

      expect(mock.registeredSchemas, containsAll([0x0001, 0x0002]));
      expect(mock.capnpSubscriptions, hasLength(2));
    });
  });

  group('VehicleSpeedReader', () {
    test('reads fields from payload bytes', () {
      // Build a mock Cap'n Proto data section (not real Cap'n Proto framing,
      // but the Reader reads at fixed offsets for testing)
      final buf = ByteData(16);
      buf.setFloat32(0, 120.5, Endian.little); // speedKmh
      buf.setUint64(4, 1234567890, Endian.little); // timestamp
      buf.setUint16(12, 42, Endian.little); // sensorId

      final reader = VehicleSpeedReader(buf.buffer.asUint8List());
      expect(reader.speedKmh, closeTo(120.5, 0.01));
      expect(reader.timestamp, equals(1234567890));
      expect(reader.sensorId, equals(42));
    });

    test('short payload returns defaults', () {
      final reader = VehicleSpeedReader(Uint8List(2));
      expect(reader.speedKmh, equals(0.0));
      expect(reader.timestamp, equals(0));
      expect(reader.sensorId, equals(0));
    });

    test('schemaId constant', () {
      expect(VehicleSpeedReader.schemaId, equals(0x0001));
    });
  });
}
