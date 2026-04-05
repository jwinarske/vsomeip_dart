/// Per-signal rate limiter. Runs on the worker isolate — no locks.
///
/// Uses a token bucket algorithm with a 1-token fill per (1/maxHz) interval.
///
/// For automotive sensor data:
///   Vehicle speed (CAN, 10 ms cycle)    -> UI cap: 30 Hz
///   Radar object list (20 ms)           -> UI cap: 10 Hz
///   Accelerometer (1 ms)                -> UI cap: 60 Hz
///   Infotainment metadata (100 ms)      -> no throttle needed
class SignalThrottle {
  final double maxHz;
  final int _intervalUs;
  int? _lastForwardUs;
  final int Function()? _clockOverride;

  SignalThrottle({required this.maxHz, int Function()? clock})
    : _intervalUs = maxHz > 0 ? (1000000 / maxHz).round() : 0,
      _clockOverride = clock;

  int get _nowUs =>
      _clockOverride?.call() ?? DateTime.now().microsecondsSinceEpoch;

  bool shouldForward() {
    if (_intervalUs == 0) return true;
    final now = _nowUs;
    final last = _lastForwardUs;
    if (last == null || now - last >= _intervalUs) {
      _lastForwardUs = now;
      return true;
    }
    return false;
  }
}
