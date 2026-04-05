import 'dart:typed_data';

/// SOME/IP message type byte values per AUTOSAR specification.
enum SomeIpMessageType {
  request(0x00),
  requestNoReturn(0x01),
  notification(0x02),
  requestAck(0x40),
  requestNoReturnAck(0x41),
  notificationAck(0x42),
  response(0x80),
  error(0x81),
  unknown(0xFF);

  const SomeIpMessageType(this.value);
  final int value;

  static SomeIpMessageType fromByte(int byte) {
    for (final t in values) {
      if (t.value == byte) return t;
    }
    return unknown;
  }
}

/// A decoded SOME/IP message delivered from the worker isolate.
class SomeIpMessage {
  final int serviceId;
  final int instanceId;
  final int methodId;
  final SomeIpMessageType messageType;
  final int returnCode;
  final int requestId;
  final Uint8List? payload;

  const SomeIpMessage({
    required this.serviceId,
    required this.instanceId,
    required this.methodId,
    required this.messageType,
    required this.returnCode,
    required this.requestId,
    this.payload,
  });

  @override
  String toString() =>
      'SomeIpMessage(svc=0x${serviceId.toRadixString(16).padLeft(4, '0')}, '
      'inst=0x${instanceId.toRadixString(16).padLeft(4, '0')}, '
      'method=0x${methodId.toRadixString(16).padLeft(4, '0')}, '
      'type=$messageType, rc=$returnCode, '
      'payload=${payload?.length ?? 0}B)';
}

/// Composite key for routing messages to the correct stream.
class SomeIpKey {
  final int serviceId;
  final int instanceId;
  final int methodId;

  const SomeIpKey(this.serviceId, this.instanceId, this.methodId);

  @override
  bool operator ==(Object other) =>
      other is SomeIpKey &&
      other.serviceId == serviceId &&
      other.instanceId == instanceId &&
      other.methodId == methodId;

  @override
  int get hashCode => Object.hash(serviceId, instanceId, methodId);

  @override
  String toString() =>
      'SomeIpKey(0x${serviceId.toRadixString(16)}, '
      '0x${instanceId.toRadixString(16)}, '
      '0x${methodId.toRadixString(16)})';
}

/// Service availability change event.
class VsomeipAvailabilityEvent {
  final int serviceId;
  final int instanceId;
  final bool available;

  const VsomeipAvailabilityEvent({
    required this.serviceId,
    required this.instanceId,
    required this.available,
  });
}

/// Application state change event.
class VsomeipStateEvent {
  final bool registered;
  final String appName;

  const VsomeipStateEvent({required this.registered, required this.appName});
}
