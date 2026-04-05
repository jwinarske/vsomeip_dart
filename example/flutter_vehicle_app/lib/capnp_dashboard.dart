// Cap'n Proto dashboard widget for the Flutter vehicle app.
//
// Demonstrates zero-copy Cap'n Proto payload reading in a Flutter widget:
//   - VehicleSpeedReader reads directly from native memory (Path A)
//   - SignalThrottle caps the UI update rate at 60 Hz
//   - setState() is safe because messages arrive on the main isolate
//
// This file is a scaffold — the full implementation requires a running
// vsomeip routing manager with a speed signal provider.

import 'package:flutter/material.dart';
import 'package:vsomeip_dart/vsomeip_dart.dart';

/// Dashboard widget that displays vehicle speed from a Cap'n Proto
/// SOME/IP event using zero-copy field access.
class CapnpDashboard extends StatefulWidget {
  const CapnpDashboard({super.key});

  @override
  State<CapnpDashboard> createState() => _CapnpDashboardState();
}

class _CapnpDashboardState extends State<CapnpDashboard> {
  double _speed = 0.0;
  int _timestamp = 0;
  int _sensorId = 0;
  int _messageCount = 0;
  int _droppedCount = 0;

  // In production these would be initialized from VsomeipClient.subscribeCapnp()
  // final VsomeipClient? _client;

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

            // Speed gauge
            LinearProgressIndicator(value: (_speed / 250).clamp(0, 1)),
            const SizedBox(height: 4),
            Text(
              '${_speed.toStringAsFixed(1)} km/h',
              style: Theme.of(context).textTheme.headlineLarge,
            ),

            const SizedBox(height: 12),

            // Metadata
            Text('Sensor: 0x${_sensorId.toRadixString(16).padLeft(4, '0')}'),
            Text('Timestamp: $_timestamp'),
            Text('Messages received: $_messageCount'),
            Text('Dropped by throttle: $_droppedCount'),

            const SizedBox(height: 8),
            const Text(
              'Zero-copy: VehicleSpeedReader reads float32 directly '
              'from native memory — no parse, no decode.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// Called when a Cap'n Proto message arrives from the worker isolate.
  /// In production, this is wired to the subscribeCapnp stream.
  void onCapnpMessage(SomeIpMessage msg) {
    if (msg.payload == null || msg.payload!.isEmpty) return;

    // Zero-copy read: VehicleSpeedReader accesses fields at fixed offsets
    // in the native memory buffer — no allocation, no parse.
    final reader = VehicleSpeedReader(msg.payload!);

    setState(() {
      _speed = reader.speedKmh;
      _timestamp = reader.timestamp;
      _sensorId = reader.sensorId;
      _messageCount++;
    });
  }
}
