import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'exceptions.dart';
import 'ffi/bindings.dart';
import 'ffi/codec.dart';
import 'vsomeip_message.dart';
import 'vsomeip_service.dart';
import 'vsomeip_worker.dart';
/// The top-level vsomeip controller for a Dart/Flutter application.
///
/// All vsomeip callbacks are delivered via `Dart_PostCObject_DL` to the
/// **worker isolate**, never to the main (UI) isolate. The worker isolate
/// throttles and forwards messages to the main isolate via [SendPort].
class VsomeipClient {
  final Object _handle;
  final VsomeipBindings _bindings;
  final ReceivePort _mainPort;
  /// Optional worker isolate — present when created via [spawn].
  final Isolate? _workerIsolate;
  /// Send port to the worker isolate — used for [setThrottle] and [close].
  final SendPort? _workerPort;
  final Map<SomeIpKey, StreamController<SomeIpMessage>> _streams = {};
  final Map<int, Completer<SomeIpMessage>> _pendingRequests = {};
  final StreamController<VsomeipAvailabilityEvent> _availCtrl =
      StreamController.broadcast();
  final StreamController<VsomeipStateEvent> _stateCtrl =
      StreamController.broadcast();
  /// Stream of service availability changes.
  Stream<VsomeipAvailabilityEvent> get availabilityChanges => _availCtrl.stream;
  /// Stream of application state changes (registered/deregistered).
  Stream<VsomeipStateEvent> get stateChanges => _stateCtrl.stream;
  VsomeipClient._({
    required Object handle,
    required VsomeipBindings bindings,
    required ReceivePort mainPort,
    Isolate? workerIsolate,
    SendPort? workerPort,
  }) : _handle = handle,
       _bindings = bindings,
       _mainPort = mainPort,
       _workerIsolate = workerIsolate,
       _workerPort = workerPort {
    _mainPort.listen(_onMainPortMessage);
  }
  /// Create a vsomeip application in **test mode** (no worker isolate).
  ///
  /// The caller controls [mainPort] and [nativePort], enabling direct message
  /// injection in tests without requiring a real vsomeip process.
  static VsomeipClient create({
    required VsomeipBindings bindings,
    required String appName,
    required ReceivePort mainPort,
    required int nativePort,
    String? configPath,
  }) {
    final handle = bindings.appCreate(nativePort, appName, configPath);
    if (handle == null) {
      throw VsomeipInitException(
        'Failed to create vsomeip application: $appName',
      );
    }
    return VsomeipClient._(
      handle: handle,
      bindings: bindings,
      mainPort: mainPort,
    );
  }
  /// Create a vsomeip application with a **real worker isolate**.
  ///
  /// This is the production entry point. It spawns the worker isolate, waits
  /// for its handshake, and then starts the native vsomeip event loop.
  ///
  /// [appName] must be unique within the vsomeip routing domain.
  /// [configPath] path to the vsomeip JSON config file, or null.
  static Future<VsomeipClient> spawn({
    required VsomeipBindings bindings,
    required String appName,
    String? configPath,
  }) async {
    final mainPort = ReceivePort('vsomeip.main');
    final setupPort = ReceivePort('vsomeip.setup');
    final workerIso = await Isolate.spawn(
      workerIsolateMain,
      WorkerConfig(setupPort.sendPort, mainPort.sendPort),
    );
    // Worker sends back its own SendPort after startup
    final workerPort = await setupPort.first as SendPort;
    setupPort.close();
    // Start native vsomeip; native callbacks post to workerPort.nativePort
    final handle = bindings.appCreate(
      workerPort.nativePort,
      appName,
      configPath,
    );
    if (handle == null) {
      workerIso.kill(priority: Isolate.immediate);
      mainPort.close();
      throw VsomeipInitException(
        'Failed to create vsomeip application: $appName',
      );
    }
    return VsomeipClient._(
      handle: handle,
      bindings: bindings,
      mainPort: mainPort,
      workerIsolate: workerIso,
      workerPort: workerPort,
    );
  }
  // ── Service consumer API ──────────────────────────────────────────────────
  /// Subscribe to a SOME/IP event group.
  ///
  /// [maxHz]: optional rate limit (configure via worker isolate).
  Stream<SomeIpMessage> subscribeEvent({
    required int serviceId,
    required int instanceId,
    required int eventgroupId,
    required int eventId,
    required int workerPort,
    double maxHz = 0.0,
  }) {
    final key = SomeIpKey(serviceId, instanceId, eventId);
    if (maxHz > 0.0) {
      _workerPort?.send(
        SetThrottleCmd(serviceId, instanceId, eventId, maxHz),
      );
    }
    _bindings.subscribe(
      _handle,
      serviceId,
      instanceId,
      eventgroupId,
      eventId,
      workerPort,
    );
    final ctrl = _streams.putIfAbsent(key, () => StreamController.broadcast());
    return ctrl.stream;
  }
  /// Unsubscribe from an event group.
  void unsubscribeEvent({
    required int serviceId,
    required int instanceId,
    required int eventgroupId,
  }) {
    _bindings.unsubscribe(_handle, serviceId, instanceId, eventgroupId);
  }
  /// Register a handler for messages on a service/instance/method.
  Stream<SomeIpMessage> onMessage({
    required int serviceId,
    required int instanceId,
    required int methodId,
    required int workerPort,
    double maxHz = 0.0,
  }) {
    final key = SomeIpKey(serviceId, instanceId, methodId);
    if (maxHz > 0.0) {
      _workerPort?.send(
        SetThrottleCmd(serviceId, instanceId, methodId, maxHz),
      );
    }
    _bindings.registerMessageHandler(
      _handle,
      serviceId,
      instanceId,
      methodId,
      workerPort,
    );
    return _streams.putIfAbsent(key, () => StreamController.broadcast()).stream;
  }
  /// Send a SOME/IP request and await the response.
  Future<SomeIpMessage> request({
    required int serviceId,
    required int instanceId,
    required int methodId,
    Uint8List? payload,
    int timeoutMs = 5000,
  }) {
    final completer = Completer<SomeIpMessage>();
    final resultPort = ReceivePort();
    resultPort.first.then((dynamic msg) {
      resultPort.close();
      if (msg is SomeIpMessage) {
        completer.complete(msg);
      } else if (msg is Uint8List && msg.isNotEmpty && msg[0] == 0x05) {
        completer.completeError(
          VsomeipRequestException(WireCodec.decodeError(msg)),
        );
      }
    });
    _bindings.sendRequest(
      _handle,
      serviceId,
      instanceId,
      methodId,
      payload ?? Uint8List(0),
      timeoutMs,
      0,
    );
    return completer.future;
  }
  /// Send a fire-and-forget message (no response expected).
  void fireAndForget({
    required int serviceId,
    required int instanceId,
    required int methodId,
    Uint8List? payload,
  }) {
    _bindings.sendFireForget(
      _handle,
      serviceId,
      instanceId,
      methodId,
      payload ?? Uint8List(0),
    );
  }
  // ── Service provider API ──────────────────────────────────────────────────
  /// Offer a SOME/IP service from this application.
  VsomeipService offerService({
    required int serviceId,
    required int instanceId,
    required int requestsPort,
    required Stream<SomeIpMessage> requestStream,
  }) {
    _bindings.offerService(_handle, serviceId, instanceId, requestsPort);
    return VsomeipService.testCreate(
      clientHandle: _handle,
      bindings: _bindings,
      serviceId: serviceId,
      instanceId: instanceId,
      requests: requestStream,
    );
  }
  // ── Rate limiting ─────────────────────────────────────────────────────────
  /// Update the per-signal rate limit for a previously subscribed event.
  ///
  /// Takes effect on the next worker isolate cycle. Requires [spawn] to have
  /// been used; silently ignored in test-mode [create].
  void setThrottle({
    required int serviceId,
    required int instanceId,
    required int methodId,
    required double maxHz,
  }) {
    _workerPort?.send(SetThrottleCmd(serviceId, instanceId, methodId, maxHz));
  }
  // ── Cap'n Proto API ───────────────────────────────────────────────────────
  /// Subscribe to a Cap'n Proto-encoded SOME/IP event (Path A — raw
  /// passthrough). The payload contains raw Cap'n Proto bytes readable
  /// by generated *Reader classes with zero decode overhead.
  Stream<SomeIpMessage> subscribeCapnp({
    required int serviceId,
    required int instanceId,
    required int eventgroupId,
    required int eventId,
    required int schemaId,
    required int workerPort,
  }) {
    _bindings.capnpRegisterSchema(_handle, schemaId, 'schema_$schemaId');
    _bindings.capnpSubscribe(
      _handle,
      serviceId,
      instanceId,
      eventgroupId,
      eventId,
      schemaId,
      workerPort,
    );
    final key = SomeIpKey(serviceId, instanceId, eventId);
    return _streams.putIfAbsent(key, () => StreamController.broadcast()).stream;
  }
  /// Subscribe with C++ selective decode (Path B).
  Stream<SomeIpMessage> subscribeCapnpDecoded({
    required int serviceId,
    required int instanceId,
    required int eventgroupId,
    required int eventId,
    required int schemaId,
    required int workerPort,
  }) {
    _bindings.capnpRegisterSchema(_handle, schemaId, 'schema_$schemaId');
    _bindings.capnpSubscribeDecoded(
      _handle,
      serviceId,
      instanceId,
      eventgroupId,
      eventId,
      schemaId,
      workerPort,
    );
    final key = SomeIpKey(serviceId, instanceId, eventId);
    return _streams.putIfAbsent(key, () => StreamController.broadcast()).stream;
  }
  /// Publish a Cap'n Proto notification (zero-copy write path).
  void notifyCapnp({
    required int serviceId,
    required int instanceId,
    required int eventId,
    required int schemaId,
    required Uint8List fieldsJson,
    bool force = false,
  }) {
    _bindings.capnpNotify(
      _handle,
      serviceId,
      instanceId,
      eventId,
      schemaId,
      fieldsJson,
      force,
    );
  }
  /// Close the vsomeip application and release all resources.
  Future<void> close() async {
    // Signal worker isolate to shut down gracefully
    _workerPort?.send('shutdown');
    _workerIsolate?.kill(priority: Isolate.immediate);
    _bindings.appDestroy(_handle);
    _mainPort.close();
    for (final ctrl in _streams.values) {
      await ctrl.close();
    }
    await _availCtrl.close();
    await _stateCtrl.close();
  }
  // ── Internal ──────────────────────────────────────────────────────────────
  void _onMainPortMessage(dynamic msg) {
    if (msg is SomeIpMessage) {
      final key = SomeIpKey(msg.serviceId, msg.instanceId, msg.methodId);
      _streams[key]?.add(msg);
      if (msg.messageType == SomeIpMessageType.response) {
        _pendingRequests.remove(msg.requestId)?.complete(msg);
      }
    } else if (msg is VsomeipAvailabilityEvent) {
      _availCtrl.add(msg);
    } else if (msg is VsomeipStateEvent) {
      _stateCtrl.add(msg);
    }
    // Unknown/unhandled messages are silently dropped
  }
}
