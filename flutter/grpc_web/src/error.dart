/// Error thrown when a gRPC-Web call fails with a non-zero grpc-status.
class GrpcWebError implements Exception {
  /// The gRPC status code (e.g., 5 = NOT_FOUND, 14 = UNAVAILABLE).
  ///
  /// See [GrpcStatus] for named constants.
  final int code;

  /// Human-readable error message from the server.
  final String message;

  /// Optional error details from the server (e.g. from `grpc-status-details-bin`).
  final String? details;

  GrpcWebError(this.code, this.message, {this.details});

  @override
  String toString() =>
      details != null
          ? 'GrpcWebError($code): $message — $details'
          : 'GrpcWebError($code): $message';
}
