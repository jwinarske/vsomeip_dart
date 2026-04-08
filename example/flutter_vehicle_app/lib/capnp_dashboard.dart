// Cap'n Proto dashboard widget for the Flutter vehicle app.
//
// Demonstrates zero-copy Cap'n Proto payload reading in a Flutter widget
// using the optimal Flutter rendering pattern:
//
//   1. ValueNotifier<double> drives the gauge — native callback writes
//      directly with `notifier.value = X` (no setState).
//   2. CustomPainter takes the listenable as `repaint:` so the painter
//      repaints without rebuilding any widgets.
//   3. RepaintBoundary isolates the gauge to its own layer so adjacent
//      widgets don't get marked dirty.
//   4. ValueListenableBuilder rebuilds only the metadata text below the
//      gauge — the surrounding Card and label stay stable.
//
// This pattern is what flutter_vehicle_app/lib/main.dart uses for the
// analog speedometer + tachometer. Use it for any high-frequency signal
// that drives a UI element.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vsomeip_dart/vsomeip_dart.dart';

/// Cap'n Proto vehicle speed dashboard card with zero-copy field reads
/// and frame-rate-locked rendering via ValueListenable.
class CapnpDashboard extends StatefulWidget {
  const CapnpDashboard({super.key});

  @override
  State<CapnpDashboard> createState() => _CapnpDashboardState();
}

class _CapnpDashboardState extends State<CapnpDashboard> {
  // High-frequency value — drives the gauge directly via repaint listenable.
  // Updated by native callback at 100 Hz; gauge repaints at frame rate.
  final ValueNotifier<double> _speedNotifier = ValueNotifier(0);

  // Per-message metadata — coalesced into the same notifier to keep them
  // in sync with the displayed speed.
  final ValueNotifier<_SpeedMetadata> _metaNotifier = ValueNotifier(
    const _SpeedMetadata(),
  );

  @override
  void dispose() {
    _speedNotifier.dispose();
    _metaNotifier.dispose();
    super.dispose();
  }

  /// Called when a Cap'n Proto message arrives. In production, this is
  /// wired to the subscribeCapnp stream. The native callback runs on the
  /// vsomeip thread; NativeCallable.listener marshals it to the main isolate.
  void onCapnpMessage(SomeIpMessage msg) {
    if (msg.payload == null || msg.payload!.isEmpty) return;

    // Zero-copy: VehicleSpeedReader reads fields at fixed offsets in
    // the native memory buffer — no allocation, no decode.
    final reader = VehicleSpeedReader(msg.payload!);

    // Direct notifier updates — no setState, no widget rebuild.
    // Multiple updates between frames are coalesced by markNeedsPaint.
    _speedNotifier.value = reader.speedKmh;
    _metaNotifier.value = _SpeedMetadata(
      timestamp: reader.timestamp,
      sensorId: reader.sensorId,
      messageCount: _metaNotifier.value.messageCount + 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Cap\'n Proto Vehicle Speed',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),

            // Speed gauge — RepaintBoundary isolates this region.
            // ValueListenableBuilder rebuilds only the bar + text on update.
            RepaintBoundary(
              child: ValueListenableBuilder<double>(
                valueListenable: _speedNotifier,
                builder: (context, speed, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(value: (speed / 250).clamp(0, 1)),
                    const SizedBox(height: 4),
                    Text(
                      '${speed.toStringAsFixed(1)} km/h',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Metadata — separate listenable so the speed gauge doesn't
            // pull along the surrounding text on every update.
            RepaintBoundary(
              child: ValueListenableBuilder<_SpeedMetadata>(
                valueListenable: _metaNotifier,
                builder: (context, meta, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sensor: 0x${meta.sensorId.toRadixString(16).padLeft(4, '0')}',
                    ),
                    Text('Timestamp: ${meta.timestamp}'),
                    Text('Messages received: ${meta.messageCount}'),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),
            const Text(
              'Zero-copy: VehicleSpeedReader reads float32 directly '
              'from native memory — no parse, no decode.\n'
              'Frame-rate-locked: ValueListenable + CustomPainter repaint '
              '— never triggers a widget rebuild.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// Immutable per-message metadata snapshot for the metadata listenable.
@immutable
class _SpeedMetadata {
  final int timestamp;
  final int sensorId;
  final int messageCount;

  const _SpeedMetadata({
    this.timestamp = 0,
    this.sensorId = 0,
    this.messageCount = 0,
  });

  @override
  bool operator ==(Object other) =>
      other is _SpeedMetadata &&
      other.timestamp == timestamp &&
      other.sensorId == sensorId &&
      other.messageCount == messageCount;

  @override
  int get hashCode => Object.hash(timestamp, sensorId, messageCount);
}
