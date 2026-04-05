import 'dart:typed_data';

import 'ffi/bindings.dart';
import 'vsomeip_message.dart';

/// A SOME/IP service offered by this application.
///
/// Handles incoming requests and publishes events/notifications.
class VsomeipService {
  final Object _clientHandle;
  final VsomeipBindings _bindings;

  /// The service ID of this offered service.
  final int serviceId;

  /// The instance ID of this offered service.
  final int instanceId;

  /// Stream of incoming requests from remote clients.
  final Stream<SomeIpMessage> requests;

  VsomeipService._({
    required Object clientHandle,
    required VsomeipBindings bindings,
    required this.serviceId,
    required this.instanceId,
    required this.requests,
  }) : _clientHandle = clientHandle,
       _bindings = bindings;

  /// Test-only constructor for creating a service without going through
  /// VsomeipClient.offerService().
  // ignore: prefer_constructors_over_static_methods
  static VsomeipService testCreate({
    required Object clientHandle,
    required VsomeipBindings bindings,
    required int serviceId,
    required int instanceId,
    required Stream<SomeIpMessage> requests,
  }) {
    return VsomeipService._(
      clientHandle: clientHandle,
      bindings: bindings,
      serviceId: serviceId,
      instanceId: instanceId,
      requests: requests,
    );
  }

  /// Offer a SOME/IP event on this service.
  ///
  /// [cycleMs]: 0 = no cyclic sending; > 0 = re-send every cycleMs ms.
  void offerEvent({
    required int eventId,
    required List<int> eventgroupIds,
    bool isField = false,
    int cycleMs = 0,
  }) {
    _bindings.offerEvent(
      _clientHandle,
      serviceId,
      instanceId,
      eventId,
      eventgroupIds,
      isField,
      cycleMs,
    );
  }

  /// Publish a notification to all current subscribers.
  void notify({
    required int eventId,
    required Uint8List payload,
    bool force = false,
  }) {
    _bindings.notify(
      _clientHandle,
      serviceId,
      instanceId,
      eventId,
      payload,
      force,
    );
  }

  /// Reply to an incoming request.
  void respond({required SomeIpMessage request, required Uint8List payload}) {
    _bindings.sendResponse(_clientHandle, request.requestId, payload);
  }

  /// Stop offering this service.
  void stop() {
    _bindings.stopOfferService(_clientHandle, serviceId, instanceId);
  }
}
