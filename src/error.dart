/// Error thrown when a gRPC-Web call fails with a non-zero grpc-status.
class GrpcWebError implements Exception {
  /// The gRPC status code (e.g., 5 = NOT_FOUND, 14 = UNAVAILABLE).
  ///
  /// See https://grpc.github.io/grpc/core/md_doc_statuscodes.html
  final int code;

  /// Human-readable error message from the server.
  final String message;

  GrpcWebError(this.code, this.message);

  @override
  String toString() => 'GrpcWebError($code): $message';
}
