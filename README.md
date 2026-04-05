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

## Platforms

| Platform | Status |
|----------|--------|
| Linux x86_64 | Supported |
| Linux arm64  | Supported |

## Getting Started

```dart
import 'package:vsomeip_dart/vsomeip_dart.dart';
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
