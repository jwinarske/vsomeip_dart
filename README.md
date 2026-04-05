# vsomeip_dart

[![pub package](https://img.shields.io/pub/v/vsomeip_dart.svg)](https://pub.dev/packages/vsomeip_dart)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Dart bridge for the [COVESA vsomeip](https://github.com/COVESA/vsomeip) SOME/IP
stack. Built on Dart build hooks with a worker-isolate architecture that never
blocks the Flutter render thread.

## Features

- **Subscribe** to SOME/IP events with zero-copy payload delivery
- **Request/response** and fire-and-forget method calls
- **Offer services** and publish events as a SOME/IP provider
- **Worker isolate** absorbs native callbacks — UI thread stays jank-free
- **Throttle** high-frequency signals (radar, IMU) to UI frame rate
- **Linux** automotive / embedded targets (x86_64, arm64)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  C++ Native Process                                             │
│                                                                  │
│  ┌──────────────────────┐    ┌──────────────────────────────┐   │
│  │  vsomeip event loop  │    │  Bridge worker               │   │
│  │  std::thread         │    │                              │   │
│  │  (app->start()       │ →  │  VsomeipSubscriber           │   │
│  │   runs here,         │    │  encode_header (21-byte LE)  │   │
│  │   never returns)     │    │                              │   │
│  │                      │    │  Dart_PostCObject_DL ────────│──┐│
│  └──────────────────────┘    └──────────────────────────────┘  ││
└─────────────────────────────────────────────────────────────────┘│
                                                                   │
┌──────────────────────────────────────────────────────────────────┘
│  Dart VM
│
│  ┌─────────────────────────────────────────────┐
│  │  WORKER ISOLATE                             │
│  │  (spawned from main at startup)             │
│  │                                             │
│  │  ReceivePort ← Dart_PostCObject_DL          │
│  │  WireCodec.decodeHeader()                   │
│  │  SignalThrottle.shouldForward()             │
│  │  SendPort.send() → main isolate ───────────│──┐
│  └─────────────────────────────────────────────┘  │
│                                                    │
│  ┌─────────────────────────────────────────────┐  │
│  │  MAIN ISOLATE (UI thread)                   │←─┘
│  │                                             │
│  │  VsomeipClient                              │
│  │  StreamController.broadcast()               │
│  │  Flutter widget setState()                  │
│  │  60 fps render loop                         │
│  └─────────────────────────────────────────────┘
```

## Thread Model

**Three threads, two isolates:**

1. **vsomeip event loop** (`std::thread`) — runs `app->start()` which never
   returns. All vsomeip message callbacks fire on Boost.Asio's internal
   thread pool.

2. **Worker isolate** (Dart) — receives `Dart_PostCObject_DL` posts from the
   native callback thread. Decodes headers, applies per-signal throttling,
   and forwards to the main isolate only when there is a subscribing widget.

3. **Main isolate** (Flutter UI thread) — receives throttled messages via
   `SendPort`. Safe to call `setState()` directly in stream listeners.

The worker isolate absorbs GC pressure from payload allocation. GC pauses
in the worker isolate never interrupt the UI thread.

## Throttle Guide

High-frequency automotive signals (radar at 50 Hz, accelerometer at 1 kHz,
CAN bus at 100 Hz) would overwhelm the Flutter render loop if forwarded
directly. `SignalThrottle` rate-limits per signal:

```dart
// Subscribe to a 1 kHz accelerometer signal, throttle to 60 Hz for UI
final stream = client.subscribeEvent(
    serviceId:    0xAABB,
    instanceId:   0x0001,
    eventgroupId: 0x0001,
    eventId:      0x9001,
    maxHz:        60.0);  // worker drops ~940 msg/s

stream.listen((msg) {
  setState(() => _accel = decodeAccel(msg.payload!));
});
```

Typical throttle settings:

| Signal | Raw Rate | UI Cap | Dropped |
|--------|----------|--------|---------|
| Vehicle speed (CAN) | 100 Hz | 30 Hz | 70% |
| Radar object list | 50 Hz | 10 Hz | 80% |
| Accelerometer | 1000 Hz | 60 Hz | 94% |
| Infotainment metadata | 1 Hz | 0 (no cap) | 0% |

Throttle can be changed at runtime:

```dart
client.setThrottle(
    serviceId: 0xAABB, instanceId: 0x0001,
    methodId:  0x9001, maxHz: 30.0);
```

## Platforms

| Platform | Status |
|----------|--------|
| Linux x86_64 | Supported |
| Linux arm64  | Supported |

## Quick Start

```dart
import 'package:vsomeip_dart/vsomeip_dart.dart';

// Subscribe to a SOME/IP event
final stream = client.subscribeEvent(
    serviceId: 0x1234, instanceId: 0x0001,
    eventgroupId: 0x0001, eventId: 0x8001,
    workerPort: workerPort);

// Send a request, await response
final response = await client.request(
    serviceId: 0x1234, instanceId: 0x0001,
    methodId: 0x0001, payload: Uint8List.fromList([0x01]));

// Offer a service
final service = client.offerService(
    serviceId: 0x5678, instanceId: 0x0001,
    requestsPort: port, requestStream: requestStream);
service.notify(eventId: 0x8001, payload: data);
```

## Examples

- [`subscribe_event.dart`](example/subscribe_event.dart) — subscribe to a SOME/IP event
- [`request_response.dart`](example/request_response.dart) — send request, await response
- [`offer_service.dart`](example/offer_service.dart) — act as a SOME/IP service provider
- [`high_frequency.dart`](example/high_frequency.dart) — 1 kHz signal with throttled UI
- [`flutter_vehicle_app/`](example/flutter_vehicle_app/) — Flutter dashboard with live sensors

## License

Apache 2.0 — see [LICENSE](LICENSE).
