/// High-performance Dart bridge to the COVESA vsomeip SOME/IP stack.
library vsomeip_dart;

export 'src/exceptions.dart';
export 'src/ffi/bindings.dart' show VsomeipBindings;
export 'src/ffi/codec.dart' show WireCodec, WireHeader, VsomeipDisc;
export 'src/throttle.dart';
export 'src/vsomeip_client.dart';
export 'src/vsomeip_message.dart';
export 'src/vsomeip_service.dart';
