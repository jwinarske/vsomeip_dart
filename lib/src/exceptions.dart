/// Thrown when vsomeip application creation fails.
class VsomeipInitException implements Exception {
  final String message;
  const VsomeipInitException(this.message);

  @override
  String toString() => 'VsomeipInitException: $message';
}

/// Thrown when a SOME/IP request fails (timeout, NAK, error response).
class VsomeipRequestException implements Exception {
  final String message;
  const VsomeipRequestException(this.message);

  @override
  String toString() => 'VsomeipRequestException: $message';
}

/// Thrown when a SOME/IP event subscription is rejected by the service.
///
/// This is raised when the subscribe ACK contains a non-zero error code,
/// indicating the service refused the subscription (e.g., max subscribers
/// reached, access denied, or service unavailable).
class VsomeipSubscribeException implements Exception {
  final String message;
  final int errorCode;
  const VsomeipSubscribeException(this.message, {this.errorCode = 0});
  @override
  String toString() =>
      'VsomeipSubscribeException(code=0x${errorCode.toRadixString(16)}): $message';
}
