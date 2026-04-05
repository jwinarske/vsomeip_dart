import 'dart:typed_data';

/// Abstract interface to the vsomeip native bridge.
///
/// In production, [NativeVsomeipBindings] calls into libvsomeip_bridge.so
/// via `@Native` FFI. In tests, [MockVsomeipBridge] replaces it.
abstract class VsomeipBindings {
  // ── Lifecycle ──────────────────────────────────────────────────────────────

  Object? appCreate(int eventsPort, String appName, String? configPath);
  void appDestroy(Object handle);

  // ── Service consumer ───────────────────────────────────────────────────────

  void requestService(Object handle, int serviceId, int instanceId);
  void releaseService(Object handle, int serviceId, int instanceId);

  void subscribe(
    Object handle,
    int serviceId,
    int instanceId,
    int eventgroupId,
    int eventId,
    int eventsPort,
  );

  void unsubscribe(
    Object handle,
    int serviceId,
    int instanceId,
    int eventgroupId,
  );

  void registerMessageHandler(
    Object handle,
    int serviceId,
    int instanceId,
    int methodId,
    int eventsPort,
  );

  void unregisterMessageHandler(
    Object handle,
    int serviceId,
    int instanceId,
    int methodId,
  );

  // ── Request / response ─────────────────────────────────────────────────────

  void sendRequest(
    Object handle,
    int serviceId,
    int instanceId,
    int methodId,
    Uint8List payload,
    int timeoutMs,
    int resultPort,
  );

  void sendFireForget(
    Object handle,
    int serviceId,
    int instanceId,
    int methodId,
    Uint8List payload,
  );

  void sendResponse(Object handle, int requestId, Uint8List payload);

  // ── Service provider ───────────────────────────────────────────────────────

  void offerService(
    Object handle,
    int serviceId,
    int instanceId,
    int requestsPort,
  );

  void stopOfferService(Object handle, int serviceId, int instanceId);

  void offerEvent(
    Object handle,
    int serviceId,
    int instanceId,
    int eventId,
    List<int> eventgroupIds,
    bool isField,
    int cycleMs,
  );

  void stopOfferEvent(
    Object handle,
    int serviceId,
    int instanceId,
    int eventId,
  );

  void notify(
    Object handle,
    int serviceId,
    int instanceId,
    int eventId,
    Uint8List payload,
    bool force,
  );

  // ── Cap'n Proto support ──────────────────────────────────────────────────

  void capnpSubscribe(
    Object handle,
    int serviceId,
    int instanceId,
    int eventgroupId,
    int eventId,
    int schemaId,
    int eventsPort,
  );

  void capnpSubscribeDecoded(
    Object handle,
    int serviceId,
    int instanceId,
    int eventgroupId,
    int eventId,
    int schemaId,
    int eventsPort,
  );

  void capnpNotify(
    Object handle,
    int serviceId,
    int instanceId,
    int eventId,
    int schemaId,
    Uint8List fieldsJson,
    bool force,
  );

  void capnpRegisterSchema(Object handle, int schemaId, String schemaName);
}
