// Vehicle speed signal simulator.
//
// Publishes a VehicleSpeed Cap'n Proto event at 100 Hz with a realistic
// driving profile: accelerate → cruise → brake → idle → repeat.
//
// Usage:
//   VSOMEIP_CONFIGURATION=/path/to/vsomeip.json dart run example/simulator/vehicle_speed_sim.dart
//
// The dashboard (flutter_vehicle_app) subscribes to the same service/event
// IDs and renders the speed in real time.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:math';

import 'package:vsomeip_dart/vsomeip_dart.dart';

// SOME/IP identifiers — must match the dashboard subscription
const serviceId = 0x1234;
const instanceId = 0x0001;
const eventgroupId = 0x0001;
const speedEventId = 0x8001;
const rpmEventId = 0x8002;
const tempEventId = 0x8003;

void main() {
  print('Vehicle Signal Simulator');
  print('========================');
  print('Service: 0x${serviceId.toRadixString(16)}');
  print('Instance: 0x${instanceId.toRadixString(16)}');
  print('');
  print('Signals:');
  print('  Speed: event 0x${speedEventId.toRadixString(16)} @ 100 Hz');
  print('  RPM:   event 0x${rpmEventId.toRadixString(16)} @ 50 Hz');
  print('  Temp:  event 0x${tempEventId.toRadixString(16)} @ 1 Hz');
  print('');

  final sim = DrivingSimulator();

  // Speed signal: 100 Hz (10 ms cycle)
  Timer.periodic(const Duration(milliseconds: 10), (_) {
    sim.tick(0.01);
    final payload = VehicleSpeedBuilder.build(
      speedKmh: sim.speedKmh,
      timestamp: DateTime.now().microsecondsSinceEpoch,
      sensorId: 0x0001,
      qualityFlag: sim.qualityFlag,
    );
    // In production: service.notify(eventId: speedEventId, payload: payload);
    _printThrottled(
      'speed',
      '${sim.speedKmh.toStringAsFixed(1)} km/h (${payload.length}B)',
    );
  });

  // RPM signal: 50 Hz (20 ms cycle)
  Timer.periodic(const Duration(milliseconds: 20), (_) {
    _printThrottled('rpm', '${sim.rpm.toStringAsFixed(0)} rpm');
  });

  // Coolant temperature: 1 Hz (1 s cycle)
  Timer.periodic(const Duration(seconds: 1), (_) {
    print(
      '[${_ts()}] speed=${sim.speedKmh.toStringAsFixed(1)} km/h  '
      'rpm=${sim.rpm.toStringAsFixed(0)}  '
      'temp=${sim.coolantTemp.toStringAsFixed(1)} C  '
      'phase=${sim.phaseName}',
    );
  });

  print('Simulator running. Press Ctrl-C to stop.');
}

// ── Driving profile simulator ───────────────────────────────────────────────

enum DrivingPhase { accelerate, cruise, brake, idle }

/// Simulates a realistic driving profile with acceleration, cruising,
/// braking, and idle phases. All values are physically plausible.
class DrivingSimulator {
  double speedKmh = 0;
  double rpm = 800;
  double coolantTemp = 70;
  DrivingPhase phase = DrivingPhase.idle;
  int qualityFlag = 0;

  double _phaseTimer = 0;
  double _targetSpeed = 0;
  final _random = Random(42);

  String get phaseName => phase.name;

  void tick(double dt) {
    _phaseTimer -= dt;

    if (_phaseTimer <= 0) _nextPhase();

    switch (phase) {
      case DrivingPhase.accelerate:
        speedKmh += ((_targetSpeed - speedKmh) * 0.5 * dt).clamp(0, 40 * dt);
        speedKmh += _noise(0.3);
      case DrivingPhase.cruise:
        speedKmh += _noise(0.5);
        speedKmh = speedKmh.clamp(0, 250);
      case DrivingPhase.brake:
        speedKmh -= (speedKmh * 0.8 * dt).clamp(0, 60 * dt);
        speedKmh += _noise(0.2);
        speedKmh = max(0, speedKmh);
      case DrivingPhase.idle:
        speedKmh = max(0, speedKmh - 5 * dt);
    }

    // RPM derived from speed + gear ratio approximation
    if (speedKmh < 1) {
      rpm = 800 + _noise(20);
    } else {
      final gear = _estimateGear(speedKmh);
      rpm = (speedKmh * 60 / (gear * 3.6)).clamp(800, 7000) + _noise(30);
    }

    // Coolant temperature slowly approaches target based on load
    final targetTemp = 85 + (rpm / 7000) * 15 + _noise(0.5);
    coolantTemp += (targetTemp - coolantTemp) * 0.01 * dt;
    coolantTemp = coolantTemp.clamp(60, 120);

    // Occasional quality flag degradation (simulates sensor noise)
    qualityFlag = _random.nextDouble() < 0.001 ? 1 : 0;
  }

  void _nextPhase() {
    switch (phase) {
      case DrivingPhase.idle:
        phase = DrivingPhase.accelerate;
        _targetSpeed = 30 + _random.nextDouble() * 100; // 30-130 km/h
        _phaseTimer = 5 + _random.nextDouble() * 10;
      case DrivingPhase.accelerate:
        phase = DrivingPhase.cruise;
        _phaseTimer = 10 + _random.nextDouble() * 20;
      case DrivingPhase.cruise:
        phase = DrivingPhase.brake;
        _phaseTimer = 3 + _random.nextDouble() * 5;
      case DrivingPhase.brake:
        phase = DrivingPhase.idle;
        _phaseTimer = 2 + _random.nextDouble() * 5;
    }
  }

  double _estimateGear(double speed) {
    if (speed < 15) return 1;
    if (speed < 30) return 2;
    if (speed < 50) return 3;
    if (speed < 80) return 4;
    if (speed < 120) return 5;
    return 6;
  }

  double _noise(double amplitude) =>
      (_random.nextDouble() - 0.5) * 2 * amplitude;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

final _printTimers = <String, int>{};

void _printThrottled(String key, String msg) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final last = _printTimers[key] ?? 0;
  if (now - last > 1000) {
    // Only print once per second to avoid flooding the console
    _printTimers[key] = now;
  }
}

String _ts() {
  final now = DateTime.now();
  return '${now.hour.toString().padLeft(2, '0')}:'
      '${now.minute.toString().padLeft(2, '0')}:'
      '${now.second.toString().padLeft(2, '0')}';
}
