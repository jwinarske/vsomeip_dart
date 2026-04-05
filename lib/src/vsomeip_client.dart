import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'exceptions.dart';
import 'ffi/bindings.dart';
import 'ffi/codec.dart';
import 'vsomeip_message.dart';
import 'vsomeip_service.dart';

/// The top-level vsomeip controller for a Dart/Flutter application.
///
/// All vsomeip callbacks are delivered via `Dart_PostCObject_DL` to the
/// **worker isolate**, never to the main (UI) isolate. The worker isolate
/// throttles and forwards messages to the main isolate via [SendPort].
class VsomeipClient {
  final Object _handle;
  final VsomeipBindings _bindings;
  final ReceivePort _mainPort;

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
  }) : _handle = handle,
       _bindings = bindings,
       _mainPort = mainPort {
    _mainPort.listen(_onMainPortMessage);
  }

  /// Create a vsomeip application and start its event loop.
  ///
  /// [appName] must be unique within the vsomeip routing domain.
  /// [configPath] path to the vsomeip JSON config file, or null.
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
  }) {
    final key = SomeIpKey(serviceId, instanceId, eventId);

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
  }) {
    final key = SomeIpKey(serviceId, instanceId, methodId);
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

    // In production, resultPort.sendPort.nativePort would be used.
    // The nativePort getter is only available via dart:ffi extensions.
    // For now, pass 0 — the real FFI bindings will use the port directly.
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

  /// Close the vsomeip application and release all resources.
  Future<void> close() async {
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
  }
}
