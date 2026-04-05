// Copyright (c) 2026 Joel Winarske
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// vsomeip_worker.dart
//
// The worker isolate runs between the native bridge and the main isolate.
// It owns the ReceivePort that Dart_PostCObject_DL posts into.
//
// Responsibilities:
//   1. Decode wire protocol messages from the native bridge
//   2. Apply per-signal throttling (rate limiting for high-frequency events)
//   3. Forward decoded Dart objects to the main isolate
//
// Message format from native bridge (post_message_to_dart):
//   List<dynamic>([Uint8List header, Uint8List? payload]) — message events
//
// Message format from native bridge (post_to_dart):
//   Uint8List([disc, ...data]) — availability/state/error/ack events
//
// Control messages sent from main isolate:
//   SetThrottleCmd — update per-signal rate limit
//   'shutdown'     — close the worker port
import 'dart:isolate';
import 'dart:typed_data';
import 'ffi/codec.dart';
import 'throttle.dart';
import 'vsomeip_message.dart';
/// Configuration passed to [workerIsolateMain] at spawn time.
class WorkerConfig {
  final SendPort setupSendPort;
  final SendPort mainSendPort;
  const WorkerConfig(this.setupSendPort, this.mainSendPort);
}
/// Control message to set per-signal throttle rate.
///
/// Sent from the main isolate to the worker via [VsomeipClient.setThrottle].
class SetThrottleCmd {
  final int serviceId;
  final int instanceId;
  final int methodId;
  final double maxHz;
  const SetThrottleCmd(
      this.serviceId, this.instanceId, this.methodId, this.maxHz);
}
/// Entry point for the vsomeip worker isolate.
///
/// Must be a top-level function for [Isolate.spawn]. [cfg] carries the
/// setup handshake port and the main isolate's [SendPort].
///
/// After startup, the worker sends its own [SendPort] back to the spawner via
/// [cfg.setupSendPort], then enters its message loop.
void workerIsolateMain(WorkerConfig cfg) {
  final port = ReceivePort('vsomeip.worker');
  final throttles = <SomeIpKey, SignalThrottle>{};
  // Handshake: send our SendPort back to the spawner so it can route native
  // Dart_PostCObject_DL calls to us.
  cfg.setupSendPort.send(port.sendPort);
  port.listen((dynamic msg) {
    // ── Native bridge: [header_bytes, payload_or_null] (post_message_to_dart)
    if (msg is List && msg.length == 2) {
      final headerBytes = msg[0] as Uint8List;
      final payload = msg[1] is Uint8List ? msg[1] as Uint8List : null;
      _handleDisc(headerBytes, payload, throttles, cfg.mainSendPort);
    }
    // ── Native bridge: single Uint8List with disc byte (post_to_dart path)
    else if (msg is Uint8List && msg.isNotEmpty) {
      _handleDisc(msg, null, throttles, cfg.mainSendPort);
    }
    // ── Control: update per-signal throttle ───────────────────────────────
    else if (msg is SetThrottleCmd) {
      final key = SomeIpKey(msg.serviceId, msg.instanceId, msg.methodId);
      throttles[key] = SignalThrottle(maxHz: msg.maxHz);
    }
    // ── Control: graceful shutdown ─────────────────────────────────────────
    else if (msg == 'shutdown') {
      port.close();
    }
  });
}
/// Dispatch a decoded discriminator to the appropriate handler.
void _handleDisc(
  Uint8List data,
  Uint8List? payload,
  Map<SomeIpKey, SignalThrottle> throttles,
  SendPort mainSendPort,
) {
  if (data.isEmpty) return;
  switch (data[0]) {
    case VsomeipDisc.message:
      _handleMessage(data, payload, throttles, mainSendPort);
    case VsomeipDisc.availability:
      mainSendPort.send(WireCodec.decodeAvailability(data));
    case VsomeipDisc.state:
      mainSendPort.send(WireCodec.decodeState(data));
    case VsomeipDisc.subscribeAck:
      // Forward raw — VsomeipClient handles subscribe ack routing
      mainSendPort.send(data);
    case VsomeipDisc.error:
      // Forward raw — VsomeipClient decodes error string
      mainSendPort.send(data);
    case VsomeipDisc.sentinel:
      // Sentinel byte — discard silently
      break;
    default:
      // Unknown discriminator — forward raw bytes to main for handling
      mainSendPort.send(data);
  }
}
/// Decode a message header, apply throttle, and forward to the main isolate.
void _handleMessage(
  Uint8List headerData,
  Uint8List? payload,
  Map<SomeIpKey, SignalThrottle> throttles,
  SendPort mainSendPort,
) {
  final hdr = WireCodec.decodeHeader(headerData);
  final key = SomeIpKey(hdr.serviceId, hdr.instanceId, hdr.methodId);
  // Apply per-signal rate limit if configured
  final throttle = throttles[key];
  if (throttle != null && !throttle.shouldForward()) {
    return; // Drop — rate limit exceeded
  }
  mainSendPort.send(WireCodec.toMessage(hdr, payload));
}
