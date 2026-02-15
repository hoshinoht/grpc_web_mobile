/// Options for a single gRPC call.
///
/// Includes per-call metadata, timeout, and deadline. When both [timeout]
/// and [deadline] are set, the tighter constraint wins.
class CallOptions {
  /// Additional HTTP headers (e.g. auth tokens) to send with the request.
  final Map<String, String>? metadata;

  /// Maximum duration for the call. Takes precedence over the client-level
  /// timeout when shorter.
  final Duration? timeout;

  /// Absolute deadline for the call. Converted to a relative timeout
  /// before the request is sent.
  final DateTime? deadline;

  const CallOptions({this.metadata, this.timeout, this.deadline});

  /// Merges this with [other], with [other]'s values taking precedence.
  ///
  /// Metadata maps are merged with [other]'s entries overwriting this one's.
  CallOptions mergedWith(CallOptions? other) {
    if (other == null) return this;
    return CallOptions(
      metadata: {
        if (metadata != null) ...metadata!,
        if (other.metadata != null) ...other.metadata!,
      },
      timeout: other.timeout ?? timeout,
      deadline: other.deadline ?? deadline,
    );
  }
}
