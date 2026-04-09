// Flutter vehicle dashboard example for vsomeip_dart.
//
// Receives real VehicleSpeed events from the vsomeip network via
// libvsomeip_bridge.so and renders a live gauge.
//
// Usage:
//   1. Build: cmake -B build-real src/ -GNinja -DBUILD_VSOMEIP_BRIDGE=ON
//             -DBUILD_VSOMEIP_TOOLS=ON && cmake --build build-real
//   2. Start simulator:
//      VSOMEIP_CONFIGURATION=example/simulator/vsomeip_local.json ./build-real/vehicle_sim
//   3. Run this app:
//      LD_LIBRARY_PATH=../../build-real/
//      VSOMEIP_CONFIGURATION=../../example/simulator/vsomeip_local.json
//      flutter run

import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vsomeip_dart/vsomeip_dart.dart';

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
  // ValueNotifiers drive the gauge painters directly via CustomPainter's
  // repaint listenable. Updates from native callbacks call .value = X
  // which schedules a paint (NOT a setState) — the widget tree never
  // rebuilds during streaming.
  final ValueNotifier<double> _speedNotifier = ValueNotifier(0);
  final ValueNotifier<double> _rpmNotifier = ValueNotifier(0);
  final ValueNotifier<double> _temperatureNotifier = ValueNotifier(0);

  // Phase notifier — values match simulator's PHASE_* constants:
  //   0=idle, 1=accelerate, 2=cruise, 3=brake
  final ValueNotifier<int> _phaseNotifier = ValueNotifier(0);
  static const int _phaseBrake = 3;

  // Sticky brake flag — latched on the callback thread, cleared when rendered.
  // Guarantees that even a momentary brake edge between frames is visible
  // for at least one frame. NativeCallable.listener serializes callbacks
  // to the main isolate, so no atomic/lock is needed.
  bool _brakeLatched = false;

  // Plain state for things that DO need a normal rebuild (infrequent).
  bool _connected = false;
  String _status = 'Disconnected';
  int _messageCount = 0;

  // Low-frequency status refresh — message count + status text update
  // once per second via setState. The high-frequency gauge values use
  // ValueNotifiers and never trigger a widget rebuild.
  Timer? _statusRefreshTimer;

  DynamicLibrary? _bridgeLib;
  Pointer<Void>? _handle;

  // Single ReceivePort for ALL events. The bridge uses Dart_PostCObject_DL
  // with kExternalTypedData — Dart GC owns the payload buffer via finalizer,
  // so there's no use-after-free regardless of when Dart processes the message.
  ReceivePort? _eventsPort;
  StreamSubscription<dynamic>? _portSubscription;

  static const _serviceId = 0x1234;
  static const _instanceId = 0x0001;
  static const _eventgroupId = 0x0001;
  static const _speedEventId = 0x8001;
  static const _rpmEventId = 0x8002;
  static const _tempEventId = 0x8003;
  static const _phaseEventId = 0x8004;

  Future<void> _connect() async {
    try {
      setState(() => _status = 'Loading bridge...');

      // Find libvsomeip_bridge.so: check env, LD_LIBRARY_PATH, then common paths
      final soPath = _findBridgeLibrary();
      setState(() => _status = 'Loading $soPath...');
      final lib = DynamicLibrary.open(soPath);
      _bridgeLib = lib;

      // Initialize Dart API DL
      final initFn = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('vsomeip_bridge_init');
      final initResult = initFn(NativeApi.initializeApiDLData);
      if (initResult != 0) {
        setState(() => _status = 'Error: bridge init failed ($initResult)');
        return;
      }

      setState(() => _status = 'Creating ReceivePort...');

      // Single ReceivePort for all events. The bridge posts via
      // Dart_PostCObject_DL with kExternalTypedData — buffer ownership
      // transfers to the Dart GC, no use-after-free risk.
      final eventsPort = ReceivePort('vsomeip.events');
      _eventsPort = eventsPort;
      final nativePortId = eventsPort.sendPort.nativePort;
      _portSubscription = eventsPort.listen(_onPortMessage);

      setState(() => _status = 'Creating vsomeip app...');

      // Create the vsomeip app — bridge posts to the Dart port via
      // Dart_PostCObject_DL.
      final createFn = lib
          .lookupFunction<
            Pointer<Void> Function(Int64, Pointer<Utf8>, Pointer<Utf8>),
            Pointer<Void> Function(int, Pointer<Utf8>, Pointer<Utf8>)
          >('vsomeip_app_create');

      final appName = 'flutter_dashboard'.toNativeUtf8();
      final handle = createFn(nativePortId, appName, nullptr);
      malloc.free(appName);

      if (handle == nullptr) {
        setState(() => _status = 'Error: vsomeip_app_create failed');
        await _portSubscription?.cancel();
        _eventsPort?.close();
        _portSubscription = null;
        _eventsPort = null;
        return;
      }
      _handle = handle;

      // Wait for vsomeip registration
      await Future<void>.delayed(const Duration(milliseconds: 500));

      setState(() => _status = 'Subscribing to events...');

      // Request the service
      final requestSvcFn = lib
          .lookupFunction<
            Void Function(Pointer<Void>, Uint16, Uint16),
            void Function(Pointer<Void>, int, int)
          >('vsomeip_request_service');
      requestSvcFn(handle, _serviceId, _instanceId);

      // Subscribe using the port-based API. All events flow to the same
      // ReceivePort; the message handler dispatches by method ID.
      final subscribeFn = lib
          .lookupFunction<
            Void Function(Pointer<Void>, Uint16, Uint16, Uint16, Uint16, Int64),
            void Function(Pointer<Void>, int, int, int, int, int)
          >('vsomeip_subscribe');

      subscribeFn(
        handle,
        _serviceId,
        _instanceId,
        _eventgroupId,
        _speedEventId,
        nativePortId,
      );
      subscribeFn(
        handle,
        _serviceId,
        _instanceId,
        _eventgroupId,
        _rpmEventId,
        nativePortId,
      );
      subscribeFn(
        handle,
        _serviceId,
        _instanceId,
        _eventgroupId,
        _tempEventId,
        nativePortId,
      );
      subscribeFn(
        handle,
        _serviceId,
        _instanceId,
        _eventgroupId,
        _phaseEventId,
        nativePortId,
      );

      // Configure native EMA smoothing per signal — runs in C++ before
      // payload crosses the FFI boundary.
      //   Speed: alpha=0.15 (heavy — needle-like motion)
      //   RPM:   alpha=0.25 (medium — engine response)
      //   Temp:  alpha=0.5  (light — slow-moving sensor)
      final setFilterFn = lib
          .lookupFunction<
            Void Function(Uint16, Uint16, Uint16, Uint8, Uint16, Float),
            void Function(int, int, int, int, int, double)
          >('vsomeip_set_filter');

      const filterEma = 1;
      setFilterFn(_serviceId, _instanceId, _speedEventId, filterEma, 0, 0.15);
      setFilterFn(_serviceId, _instanceId, _rpmEventId, filterEma, 0, 0.25);
      setFilterFn(_serviceId, _instanceId, _tempEventId, filterEma, 0, 0.5);

      setState(() {
        _connected = true;
        _status = 'Connected — waiting for events';
      });

      // Refresh status card once per second (no impact on gauge updates)
      _statusRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {
          if (_messageCount > 0 &&
              _status == 'Connected — waiting for events') {
            _status = 'Receiving events';
          }
        });
      });
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  /// Handle a message from the bridge's ReceivePort.
  ///
  /// The bridge posts a 2-element array via Dart_PostCObject_DL:
  ///   msg[0] = Uint8List header (kTypedData — Dart copies during marshal)
  ///   msg[1] = Uint8List payload (kExternalTypedData — Dart GC owns,
  ///            finalizer in C frees the buffer when GC'd)
  ///
  /// Both Uint8Lists are valid for the lifetime of this method (and beyond,
  /// until GC). No use-after-free.
  void _onPortMessage(dynamic msg) {
    if (msg is! List || msg.length != 2) return;
    final header = msg[0];
    final payload = msg[1];
    if (header is! Uint8List || header.length < 21) return;

    // Wire header layout (21 bytes total — discriminator NOT stripped):
    //   [0]      discriminator (0x01 = VsomeipMessage)
    //   [1..2]   service_id LE
    //   [3..4]   instance_id LE
    //   [5..6]   method_id LE
    //   [7]      message_type
    //   [8]      return_code
    //   [9..16]  request_id LE
    //   [17..20] payload_len LE
    if (header[0] != VsomeipDisc.message) return;
    final hdr = ByteData.sublistView(header);
    final methodId = hdr.getUint16(5, Endian.little);

    _messageCount++;

    if (payload is Uint8List) {
      _dispatchMessage(methodId, payload);
    } else {
      // Null payload (header-only message)
      _dispatchMessage(methodId, Uint8List(0));
    }
  }

  void _dispatchMessage(int methodId, Uint8List payload) {
    switch (methodId) {
      case _speedEventId:
        if (payload.length >= 4) {
          _speedNotifier.value = ByteData.sublistView(
            payload,
            0,
            4,
          ).getFloat32(0, Endian.little);
        }
      case _rpmEventId:
        if (payload.length >= 4) {
          _rpmNotifier.value = ByteData.sublistView(
            payload,
            0,
            4,
          ).getFloat32(0, Endian.little);
        }
      case _tempEventId:
        if (payload.length >= 4) {
          _temperatureNotifier.value = ByteData.sublistView(
            payload,
            0,
            4,
          ).getFloat32(0, Endian.little);
        }
      case _phaseEventId:
        if (payload.isNotEmpty) {
          final phase = payload[0];
          if (phase == _phaseBrake) _brakeLatched = true;
          _phaseNotifier.value = phase;
        }
    }
  }

  /// Consume and clear the brake latch. Returns true if brake was active
  /// since the last call. Called by BrakeLightStrip on each render.
  bool _consumeBrakeLatch() {
    final wasLatched = _brakeLatched;
    _brakeLatched = false;
    return wasLatched;
  }

  /// Search for libvsomeip_bridge.so in common locations.
  String _findBridgeLibrary() {
    // 1. Environment variable override
    final envPath = Platform.environment['VSOMEIP_BRIDGE_PATH'];
    if (envPath != null && File(envPath).existsSync()) return envPath;

    // 2. Common build output locations (relative to package root)
    final candidates = [
      'libvsomeip_bridge.so',
      '../../build-real/libvsomeip_bridge.so',
      '../../../build-real/libvsomeip_bridge.so',
      '/usr/local/lib/libvsomeip_bridge.so',
      '/usr/lib/libvsomeip_bridge.so',
    ];

    // Also check LD_LIBRARY_PATH entries
    final ldPath = Platform.environment['LD_LIBRARY_PATH'] ?? '';
    for (final dir in ldPath.split(':')) {
      if (dir.isNotEmpty) {
        candidates.insert(0, '$dir/libvsomeip_bridge.so');
      }
    }

    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }

    // Fall back to bare name — let the dynamic linker try LD_LIBRARY_PATH
    return 'libvsomeip_bridge.so';
  }

  Future<void> _disconnect() async {
    _statusRefreshTimer?.cancel();
    _statusRefreshTimer = null;
    if (_handle != null && _bridgeLib != null) {
      final destroyFn = _bridgeLib!
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('vsomeip_app_destroy');
      destroyFn(_handle!);
    }
    await _portSubscription?.cancel();
    _eventsPort?.close();
    _portSubscription = null;
    _eventsPort = null;
    _handle = null;
    _bridgeLib = null;
    _speedNotifier.value = 0;
    _rpmNotifier.value = 0;
    _temperatureNotifier.value = 0;
    _phaseNotifier.value = 0;
    _brakeLatched = false;
    setState(() {
      _connected = false;
      _messageCount = 0;
      _status = 'Disconnected';
    });
  }

  @override
  void dispose() {
    _disconnect();
    _speedNotifier.dispose();
    _rpmNotifier.dispose();
    _temperatureNotifier.dispose();
    _phaseNotifier.dispose();
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
            // Brake light strip — only visible when phase == brake.
            // Uses the latched brake flag to ensure transient edges show.
            BrakeLightStrip(
              phaseListenable: _phaseNotifier,
              brakePhaseValue: _phaseBrake,
              consumeLatch: _consumeBrakeLatch,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 240,
                  height: 240,
                  child: AnalogSpeedometer(
                    valueListenable: _speedNotifier,
                    max: 250,
                    unit: 'km/h',
                    label: 'Speed',
                    majorTickStep: 25,
                    minorTickStep: 5,
                  ),
                ),
                SizedBox(
                  width: 240,
                  height: 240,
                  child: AnalogSpeedometer(
                    valueListenable: _rpmNotifier,
                    max: 8000,
                    unit: 'x1000 rpm',
                    label: 'Tach',
                    majorTickStep: 1000,
                    minorTickStep: 250,
                    labelDivisor: 1000,
                    redlineStart: 6500,
                    showCenterValue: false,
                  ),
                ),
                SizedBox(
                  width: 110,
                  height: 280,
                  child: VerticalTemperatureGauge(
                    valueListenable: _temperatureNotifier,
                    minValue: 60,
                    maxValue: 130,
                    coldZoneEnd: 80,
                    normalZoneEnd: 100,
                    warningZoneEnd: 110,
                  ),
                ),
              ],
            ),
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
                      'Service: 0x${_serviceId.toRadixString(16)}  '
                      'Events: 0x${_speedEventId.toRadixString(16)}, '
                      '0x${_rpmEventId.toRadixString(16)}, '
                      '0x${_tempEventId.toRadixString(16)}',
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _connected ? _disconnect : _connect,
        icon: Icon(_connected ? Icons.stop : Icons.play_arrow),
        label: Text(_connected ? 'Stop' : 'Connect'),
      ),
    );
  }
}

/// Analog round gauge with sweeping needle, tick marks, and numeric labels.
///
/// Renders a 270° arc from 7:30 to 4:30 (clockwise). Major ticks at
/// [majorTickStep] are labeled; minor ticks at [minorTickStep] are unlabeled.
/// The needle rotates with [value], driven by frame-rate-locked updates.
///
/// Used for both the speedometer (km/h) and the tachometer (rpm) — only the
/// range and tick spacing differ. Optional [redlineStart] highlights the
/// upper portion of the arc in red (e.g., engine redline).
class AnalogSpeedometer extends StatelessWidget {
  final ValueListenable<double> valueListenable;
  final double max;
  final String unit;
  final String label;
  final double majorTickStep;
  final double minorTickStep;
  final int labelDivisor;
  final double? redlineStart;
  final bool showCenterValue;

  const AnalogSpeedometer({
    super.key,
    required this.valueListenable,
    required this.max,
    required this.unit,
    required this.label,
    this.majorTickStep = 25,
    this.minorTickStep = 5,
    this.labelDivisor = 1,
    this.redlineStart,
    this.showCenterValue = true,
  });

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary isolates this gauge to its own layer — repaints
    // here don't dirty pixels of sibling widgets.
    return RepaintBoundary(
      child: CustomPaint(
        painter: _SpeedometerPainter(
          valueListenable: valueListenable,
          max: max,
          unit: unit,
          label: label,
          majorTickStep: majorTickStep,
          minorTickStep: minorTickStep,
          labelDivisor: labelDivisor,
          redlineStart: redlineStart,
          showCenterValue: showCenterValue,
          primaryColor: Theme.of(context).colorScheme.primary,
          textColor: Theme.of(context).colorScheme.onSurface,
          dialColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
      ),
    );
  }
}

class _SpeedometerPainter extends CustomPainter {
  final ValueListenable<double> valueListenable;
  final double max;
  final String unit;
  final String label;
  final double majorTickStep;
  final double minorTickStep;
  final int labelDivisor;
  final double? redlineStart;
  final bool showCenterValue;
  final Color primaryColor;
  final Color textColor;
  final Color dialColor;

  // Sweep from -225° (7:30) to +45° (4:30) = 270° total
  static const double _startAngle = math.pi * 0.75; // 135°
  static const double _sweepAngle = math.pi * 1.5; // 270°

  _SpeedometerPainter({
    required this.valueListenable,
    required this.max,
    required this.unit,
    required this.label,
    required this.majorTickStep,
    required this.minorTickStep,
    required this.labelDivisor,
    required this.redlineStart,
    required this.showCenterValue,
    required this.primaryColor,
    required this.textColor,
    required this.dialColor,
  }) : super(repaint: valueListenable);

  /// Current value, read fresh from the listenable on each paint.
  double get value => valueListenable.value.clamp(0, max).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 8;

    _drawDialBackground(canvas, center, radius);
    _drawArcTrack(canvas, center, radius);
    if (redlineStart != null) {
      _drawRedlineZone(canvas, center, radius);
    }
    _drawValueArc(canvas, center, radius);
    _drawTicks(canvas, center, radius);
    _drawTickLabels(canvas, center, radius);
    _drawCenterText(canvas, center, radius);
    _drawNeedle(canvas, center, radius);
    _drawHub(canvas, center);
  }

  void _drawRedlineZone(Canvas canvas, Offset center, double radius) {
    final start = (redlineStart! / max).clamp(0.0, 1.0);
    final paint = Paint()
      ..color = Colors.red.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.butt;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 8),
      _startAngle + _sweepAngle * start,
      _sweepAngle * (1 - start),
      false,
      paint,
    );
  }

  void _drawDialBackground(Canvas canvas, Offset center, double radius) {
    final paint = Paint()
      ..color = dialColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius + 6, paint);
  }

  void _drawArcTrack(Canvas canvas, Offset center, double radius) {
    final paint = Paint()
      ..color = textColor.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 8),
      _startAngle,
      _sweepAngle,
      false,
      paint,
    );
  }

  void _drawValueArc(Canvas canvas, Offset center, double radius) {
    final fraction = (value / max).clamp(0.0, 1.0);
    if (fraction <= 0) return;

    // Color shifts from green → yellow → red as speed increases
    final color = Color.lerp(
      Colors.green,
      fraction > 0.6 ? Colors.red : Colors.yellow,
      fraction,
    )!;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 8),
      _startAngle,
      _sweepAngle * fraction,
      false,
      paint,
    );
  }

  void _drawTicks(Canvas canvas, Offset center, double radius) {
    final majorPaint = Paint()
      ..color = textColor.withValues(alpha: 0.85)
      ..strokeWidth = 2.5;
    final minorPaint = Paint()
      ..color = textColor.withValues(alpha: 0.4)
      ..strokeWidth = 1.5;

    var v = 0.0;
    while (v <= max + 1e-6) {
      final isMajor = (v % majorTickStep).abs() < 1e-6;
      final fraction = v / max;
      final angle = _startAngle + _sweepAngle * fraction;

      final outerR = radius - 14;
      final innerR = isMajor ? radius - 28 : radius - 22;

      final p1 =
          center + Offset(math.cos(angle) * outerR, math.sin(angle) * outerR);
      final p2 =
          center + Offset(math.cos(angle) * innerR, math.sin(angle) * innerR);
      canvas.drawLine(p1, p2, isMajor ? majorPaint : minorPaint);

      v += minorTickStep;
    }
  }

  void _drawTickLabels(Canvas canvas, Offset center, double radius) {
    var v = 0.0;
    while (v <= max + 1e-6) {
      final fraction = v / max;
      final angle = _startAngle + _sweepAngle * fraction;
      final labelR = radius - 42;
      final pos =
          center + Offset(math.cos(angle) * labelR, math.sin(angle) * labelR);

      final labelValue = (v / labelDivisor).toInt();
      final tp = TextPainter(
        text: TextSpan(
          text: '$labelValue',
          style: TextStyle(
            color: textColor.withValues(alpha: 0.85),
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));

      v += majorTickStep;
    }
  }

  void _drawCenterText(Canvas canvas, Offset center, double radius) {
    if (showCenterValue) {
      final valueText = TextPainter(
        text: TextSpan(
          text: value.toStringAsFixed(0),
          style: TextStyle(
            color: textColor,
            fontSize: 44,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      valueText.paint(
        canvas,
        Offset(center.dx - valueText.width / 2, center.dy + radius * 0.15),
      );

      final unitText = TextPainter(
        text: TextSpan(
          text: unit,
          style: TextStyle(
            color: textColor.withValues(alpha: 0.7),
            fontSize: 14,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      unitText.paint(
        canvas,
        Offset(center.dx - unitText.width / 2, center.dy + radius * 0.15 + 48),
      );
    }

    final labelText = TextPainter(
      text: TextSpan(
        text: label.toUpperCase(),
        style: TextStyle(
          color: textColor.withValues(alpha: 0.6),
          fontSize: 11,
          letterSpacing: 1.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    labelText.paint(
      canvas,
      Offset(center.dx - labelText.width / 2, center.dy - radius * 0.55),
    );
  }

  void _drawNeedle(Canvas canvas, Offset center, double radius) {
    final fraction = (value / max).clamp(0.0, 1.0);
    final angle = _startAngle + _sweepAngle * fraction;

    final tipR = radius - 12;
    final tailR = 12.0;
    final widthR = 6.0;

    final tip = center + Offset(math.cos(angle) * tipR, math.sin(angle) * tipR);
    final tail =
        center - Offset(math.cos(angle) * tailR, math.sin(angle) * tailR);

    // Perpendicular offset for needle width
    final perp = Offset(-math.sin(angle), math.cos(angle));
    final baseLeft = center + perp * widthR;
    final baseRight = center - perp * widthR;

    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(baseLeft.dx, baseLeft.dy)
      ..lineTo(tail.dx, tail.dy)
      ..lineTo(baseRight.dx, baseRight.dy)
      ..close();

    final paint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, paint);

    // Needle outline for contrast
    final outline = Paint()
      ..color = Colors.black.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawPath(path, outline);
  }

  void _drawHub(Canvas canvas, Offset center) {
    canvas.drawCircle(center, 10, Paint()..color = primaryColor);
    canvas.drawCircle(
      center,
      10,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawCircle(center, 4, Paint()..color = Colors.black);
  }

  @override
  bool shouldRepaint(_SpeedometerPainter old) =>
      // Listenable drives in-frame repaints. Only return true here for
      // config changes (rebuilds with different params, e.g. theme switch).
      old.max != max ||
      old.redlineStart != redlineStart ||
      old.primaryColor != primaryColor ||
      old.dialColor != dialColor;
}

class _GaugeCard extends StatelessWidget {
  final String label;
  final ValueListenable<double> valueListenable;
  final String unit;
  final double max;

  const _GaugeCard({
    required this.label,
    required this.valueListenable,
    required this.unit,
    required this.max,
  });

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary + ValueListenableBuilder: only the bar/text rebuild
    // when the value changes — the surrounding Card and label stay stable.
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            RepaintBoundary(
              child: ValueListenableBuilder<double>(
                valueListenable: valueListenable,
                builder: (context, value, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(value: (value / max).clamp(0, 1)),
                    const SizedBox(height: 4),
                    Text(
                      '${value.toStringAsFixed(1)} $unit',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Brake light strip — only visible while the vehicle is braking.
///
/// Listens to a phase notifier (continuous state) AND consumes a sticky
/// "brake latched" flag (transient edge) on each render. This guarantees
/// that even a sub-frame brake pulse is shown for at least one frame.
class BrakeLightStrip extends StatelessWidget {
  final ValueListenable<int> phaseListenable;
  final int brakePhaseValue;
  final bool Function() consumeLatch;

  const BrakeLightStrip({
    super.key,
    required this.phaseListenable,
    required this.brakePhaseValue,
    required this.consumeLatch,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: phaseListenable,
        builder: (context, phase, _) {
          // Consume the latch on every rebuild — combines steady-state
          // (phase == brake) with transient edges (latched flag).
          final latched = consumeLatch();
          final isBraking = phase == brakePhaseValue || latched;

          return AnimatedOpacity(
            opacity: isBraking ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 150),
            child: Container(
              height: 32,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFFFF0000),
                    Color(0xFFFF4040),
                    Color(0xFFFF0000),
                  ],
                ),
                borderRadius: BorderRadius.circular(6),
                boxShadow: [
                  BoxShadow(
                    color: Colors.red.withValues(alpha: 0.7),
                    blurRadius: 16,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Center(
                child: Text(
                  'BRAKE',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Vertical coolant temperature gauge with automotive thermometer icon,
/// color zones, tick marks, and dual °C / °F readouts.
///
/// Color zones (configurable):
///   < coldZoneEnd     blue   (cold — engine warming up)
///   < normalZoneEnd   green  (normal operating temperature)
///   < warningZoneEnd  amber  (warning — running hot)
///   ≥ warningZoneEnd  red    (overheating — stop the engine)
///
/// Uses ValueListenable + CustomPainter(repaint:) like the speedometer:
/// the bar repaints without rebuilding any widgets, frame-rate locked.
class VerticalTemperatureGauge extends StatelessWidget {
  final ValueListenable<double> valueListenable;
  final double minValue;
  final double maxValue;
  final double coldZoneEnd;
  final double normalZoneEnd;
  final double warningZoneEnd;

  const VerticalTemperatureGauge({
    super.key,
    required this.valueListenable,
    this.minValue = 60,
    this.maxValue = 130,
    this.coldZoneEnd = 80,
    this.normalZoneEnd = 100,
    this.warningZoneEnd = 110,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _TemperatureGaugePainter(
          valueListenable: valueListenable,
          minValue: minValue,
          maxValue: maxValue,
          coldZoneEnd: coldZoneEnd,
          normalZoneEnd: normalZoneEnd,
          warningZoneEnd: warningZoneEnd,
          textColor: Theme.of(context).colorScheme.onSurface,
          dialColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
      ),
    );
  }
}

class _TemperatureGaugePainter extends CustomPainter {
  final ValueListenable<double> valueListenable;
  final double minValue;
  final double maxValue;
  final double coldZoneEnd;
  final double normalZoneEnd;
  final double warningZoneEnd;
  final Color textColor;
  final Color dialColor;

  _TemperatureGaugePainter({
    required this.valueListenable,
    required this.minValue,
    required this.maxValue,
    required this.coldZoneEnd,
    required this.normalZoneEnd,
    required this.warningZoneEnd,
    required this.textColor,
    required this.dialColor,
  }) : super(repaint: valueListenable);

  double get value => valueListenable.value.clamp(minValue, maxValue);

  @override
  void paint(Canvas canvas, Size size) {
    // Layout (top to bottom):
    //   icon area    (32 px)
    //   bar          (variable height)
    //   °C readout   (28 px)
    //   °F readout   (20 px)
    const iconArea = 36.0;
    const celsiusArea = 32.0;
    const fahrenheitArea = 22.0;
    final barTop = iconArea;
    final barBottom = size.height - celsiusArea - fahrenheitArea;
    final barHeight = barBottom - barTop;

    // Bar geometry
    const barWidth = 28.0;
    final barLeft = (size.width - barWidth) / 2;
    final barRight = barLeft + barWidth;
    final barRect = Rect.fromLTRB(barLeft, barTop, barRight, barBottom);
    final radius = const Radius.circular(barWidth / 2);

    _drawIcon(canvas, size, iconArea);
    _drawBarBackground(canvas, barRect, radius);
    _drawColorZones(canvas, barRect, radius);
    _drawFill(canvas, barRect, radius, barHeight);
    _drawTicks(canvas, barRect, barHeight);
    _drawCelsius(canvas, size, barBottom);
    _drawFahrenheit(canvas, size);
  }

  void _drawIcon(Canvas canvas, Size size, double iconArea) {
    // Use a TextPainter to render a Material icon glyph (Icons.thermostat)
    // for self-contained rendering inside the painter.
    final iconColor = _zoneColor(value);
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.thermostat.codePoint),
        style: TextStyle(
          fontSize: 30,
          fontFamily: Icons.thermostat.fontFamily,
          package: Icons.thermostat.fontPackage,
          color: iconColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset((size.width - tp.width) / 2, (iconArea - tp.height) / 2),
    );
  }

  void _drawBarBackground(Canvas canvas, Rect bar, Radius r) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(bar.inflate(2), Radius.circular(r.x + 2)),
      Paint()..color = dialColor,
    );
  }

  /// Subtle full-height background color zones (very light) so the user
  /// can see where green/yellow/red bands are even when the bar is empty.
  void _drawColorZones(Canvas canvas, Rect bar, Radius r) {
    final paint = Paint()..style = PaintingStyle.fill;

    // Helper: get the y coordinate for a temperature value (top = max)
    double yFor(double v) {
      final fraction = (v - minValue) / (maxValue - minValue);
      return bar.bottom - fraction * bar.height;
    }

    // Cold zone (bottom of bar)
    paint.color = Colors.blue.withValues(alpha: 0.15);
    canvas.drawRect(
      Rect.fromLTRB(bar.left, yFor(coldZoneEnd), bar.right, bar.bottom),
      paint,
    );
    // Normal zone
    paint.color = Colors.green.withValues(alpha: 0.15);
    canvas.drawRect(
      Rect.fromLTRB(
        bar.left,
        yFor(normalZoneEnd),
        bar.right,
        yFor(coldZoneEnd),
      ),
      paint,
    );
    // Warning zone
    paint.color = Colors.amber.withValues(alpha: 0.15);
    canvas.drawRect(
      Rect.fromLTRB(
        bar.left,
        yFor(warningZoneEnd),
        bar.right,
        yFor(normalZoneEnd),
      ),
      paint,
    );
    // Danger zone (top)
    paint.color = Colors.red.withValues(alpha: 0.15);
    canvas.drawRect(
      Rect.fromLTRB(bar.left, bar.top, bar.right, yFor(warningZoneEnd)),
      paint,
    );

    // Outline
    canvas.drawRRect(
      RRect.fromRectAndRadius(bar, r),
      Paint()
        ..color = textColor.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  void _drawFill(Canvas canvas, Rect bar, Radius r, double barHeight) {
    final fraction = ((value - minValue) / (maxValue - minValue)).clamp(
      0.0,
      1.0,
    );
    if (fraction <= 0) return;

    final fillTop = bar.bottom - fraction * bar.height;
    final fillRect = Rect.fromLTRB(bar.left, fillTop, bar.right, bar.bottom);

    // Save layer to clip the fill to the bar's rounded shape
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(bar, r));
    canvas.drawRect(fillRect, Paint()..color = _zoneColor(value));
    canvas.restore();
  }

  void _drawTicks(Canvas canvas, Rect bar, double barHeight) {
    // Logical ticks every 10°C, labels at zone boundaries and every 20°C
    final tickPaint = Paint()
      ..color = textColor.withValues(alpha: 0.7)
      ..strokeWidth = 1.5;
    final majorTickPaint = Paint()
      ..color = textColor.withValues(alpha: 0.9)
      ..strokeWidth = 2;

    final labeledValues = <double>{
      coldZoneEnd,
      normalZoneEnd,
      warningZoneEnd,
      maxValue,
    };

    for (var v = minValue; v <= maxValue + 0.01; v += 5) {
      final fraction = (v - minValue) / (maxValue - minValue);
      final y = bar.bottom - fraction * bar.height;

      final isMajor = v % 10 == 0;
      final tickLen = isMajor ? 8.0 : 5.0;
      canvas.drawLine(
        Offset(bar.right + 2, y),
        Offset(bar.right + 2 + tickLen, y),
        isMajor ? majorTickPaint : tickPaint,
      );

      if (labeledValues.contains(v) || (isMajor && v % 20 == 0)) {
        final tp = TextPainter(
          text: TextSpan(
            text: '${v.toInt()}',
            style: TextStyle(
              color: textColor.withValues(alpha: 0.85),
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(bar.right + 12, y - tp.height / 2));
      }
    }
  }

  void _drawCelsius(Canvas canvas, Size size, double barBottom) {
    final tp = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: value.toStringAsFixed(0),
            style: TextStyle(
              color: textColor,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          TextSpan(
            text: ' °C',
            style: TextStyle(
              color: textColor.withValues(alpha: 0.7),
              fontSize: 14,
            ),
          ),
        ],
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size.width - tp.width) / 2, barBottom + 4));
  }

  void _drawFahrenheit(Canvas canvas, Size size) {
    final fahrenheit = value * 9 / 5 + 32;
    final tp = TextPainter(
      text: TextSpan(
        text: '${fahrenheit.toStringAsFixed(0)} °F',
        style: TextStyle(
          color: textColor.withValues(alpha: 0.55),
          fontSize: 12,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset((size.width - tp.width) / 2, size.height - tp.height - 2),
    );
  }

  Color _zoneColor(double v) {
    if (v < coldZoneEnd) return Colors.blue.shade400;
    if (v < normalZoneEnd) return Colors.green.shade500;
    if (v < warningZoneEnd) return Colors.amber.shade600;
    return Colors.red.shade600;
  }

  @override
  bool shouldRepaint(_TemperatureGaugePainter old) =>
      old.minValue != minValue ||
      old.maxValue != maxValue ||
      old.coldZoneEnd != coldZoneEnd ||
      old.normalZoneEnd != normalZoneEnd ||
      old.warningZoneEnd != warningZoneEnd ||
      old.dialColor != dialColor ||
      old.textColor != textColor;
}
