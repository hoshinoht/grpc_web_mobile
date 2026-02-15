import 'package:protobuf/protobuf.dart';

import 'call_options.dart';

/// Signature for a unary RPC invocation.
typedef UnaryInvoker<T extends GeneratedMessage> = Future<T> Function(
  String path,
  GeneratedMessage request,
  T Function(List<int>) deserializer,
  CallOptions options,
);

/// Signature for a server-streaming RPC invocation.
typedef StreamingInvoker<T extends GeneratedMessage> = Stream<T> Function(
  String path,
  GeneratedMessage request,
  T Function(List<int>) deserializer,
  CallOptions options,
);

/// Interceptor for gRPC-Web calls.
///
/// Interceptors can inspect and modify metadata, log calls, inject auth
/// tokens, handle errors, add retry logic, etc.
///
/// The [next] callback invokes the next interceptor in the chain (or the
/// actual RPC if this is the last interceptor).
abstract class GrpcWebInterceptor {
  /// Intercepts a unary call. Call [next] to continue the chain.
  Future<T> interceptUnary<T extends GeneratedMessage>(
    String path,
    GeneratedMessage request,
    T Function(List<int>) deserializer,
    CallOptions options,
    UnaryInvoker<T> next,
  );

  /// Intercepts a server-streaming call. Call [next] to continue the chain.
  Stream<T> interceptStreaming<T extends GeneratedMessage>(
    String path,
    GeneratedMessage request,
    T Function(List<int>) deserializer,
    CallOptions options,
    StreamingInvoker<T> next,
  );
}
