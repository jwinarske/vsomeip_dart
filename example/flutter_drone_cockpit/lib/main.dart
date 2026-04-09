// Flutter drone cockpit example for vsomeip_dart.
//
// Displays a drone cockpit with:
//   - Artificial horizon (attitude indicator)
//   - Compass / heading
//   - Altitude tape
//   - Speed tape
//   - Vertical speed indicator
//   - Battery + signal indicators
//   - Mode + GPS status
//
// Telemetry arrives from drone_sim over vsomeip via the same port-based
// pipeline used by flutter_vehicle_app:
//   bridge → Dart_PostCObject_DL → ReceivePort → ValueNotifier → CustomPainter
//
// Build & run:
//   1. Build bridge + simulator:
//      cmake -B build-real src/ -GNinja && cmake --build build-real
//   2. Start simulator:
//      VSOMEIP_CONFIGURATION=example/flutter_drone_cockpit/vsomeip_drone.json \
//        ./build-real/drone_sim
//   3. Run cockpit:
//      cd example/flutter_drone_cockpit && \
//        LD_LIBRARY_PATH=../../build-real \
//        VSOMEIP_CONFIGURATION=../../example/flutter_drone_cockpit/vsomeip_drone.json \
//        flutter run

import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:vsomeip_dart/vsomeip_dart.dart';

void main() => runApp(const DroneCockpitApp());

class DroneCockpitApp extends StatelessWidget {
  const DroneCockpitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Drone Cockpit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          surface: Color(0xFF0A0F1A),
        ),
        scaffoldBackgroundColor: const Color(0xFF050810),
        useMaterial3: true,
      ),
      home: const CockpitScreen(),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
// SmoothedValue — frame-rate interpolation between samples.
//
// Each high-frequency telemetry float gets one of these. The native callback
// thread sets `target = X` (the latest received sample) and a per-frame
// callback lerps the displayed `notifier.value` toward that target.
//
// The result is fluid motion at the screen refresh rate, even when the
// underlying telemetry arrives at 10 Hz (motion) or 50 Hz (attitude).
//
// Combined with the C++ EMA filter, this gives two stages of smoothing:
//   1. Bridge EMA — rejects sensor noise within the sample stream
//   2. Frame-rate lerp (this class) — interpolates BETWEEN samples
// ───────────────────────────────────────────────────────────────────────────

class SmoothedValue {
  final ValueNotifier<double> notifier;

  /// Fraction of the remaining gap to close per frame. 0.25 ≈ 64ms time
  /// constant at 60fps. Higher = snappier, lower = smoother.
  final double smoothing;

  /// If true, treats the value as an angle in radians and takes the shortest
  /// path through ±π when interpolating (so 359°→1° goes the short way, not
  /// backwards through 358°…2°).
  final bool wrapAngle;

  double _target;
  bool _ticking = false;
  bool _disposed = false;

  SmoothedValue({
    double initial = 0,
    this.smoothing = 0.25,
    this.wrapAngle = false,
  }) : notifier = ValueNotifier(initial),
       _target = initial;

  /// The latest received value. Setting this schedules frame callbacks
  /// until the displayed value catches up.
  double get target => _target;
  set target(double v) {
    if (_disposed) return;
    _target = v;
    _ensureTicking();
  }

  /// Snap to a value immediately (no interpolation). Used on connect/reset.
  void snap(double v) {
    _target = v;
    notifier.value = v;
  }

  void _ensureTicking() {
    if (_ticking || _disposed) return;
    _ticking = true;
    SchedulerBinding.instance.scheduleFrameCallback(_tick);
  }

  void _tick(Duration _) {
    if (_disposed) {
      _ticking = false;
      return;
    }
    final current = notifier.value;
    var delta = _target - current;

    // Wrap-aware delta for angles
    if (wrapAngle) {
      const twoPi = math.pi * 2;
      while (delta > math.pi) {
        delta -= twoPi;
      }
      while (delta < -math.pi) {
        delta += twoPi;
      }
    }

    const epsilon = 0.0005;
    if (delta.abs() < epsilon) {
      // Snap to target and stop ticking until the next setter call
      notifier.value = wrapAngle
          ? ((_target % (math.pi * 2)) + math.pi * 2) % (math.pi * 2)
          : _target;
      _ticking = false;
      return;
    }

    var next = current + delta * smoothing;
    if (wrapAngle) {
      const twoPi = math.pi * 2;
      next = ((next % twoPi) + twoPi) % twoPi;
    }
    notifier.value = next;

    SchedulerBinding.instance.scheduleFrameCallback(_tick);
  }

  void dispose() {
    _disposed = true;
    notifier.dispose();
  }
}

// ───────────────────────────────────────────────────────────────────────────
// SignalHistory — bounded ring buffer of recent samples for sparkline graphs.
//
// Implemented as a single Float64List with a head index. Always exposes a
// snapshot in chronological order via [samples]. Wired to a ChangeNotifier
// so the sparkline painter can use it as a `repaint:` listenable.
// ───────────────────────────────────────────────────────────────────────────

class SignalHistory extends ChangeNotifier {
  final int capacity;
  final Float64List _buf;
  int _head = 0;
  int _count = 0;

  // Throttle history capture so we don't append on every smoother step —
  // record a sample at most once per [interval]. Default ~50 ms.
  final Duration interval;
  int _lastCaptureMs = 0;

  SignalHistory({
    this.capacity = 120,
    this.interval = const Duration(milliseconds: 50),
  }) : _buf = Float64List(capacity);

  /// Append a new sample. Throttled by [interval].
  void add(double value) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastCaptureMs < interval.inMilliseconds) return;
    _lastCaptureMs = now;
    _buf[_head] = value;
    _head = (_head + 1) % capacity;
    if (_count < capacity) _count++;
    notifyListeners();
  }

  /// Returns samples in chronological order (oldest first).
  /// Length equals [length].
  Iterable<double> get samples sync* {
    if (_count == 0) return;
    final start = (_head - _count + capacity) % capacity;
    for (var i = 0; i < _count; i++) {
      yield _buf[(start + i) % capacity];
    }
  }

  int get length => _count;
  bool get isEmpty => _count == 0;

  (double, double) get range {
    if (_count == 0) return (0, 1);
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (final v in samples) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    if (lo == hi) return (lo - 1, hi + 1);
    return (lo, hi);
  }

  void clear() {
    _head = 0;
    _count = 0;
    _lastCaptureMs = 0;
    notifyListeners();
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Telemetry state — smoothed values for high-frequency floats, plain
// notifiers for discrete/low-rate signals.
// ───────────────────────────────────────────────────────────────────────────

class _Telemetry {
  // Attitude (radians) — 50 Hz native, lighter smoothing (sample interval
  // is already close to one frame)
  final SmoothedValue pitch = SmoothedValue(smoothing: 0.5);
  final SmoothedValue roll = SmoothedValue(smoothing: 0.5);
  final SmoothedValue yaw = SmoothedValue(smoothing: 0.4, wrapAngle: true);
  final SmoothedValue throttle = SmoothedValue(smoothing: 0.4);

  // Motion — 10 Hz native, heavier smoothing (6 frames between samples,
  // need ~70% caught up by next sample)
  final SmoothedValue altitude = SmoothedValue(smoothing: 0.25);
  final SmoothedValue vsi = SmoothedValue(smoothing: 0.25);
  final SmoothedValue groundSpeed = SmoothedValue(smoothing: 0.25);
  final SmoothedValue distance = SmoothedValue(smoothing: 0.25);

  // Battery — low rate, displayed as text, no interpolation needed
  final ValueNotifier<double> voltage = ValueNotifier(0);
  final ValueNotifier<double> percent = ValueNotifier(0);

  // Status — discrete state
  final ValueNotifier<int> armed = ValueNotifier(0);
  final ValueNotifier<int> flightMode = ValueNotifier(0);
  final ValueNotifier<int> gpsFix = ValueNotifier(0);
  final ValueNotifier<int> satCount = ValueNotifier(0);

  // Signal — low rate
  final ValueNotifier<int> rssi = ValueNotifier(0);
  final ValueNotifier<int> linkQuality = ValueNotifier(0);

  // Gimbal — degrees, 5 Hz native, smoothed lightly
  final SmoothedValue gimbalPitch = SmoothedValue(smoothing: 0.30);
  final SmoothedValue gimbalRoll = SmoothedValue(smoothing: 0.30);

  // Sparkline history — 120 samples × 50 ms = 6 sec window
  final SignalHistory altitudeHistory = SignalHistory();
  final SignalHistory vsiHistory = SignalHistory();
  final SignalHistory groundSpeedHistory = SignalHistory();

  // Last-update wall-clock for the watchdog (ms since epoch).
  // Updated by every payload processed.
  int lastUpdateMs = 0;

  // HUD info
  // armedSinceMs == 0 means not armed; otherwise wall-clock when ARMED rose.
  final ValueNotifier<int> armedSinceMs = ValueNotifier(0);
  // Estimated battery time remaining in seconds; -1 if unknown.
  final ValueNotifier<int> batteryRemainingSec = ValueNotifier(-1);
  // Drain anchor for the estimator.
  int _battAnchorMs = 0;
  double _battAnchorPct = -1;

  void dispose() {
    pitch.dispose();
    roll.dispose();
    yaw.dispose();
    throttle.dispose();
    altitude.dispose();
    vsi.dispose();
    groundSpeed.dispose();
    distance.dispose();
    voltage.dispose();
    percent.dispose();
    armed.dispose();
    flightMode.dispose();
    gpsFix.dispose();
    satCount.dispose();
    rssi.dispose();
    linkQuality.dispose();
    gimbalPitch.dispose();
    gimbalRoll.dispose();
    armedSinceMs.dispose();
    batteryRemainingSec.dispose();
    altitudeHistory.dispose();
    vsiHistory.dispose();
    groundSpeedHistory.dispose();
  }

  void reset() {
    pitch.snap(0);
    roll.snap(0);
    yaw.snap(0);
    throttle.snap(0);
    altitude.snap(0);
    vsi.snap(0);
    groundSpeed.snap(0);
    distance.snap(0);
    voltage.value = 0;
    percent.value = 0;
    armed.value = 0;
    flightMode.value = 0;
    gpsFix.value = 0;
    satCount.value = 0;
    rssi.value = 0;
    linkQuality.value = 0;
    gimbalPitch.snap(0);
    gimbalRoll.snap(0);
    altitudeHistory.clear();
    vsiHistory.clear();
    groundSpeedHistory.clear();
    lastUpdateMs = 0;
    armedSinceMs.value = 0;
    batteryRemainingSec.value = -1;
    _battAnchorMs = 0;
    _battAnchorPct = -1;
  }

  /// Update the battery time-remaining estimate from a new percent sample.
  /// Anchors to the first sample, then updates whenever the percent has
  /// dropped by ≥1% — projects current drain rate forward to 0%.
  void updateBatteryEstimate(double pct) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_battAnchorPct < 0) {
      _battAnchorMs = now;
      _battAnchorPct = pct;
      return;
    }
    final dropped = _battAnchorPct - pct;
    if (dropped >= 1.0) {
      final dtSec = (now - _battAnchorMs) / 1000.0;
      if (dtSec > 0) {
        final pctPerSec = dropped / dtSec;
        if (pctPerSec > 0) {
          batteryRemainingSec.value = (pct / pctPerSec).round();
        }
      }
      _battAnchorMs = now;
      _battAnchorPct = pct;
    }
  }

  /// Apply an ARMED state transition. Sets/clears the flight-time anchor.
  void updateArmedTransition(int newArmed) {
    final wasArmed = armed.value != 0;
    final isArmed = newArmed != 0;
    if (isArmed && !wasArmed) {
      armedSinceMs.value = DateTime.now().millisecondsSinceEpoch;
    } else if (!isArmed && wasArmed) {
      armedSinceMs.value = 0;
    }
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Cockpit screen — owns the connection and lays out instruments
// ───────────────────────────────────────────────────────────────────────────

class CockpitScreen extends StatefulWidget {
  const CockpitScreen({super.key});

  @override
  State<CockpitScreen> createState() => _CockpitScreenState();
}

class _CockpitScreenState extends State<CockpitScreen> {
  final _Telemetry _t = _Telemetry();
  bool _connected = false;
  String _status = 'Disconnected';

  DynamicLibrary? _bridgeLib;
  Pointer<Void>? _handle;
  ReceivePort? _eventsPort;
  StreamSubscription<dynamic>? _portSubscription;

  // Joystick state — 4 floats sent at 50 Hz to the drone via fire-and-forget
  // method calls. Updated by both joysticks; sent by a periodic timer while
  // the joysticks are non-zero (or were recently).
  double _ctrlThr = 0;
  double _ctrlYaw = 0;
  double _ctrlPitch = 0;
  double _ctrlRoll = 0;
  Timer? _ctrlTimer;
  Pointer<Uint8>? _ctrlBuf;

  // Watchdog: monitors `_t.lastUpdateMs` and re-subscribes if telemetry
  // stalls for more than `_watchdogStaleMs` while connected. Handles cases
  // where the routing host (drone_sim) restarts mid-flight.
  Timer? _watchdogTimer;
  static const _watchdogStaleMs = 2000;
  bool _stale = false;

  static const _serviceId = 0x2000;
  static const _instanceId = 0x0001;
  static const _eventgroupId = 0x0001;
  static const _attitudeEvt = 0x9001;
  static const _motionEvt = 0x9002;
  static const _batteryEvt = 0x9003;
  static const _statusEvt = 0x9004;
  static const _signalEvt = 0x9005;
  static const _gimbalEvt = 0x9006;
  static const _ctrlMethod = 0xA001;

  Future<void> _connect() async {
    try {
      setState(() => _status = 'Loading bridge...');
      final lib = DynamicLibrary.open(_findBridgeLibrary());
      _bridgeLib = lib;

      final initFn = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('vsomeip_bridge_init');
      if (initFn(NativeApi.initializeApiDLData) != 0) {
        setState(() => _status = 'Bridge init failed');
        return;
      }

      final eventsPort = ReceivePort('drone.events');
      _eventsPort = eventsPort;
      final nativePortId = eventsPort.sendPort.nativePort;
      _portSubscription = eventsPort.listen(_onPortMessage);

      final createFn = lib
          .lookupFunction<
            Pointer<Void> Function(Int64, Pointer<Utf8>, Pointer<Utf8>),
            Pointer<Void> Function(int, Pointer<Utf8>, Pointer<Utf8>)
          >('vsomeip_app_create');

      final appName = 'drone_cockpit'.toNativeUtf8();
      final handle = createFn(nativePortId, appName, nullptr);
      malloc.free(appName);

      if (handle == nullptr) {
        setState(() => _status = 'vsomeip_app_create failed');
        await _disconnect();
        return;
      }
      _handle = handle;

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final requestSvcFn = lib
          .lookupFunction<
            Void Function(Pointer<Void>, Uint16, Uint16),
            void Function(Pointer<Void>, int, int)
          >('vsomeip_request_service');
      requestSvcFn(handle, _serviceId, _instanceId);

      final subscribeFn = lib
          .lookupFunction<
            Void Function(Pointer<Void>, Uint16, Uint16, Uint16, Uint16, Int64),
            void Function(Pointer<Void>, int, int, int, int, int)
          >('vsomeip_subscribe');

      for (final evt in [
        _attitudeEvt,
        _motionEvt,
        _batteryEvt,
        _statusEvt,
        _signalEvt,
        _gimbalEvt,
      ]) {
        subscribeFn(
          handle,
          _serviceId,
          _instanceId,
          _eventgroupId,
          evt,
          nativePortId,
        );
      }

      // Native EMA filters for the high-frequency telemetry. The bridge
      // supports multiple filters per (svc, inst, evt) tuple — one per byte
      // offset — so we can smooth pitch, roll, and yaw on the same attitude
      // event with independent rates.
      final setFilterFn = lib
          .lookupFunction<
            Void Function(Uint16, Uint16, Uint16, Uint8, Uint16, Float),
            void Function(int, int, int, int, int, double)
          >('vsomeip_set_filter');
      const filterEma = 1;

      // Attitude payload: [float pitch][float roll][float yaw][float throttle]
      // Pitch is the most visually critical (drives the artificial horizon),
      // so it gets the heaviest smoothing. Yaw drives the heading tape and
      // can be lighter. Throttle is not displayed prominently — no filter.
      setFilterFn(_serviceId, _instanceId, _attitudeEvt, filterEma, 0, 0.18);
      setFilterFn(_serviceId, _instanceId, _attitudeEvt, filterEma, 4, 0.20);
      setFilterFn(_serviceId, _instanceId, _attitudeEvt, filterEma, 8, 0.30);

      // Motion payload: [float alt][float vsi][float gnd_speed][float dist]
      // VSI is a derivative — extremely jittery on real drones. Filter heavy.
      // Altitude gets a light filter, distance is monotonic so no filter.
      setFilterFn(_serviceId, _instanceId, _motionEvt, filterEma, 0, 0.50);
      setFilterFn(_serviceId, _instanceId, _motionEvt, filterEma, 4, 0.30);

      setState(() {
        _connected = true;
        _status = 'Connected — waiting for telemetry';
      });
      _t.lastUpdateMs = DateTime.now().millisecondsSinceEpoch;
      _startWatchdog();
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  /// Send the current joystick state to the drone via fire-and-forget.
  /// Called at 50 Hz by `_ctrlTimer` while joysticks are active.
  void _sendControlInput() {
    if (_handle == null || _bridgeLib == null) return;
    final lib = _bridgeLib!;

    // Allocate the 16-byte buffer once and reuse.
    _ctrlBuf ??= malloc<Uint8>(16);
    final buf = _ctrlBuf!;

    // Pack 4 floats LE: [thr][yaw][pitch][roll]
    final bd = buf.cast<Float>();
    bd[0] = _ctrlThr;
    bd[1] = _ctrlYaw;
    bd[2] = _ctrlPitch;
    bd[3] = _ctrlRoll;

    final sendFn = lib
        .lookupFunction<
          Void Function(
            Pointer<Void>,
            Uint16,
            Uint16,
            Uint16,
            Pointer<Uint8>,
            Uint32,
          ),
          void Function(Pointer<Void>, int, int, int, Pointer<Uint8>, int)
        >('vsomeip_send_fire_forget');
    sendFn(_handle!, _serviceId, _instanceId, _ctrlMethod, buf, 16);
  }

  void _ensureCtrlTimer() {
    _ctrlTimer ??= Timer.periodic(
      const Duration(milliseconds: 20), // 50 Hz
      (_) => _sendControlInput(),
    );
  }

  void _stopCtrlTimer() {
    _ctrlTimer?.cancel();
    _ctrlTimer = null;
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_connected) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final age = now - _t.lastUpdateMs;
      if (age > _watchdogStaleMs) {
        if (!_stale) {
          _stale = true;
          if (mounted) setState(() => _status = 'Link stalled — reconnecting');
        }
        _reconnect();
      } else if (_stale) {
        _stale = false;
        if (mounted) setState(() => _status = 'Live');
      }
    });
  }

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _stale = false;
  }

  Future<void> _reconnect() async {
    if (!_connected) return;
    await _disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    await _connect();
  }

  Future<void> _disconnect() async {
    _stopWatchdog();
    _stopCtrlTimer();
    if (_ctrlBuf != null) {
      malloc.free(_ctrlBuf!);
      _ctrlBuf = null;
    }
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
    _t.reset();
    setState(() {
      _connected = false;
      _status = 'Disconnected';
    });
  }

  void _onPortMessage(dynamic msg) {
    if (msg is! List || msg.length != 2) return;
    final header = msg[0];
    final payload = msg[1];
    if (header is! Uint8List || header.length < 21) return;
    if (header[0] != VsomeipDisc.message) return;

    final methodId = ByteData.sublistView(header).getUint16(5, Endian.little);

    if (payload is! Uint8List) return;
    final pd = ByteData.sublistView(payload);

    switch (methodId) {
      case _attitudeEvt:
        if (payload.length >= 16) {
          // Set targets — SmoothedValue lerps the displayed value toward
          // each new sample at frame rate.
          _t.pitch.target = pd.getFloat32(0, Endian.little);
          _t.roll.target = pd.getFloat32(4, Endian.little);
          _t.yaw.target = pd.getFloat32(8, Endian.little);
          _t.throttle.target = pd.getFloat32(12, Endian.little);
        }
      case _motionEvt:
        if (payload.length >= 16) {
          final alt = pd.getFloat32(0, Endian.little);
          final vsi = pd.getFloat32(4, Endian.little);
          final gs = pd.getFloat32(8, Endian.little);
          _t.altitude.target = alt;
          _t.vsi.target = vsi;
          _t.groundSpeed.target = gs;
          _t.distance.target = pd.getFloat32(12, Endian.little);
          _t.altitudeHistory.add(alt);
          _t.vsiHistory.add(vsi);
          _t.groundSpeedHistory.add(gs);
        }
      case _batteryEvt:
        if (payload.length >= 8) {
          _t.voltage.value = pd.getFloat32(0, Endian.little);
          final pct = pd.getFloat32(4, Endian.little);
          _t.percent.value = pct;
          _t.updateBatteryEstimate(pct);
        }
      case _statusEvt:
        if (payload.length >= 4) {
          _t.updateArmedTransition(payload[0]);
          _t.armed.value = payload[0];
          _t.flightMode.value = payload[1];
          _t.gpsFix.value = payload[2];
          _t.satCount.value = payload[3];
        }
      case _signalEvt:
        if (payload.length >= 2) {
          _t.rssi.value = payload[0];
          _t.linkQuality.value = payload[1];
        }
      case _gimbalEvt:
        if (payload.length >= 8) {
          _t.gimbalPitch.target = pd.getFloat32(0, Endian.little);
          _t.gimbalRoll.target = pd.getFloat32(4, Endian.little);
        }
    }

    // Watchdog timestamp — used by auto-reconnect.
    _t.lastUpdateMs = DateTime.now().millisecondsSinceEpoch;

    // Flip status to "Live" on first telemetry after connect/reconnect.
    if (_status != 'Live') {
      setState(() => _status = 'Live');
    }
  }

  String _findBridgeLibrary() {
    final env = Platform.environment['VSOMEIP_BRIDGE_PATH'];
    if (env != null && File(env).existsSync()) return env;
    final candidates = [
      'libvsomeip_bridge.so',
      '../../build-real/libvsomeip_bridge.so',
    ];
    final ldPath = Platform.environment['LD_LIBRARY_PATH'] ?? '';
    for (final dir in ldPath.split(':')) {
      if (dir.isNotEmpty) {
        candidates.insert(0, '$dir/libvsomeip_bridge.so');
      }
    }
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    return 'libvsomeip_bridge.so';
  }

  @override
  void dispose() {
    _disconnect();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 400),
          opacity: _stale ? 0.45 : 1.0,
          child: Stack(
            children: [
              // ── Top status bar — armed badge | CONNECT | batt sig gps ──
              //
              // All badges have FIXED widths so the row layout doesn't
              // reflow when text content changes (e.g., ARMED ↔ DISARMED,
              // 100% ↔ 5%, NO FIX ↔ DGPS). Avoids visual jitter in the
              // status bar.
              Positioned(
                top: 12,
                left: 16,
                right: 16,
                child: SizedBox(
                  height: 48,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 100,
                        child: ValueListenableBuilder<int>(
                          valueListenable: _t.armed,
                          builder: (_, armed, __) => AnimatedSwitcher(
                            duration: const Duration(milliseconds: 350),
                            transitionBuilder: (child, anim) => ScaleTransition(
                              scale: Tween<double>(
                                begin: 1.15,
                                end: 1.0,
                              ).animate(anim),
                              child: FadeTransition(
                                opacity: anim,
                                child: child,
                              ),
                            ),
                            child: StatusBadge(
                              key: ValueKey<int>(armed),
                              text: armed != 0 ? 'ARMED' : 'DISARMED',
                              color: armed != 0 ? Colors.red : Colors.grey,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 140,
                        child: FilledButton.tonal(
                          onPressed: _connected ? _disconnect : _connect,
                          child: Text(_connected ? 'DISCONNECT' : 'CONNECT'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: HudInfoBar(
                          armedSinceListenable: _t.armedSinceMs,
                          batteryRemainingSecListenable: _t.batteryRemainingSec,
                          gpsFixListenable: _t.gpsFix,
                        ),
                      ),
                      const SizedBox(width: 16),
                      SizedBox(
                        width: 130,
                        child: BatteryIndicator(
                          percentListenable: _t.percent,
                          voltageListenable: _t.voltage,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 100,
                        child: SignalIndicator(
                          rssiListenable: _t.rssi,
                          linkListenable: _t.linkQuality,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 130,
                        child: GpsIndicator(
                          fixListenable: _t.gpsFix,
                          satListenable: _t.satCount,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Top instrument row (below status bar) ──
              Positioned(
                top: 70,
                left: 16,
                right: 16,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Speed tape
                    SizedBox(
                      width: 70,
                      height: 280,
                      child: TapeIndicator(
                        valueListenable: _t.groundSpeed.notifier,
                        label: 'GS',
                        unit: 'm/s',
                        majorStep: 5,
                        minorStep: 1,
                        range: 30,
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Attitude indicator (artificial horizon)
                    Expanded(
                      child: SizedBox(
                        height: 280,
                        child: AttitudeIndicator(
                          pitchListenable: _t.pitch.notifier,
                          rollListenable: _t.roll.notifier,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Altitude tape
                    SizedBox(
                      width: 80,
                      height: 280,
                      child: TapeIndicator(
                        valueListenable: _t.altitude.notifier,
                        label: 'ALT',
                        unit: 'm',
                        majorStep: 10,
                        minorStep: 2,
                        range: 60,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // VSI — to the right of the altitude tape
                    SizedBox(
                      width: 50,
                      height: 280,
                      child: VsiIndicator(vsiListenable: _t.vsi.notifier),
                    ),
                  ],
                ),
              ),

              // ── Compass row (below the instruments) ──
              Positioned(
                left: 16,
                right: 16,
                top: 366,
                child: SizedBox(
                  height: 60,
                  child: HeadingTape(yawListenable: _t.yaw.notifier),
                ),
              ),

              // ── Sparkline row — 6-second history graphs ──
              Positioned(
                left: 16,
                right: 16,
                top: 432,
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 56,
                        child: Sparkline(
                          history: _t.altitudeHistory,
                          label: 'ALTITUDE',
                          lineColor: const Color(0xFF00E5FF),
                          fillColor: const Color(0x3300E5FF),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(
                        height: 56,
                        child: Sparkline(
                          history: _t.vsiHistory,
                          label: 'VSI',
                          lineColor: const Color(0xFF8AFF6F),
                          fillColor: const Color(0x338AFF6F),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(
                        height: 56,
                        child: Sparkline(
                          history: _t.groundSpeedHistory,
                          label: 'GND SPD',
                          lineColor: const Color(0xFFFFD24A),
                          fillColor: const Color(0x33FFD24A),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Bottom-left: throttle / yaw joystick ──
              Positioned(
                bottom: 24,
                left: 24,
                child: Joystick(
                  size: 150,
                  label: 'THR / YAW',
                  onChanged: (x, y) {
                    _ctrlYaw = x;
                    _ctrlThr = y;
                    if (_ctrlThr.abs() > 0.01 ||
                        _ctrlYaw.abs() > 0.01 ||
                        _ctrlPitch.abs() > 0.01 ||
                        _ctrlRoll.abs() > 0.01) {
                      _ensureCtrlTimer();
                    }
                    if (_connected) _sendControlInput();
                  },
                ),
              ),

              // ── Bottom-right: pitch / roll joystick ──
              Positioned(
                bottom: 24,
                right: 24,
                child: Joystick(
                  size: 150,
                  label: 'PITCH / ROLL',
                  onChanged: (x, y) {
                    _ctrlRoll = x;
                    _ctrlPitch = y;
                    if (_ctrlThr.abs() > 0.01 ||
                        _ctrlYaw.abs() > 0.01 ||
                        _ctrlPitch.abs() > 0.01 ||
                        _ctrlRoll.abs() > 0.01) {
                      _ensureCtrlTimer();
                    }
                    if (_connected) _sendControlInput();
                  },
                ),
              ),

              // ── Bottom-center: status text + flight mode ──
              Positioned(
                bottom: 24,
                left: 0,
                right: 0,
                child: Center(
                  child: Column(
                    children: [
                      ValueListenableBuilder<int>(
                        valueListenable: _t.flightMode,
                        builder: (_, mode, __) => Text(
                          _flightModeName(mode),
                          style: const TextStyle(
                            color: Color(0xFF00E5FF),
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 4,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _status,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _flightModeName(int mode) {
    switch (mode) {
      case 0:
        return 'MANUAL';
      case 1:
        return 'STABILIZE';
      case 2:
        return 'LOITER';
      case 3:
        return 'RTH';
      default:
        return '?';
    }
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Attitude Indicator (artificial horizon)
// ───────────────────────────────────────────────────────────────────────────

class AttitudeIndicator extends StatelessWidget {
  final ValueListenable<double> pitchListenable;
  final ValueListenable<double> rollListenable;

  const AttitudeIndicator({
    super.key,
    required this.pitchListenable,
    required this.rollListenable,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CustomPaint(
          painter: _AttitudePainter(
            pitchListenable: pitchListenable,
            rollListenable: rollListenable,
          ),
        ),
      ),
    );
  }
}

class _AttitudePainter extends CustomPainter {
  final ValueListenable<double> pitchListenable;
  final ValueListenable<double> rollListenable;

  _AttitudePainter({
    required this.pitchListenable,
    required this.rollListenable,
  }) : super(repaint: Listenable.merge([pitchListenable, rollListenable]));

  @override
  void paint(Canvas canvas, Size size) {
    final pitch = pitchListenable.value; // radians
    final roll = rollListenable.value;
    final center = Offset(size.width / 2, size.height / 2);

    // Pitch: 1 radian ≈ half the height (so a few degrees moves the horizon visibly)
    final pitchPixels = pitch * size.height * 0.6;

    // saveLayer with the widget bounds composites the rotated sky/ground/
    // horizon through a single off-screen layer with high-quality
    // resampling — this softens the edges of the rotated rects more than
    // primitive-by-primitive antialiasing alone.
    canvas.saveLayer(
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.high,
    );
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-roll); // bank — sky/ground rotate opposite

    // Solid sky/ground colors (not gradients).
    //
    // Why solid: canvas.rotate(-roll) re-samples every pixel as the bank
    // angle changes by sub-degree amounts. With a gradient, each pixel
    // reads a slightly-different interpolated color frame-to-frame, which
    // is visible as shimmer in the smooth blue area. Solid fills under
    // rotation don't shimmer because every pixel maps to one constant color.
    //
    // Real attitude indicators use solid sky-blue / earth-brown for exactly
    // this reason — and it keeps maximum contrast with the white pitch ladder.
    final w = size.width;
    final h = size.height;
    const skyColor = Color(0xFF2D7DD2);
    const groundColor = Color(0xFF7A4F1E);

    // Extended rects so rotation by `roll` never reveals an unfilled corner.
    // Sky overlaps the ground by 1 px at the horizon to avoid an antialiased
    // seam between the two rects.
    canvas.drawRect(
      Rect.fromLTRB(-w * 2, -h * 2, w * 2, pitchPixels + 1),
      Paint()
        ..color = skyColor
        ..isAntiAlias = true,
    );
    canvas.drawRect(
      Rect.fromLTRB(-w * 2, pitchPixels, w * 2, h * 2),
      Paint()
        ..color = groundColor
        ..isAntiAlias = true,
    );

    // Horizon line — drawn as a thin filled rect (not drawLine) so it
    // anti-aliases cleanly under rotation. drawLine with strokeWidth=2 gives
    // visible stair-stepping when the horizon is at small bank angles
    // because the line is rasterized with 2px integer width. A filled rect
    // composited with isAntiAlias=true uses sub-pixel edge coverage, which
    // produces a much smoother edge across all bank angles.
    canvas.drawRect(
      Rect.fromLTRB(-w * 2, pitchPixels - 1, w * 2, pitchPixels + 1),
      Paint()
        ..color = Colors.white
        ..isAntiAlias = true,
    );

    // Pitch ladder — short white lines every 10°
    final ladderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 1.5;
    final degToPixels = (math.pi / 180) * size.height * 0.6;
    for (int deg = -60; deg <= 60; deg += 10) {
      if (deg == 0) continue;
      final y = pitchPixels - deg * degToPixels;
      final width = (deg.abs() % 20 == 0) ? 50.0 : 30.0;
      canvas.drawLine(Offset(-width, y), Offset(width, y), ladderPaint);
      // Label
      final tp = TextPainter(
        text: TextSpan(
          text: '$deg',
          style: const TextStyle(color: Colors.white, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(width + 4, y - tp.height / 2));
    }

    canvas.restore();

    // Roll arc + bank pointer (drawn fixed, not rotated)
    _drawBankIndicator(canvas, center, size, roll);

    // Center fixed aircraft symbol (yellow)
    final acPaint = Paint()
      ..color = const Color(0xFFFFD600)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(center.dx - 40, center.dy),
      Offset(center.dx - 12, center.dy),
      acPaint,
    );
    canvas.drawLine(
      Offset(center.dx + 12, center.dy),
      Offset(center.dx + 40, center.dy),
      acPaint,
    );
    canvas.drawCircle(center, 3, Paint()..color = const Color(0xFFFFD600));

    // Frame
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawBankIndicator(
    Canvas canvas,
    Offset center,
    Size size,
    double roll,
  ) {
    final r = math.min(size.width, size.height) * 0.42;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    // Top arc
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      math.pi + math.pi / 6,
      math.pi - math.pi / 3,
      false,
      paint,
    );
    // Tick marks at -45,-30,-20,-10,0,10,20,30,45
    for (final deg in [-45, -30, -20, -10, 0, 10, 20, 30, 45]) {
      final a = -math.pi / 2 + deg * math.pi / 180;
      final isMajor = deg == 0 || deg.abs() == 30 || deg.abs() == 45;
      final outerR = r;
      final innerR = isMajor ? r - 10 : r - 5;
      canvas.drawLine(
        center + Offset(math.cos(a) * innerR, math.sin(a) * innerR),
        center + Offset(math.cos(a) * outerR, math.sin(a) * outerR),
        paint,
      );
    }
    // Bank pointer (rotates with roll)
    final ptrAngle = -math.pi / 2 - roll;
    final tip =
        center +
        Offset(math.cos(ptrAngle) * (r - 14), math.sin(ptrAngle) * (r - 14));
    final left =
        center +
        Offset(
          math.cos(ptrAngle - 0.08) * (r - 22),
          math.sin(ptrAngle - 0.08) * (r - 22),
        );
    final right =
        center +
        Offset(
          math.cos(ptrAngle + 0.08) * (r - 22),
          math.sin(ptrAngle + 0.08) * (r - 22),
        );
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(left.dx, left.dy)
      ..lineTo(right.dx, right.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFFFD600));
  }

  @override
  bool shouldRepaint(_AttitudePainter old) => false;
}

// ───────────────────────────────────────────────────────────────────────────
// Tape indicator (vertical scrolling tape for altitude / speed)
// ───────────────────────────────────────────────────────────────────────────

/// A horizontal color band on a vertical tape, in value-domain units.
/// Drawn as a translucent strip across the tape between [from] and [to].
class TapeColorZone {
  final double from;
  final double to;
  final Color color;
  const TapeColorZone({
    required this.from,
    required this.to,
    required this.color,
  });
}

class TapeIndicator extends StatelessWidget {
  final ValueListenable<double> valueListenable;
  final String label;
  final String unit;
  final double majorStep;
  final double minorStep;
  final double range;
  final List<TapeColorZone> colorZones;
  final double? bugValue;

  const TapeIndicator({
    super.key,
    required this.valueListenable,
    required this.label,
    required this.unit,
    required this.majorStep,
    required this.minorStep,
    required this.range,
    this.colorZones = const [],
    this.bugValue,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _TapePainter(
          valueListenable: valueListenable,
          label: label,
          unit: unit,
          majorStep: majorStep,
          minorStep: minorStep,
          range: range,
          colorZones: colorZones,
          bugValue: bugValue,
        ),
      ),
    );
  }
}

class _TapePainter extends CustomPainter {
  final ValueListenable<double> valueListenable;
  final String label;
  final String unit;
  final double majorStep;
  final double minorStep;
  final double range;
  final List<TapeColorZone> colorZones;
  final double? bugValue;

  _TapePainter({
    required this.valueListenable,
    required this.label,
    required this.unit,
    required this.majorStep,
    required this.minorStep,
    required this.range,
    required this.colorZones,
    required this.bugValue,
  }) : super(repaint: valueListenable);

  @override
  void paint(Canvas canvas, Size size) {
    final value = valueListenable.value;

    // Background
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xCC0A1525),
    );

    final cy = size.height / 2;
    final pixelsPerUnit = size.height / range;

    // Compute the visible range, snap to nearest minorStep
    final minVal = value - range / 2;
    final maxVal = value + range / 2;
    final firstTick = (minVal / minorStep).ceil() * minorStep;

    // Color zones — translucent strips behind the ticks
    if (colorZones.isNotEmpty) {
      double yFor(double v) => cy + (value - v) * pixelsPerUnit;
      for (final z in colorZones) {
        final lo = math.min(z.from, z.to);
        final hi = math.max(z.from, z.to);
        if (hi < minVal || lo > maxVal) continue;
        final y1 = yFor(math.min(hi, maxVal));
        final y2 = yFor(math.max(lo, minVal));
        final top = math.min(y1, y2);
        final bottom = math.max(y1, y2);
        canvas.drawRect(
          Rect.fromLTRB(0, top, size.width, bottom),
          Paint()..color = z.color,
        );
      }
    }

    final tickPaint = Paint()..color = Colors.white.withValues(alpha: 0.7);
    final majorPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;

    for (var v = firstTick; v <= maxVal; v += minorStep) {
      final y = cy + (value - v) * pixelsPerUnit;
      final isMajor = (v / majorStep - (v / majorStep).round()).abs() < 1e-3;
      final tickLen = isMajor ? 12.0 : 6.0;
      canvas.drawLine(
        Offset(size.width - tickLen, y),
        Offset(size.width, y),
        isMajor ? majorPaint : tickPaint,
      );
      if (isMajor) {
        final tp = TextPainter(
          text: TextSpan(
            text: '${v.toInt()}',
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(4, y - tp.height / 2));
      }
    }

    // Bug indicator (e.g. selected altitude / target speed) — drawn before
    // the center value box so the box overlays it if they coincide.
    if (bugValue != null) {
      final bv = bugValue!;
      // Compute y position; clamp to visible tape area
      final by = cy + (value - bv) * pixelsPerUnit;
      final clampedY = by.clamp(2.0, size.height - 2);
      // Magenta triangular pointer at the right edge
      final bugPath = Path()
        ..moveTo(size.width, clampedY - 6)
        ..lineTo(size.width - 8, clampedY)
        ..lineTo(size.width, clampedY + 6)
        ..close();
      canvas.drawPath(bugPath, Paint()..color = const Color(0xFFFF00FF));
      // Tick line through the bug
      canvas.drawLine(
        Offset(0, clampedY),
        Offset(size.width - 10, clampedY),
        Paint()
          ..color = const Color(0xFFFF00FF).withValues(alpha: 0.5)
          ..strokeWidth = 1,
      );
    }

    // Center indicator (chevron pointing left)
    final boxRect = Rect.fromLTRB(0, cy - 14, size.width, cy + 14);
    canvas.drawRect(
      boxRect,
      Paint()..color = const Color(0xFF00E5FF).withValues(alpha: 0.9),
    );
    final valueText = TextPainter(
      text: TextSpan(
        text: value.toStringAsFixed(0),
        style: const TextStyle(
          color: Colors.black,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    valueText.paint(
      canvas,
      Offset(size.width - valueText.width - 4, cy - valueText.height / 2),
    );

    // Label at top
    final labelText = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.85),
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    labelText.paint(canvas, Offset((size.width - labelText.width) / 2, 4));

    // Unit at bottom
    final unitText = TextPainter(
      text: TextSpan(
        text: unit,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.6),
          fontSize: 10,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    unitText.paint(
      canvas,
      Offset(
        (size.width - unitText.width) / 2,
        size.height - unitText.height - 4,
      ),
    );

    // Frame
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_TapePainter old) =>
      old.bugValue != bugValue || old.colorZones != colorZones;
}

// ───────────────────────────────────────────────────────────────────────────
// Heading tape (horizontal scrolling compass)
// ───────────────────────────────────────────────────────────────────────────

class HeadingTape extends StatelessWidget {
  final ValueListenable<double> yawListenable;
  const HeadingTape({super.key, required this.yawListenable});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _HeadingTapePainter(yawListenable: yawListenable),
      ),
    );
  }
}

class _HeadingTapePainter extends CustomPainter {
  final ValueListenable<double> yawListenable;

  _HeadingTapePainter({required this.yawListenable})
    : super(repaint: yawListenable);

  @override
  void paint(Canvas canvas, Size size) {
    final yawDeg = yawListenable.value * 180.0 / math.pi;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xCC0A1525),
    );

    final cx = size.width / 2;
    final pxPerDeg = size.width / 80; // show ±40°

    final tickPaint = Paint()..color = Colors.white.withValues(alpha: 0.7);
    final majorPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;

    // Iterate over heading VALUES (snapped to 5° increments) and compute
    // their pixel positions on the tape. This binds each tick/label to a
    // specific compass heading rather than to a fixed pixel offset, so
    // labels slide smoothly across the tape instead of flickering on/off
    // as yaw drifts.
    const visibleSpanDeg = 50.0;
    final firstHeading = ((yawDeg - visibleSpanDeg) / 5.0).floor() * 5;
    final lastHeading = ((yawDeg + visibleSpanDeg) / 5.0).ceil() * 5;

    for (var h = firstHeading; h <= lastHeading; h += 5) {
      // Pixel offset from center is determined by the heading delta —
      // not by an integer index.
      final delta = h - yawDeg;
      final x = cx + delta * pxPerDeg;
      if (x < -10 || x > size.width + 10) continue;

      // Normalize the heading value into 0..359 for label/cardinal lookup.
      final normalized = ((h % 360) + 360) % 360;
      final isMajor = normalized % 30 == 0;

      final tickLen = isMajor ? 12.0 : 6.0;
      canvas.drawLine(
        Offset(x, size.height - tickLen),
        Offset(x, size.height),
        isMajor ? majorPaint : tickPaint,
      );

      if (isMajor) {
        final label = _cardinal(normalized) ?? '$normalized';
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, size.height - 30));
      }
    }

    // Center indicator
    final box = Rect.fromCenter(center: Offset(cx, 14), width: 60, height: 22);
    canvas.drawRect(
      box,
      Paint()..color = const Color(0xFF00E5FF).withValues(alpha: 0.9),
    );
    final headingText = TextPainter(
      text: TextSpan(
        text: '${yawDeg.toInt().toString().padLeft(3, '0')}°',
        style: const TextStyle(
          color: Colors.black,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    headingText.paint(
      canvas,
      Offset(cx - headingText.width / 2, 14 - headingText.height / 2),
    );

    // Frame
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  String? _cardinal(int deg) {
    switch (deg) {
      case 0:
      case 360:
        return 'N';
      case 90:
        return 'E';
      case 180:
        return 'S';
      case 270:
        return 'W';
    }
    return null;
  }

  @override
  bool shouldRepaint(_HeadingTapePainter old) => false;
}

// ───────────────────────────────────────────────────────────────────────────
// Vertical Speed Indicator (small vertical needle gauge)
// ───────────────────────────────────────────────────────────────────────────

class VsiIndicator extends StatelessWidget {
  final ValueListenable<double> vsiListenable;
  const VsiIndicator({super.key, required this.vsiListenable});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(painter: _VsiPainter(vsiListenable: vsiListenable)),
    );
  }
}

class _VsiPainter extends CustomPainter {
  final ValueListenable<double> vsiListenable;
  static const double maxVsi = 5.0; // ±5 m/s

  _VsiPainter({required this.vsiListenable}) : super(repaint: vsiListenable);

  @override
  void paint(Canvas canvas, Size size) {
    final vsi = vsiListenable.value.clamp(-maxVsi, maxVsi);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xCC0A1525),
    );

    final cx = size.width / 2;
    final h = size.height - 24;
    final centerY = 12 + h / 2;

    // Center line
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      Paint()..color = Colors.white.withValues(alpha: 0.5),
    );

    // Ticks at ±1, ±2, ±5
    final tickPaint = Paint()..color = Colors.white.withValues(alpha: 0.7);
    for (final v in [-5, -2, -1, 0, 1, 2, 5]) {
      final y = centerY - (v / maxVsi) * (h / 2);
      canvas.drawLine(Offset(cx - 4, y), Offset(cx + 4, y), tickPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: v >= 0 ? '+$v' : '$v',
          style: const TextStyle(color: Colors.white, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx + 8, y - tp.height / 2));
    }

    // Bar from center
    final fillY = centerY - (vsi / maxVsi) * (h / 2);
    final barColor = vsi >= 0 ? Colors.green : Colors.red;
    canvas.drawRect(
      Rect.fromLTRB(
        cx - 8,
        math.min(centerY, fillY),
        cx,
        math.max(centerY, fillY),
      ),
      Paint()..color = barColor,
    );

    // Label
    final tp = TextPainter(
      text: const TextSpan(
        text: 'VSI',
        style: TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, 2));

    // Numeric value
    final valTp = TextPainter(
      text: TextSpan(
        text: '${vsi >= 0 ? "+" : ""}${vsi.toStringAsFixed(1)}',
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    valTp.paint(
      canvas,
      Offset(cx - valTp.width / 2, size.height - valTp.height - 2),
    );

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_VsiPainter old) => false;
}

// ───────────────────────────────────────────────────────────────────────────
// Battery indicator (rebuilds via ValueListenableBuilder, low frequency)
// ───────────────────────────────────────────────────────────────────────────

class BatteryIndicator extends StatelessWidget {
  final ValueListenable<double> percentListenable;
  final ValueListenable<double> voltageListenable;
  const BatteryIndicator({
    super.key,
    required this.percentListenable,
    required this.voltageListenable,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: percentListenable,
        builder: (context, percent, _) => ValueListenableBuilder<double>(
          valueListenable: voltageListenable,
          builder: (context, voltage, __) {
            final color = percent > 50
                ? Colors.green
                : percent > 20
                ? Colors.amber
                : Colors.red;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xCC0A1525),
                border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.battery_full, color: color, size: 24),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${percent.toStringAsFixed(0)}%',
                        style: TextStyle(
                          color: color,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${voltage.toStringAsFixed(1)}V',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Signal indicator
// ───────────────────────────────────────────────────────────────────────────

class SignalIndicator extends StatelessWidget {
  final ValueListenable<int> rssiListenable;
  final ValueListenable<int> linkListenable;
  const SignalIndicator({
    super.key,
    required this.rssiListenable,
    required this.linkListenable,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: rssiListenable,
        builder: (context, rssi, _) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xCC0A1525),
            border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.signal_cellular_alt,
                color: rssi > 80
                    ? Colors.green
                    : rssi > 60
                    ? Colors.amber
                    : Colors.red,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                '$rssi%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
// GPS indicator
// ───────────────────────────────────────────────────────────────────────────

class GpsIndicator extends StatelessWidget {
  final ValueListenable<int> fixListenable;
  final ValueListenable<int> satListenable;
  const GpsIndicator({
    super.key,
    required this.fixListenable,
    required this.satListenable,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: satListenable,
        builder: (context, sats, _) => ValueListenableBuilder<int>(
          valueListenable: fixListenable,
          builder: (context, fix, __) {
            final fixStr = ['NO FIX', '2D', '3D', 'DGPS'][fix.clamp(0, 3)];
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xCC0A1525),
                border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.satellite_alt,
                    color: fix >= 2 ? Colors.green : Colors.amber,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        fixStr,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '$sats sats',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
// HUD info bar — flight time since arming, battery time remaining, GPS HDOP
// proxy. Driven by ValueNotifiers updated in `_onPortMessage`. Re-renders
// itself once per second via an internal Ticker so the flight-time clock
// advances even when no telemetry has updated the notifiers.
// ───────────────────────────────────────────────────────────────────────────

class HudInfoBar extends StatefulWidget {
  final ValueListenable<int> armedSinceListenable;
  final ValueListenable<int> batteryRemainingSecListenable;
  final ValueListenable<int> gpsFixListenable;
  const HudInfoBar({
    super.key,
    required this.armedSinceListenable,
    required this.batteryRemainingSecListenable,
    required this.gpsFixListenable,
  });

  @override
  State<HudInfoBar> createState() => _HudInfoBarState();
}

class _HudInfoBarState extends State<HudInfoBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String _fmtDuration(int seconds) {
    if (seconds < 0) return '--:--';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: widget.armedSinceListenable,
        builder: (_, armedSince, __) => ValueListenableBuilder<int>(
          valueListenable: widget.batteryRemainingSecListenable,
          builder: (_, battSec, __) {
            final now = DateTime.now().millisecondsSinceEpoch;
            final flightSec = armedSince == 0 ? -1 : (now - armedSince) ~/ 1000;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xCC0A1525),
                border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _HudCell(
                    label: 'FLIGHT',
                    value: _fmtDuration(flightSec),
                    color: armedSince != 0 ? Colors.cyanAccent : Colors.white54,
                  ),
                  _HudCell(
                    label: 'BATT TIME',
                    value: _fmtDuration(battSec),
                    color: battSec >= 0 && battSec < 120
                        ? Colors.redAccent
                        : Colors.white,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HudCell extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _HudCell({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 9,
            letterSpacing: 1.2,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 16,
            fontFeatures: const [FontFeature.tabularFigures()],
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Status badge
// ───────────────────────────────────────────────────────────────────────────

class StatusBadge extends StatelessWidget {
  final String text;
  final Color color;
  const StatusBadge({super.key, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
// WarningsPanel — banner showing the highest-priority active alert.
//
// Each warning condition has an entry threshold, an exit threshold (for
// hysteresis), and a priority. The panel computes the active set every
// frame from the telemetry notifiers and displays the highest-priority one.
// ───────────────────────────────────────────────────────────────────────────

class WarningsPanel extends StatefulWidget {
  // ignore: library_private_types_in_public_api
  final _Telemetry telemetry;
  // ignore: library_private_types_in_public_api
  const WarningsPanel({super.key, required this.telemetry});

  @override
  State<WarningsPanel> createState() => _WarningsPanelState();
}

class _WarningsPanelState extends State<WarningsPanel> {
  // Latched state per warning — true while active.
  // Hysteresis: enter at one threshold, exit at another.
  bool _lowBattery = false;
  bool _criticalBattery = false;
  bool _gpsLost = false;
  bool _linkLow = false;
  bool _descendingFast = false;

  late final List<VoidCallback> _detachers;

  @override
  void initState() {
    super.initState();
    final t = widget.telemetry;

    void evalBattery() {
      final p = t.percent.value;
      if (p < 10 && p > 0) _criticalBattery = true;
      if (p > 15) _criticalBattery = false;
      if (p < 20 && p > 0) _lowBattery = true;
      if (p > 25) _lowBattery = false;
      _refresh();
    }

    void evalGps() {
      final fix = t.gpsFix.value;
      final sats = t.satCount.value;
      if (fix < 2 || sats < 6) _gpsLost = true;
      if (fix >= 2 && sats >= 8) _gpsLost = false;
      _refresh();
    }

    void evalSignal() {
      final r = t.rssi.value;
      if (r < 60) _linkLow = true;
      if (r > 75) _linkLow = false;
      _refresh();
    }

    void evalVsi() {
      final v = t.vsi.notifier.value;
      if (v < -2.0) _descendingFast = true;
      if (v > -1.0) _descendingFast = false;
      _refresh();
    }

    t.percent.addListener(evalBattery);
    t.gpsFix.addListener(evalGps);
    t.satCount.addListener(evalGps);
    t.rssi.addListener(evalSignal);
    t.vsi.notifier.addListener(evalVsi);

    _detachers = [
      () => t.percent.removeListener(evalBattery),
      () => t.gpsFix.removeListener(evalGps),
      () => t.satCount.removeListener(evalGps),
      () => t.rssi.removeListener(evalSignal),
      () => t.vsi.notifier.removeListener(evalVsi),
    ];
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final d in _detachers) {
      d();
    }
    super.dispose();
  }

  /// Highest-priority active warning, or null if none.
  ({String text, Color color, IconData icon})? _active() {
    // Priority order: critical battery > GPS lost > descending > low battery > link
    if (_criticalBattery) {
      return (
        text: 'CRITICAL BATTERY',
        color: Colors.red,
        icon: Icons.battery_alert,
      );
    }
    if (_gpsLost) {
      return (text: 'GPS LOST', color: Colors.red, icon: Icons.satellite_alt);
    }
    if (_descendingFast) {
      return (
        text: 'DESCENDING FAST',
        color: Colors.orange,
        icon: Icons.arrow_downward,
      );
    }
    if (_lowBattery) {
      return (
        text: 'LOW BATTERY',
        color: Colors.orange,
        icon: Icons.battery_2_bar,
      );
    }
    if (_linkLow) {
      return (
        text: 'WEAK LINK',
        color: Colors.amber,
        icon: Icons.signal_cellular_alt,
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final w = _active();
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: w == null
          ? const SizedBox.shrink(key: ValueKey('none'))
          : Container(
              key: ValueKey(w.text),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: w.color.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(6),
                boxShadow: [
                  BoxShadow(
                    color: w.color.withValues(alpha: 0.6),
                    blurRadius: 14,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(w.icon, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    w.text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
// HomeArrow — circular widget with an arrow pointing home and distance text.
//
// The arrow's angle is the bearing FROM the drone TO home, in screen
// coordinates (north up). For this example we use the negative of the
// drone's yaw as a proxy for "home is behind me" — a real implementation
// would use cumulative GPS displacement.
// ───────────────────────────────────────────────────────────────────────────

class HomeArrow extends StatelessWidget {
  final ValueListenable<double> yawListenable;
  final ValueListenable<double> distanceListenable;

  const HomeArrow({
    super.key,
    required this.yawListenable,
    required this.distanceListenable,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _HomeArrowPainter(
          yawListenable: yawListenable,
          distanceListenable: distanceListenable,
        ),
      ),
    );
  }
}

class _HomeArrowPainter extends CustomPainter {
  final ValueListenable<double> yawListenable;
  final ValueListenable<double> distanceListenable;

  _HomeArrowPainter({
    required this.yawListenable,
    required this.distanceListenable,
  }) : super(repaint: Listenable.merge([yawListenable, distanceListenable]));

  @override
  void paint(Canvas canvas, Size size) {
    final yaw = yawListenable.value;
    final distance = distanceListenable.value;
    final center = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2 - 4;

    // Background circle
    canvas.drawCircle(center, r, Paint()..color = const Color(0xCC0A1525));
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );

    // North marker (small N at top)
    final northTp = TextPainter(
      text: TextSpan(
        text: 'N',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.6),
          fontSize: 9,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    northTp.paint(
      canvas,
      Offset(center.dx - northTp.width / 2, center.dy - r + 2),
    );

    // Bearing to home (radians, 0=N, clockwise). Simplified: opposite of
    // current yaw (so flying north → home appears south).
    final homeBearing = yaw + math.pi;

    // Arrow path — points outward toward the home direction
    final tipR = r - 14;
    final tip =
        center +
        Offset(math.sin(homeBearing) * tipR, -math.cos(homeBearing) * tipR);
    final perpAngle = homeBearing + math.pi / 2;
    final baseR = r - 28;
    final back =
        center +
        Offset(math.sin(homeBearing) * baseR, -math.cos(homeBearing) * baseR);
    final left =
        back + Offset(math.sin(perpAngle) * 8, -math.cos(perpAngle) * 8);
    final right =
        back - Offset(math.sin(perpAngle) * 8, -math.cos(perpAngle) * 8);

    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(left.dx, left.dy)
      ..lineTo(back.dx, back.dy)
      ..lineTo(right.dx, right.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF00E5FF));

    // Center dot (drone position)
    canvas.drawCircle(center, 3, Paint()..color = Colors.white);

    // Distance text (center)
    final distText = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: distance.toStringAsFixed(0),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          TextSpan(
            text: ' m',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 9,
            ),
          ),
        ],
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    distText.paint(
      canvas,
      Offset(center.dx - distText.width / 2, center.dy + r - 18),
    );

    // Label
    final labelTp = TextPainter(
      text: TextSpan(
        text: 'HOME',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.6),
          fontSize: 8,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    labelTp.paint(
      canvas,
      Offset(center.dx - labelTp.width / 2, center.dy + r - 32),
    );
  }

  @override
  bool shouldRepaint(_HomeArrowPainter old) => false;
}

// ───────────────────────────────────────────────────────────────────────────
// GimbalIndicator — vertical bar showing camera pitch (-90°..+30°)
// ───────────────────────────────────────────────────────────────────────────

class GimbalIndicator extends StatelessWidget {
  final ValueListenable<double> pitchListenable;

  const GimbalIndicator({super.key, required this.pitchListenable});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _GimbalPainter(pitchListenable: pitchListenable),
      ),
    );
  }
}

class _GimbalPainter extends CustomPainter {
  final ValueListenable<double> pitchListenable;
  static const double _minDeg = -90;
  static const double _maxDeg = 30;

  _GimbalPainter({required this.pitchListenable})
    : super(repaint: pitchListenable);

  @override
  void paint(Canvas canvas, Size size) {
    final pitch = pitchListenable.value.clamp(_minDeg, _maxDeg);

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xCC0A1525),
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.3)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );

    final cx = size.width / 2;
    const labelArea = 14.0;
    const valueArea = 14.0;
    final barTop = labelArea + 6;
    final barBottom = size.height - valueArea - 4;
    final barH = barBottom - barTop;

    // Background scale line
    canvas.drawLine(
      Offset(cx, barTop),
      Offset(cx, barBottom),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..strokeWidth = 2,
    );

    // Tick marks every 30°
    final tickPaint = Paint()..color = Colors.white.withValues(alpha: 0.6);
    final tpStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.7),
      fontSize: 8,
    );
    for (final deg in [-90, -60, -30, 0, 30]) {
      final t = (deg - _minDeg) / (_maxDeg - _minDeg);
      final y = barTop + barH * (1 - t);
      canvas.drawLine(Offset(cx - 6, y), Offset(cx + 6, y), tickPaint);
      final tp = TextPainter(
        text: TextSpan(text: '$deg', style: tpStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx + 8, y - tp.height / 2));
    }

    // Pointer at current pitch
    final t = (pitch - _minDeg) / (_maxDeg - _minDeg);
    final pointerY = barTop + barH * (1 - t);
    final path = Path()
      ..moveTo(cx - 12, pointerY)
      ..lineTo(cx - 4, pointerY - 5)
      ..lineTo(cx - 4, pointerY + 5)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFFFD600));

    // Label
    final labelTp = TextPainter(
      text: const TextSpan(
        text: 'GIMBAL',
        style: TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    labelTp.paint(canvas, Offset((size.width - labelTp.width) / 2, 2));

    // Value text
    final valTp = TextPainter(
      text: TextSpan(
        text: '${pitch.toStringAsFixed(0)}°',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    valTp.paint(
      canvas,
      Offset((size.width - valTp.width) / 2, size.height - valTp.height - 2),
    );
  }

  @override
  bool shouldRepaint(_GimbalPainter old) => false;
}

// ───────────────────────────────────────────────────────────────────────────
// Sparkline — small line graph of a SignalHistory
// ───────────────────────────────────────────────────────────────────────────

class Sparkline extends StatelessWidget {
  final SignalHistory history;
  final Color lineColor;
  final Color fillColor;
  final String? label;

  const Sparkline({
    super.key,
    required this.history,
    this.lineColor = const Color(0xFF00E5FF),
    this.fillColor = const Color(0x3300E5FF),
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _SparklinePainter(
          history: history,
          lineColor: lineColor,
          fillColor: fillColor,
          label: label,
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final SignalHistory history;
  final Color lineColor;
  final Color fillColor;
  final String? label;

  _SparklinePainter({
    required this.history,
    required this.lineColor,
    required this.fillColor,
    required this.label,
  }) : super(repaint: history);

  @override
  void paint(Canvas canvas, Size size) {
    // Background panel
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xCC0A1525),
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.3)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );

    if (history.length < 2) {
      if (label != null) _drawLabel(canvas, size);
      return;
    }

    final samples = history.samples.toList(growable: false);
    final (lo, hi) = history.range;
    final span = hi - lo;
    final n = samples.length;

    // Reserve top 14 px for label
    const labelArea = 14.0;
    final graphTop = labelArea + 2;
    final graphBottom = size.height - 2;
    final graphH = graphBottom - graphTop;
    final graphW = size.width - 4;

    double xFor(int i) => 2 + i * (graphW / (n - 1));
    double yFor(double v) => graphBottom - ((v - lo) / span) * graphH;

    // Build the line path
    final linePath = Path();
    linePath.moveTo(xFor(0), yFor(samples[0]));
    for (var i = 1; i < n; i++) {
      linePath.lineTo(xFor(i), yFor(samples[i]));
    }

    // Build a fill path (line + close along bottom)
    final fillPath = Path.from(linePath);
    fillPath.lineTo(xFor(n - 1), graphBottom);
    fillPath.lineTo(xFor(0), graphBottom);
    fillPath.close();

    canvas.drawPath(fillPath, Paint()..color = fillColor);
    canvas.drawPath(
      linePath,
      Paint()
        ..color = lineColor
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    // Last-value dot
    final last = Offset(xFor(n - 1), yFor(samples.last));
    canvas.drawCircle(last, 2.5, Paint()..color = lineColor);

    if (label != null) _drawLabel(canvas, size);
  }

  void _drawLabel(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: label!,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.8),
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(4, 2));
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.lineColor != lineColor || old.fillColor != fillColor;
}

// ───────────────────────────────────────────────────────────────────────────
// Virtual joystick
// ───────────────────────────────────────────────────────────────────────────

class Joystick extends StatefulWidget {
  final double size;
  final String label;
  final void Function(double x, double y)? onChanged;

  const Joystick({
    super.key,
    required this.size,
    required this.label,
    this.onChanged,
  });

  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  Offset _knob = Offset.zero;

  void _update(Offset local) {
    final c = widget.size / 2;
    final dx = (local.dx - c) / c;
    final dy = (local.dy - c) / c;
    final r = math.sqrt(dx * dx + dy * dy);
    final clamped = r > 1 ? Offset(dx / r, dy / r) : Offset(dx, dy);
    setState(() => _knob = clamped);
    widget.onChanged?.call(clamped.dx, -clamped.dy);
  }

  void _release() {
    setState(() => _knob = Offset.zero);
    widget.onChanged?.call(0, 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (d) => _update(d.localPosition),
      onPanUpdate: (d) => _update(d.localPosition),
      onPanEnd: (_) => _release(),
      onPanCancel: _release,
      child: SizedBox(
        width: widget.size,
        height: widget.size + 22,
        child: Column(
          children: [
            CustomPaint(
              size: Size(widget.size, widget.size),
              painter: _JoystickPainter(knob: _knob),
            ),
            const SizedBox(height: 4),
            Text(
              widget.label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 10,
                letterSpacing: 1.2,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JoystickPainter extends CustomPainter {
  final Offset knob;
  _JoystickPainter({required this.knob});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 4;

    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = const Color(0xCC0A1525)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );

    // Crosshairs
    final crossPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(center.dx - r, center.dy),
      Offset(center.dx + r, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - r),
      Offset(center.dx, center.dy + r),
      crossPaint,
    );

    final knobCenter = center + Offset(knob.dx * (r - 18), knob.dy * (r - 18));
    canvas.drawCircle(knobCenter, 18, Paint()..color = const Color(0xFF00E5FF));
    canvas.drawCircle(
      knobCenter,
      18,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_JoystickPainter old) => old.knob != knob;
}
