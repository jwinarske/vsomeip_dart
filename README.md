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

First time setup — fetch git submodules (vsomeip + capnpc-dart):

```sh
git submodule update --init --recursive
```

Then write Dart against the high-level API:

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
- [`flutter_drone_cockpit/`](example/flutter_drone_cockpit/) — Flutter drone cockpit (artificial horizon, compass, tapes, VSI, gimbal, joysticks → fire-and-forget control input)
- [`capnp/zero_copy_receive.dart`](example/capnp/zero_copy_receive.dart) — Cap'n Proto Path A raw passthrough
- [`capnp/selective_decode.dart`](example/capnp/selective_decode.dart) — Cap'n Proto Path B selective decode
- [`capnp/service_publish.dart`](example/capnp/service_publish.dart) — Cap'n Proto zero-copy send
- [`simulator/`](example/simulator/) — standalone vehicle signal simulator for dashboard testing

## Cap'n Proto Integration

vsomeip payloads are raw bytes — the SOME/IP standard defines the envelope
but leaves payload encoding to the application. Cap'n Proto provides
zero-parse, zero-allocation access to structured data directly from the
vsomeip payload buffer.

### Three Receive Paths

| Path | Description | Copies | Decode | Use case |
|------|-------------|--------|--------|----------|
| **A** Raw passthrough | Post raw bytes to Dart, read via `*Reader` | 0 | 0 | 1 kHz+ sensors |
| **B** Selective decode | C++ decodes subset, posts compact struct | 1 encode | 1 decode | Dashboard widgets |
| **C** Dart reader | Post raw bytes, Dart capnp package decodes | 0 | Dart | Generic schemas |

### Schema Definition

Define schemas in `schemas/*.capnp`:

```capnp
# schemas/vehicle_speed.capnp
@0xdeadbeefcafe0001;

struct VehicleSpeed {
  speedKmh     @0 :Float32;
  timestamp    @1 :UInt64;
  sensorId     @2 :UInt16;
  qualityFlag  @3 :UInt8;
}
```

The build hook compiles schemas to C++ headers and generates Dart bindings.
Two generators are supported, with the hook resolving them in order:

1. **[`capnpc-dart`](https://github.com/jwinarske/capnpc-dart)** (preferred) —
   a `capnp compile -odart` plugin written in C++ that emits canonical
   Cap'n Proto wire-format readers (data section + pointer section, bounds
   checked, no runtime dependency). The hook locates it in this order:
   `CAPNPC_DART` env → `capnpc-dart` on `PATH` → built from the
   `third_party/capnpc-dart` submodule and cached under the build dir.
2. **`tool/capnp_dart_gen.py`** (fallback) — pure-Python generator that
   parses `.capnp` text directly and emits a packed-layout `Reader`/
   `Builder` pair. Used when `capnp` or `capnpc-dart` are unavailable, and
   when no clean upgrade path exists. Skips files that already exist;
   pass `--force` to overwrite.

To skip codegen entirely, set `VSOMEIP_SKIP_CAPNP=1` before running the
hook. Both generators target `lib/generated/`.

> **Note on Dart-side builders.** `capnpc-dart` currently emits Builder
> stubs only for scalars and enums; Text/Data write paths are not yet
> implemented upstream. If you need to *send* a Cap'n Proto message
> from Dart that contains Text or Data fields (e.g. `Infotainment`), use
> the Python-generated builder until upstream support lands.

### Zero-Copy Read (Path A)

```dart
final stream = client.subscribeCapnp(
    serviceId: 0x1234, instanceId: 0x0001,
    eventgroupId: 0x0001, eventId: 0x8001,
    schemaId: VehicleSpeedReader.schemaId,
    workerPort: port);

stream.listen((msg) {
  // Reads directly from native memory — no parse, no allocation
  final speed = VehicleSpeedReader(msg.payload!);
  setState(() => _speed = speed.speedKmh);
});
```

### Zero-Copy Write

```dart
service.notify(
    eventId: 0x8001,
    payload: VehicleSpeedBuilder.build(
        speedKmh: 87.3,
        timestamp: DateTime.now().microsecondsSinceEpoch,
        sensorId: 0x0001));
```

### Available Schemas

| Schema | Fields | Size | Use case |
|--------|--------|------|----------|
| `VehicleSpeed` | speed, timestamp, sensor, quality | 16 B | Speedometer, trip computer |
| `RadarObject` | id, distance, azimuth, velocity, rcs, class | 40 B | ADAS, collision warning |
| `ImuData` | accel xyz, gyro xyz, timestamp, sensor | 40 B | Stability control, navigation |
| `DoorStatus` | door, open, locked, angle, timestamp | — | Body control, security |
| `Infotainment` | track, artist, art, duration, position | — | Media player, HMI |

### Performance

| Operation | Latency | Allocations |
|-----------|---------|-------------|
| Path A read (VehicleSpeedReader.speedKmh) | < 50 ns | 0 |
| Path B decode (C++ selective) | < 1 us | 1 struct |
| Path A write (VehicleSpeedBuilder.build) | < 100 ns | 1 Uint8List |
| Alignment check (is_capnp_aligned) | < 5 ns | 0 |
| Alignment copy fallback (< 0.001% of messages) | ~ 200 ns | 1 buffer |

## License

Apache 2.0 — see [LICENSE](LICENSE).
