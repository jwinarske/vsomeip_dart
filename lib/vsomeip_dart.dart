/// High-performance Dart bridge to the COVESA vsomeip SOME/IP stack.
library;

export 'src/exceptions.dart';
export 'src/ffi/bindings.dart' show VsomeipBindings;
export 'src/ffi/codec.dart' show WireCodec, WireHeader, VsomeipDisc;
export 'src/ffi/native_bindings.dart' show NativeVsomeipBindings;
export 'src/throttle.dart';
export 'src/vsomeip_client.dart';
export 'src/vsomeip_message.dart';
export 'src/vsomeip_service.dart';
export 'src/vsomeip_worker.dart'
    show WorkerConfig, SetThrottleCmd, workerIsolateMain;
// Cap'n Proto generated readers
export 'generated/imu_data.capnp.dart';
export 'generated/radar_object.capnp.dart';
export 'generated/vehicle_speed.capnp.dart';
