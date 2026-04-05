import 'dart:typed_data';

import '../vsomeip_message.dart';

/// Wire protocol discriminator bytes.
class VsomeipDisc {
  static const int message = 0x01;
  static const int availability = 0x02;
  static const int state = 0x03;
  static const int subscribeAck = 0x04;
  static const int error = 0x05;
  static const int batch = 0x10;
  static const int sentinel = 0xFF;
}

/// Decoded wire header matching the C++ VsomeipMessageHeader layout.
class WireHeader {
  final int serviceId;
  final int instanceId;
  final int methodId;
  final int messageType;
  final int returnCode;
  final int requestId;
  final int payloadLen;

  const WireHeader({
    required this.serviceId,
    required this.instanceId,
    required this.methodId,
    required this.messageType,
    required this.returnCode,
    required this.requestId,
    required this.payloadLen,
  });
}

/// Codec for the vsomeip bridge wire protocol.
///
/// Wire format (21 bytes, little-endian):
///   [0]       discriminator (0x01 for message)
///   [1..2]    service_id
///   [3..4]    instance_id
///   [5..6]    method_id
///   [7]       message_type
///   [8]       return_code
///   [9..16]   request_id
///   [17..20]  payload_len
class WireCodec {
  /// Decode a message header from wire bytes starting at [offset].
  /// The discriminator byte at `data[offset]` should be 0x01.
  static WireHeader decodeHeader(Uint8List data, [int offset = 0]) {
    final d = ByteData.sublistView(data);
    // Skip discriminator at offset
    final o = offset + 1;
    return WireHeader(
      serviceId: d.getUint16(o, Endian.little),
      instanceId: d.getUint16(o + 2, Endian.little),
      methodId: d.getUint16(o + 4, Endian.little),
      messageType: d.getUint8(o + 6),
      returnCode: d.getUint8(o + 7),
      requestId: d.getUint64(o + 8, Endian.little),
      payloadLen: d.getUint32(o + 16, Endian.little),
    );
  }

  /// Decode an availability event from wire bytes starting at [offset].
  /// Wire format: [disc][service_id LE][instance_id LE][available u8]
  static VsomeipAvailabilityEvent decodeAvailability(
    Uint8List data, [
    int offset = 0,
  ]) {
    final d = ByteData.sublistView(data);
    final o = offset + 1; // skip discriminator
    return VsomeipAvailabilityEvent(
      serviceId: d.getUint16(o, Endian.little),
      instanceId: d.getUint16(o + 2, Endian.little),
      available: d.getUint8(o + 4) != 0,
    );
  }

  /// Decode a state event from wire bytes starting at [offset].
  /// Wire format: [disc][registered u8][app_name UTF-8 bytes...]
  static VsomeipStateEvent decodeState(Uint8List data, [int offset = 0]) {
    final o = offset + 1; // skip discriminator
    final registered = data[o] != 0;
    final appName = String.fromCharCodes(data, o + 1);
    return VsomeipStateEvent(registered: registered, appName: appName);
  }

  /// Decode a subscribe ACK from wire bytes.
  static ({
    int serviceId,
    int instanceId,
    int eventgroupId,
    int eventId,
    int errorCode,
  })
  decodeSubscribeAck(Uint8List data, [int offset = 0]) {
    final d = ByteData.sublistView(data);
    final o = offset + 1;
    return (
      serviceId: d.getUint16(o, Endian.little),
      instanceId: d.getUint16(o + 2, Endian.little),
      eventgroupId: d.getUint16(o + 4, Endian.little),
      eventId: d.getUint16(o + 6, Endian.little),
      errorCode: d.getUint16(o + 8, Endian.little),
    );
  }

  /// Decode an error from wire bytes.
  static String decodeError(Uint8List data, [int offset = 0]) {
    final o = offset + 1;
    return String.fromCharCodes(data, o);
  }

  /// Convert a [WireHeader] to a [SomeIpMessage] with optional payload.
  static SomeIpMessage toMessage(WireHeader hdr, Uint8List? payload) {
    return SomeIpMessage(
      serviceId: hdr.serviceId,
      instanceId: hdr.instanceId,
      methodId: hdr.methodId,
      messageType: SomeIpMessageType.fromByte(hdr.messageType),
      returnCode: hdr.returnCode,
      requestId: hdr.requestId,
      payload: payload,
    );
  }
}
