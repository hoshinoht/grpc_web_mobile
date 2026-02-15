import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:protobuf/protobuf.dart';

import 'call_options.dart';
import 'codec.dart';
import 'error.dart';
import 'interceptor.dart';
import 'retry.dart';
import 'status_codes.dart';

/// A gRPC-Web client that sends requests over HTTP/1.1.
///
/// This enables gRPC through HTTP/1.1-only proxies such as Cloudflare Tunnels.
/// The remote server must have gRPC-Web middleware enabled
/// (e.g. ASP.NET `UseGrpcWeb()`).
///
/// Only `package:http` and `package:protobuf` are required — no dependency
/// on the Dart `grpc` package — so this can run on any Flutter platform.
///
/// ```dart
/// final client = GrpcWebClient(baseUrl: 'https://api.example.com');
///
/// final response = await client.unaryCall(
///   '/my.package.MyService/MyMethod',
///   myRequest,
///   MyResponse.fromBuffer,
///   options: CallOptions(metadata: {'authorization': 'Bearer $token'}),
/// );
/// ```
class GrpcWebClient {
  /// Base URL of the gRPC-Web endpoint (e.g. `https://api.example.com`).
  final String baseUrl;

  /// Default timeout for calls when no per-call timeout/deadline is set.
  final Duration timeout;

  /// When `true`, use `application/grpc-web-text` (base64) content type.
  final bool useTextMode;

  final http.Client _httpClient;
  final List<GrpcWebInterceptor> _interceptors;

  /// Creates a gRPC-Web client.
  ///
  /// If [httpClient] is omitted a default `http.Client()` is created.
  /// Pass a custom client for testing or to configure timeouts.
  ///
  /// [interceptors] are applied in order — the first interceptor in the list
  /// is the outermost wrapper around the actual RPC.
  ///
  /// When [retryPolicy] is provided, a [RetryInterceptor] is automatically
  /// prepended to the interceptor chain.
  ///
  /// When [useTextMode] is `true`, requests use the `application/grpc-web-text`
  /// content type (base64-encoded frames), which some proxies require for
  /// server-streaming calls.
  GrpcWebClient({
    required this.baseUrl,
    this.timeout = const Duration(seconds: 10),
    this.useTextMode = false,
    http.Client? httpClient,
    List<GrpcWebInterceptor>? interceptors,
    RetryPolicy? retryPolicy,
  }) : _httpClient = httpClient ?? http.Client(),
       _interceptors = [
         if (retryPolicy != null) RetryInterceptor(retryPolicy),
         ...?interceptors,
       ];

  // ---------------------------------------------------------------------------
  // Unary RPC
  // ---------------------------------------------------------------------------

  /// Executes a unary gRPC-Web call and returns the deserialized response.
  ///
  /// * [path] — full method path, e.g. `'/pkg.Service/Method'`
  /// * [request] — protobuf request message
  /// * [responseDeserializer] — factory such as `MyResponse.fromBuffer`
  /// * [options] — per-call metadata, timeout, and deadline
  Future<T> unaryCall<T extends GeneratedMessage>(
    String path,
    GeneratedMessage request,
    T Function(List<int>) responseDeserializer, {
    CallOptions? options,
  }) {
    final resolvedOptions = options ?? const CallOptions();
    if (_interceptors.isEmpty) {
      return _executeUnary(path, request, responseDeserializer, resolvedOptions);
    }
    return _buildUnaryChain<T>(0)(
      path,
      request,
      responseDeserializer,
      resolvedOptions,
    );
  }

  // ---------------------------------------------------------------------------
  // Server-streaming RPC
  // ---------------------------------------------------------------------------

  /// Executes a server-streaming gRPC-Web call.
  ///
  /// Yields deserialized protobuf messages as they arrive.
  Stream<T> serverStreamingCall<T extends GeneratedMessage>(
    String path,
    GeneratedMessage request,
    T Function(List<int>) responseDeserializer, {
    CallOptions? options,
  }) {
    final resolvedOptions = options ?? const CallOptions();
    if (_interceptors.isEmpty) {
      return _executeStreaming(
        path,
        request,
        responseDeserializer,
        resolvedOptions,
      );
    }
    return _buildStreamingChain<T>(0)(
      path,
      request,
      responseDeserializer,
      resolvedOptions,
    );
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Closes the underlying HTTP client.
  ///
  /// After calling this, no further requests can be made with this instance.
  void close() {
    _httpClient.close();
  }

  // ---------------------------------------------------------------------------
  // Interceptor chain builders
  // ---------------------------------------------------------------------------

  UnaryInvoker<T> _buildUnaryChain<T extends GeneratedMessage>(int index) {
    if (index >= _interceptors.length) return _executeUnary;
    return (path, request, deserializer, options) =>
        _interceptors[index].interceptUnary<T>(
          path,
          request,
          deserializer,
          options,
          _buildUnaryChain<T>(index + 1),
        );
  }

  StreamingInvoker<T> _buildStreamingChain<T extends GeneratedMessage>(
    int index,
  ) {
    if (index >= _interceptors.length) return _executeStreaming;
    return (path, request, deserializer, options) =>
        _interceptors[index].interceptStreaming<T>(
          path,
          request,
          deserializer,
          options,
          _buildStreamingChain<T>(index + 1),
        );
  }

  // ---------------------------------------------------------------------------
  // Actual RPC execution
  // ---------------------------------------------------------------------------

  Future<T> _executeUnary<T extends GeneratedMessage>(
    String path,
    GeneratedMessage request,
    T Function(List<int>) responseDeserializer,
    CallOptions options,
  ) async {
    final framedRequest =
        encodeGrpcWebFrame(Uint8List.fromList(request.writeToBuffer()));

    final body = useTextMode ? encodeGrpcWebTextFrame(framedRequest) : framedRequest;
    final effectiveTimeout = _resolveTimeout(options);

    final response = await _httpClient
        .post(
          Uri.parse('$baseUrl$path'),
          headers: _buildHeaders(options),
          body: body,
        )
        .timeout(effectiveTimeout, onTimeout: () {
          throw GrpcWebError(
            GrpcStatus.deadlineExceeded,
            'gRPC-Web request timed out after ${effectiveTimeout.inSeconds}s',
          );
        });

    if (response.statusCode != 200) {
      throw GrpcWebError(
        httpStatusToGrpcCode(response.statusCode),
        'HTTP ${response.statusCode}: ${response.reasonPhrase}',
      );
    }

    // Handle "trailers-only" responses where grpc-status is in HTTP headers
    // and the body is empty (e.g. auth errors, unimplemented methods).
    final responseBytes = Uint8List.fromList(response.bodyBytes);
    if (responseBytes.isEmpty) {
      final headerStatus = response.headers['grpc-status'];
      if (headerStatus != null) {
        final status = int.tryParse(headerStatus) ?? 0;
        if (status != GrpcStatus.ok) {
          throw GrpcWebError(
            status,
            response.headers['grpc-message'] ?? 'Unknown error',
          );
        }
      }
      throw const FormatException('Empty gRPC-Web response body');
    }

    final decoded =
        useTextMode
            ? decodeGrpcWebTextResponse(responseBytes)
            : decodeGrpcWebResponse(responseBytes);
    _checkTrailerStatus(decoded.trailers);
    return responseDeserializer(decoded.data);
  }

  Stream<T> _executeStreaming<T extends GeneratedMessage>(
    String path,
    GeneratedMessage request,
    T Function(List<int>) responseDeserializer,
    CallOptions options,
  ) async* {
    final framedRequest =
        encodeGrpcWebFrame(Uint8List.fromList(request.writeToBuffer()));

    final body = useTextMode ? encodeGrpcWebTextFrame(framedRequest) : framedRequest;

    final httpRequest =
        http.StreamedRequest('POST', Uri.parse('$baseUrl$path'));
    _buildHeaders(options)
        .forEach((key, value) => httpRequest.headers[key] = value);
    httpRequest.sink.add(body);
    httpRequest.sink.close();

    final response = await _httpClient.send(httpRequest);

    if (response.statusCode != 200) {
      throw GrpcWebError(
        httpStatusToGrpcCode(response.statusCode),
        'HTTP ${response.statusCode}',
      );
    }

    final stream =
        useTextMode
            ? decodeGrpcWebTextStream(response.stream)
            : decodeGrpcWebStream(response.stream);
    yield* stream.map((payload) => responseDeserializer(payload));
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Computes the effective timeout from [CallOptions] and the client default.
  Duration _resolveTimeout(CallOptions options) {
    var effective = timeout;

    if (options.timeout != null && options.timeout! < effective) {
      effective = options.timeout!;
    }

    if (options.deadline != null) {
      final remaining = options.deadline!.difference(DateTime.now());
      if (remaining < effective) effective = remaining;
    }

    // Clamp to at least zero to avoid negative durations.
    if (effective.isNegative) return Duration.zero;
    return effective;
  }

  /// Formats a [Duration] as a gRPC timeout header value.
  ///
  /// Uses the largest unit that fits without loss: hours (`H`), minutes (`M`),
  /// seconds (`S`), milliseconds (`m`), microseconds (`u`), or nanoseconds (`n`).
  static String _formatGrpcTimeout(Duration d) {
    final us = d.inMicroseconds;
    if (us <= 0) return '0m';
    if (us % (Duration.microsecondsPerHour) == 0) {
      return '${us ~/ Duration.microsecondsPerHour}H';
    }
    if (us % (Duration.microsecondsPerMinute) == 0) {
      return '${us ~/ Duration.microsecondsPerMinute}M';
    }
    if (us % (Duration.microsecondsPerSecond) == 0) {
      return '${us ~/ Duration.microsecondsPerSecond}S';
    }
    if (us % (Duration.microsecondsPerMillisecond) == 0) {
      return '${us ~/ Duration.microsecondsPerMillisecond}m';
    }
    return '${us}u';
  }

  Map<String, String> _buildHeaders(CallOptions options) {
    final contentType =
        useTextMode ? 'application/grpc-web-text' : 'application/grpc-web+proto';
    final effectiveTimeout = _resolveTimeout(options);

    return <String, String>{
      'Content-Type': contentType,
      'Accept': contentType,
      'x-grpc-web': '1',
      'Accept-Encoding': 'gzip',
      'grpc-timeout': _formatGrpcTimeout(effectiveTimeout),
      if (options.metadata != null) ...options.metadata!,
    };
  }

  static void _checkTrailerStatus(Map<String, String> trailers) {
    final statusStr = trailers['grpc-status'];
    final status = statusStr != null ? int.tryParse(statusStr) ?? 0 : 0;
    if (status != GrpcStatus.ok) {
      throw GrpcWebError(
        status,
        trailers['grpc-message'] ?? 'Unknown error',
      );
    }
  }

  /// Maps common HTTP status codes to gRPC status codes.
  static int httpStatusToGrpcCode(int httpStatus) {
    switch (httpStatus) {
      case 400:
        return GrpcStatus.invalidArgument;
      case 401:
        return GrpcStatus.unauthenticated;
      case 403:
        return GrpcStatus.permissionDenied;
      case 404:
        return GrpcStatus.notFound;
      case 408:
        return GrpcStatus.deadlineExceeded;
      case 429:
        return GrpcStatus.resourceExhausted;
      case 500:
        return GrpcStatus.internal;
      case 501:
        return GrpcStatus.unimplemented;
      case 503:
        return GrpcStatus.unavailable;
      case 504:
        return GrpcStatus.deadlineExceeded;
      default:
        return GrpcStatus.unknown;
    }
  }
}
