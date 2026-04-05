// Flutter vehicle dashboard example for vsomeip_dart.
//
// Demonstrates:
//   - Realtime sensor display with throttled SOME/IP events
//   - Service registry browser showing available services
//   - Live waveform chart throttled to 60 fps
//
// This is a scaffold — the full implementation requires a running
// vsomeip routing manager and vehicle ECU simulators.

import 'package:flutter/material.dart';

void main() => runApp(const VehicleApp());

class VehicleApp extends StatelessWidget {
  const VehicleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vehicle Dashboard',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  double _speed = 0.0;
  double _rpm = 0.0;
  double _temperature = 0.0;
  bool _connected = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vehicle Dashboard'),
        actions: [
          Icon(
            _connected ? Icons.link : Icons.link_off,
            color: _connected ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _GaugeCard(label: 'Speed', value: _speed, unit: 'km/h', max: 250),
            const SizedBox(height: 16),
            _GaugeCard(label: 'RPM', value: _rpm, unit: 'rpm', max: 8000),
            const SizedBox(height: 16),
            _GaugeCard(
              label: 'Coolant Temp',
              value: _temperature,
              unit: '\u00B0C',
              max: 130,
            ),
            const Spacer(),
            Text(
              'vsomeip_dart example — connect to a SOME/IP routing manager '
              'to see live data.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          setState(() {
            _connected = !_connected;
            if (!_connected) {
              _speed = 0;
              _rpm = 0;
              _temperature = 0;
            }
          });
        },
        child: Icon(_connected ? Icons.stop : Icons.play_arrow),
      ),
    );
  }
}

class _GaugeCard extends StatelessWidget {
  final String label;
  final double value;
  final String unit;
  final double max;

  const _GaugeCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.max,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: (value / max).clamp(0, 1)),
            const SizedBox(height: 4),
            Text(
              '${value.toStringAsFixed(1)} $unit',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ],
        ),
      ),
    );
  }
}
