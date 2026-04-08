import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'bindings.dart';

/// Native FFI implementation of [VsomeipBindings].
///
/// Loads `libvsomeip_bridge.so` and calls the C ABI functions.
/// Use [NativeVsomeipBindings.open] to load a specific library path,
/// or [NativeVsomeipBindings.system] for the default system library.
class NativeVsomeipBindings implements VsomeipBindings {
  final DynamicLibrary _lib;
  NativeVsomeipBindings._(this._lib) {
    // Initialize the bridge with Dart API DL
    final init = _lib
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('vsomeip_bridge_init');
    init(nullptr); // Pass NativeApi.initializeApiDLData in production
  }

  /// Load from a specific path.
  factory NativeVsomeipBindings.open(String path) {
    return NativeVsomeipBindings._(DynamicLibrary.open(path));
  }
  @override
  Object? appCreate(int eventsPort, String appName, String? configPath) {
    final fn = _lib
        .lookupFunction<
          Pointer<Void> Function(Int64, Pointer<Utf8>, Pointer<Utf8>),
          Pointer<Void> Function(int, Pointer<Utf8>, Pointer<Utf8>)
        >('vsomeip_app_create');
    final namePtr = appName.toNativeUtf8();
    final configPtr = configPath != null ? configPath.toNativeUtf8() : nullptr;
    final handle = fn(eventsPort, namePtr, configPtr);
    malloc.free(namePtr);
    if (configPtr != nullptr) malloc.free(configPtr);
    if (handle == nullptr) return null;
    return handle.address; // Use address as handle
  }

  @override
  void appDestroy(Object handle) {
    final fn = _lib
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('vsomeip_app_destroy');
    fn(Pointer.fromAddress(handle as int));
  }

  Pointer<Void> _h(Object handle) => Pointer.fromAddress(handle as int);
  @override
  void requestService(Object handle, int serviceId, int instanceId) {
    final fn = _lib
        .lookupFunction<
          Void Function(Pointer<Void>, Uint16, Uint16),
          void Function(Pointer<Void>, int, int)
        >('vsomeip_request_service');
    fn(_h(handle), serviceId, instanceId);
  }

  @override
  void releaseService(Object handle, int serviceId, int instanceId) {
    final fn = _lib
        .lookupFunction<
          Void Function(Pointer<Void>, Uint16, Uint16),
          void Function(Pointer<Void>, int, int)
        >('vsomeip_release_service');
    fn(_h(handle), serviceId, instanceId);
  }

  @override
  void subscribe(
    Object handle,
    int serviceId,
    int instanceId,
    int eventgroupId,
    int eventId,
    int eventsPort,
  ) {
    final fn = _lib
        .lookupFunction<
          Void Function(Pointer<Void>, Uint16, Uint16, Uint16, Uint16, Int64),
          void Function(Pointer<Void>, int, int, int, int, int)
        >('vsomeip_subscribe');
    fn(_h(handle), serviceId, instanceId, eventgroupId, eventId, eventsPort);
  }

  @override
  void unsubscribe(
    Object handle,
    int serviceId,
    int instanceId,
    int eventgroupId,
  ) {
    final fn = _lib
        .lookupFunction<
          Void Function(Pointer<Void>, Uint16, Uint16, Uint16),
          void Function(Pointer<Void>, int, int, int)
        >('vsomeip_unsubscribe');
    fn(_h(handle), serviceId, instanceId, eventgroupId);
  }

  @override
  void registerMessageHandler(
    Object handle,
    int serviceId,
    int instanceId,
    int methodId,
    int eventsPort,
  ) {
    final fn = _lib
        .lookupFunction<
          Void Function(Pointer<Void>, Uint16, Uint16, Uint16, Int64),
          void Function(Pointer<Void>, int, int, int, int)
        >('vsomeip_register_message_handler');
    fn(_h(handle), serviceId, instanceId, methodId, eventsPort);
  }

  @override
  void unregisterMessageHandler(
    Object handle,
    int serviceId,
    int instanceId,
    int methodId,
  ) {
    final fn = _lib
        .lookupFunction<
          Void Function(Pointer<Void>, Uint16, Uint16, Uint16),
          void Function(Pointer<Void>, int, int, int)
        >('vsomeip_unregister_message_handler');
    fn(_h(handle), serviceId, instanceId, methodId);
  }

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
    final fn = _lib
        .lookupFunction<
          Void Function(
            Pointer<Void>,
            Uint16,
            Uint16,
            Uint16,
            Pointer<Uint8>,
            Uint32,
            Uint32,
            Int64,
          ),
          void Function(
            Pointer<Void>,
            int,
            int,
            int,
            Pointer<Uint8>,
            int,
            int,
            int,
          )
        >('vsomeip_send_request');
    final buf = malloc<Uint8>(payload.isEmpty ? 1 : payload.length);
    for (var i = 0; i < payload.length; i++) {
      buf[i] = payload[i];
    }
    fn(
      _h(handle),
      serviceId,
      instanceId,
      methodId,
      buf,
      payload.length,
      timeoutMs,
      resultPort,
    );
    malloc.free(buf);
  }

  @override
  void sendFireForget(
    Object handle,
    int serviceId,
    int instanceId,
    int methodId,
    Uint8List payload,
  ) {
    final fn = _lib
        .lookupFunction<
          Void Function(
            Pointer<Void>,
            Uint16,
            Uint16,
            Uint16,
            Pointer<Uint8>,
            Uint32,
          ),
          void Function(Pointer<Void>, int, int, int, Pointer<Uint8>, int)
        >('vsomeip_send_fire_forget');
    final buf = malloc<Uint8>(payload.isEmpty ? 1 : payload.length);
    for (var i = 0; i < payload.length; i++) {
      buf[i] = payload[i];
    }
    fn(_h(handle), serviceId, instanceId, methodId, buf, payload.length);
    malloc.free(buf);
  }

  @override
  void sendResponse(Object handle, int requestId, Uint8List payload) {
    final fn = _lib
        .lookupFunction<
          Void Function(Pointer<Void>, Uint64, Pointer<Uint8>, Uint32),
          void Function(Pointer<Void>, int, Pointer<Uint8>, int)
        >('vsomeip_send_response');
    final buf = malloc<Uint8>(payload.isEmpty ? 1 : payload.length);
    for (var i = 0; i < payload.length; i++) {
      buf[i] = payload[i];
    }
    fn(_h(handle), requestId, buf, payload.length);
    malloc.free(buf);
  }

  @override
  void offerService(
    Object handle,
    int serviceId,
    int instanceId,
    int requestsPort,
  ) {
    final fn = _lib
        .lookupFunction<
          Void Function(Pointer<Void>, Uint16, Uint16, Int64),
          void Function(Pointer<Void>, int, int, int)
        >('vsomeip_offer_service');
    fn(_h(handle), serviceId, instanceId, requestsPort);
  }

  @override
  void stopOfferService(Object handle, int serviceId, int instanceId) {
    final fn = _lib
        .lookupFunction<
          Void Function(Pointer<Void>, Uint16, Uint16),
          void Function(Pointer<Void>, int, int)
        >('vsomeip_stop_offer_service');
    fn(_h(handle), serviceId, instanceId);
  }

  @override
  void offerEvent(
    Object handle,
    int serviceId,
    int instanceId,
    int eventId,
    List<int> eventgroupIds,
    bool isField,
    int cycleMs,
  ) {
    final fn = _lib
        .lookupFunction<
          Void Function(
            Pointer<Void>,
            Uint16,
            Uint16,
            Uint16,
            Pointer<Uint16>,
            Uint32,
            Bool,
            Uint32,
          ),
          void Function(
            Pointer<Void>,
            int,
            int,
            int,
            Pointer<Uint16>,
            int,
            bool,
            int,
          )
        >('vsomeip_offer_event');
    // Marshal Dart List<int> to native uint16_t array
    final n = eventgroupIds.length;
    final buf = malloc<Uint16>(n == 0 ? 1 : n);
    for (var i = 0; i < n; i++) {
      buf[i] = eventgroupIds[i];
    }
    fn(_h(handle), serviceId, instanceId, eventId, buf, n, isField, cycleMs);
    malloc.free(buf);
  }

  @override
  void stopOfferEvent(
    Object handle,
    int serviceId,
    int instanceId,
    int eventId,
  ) {
    final fn = _lib
        .lookupFunction<
          Void Function(Pointer<Void>, Uint16, Uint16, Uint16),
          void Function(Pointer<Void>, int, int, int)
        >('vsomeip_stop_offer_event');
    fn(_h(handle), serviceId, instanceId, eventId);
  }

  @override
  void notify(
    Object handle,
    int serviceId,
    int instanceId,
    int eventId,
    Uint8List payload,
    bool force,
  ) {
    final fn = _lib
        .lookupFunction<
          Void Function(
            Pointer<Void>,
            Uint16,
            Uint16,
            Uint16,
            Pointer<Uint8>,
            Uint32,
            Bool,
          ),
          void Function(Pointer<Void>, int, int, int, Pointer<Uint8>, int, bool)
        >('vsomeip_notify');
    final buf = malloc<Uint8>(payload.isEmpty ? 1 : payload.length);
    for (var i = 0; i < payload.length; i++) {
      buf[i] = payload[i];
    }
    fn(_h(handle), serviceId, instanceId, eventId, buf, payload.length, force);
    malloc.free(buf);
  }

  @override
  void capnpSubscribe(
    Object handle,
    int serviceId,
    int instanceId,
    int eventgroupId,
    int eventId,
    int schemaId,
    int eventsPort,
  ) {
    final fn = _lib
        .lookupFunction<
          Void Function(
            Pointer<Void>,
            Uint16,
            Uint16,
            Uint16,
            Uint16,
            Uint32,
            Int64,
          ),
          void Function(Pointer<Void>, int, int, int, int, int, int)
        >('vsomeip_capnp_subscribe');
    fn(
      _h(handle),
      serviceId,
      instanceId,
      eventgroupId,
      eventId,
      schemaId,
      eventsPort,
    );
  }

  @override
  void capnpSubscribeDecoded(
    Object handle,
    int serviceId,
    int instanceId,
    int eventgroupId,
    int eventId,
    int schemaId,
    int eventsPort,
  ) {
    final fn = _lib
        .lookupFunction<
          Void Function(
            Pointer<Void>,
            Uint16,
            Uint16,
            Uint16,
            Uint16,
            Uint32,
            Int64,
          ),
          void Function(Pointer<Void>, int, int, int, int, int, int)
        >('vsomeip_capnp_subscribe_decoded');
    fn(
      _h(handle),
      serviceId,
      instanceId,
      eventgroupId,
      eventId,
      schemaId,
      eventsPort,
    );
  }

  @override
  void capnpNotify(
    Object handle,
    int serviceId,
    int instanceId,
    int eventId,
    int schemaId,
    Uint8List fieldsJson,
    bool force,
  ) {
    final fn = _lib
        .lookupFunction<
          Void Function(
            Pointer<Void>,
            Uint16,
            Uint16,
            Uint16,
            Uint32,
            Pointer<Uint8>,
            Int32,
            Bool,
          ),
          void Function(
            Pointer<Void>,
            int,
            int,
            int,
            int,
            Pointer<Uint8>,
            int,
            bool,
          )
        >('vsomeip_capnp_notify');
    final buf = malloc<Uint8>(fieldsJson.isEmpty ? 1 : fieldsJson.length);
    for (var i = 0; i < fieldsJson.length; i++) {
      buf[i] = fieldsJson[i];
    }
    fn(
      _h(handle),
      serviceId,
      instanceId,
      eventId,
      schemaId,
      buf,
      fieldsJson.length,
      force,
    );
    malloc.free(buf);
  }

  @override
  void capnpRegisterSchema(Object handle, int schemaId, String schemaName) {
    final fn = _lib
        .lookupFunction<
          Void Function(Pointer<Void>, Uint32, Pointer<Utf8>),
          void Function(Pointer<Void>, int, Pointer<Utf8>)
        >('vsomeip_capnp_register_schema');
    final namePtr = schemaName.toNativeUtf8();
    fn(_h(handle), schemaId, namePtr);
    malloc.free(namePtr);
  }
}
