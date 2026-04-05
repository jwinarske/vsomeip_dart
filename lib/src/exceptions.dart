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
