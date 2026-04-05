import 'dart:typed_data';

import 'package:vsomeip_dart/vsomeip_dart.dart';

/// Records of bridge invocations for assertion in tests.
class SubscribeCall {
  final int serviceId, instanceId, eventgroupId, eventId;
  const SubscribeCall(
    this.serviceId,
    this.instanceId,
    this.eventgroupId,
    this.eventId,
  );
}

class SendRequestCall {
  final int serviceId, instanceId, methodId;
  final Uint8List payload;
  const SendRequestCall(
    this.serviceId,
    this.instanceId,
    this.methodId,
    this.payload,
  );
}

class NotifyCall {
  final int serviceId, instanceId, eventId;
  final Uint8List payload;
  final bool force;
  const NotifyCall(
    this.serviceId,
    this.instanceId,
    this.eventId,
    this.payload,
    this.force,
  );
}

class OfferServiceCall {
  final int serviceId, instanceId;
  const OfferServiceCall(this.serviceId, this.instanceId);
}

/// Mock implementation of [VsomeipBindings] for unit testing.
///
/// Records all invocations and allows configuring failure modes.
class MockVsomeipBridge implements VsomeipBindings {
  bool initShouldFail = false;
  int _handleCounter = 1;

  final List<SubscribeCall> subscriptions = [];
  final List<SendRequestCall> sentRequests = [];
  final List<NotifyCall> notified = [];
  final List<OfferServiceCall> offeredServices = [];

  bool _destroyed = false;
  bool get wasDestroyed => _destroyed;

  @override
  Object? appCreate(int eventsPort, String appName, String? configPath) {
    if (initShouldFail) return null;
    return _handleCounter++;
  }

  @override
  void appDestroy(Object handle) {
    _destroyed = true;
  }

  @override
  void requestService(Object handle, int serviceId, int instanceId) {}

  @override
  void releaseService(Object handle, int serviceId, int instanceId) {}

  @override
  void subscribe(
    Object handle,
    int serviceId,
    int instanceId,
    int eventgroupId,
    int eventId,
    int eventsPort,
  ) {
    subscriptions.add(
      SubscribeCall(serviceId, instanceId, eventgroupId, eventId),
    );
  }

  @override
  void unsubscribe(
    Object handle,
    int serviceId,
    int instanceId,
    int eventgroupId,
  ) {}

  @override
  void registerMessageHandler(
    Object handle,
    int serviceId,
    int instanceId,
    int methodId,
    int eventsPort,
  ) {}

  @override
  void unregisterMessageHandler(
    Object handle,
    int serviceId,
    int instanceId,
    int methodId,
  ) {}

  @override
  void sendRequest(
    Object handle,
    int serviceId,
    int instanceId,
    int methodId,
    Uint8List payload,
    int timeoutMs,
    int resultPort,
  ) {
    sentRequests.add(SendRequestCall(serviceId, instanceId, methodId, payload));
  }

  @override
  void sendFireForget(
    Object handle,
    int serviceId,
    int instanceId,
    int methodId,
    Uint8List payload,
  ) {}

  @override
  void sendResponse(Object handle, int requestId, Uint8List payload) {}

  @override
  void offerService(
    Object handle,
    int serviceId,
    int instanceId,
    int requestsPort,
  ) {
    offeredServices.add(OfferServiceCall(serviceId, instanceId));
  }

  @override
  void stopOfferService(Object handle, int serviceId, int instanceId) {}

  @override
  void offerEvent(
    Object handle,
    int serviceId,
    int instanceId,
    int eventId,
    List<int> eventgroupIds,
    bool isField,
    int cycleMs,
  ) {}

  @override
  void stopOfferEvent(
    Object handle,
    int serviceId,
    int instanceId,
    int eventId,
  ) {}

  @override
  void notify(
    Object handle,
    int serviceId,
    int instanceId,
    int eventId,
    Uint8List payload,
    bool force,
  ) {
    notified.add(NotifyCall(serviceId, instanceId, eventId, payload, force));
  }
}
