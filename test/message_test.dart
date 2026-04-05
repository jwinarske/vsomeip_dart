import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vsomeip_dart/vsomeip_dart.dart';

void main() {
  group('SomeIpMessageType', () {
    test('fromByte maps all documented message types', () {
      expect(SomeIpMessageType.fromByte(0x00), SomeIpMessageType.request);
      expect(
        SomeIpMessageType.fromByte(0x01),
        SomeIpMessageType.requestNoReturn,
      );
      expect(SomeIpMessageType.fromByte(0x02), SomeIpMessageType.notification);
      expect(SomeIpMessageType.fromByte(0x40), SomeIpMessageType.requestAck);
      expect(
        SomeIpMessageType.fromByte(0x41),
        SomeIpMessageType.requestNoReturnAck,
      );
      expect(
        SomeIpMessageType.fromByte(0x42),
        SomeIpMessageType.notificationAck,
      );
      expect(SomeIpMessageType.fromByte(0x80), SomeIpMessageType.response);
      expect(SomeIpMessageType.fromByte(0x81), SomeIpMessageType.error);
    });

    test('fromByte unknown value returns unknown', () {
      expect(SomeIpMessageType.fromByte(0xFF), SomeIpMessageType.unknown);
      expect(SomeIpMessageType.fromByte(0x10), SomeIpMessageType.unknown);
    });

    test('value roundtrips through fromByte', () {
      for (final t in SomeIpMessageType.values) {
        if (t == SomeIpMessageType.unknown) continue;
        expect(SomeIpMessageType.fromByte(t.value), t);
      }
    });
  });

  group('SomeIpMessage', () {
    test('all fields accessible', () {
      final msg = SomeIpMessage(
        serviceId: 0x1234,
        instanceId: 0x0001,
        methodId: 0x0001,
        messageType: SomeIpMessageType.response,
        returnCode: 0,
        requestId: 0xDEAD0001,
        payload: Uint8List.fromList([1, 2, 3]),
      );
      expect(msg.serviceId, equals(0x1234));
      expect(msg.instanceId, equals(0x0001));
      expect(msg.methodId, equals(0x0001));
      expect(msg.messageType, equals(SomeIpMessageType.response));
      expect(msg.returnCode, equals(0));
      expect(msg.requestId, equals(0xDEAD0001));
      expect(msg.payload, equals(Uint8List.fromList([1, 2, 3])));
    });

    test('null payload is valid', () {
      const msg = SomeIpMessage(
        serviceId: 1,
        instanceId: 1,
        methodId: 1,
        messageType: SomeIpMessageType.notification,
        returnCode: 0,
        requestId: 0,
      );
      expect(msg.payload, isNull);
    });

    test('toString includes service/instance/method identifiers', () {
      const msg = SomeIpMessage(
        serviceId: 0x1234,
        instanceId: 0x0001,
        methodId: 0x0001,
        messageType: SomeIpMessageType.request,
        returnCode: 0,
        requestId: 0,
      );
      final s = msg.toString();
      expect(s, contains('1234'));
      expect(s, contains('0001'));
    });
  });

  group('SomeIpKey', () {
    test('equality: same IDs are equal', () {
      const k1 = SomeIpKey(0x1234, 0x0001, 0x8001);
      const k2 = SomeIpKey(0x1234, 0x0001, 0x8001);
      expect(k1, equals(k2));
      expect(k1.hashCode, equals(k2.hashCode));
    });

    test('inequality: different IDs are not equal', () {
      const k1 = SomeIpKey(0x1234, 0x0001, 0x8001);
      const k2 = SomeIpKey(0x1234, 0x0001, 0x8002);
      const k3 = SomeIpKey(0x1234, 0x0002, 0x8001);
      const k4 = SomeIpKey(0x5678, 0x0001, 0x8001);
      expect(k1, isNot(equals(k2)));
      expect(k1, isNot(equals(k3)));
      expect(k1, isNot(equals(k4)));
    });

    test('can be used as map key', () {
      final map = <SomeIpKey, String>{};
      const key = SomeIpKey(0x1234, 0x0001, 0x8001);
      map[key] = 'test';
      expect(map[const SomeIpKey(0x1234, 0x0001, 0x8001)], equals('test'));
    });

    test('toString contains hex IDs', () {
      const key = SomeIpKey(0x1234, 0x0001, 0x8001);
      expect(key.toString(), contains('1234'));
      expect(key.toString(), contains('8001'));
    });
  });

  group('VsomeipAvailabilityEvent', () {
    test('fields are accessible', () {
      const evt = VsomeipAvailabilityEvent(
        serviceId: 0x1234,
        instanceId: 0x0001,
        available: true,
      );
      expect(evt.serviceId, equals(0x1234));
      expect(evt.instanceId, equals(0x0001));
      expect(evt.available, isTrue);
    });
  });

  group('VsomeipStateEvent', () {
    test('fields are accessible', () {
      const evt = VsomeipStateEvent(registered: true, appName: 'test_app');
      expect(evt.registered, isTrue);
      expect(evt.appName, equals('test_app'));
    });
  });

  group('VsomeipDisc', () {
    test('discriminator constants match C++ values', () {
      expect(VsomeipDisc.message, equals(0x01));
      expect(VsomeipDisc.availability, equals(0x02));
      expect(VsomeipDisc.state, equals(0x03));
      expect(VsomeipDisc.subscribeAck, equals(0x04));
      expect(VsomeipDisc.error, equals(0x05));
      expect(VsomeipDisc.batch, equals(0x10));
      expect(VsomeipDisc.sentinel, equals(0xFF));
    });
  });

  group('WireCodec', () {
    test('decodeHeader roundtrips with C++ encode_header format', () {
      // Build a wire header matching the C++ 21-byte LE format
      final buf = ByteData(21);
      buf.setUint8(0, 0x01); // discriminator
      buf.setUint16(1, 0x1234, Endian.little); // service_id
      buf.setUint16(3, 0x0001, Endian.little); // instance_id
      buf.setUint16(5, 0x8001, Endian.little); // method_id
      buf.setUint8(7, 0x02); // message_type (notification)
      buf.setUint8(8, 0x00); // return_code
      buf.setUint64(9, 0x12345678, Endian.little); // request_id
      buf.setUint32(17, 100, Endian.little); // payload_len

      final hdr = WireCodec.decodeHeader(buf.buffer.asUint8List());
      expect(hdr.serviceId, equals(0x1234));
      expect(hdr.instanceId, equals(0x0001));
      expect(hdr.methodId, equals(0x8001));
      expect(hdr.messageType, equals(0x02));
      expect(hdr.returnCode, equals(0x00));
      expect(hdr.requestId, equals(0x12345678));
      expect(hdr.payloadLen, equals(100));
    });

    test('decodeAvailability decodes struct bytes', () {
      // [disc=0x02][svc_id LE][inst_id LE][available]
      final buf = ByteData(6);
      buf.setUint8(0, 0x02);
      buf.setUint16(1, 0xABCD, Endian.little);
      buf.setUint16(3, 0x0002, Endian.little);
      buf.setUint8(5, 1);

      final evt = WireCodec.decodeAvailability(buf.buffer.asUint8List());
      expect(evt.serviceId, equals(0xABCD));
      expect(evt.instanceId, equals(0x0002));
      expect(evt.available, isTrue);
    });

    test('decodeState decodes registered + appName', () {
      // [disc=0x03][registered][app_name bytes...]
      const appName = 'test_app';
      final data = Uint8List.fromList([
        0x03,
        1, // registered
        ...appName.codeUnits,
      ]);

      final evt = WireCodec.decodeState(data);
      expect(evt.registered, isTrue);
      expect(evt.appName, equals('test_app'));
    });

    test('decodeState deregistered', () {
      final data = Uint8List.fromList([0x03, 0, ...('app'.codeUnits)]);
      final evt = WireCodec.decodeState(data);
      expect(evt.registered, isFalse);
      expect(evt.appName, equals('app'));
    });

    test('decodeError extracts message string', () {
      const errMsg = 'something went wrong';
      final data = Uint8List.fromList([0x05, ...errMsg.codeUnits]);
      expect(WireCodec.decodeError(data), equals(errMsg));
    });

    test('toMessage converts WireHeader to SomeIpMessage', () {
      const hdr = WireHeader(
        serviceId: 0x1234,
        instanceId: 0x0001,
        methodId: 0x0001,
        messageType: 0x80,
        returnCode: 0,
        requestId: 42,
        payloadLen: 3,
      );
      final payload = Uint8List.fromList([1, 2, 3]);
      final msg = WireCodec.toMessage(hdr, payload);

      expect(msg.serviceId, equals(0x1234));
      expect(msg.messageType, equals(SomeIpMessageType.response));
      expect(msg.requestId, equals(42));
      expect(msg.payload, equals(payload));
    });
  });
}
