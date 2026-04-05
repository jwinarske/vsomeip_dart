// Flutter vehicle dashboard example for vsomeip_dart.
//
// Receives real VehicleSpeed events from the vsomeip network via
// libvsomeip_bridge.so and renders a live gauge.
//
// Usage:
//   1. Start simulator: VSOMEIP_CONFIGURATION=... ./build-real/vehicle_sim
//   2. Run this app:    VSOMEIP_CONFIGURATION=... flutter run

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:vsomeip_dart/vsomeip_dart.dart';
import 'package:vsomeip_dart/src/ffi/native_bindings.dart';

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
  VsomeipClient? _client;
  double _speed = 0.0;
  int _messageCount = 0;
  bool _connected = false;
  String _status = 'Disconnected';
  StreamSubscription<dynamic>? _subscription;

  static const _serviceId = 0x1234;
  static const _instanceId = 0x0001;
  static const _eventgroupId = 0x0001;
  static const _speedEventId = 0x8001;

  Future<void> _connect() async {
    try {
      setState(() => _status = 'Connecting...');

      final bindings = NativeVsomeipBindings.open(
        'build-real/libvsomeip_bridge.so',
      );
      final mainPort = ReceivePort('dashboard.main');

      _client = VsomeipClient.create(
        bindings: bindings,
        appName: 'flutter_dashboard',
        mainPort: mainPort,
        nativePort: mainPort.sendPort.nativePort,
      );

      // Request the service so we get availability notifications
      bindings.requestService(_client!, _serviceId, _instanceId);

      // Subscribe to speed events
      final stream = _client!.subscribeEvent(
        serviceId: _serviceId,
        instanceId: _instanceId,
        eventgroupId: _eventgroupId,
        eventId: _speedEventId,
        workerPort: mainPort.sendPort.nativePort,
      );

      _subscription = stream.listen((msg) {
        if (msg.payload != null && msg.payload!.length >= 4) {
          final speed = ByteData.sublistView(
            msg.payload!,
          ).getFloat32(0, Endian.little);
          setState(() {
            _speed = speed;
            _messageCount++;
          });
        }
      });

      // Also listen for raw messages on the mainPort (from Dart_PostCObject_DL)
      mainPort.listen((dynamic msg) {
        if (msg is Uint8List && msg.isNotEmpty) {
          // Discriminator 0x01 = VsomeipMessage
          if (msg[0] == 0x01 && msg.length >= 21) {
            final hdr = WireCodec.decodeHeader(msg);
            if (hdr.serviceId == _serviceId && hdr.methodId == _speedEventId) {
              // Extract payload after the 21-byte header
              Uint8List? payload;
              if (msg.length > 21 && hdr.payloadLen > 0) {
                payload = msg.sublist(21);
              }
              if (payload != null && payload.length >= 4) {
                final speed = ByteData.sublistView(
                  payload,
                ).getFloat32(0, Endian.little);
                setState(() {
                  _speed = speed;
                  _messageCount++;
                });
              }
            }
          }
        }
      });

      setState(() {
        _connected = true;
        _status = 'Connected — waiting for events';
      });
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _disconnect() async {
    await _subscription?.cancel();
    await _client?.close();
    _client = null;
    setState(() {
      _connected = false;
      _speed = 0;
      _messageCount = 0;
      _status = 'Disconnected';
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _client?.close();
    super.dispose();
  }

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
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Status: $_status'),
                    Text('Messages received: $_messageCount'),
                    Text(
                      'Service: 0x${_serviceId.toRadixString(16)} '
                      'Event: 0x${_speedEventId.toRadixString(16)}',
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            Text(
              'Start simulator first:\n'
              'VSOMEIP_CONFIGURATION=example/simulator/vsomeip_local.json '
              './build-real/vehicle_sim',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _connected ? _disconnect : _connect,
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
              style: Theme.of(context).textTheme.headlineLarge,
            ),
          ],
        ),
      ),
    );
  }
}
