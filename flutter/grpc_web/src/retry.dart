import 'dart:math';

import 'package:protobuf/protobuf.dart';

import 'call_options.dart';
import 'error.dart';
import 'interceptor.dart';
import 'status_codes.dart';

/// Configuration for automatic retry of failed unary RPCs.
class RetryPolicy {
  /// Maximum number of attempts (including the initial call).
  final int maxAttempts;

  /// Delay before the first retry.
  final Duration initialBackoff;

  /// Upper bound on retry delay.
  final Duration maxBackoff;

  /// Multiplier applied to the backoff after each attempt.
  final double backoffMultiplier;

  /// gRPC status codes that are eligible for retry.
  final Set<int> retryableStatusCodes;

  const RetryPolicy({
    this.maxAttempts = 3,
    this.initialBackoff = const Duration(milliseconds: 100),
    this.maxBackoff = const Duration(seconds: 5),
    this.backoffMultiplier = 2.0,
    this.retryableStatusCodes = const {
      GrpcStatus.unavailable,
      GrpcStatus.deadlineExceeded,
    },
  });
}

/// Interceptor that retries failed unary calls according to a [RetryPolicy].
///
/// Streaming calls are passed through without retry — retrying a partially
/// consumed stream is inherently unsafe.
class RetryInterceptor extends GrpcWebInterceptor {
  final RetryPolicy policy;
  final Random _random;

  RetryInterceptor(this.policy, [Random? random])
      : _random = random ?? Random();

  @override
  Future<T> interceptUnary<T extends GeneratedMessage>(
    String path,
    GeneratedMessage request,
    T Function(List<int>) deserializer,
    CallOptions options,
    UnaryInvoker<T> next,
  ) async {
    var backoff = policy.initialBackoff;

    for (var attempt = 0; attempt < policy.maxAttempts; attempt++) {
      try {
        return await next(path, request, deserializer, options);
      } on GrpcWebError catch (e) {
        final isLastAttempt = attempt == policy.maxAttempts - 1;
        if (isLastAttempt || !policy.retryableStatusCodes.contains(e.code)) {
          rethrow;
        }

        // Check if the deadline would be exceeded by waiting.
        if (options.deadline != null) {
          final remaining = options.deadline!.difference(DateTime.now());
          if (remaining <= backoff) rethrow;
        }

        // Exponential backoff with random jitter (0.5x – 1.0x of backoff).
        final jitteredMs =
            (backoff.inMilliseconds * (0.5 + _random.nextDouble() * 0.5))
                .round();
        await Future<void>.delayed(Duration(milliseconds: jitteredMs));

        // Increase backoff for next attempt, capped at maxBackoff.
        backoff = Duration(
          milliseconds:
              min(
                (backoff.inMilliseconds * policy.backoffMultiplier).round(),
                policy.maxBackoff.inMilliseconds,
              ),
        );
      }
    }

    // Unreachable — the loop always returns or rethrows.
    throw StateError('Retry loop exited unexpectedly');
  }

  @override
  Stream<T> interceptStreaming<T extends GeneratedMessage>(
    String path,
    GeneratedMessage request,
    T Function(List<int>) deserializer,
    CallOptions options,
    StreamingInvoker<T> next,
  ) {
    // No retry for streaming calls.
    return next(path, request, deserializer, options);
  }
}
