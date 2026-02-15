/// A portable gRPC-Web client for Dart/Flutter.
///
/// Sends gRPC requests over HTTP/1.1 using `package:http`, enabling gRPC
/// through proxies that don't support HTTP/2 (e.g. Cloudflare Tunnels).
///
/// ## Usage
///
/// ```dart
/// import 'package:my_app/grpc_web/grpc_web.dart';
///
/// final client = GrpcWebClient(
///   baseUrl: 'https://api.example.com',
///   retryPolicy: RetryPolicy(),
///   interceptors: [MyAuthInterceptor()],
/// );
///
/// // Unary call
/// final response = await client.unaryCall(
///   '/my.package.MyService/MyMethod',
///   myRequest,
///   MyResponse.fromBuffer,
///   options: CallOptions(metadata: {'authorization': 'Bearer $token'}),
/// );
///
/// // Server-streaming call
/// await for (final event in client.serverStreamingCall(
///   '/my.package.MyService/StreamMethod',
///   streamRequest,
///   StreamResponse.fromBuffer,
/// )) {
///   print(event);
/// }
///
/// client.close();
/// ```
///
/// ## Dependencies
///
/// Only `package:http` and `package:protobuf` — no dependency on `package:grpc`.
///
/// ## Plugin extraction
///
/// This entire `grpc_web/` directory is self-contained and can be extracted
/// into a standalone Dart package by adding a `pubspec.yaml` with:
/// ```yaml
/// dependencies:
///   http: ^1.1.0
///   protobuf: ^6.0.0
/// ```
library grpc_web;

export 'src/call_options.dart' show CallOptions;
export 'src/client.dart' show GrpcWebClient;
export 'src/codec.dart'
    show
        encodeGrpcWebFrame,
        decodeGrpcWebResponse,
        decodeGrpcWebStream,
        encodeGrpcWebTextFrame,
        decodeGrpcWebTextResponse,
        decodeGrpcWebTextStream,
        parseTrailers,
        GrpcWebResponse;
export 'src/error.dart' show GrpcWebError;
export 'src/interceptor.dart' show GrpcWebInterceptor;
export 'src/retry.dart' show RetryPolicy;
export 'src/status_codes.dart' show GrpcStatus;
