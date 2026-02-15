import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:protobuf/protobuf.dart';

import 'codec.dart';
import 'error.dart';

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
///   metadata: {'authorization': 'Bearer $token'},
/// );
/// ```
class GrpcWebClient {
  /// Base URL of the gRPC-Web endpoint (e.g. `https://api.example.com`).
  final String baseUrl;

  /// Timeout for unary calls.
  final Duration timeout;

  final http.Client _httpClient;

  /// Creates a gRPC-Web client.
  ///
  /// If [httpClient] is omitted a default `http.Client()` is created.
  /// Pass a custom client for testing or to configure timeouts.
  GrpcWebClient({
    required this.baseUrl,
    this.timeout = const Duration(seconds: 10),
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  // ---------------------------------------------------------------------------
  // Unary RPC
  // ---------------------------------------------------------------------------

  /// Executes a unary gRPC-Web call and returns the deserialized response.
  ///
  /// * [path] — full method path, e.g. `'/pkg.Service/Method'`
  /// * [request] — protobuf request message
  /// * [responseDeserializer] — factory such as `MyResponse.fromBuffer`
  /// * [metadata] — optional HTTP headers (e.g. auth tokens)
  Future<T> unaryCall<T extends GeneratedMessage>(
    String path,
    GeneratedMessage request,
    T Function(List<int>) responseDeserializer, {
    Map<String, String>? metadata,
  }) async {
    final framedRequest =
        encodeGrpcWebFrame(Uint8List.fromList(request.writeToBuffer()));

    final response = await _httpClient.post(
      Uri.parse('$baseUrl$path'),
      headers: _buildHeaders(metadata),
      body: framedRequest,
    ).timeout(timeout, onTimeout: () {
      throw GrpcWebError(4, 'gRPC-Web request timed out after ${timeout.inSeconds}s');
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
        if (status != 0) {
          throw GrpcWebError(
            status,
            response.headers['grpc-message'] ?? 'Unknown error',
          );
        }
      }
      throw const FormatException('Empty gRPC-Web response body');
    }

    final decoded = decodeGrpcWebResponse(responseBytes);
    _checkTrailerStatus(decoded.trailers);
    return responseDeserializer(decoded.data);
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
    Map<String, String>? metadata,
  }) async* {
    final framedRequest =
        encodeGrpcWebFrame(Uint8List.fromList(request.writeToBuffer()));

    final httpRequest =
        http.StreamedRequest('POST', Uri.parse('$baseUrl$path'));
    _buildHeaders(metadata)
        .forEach((key, value) => httpRequest.headers[key] = value);
    httpRequest.sink.add(framedRequest);
    httpRequest.sink.close();

    final response = await _httpClient.send(httpRequest);

    if (response.statusCode != 200) {
      throw GrpcWebError(
        httpStatusToGrpcCode(response.statusCode),
        'HTTP ${response.statusCode}',
      );
    }

    yield* decodeGrpcWebStream(response.stream)
        .map((payload) => responseDeserializer(payload));
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
  // Internals
  // ---------------------------------------------------------------------------

  Map<String, String> _buildHeaders(Map<String, String>? metadata) {
    return <String, String>{
      'Content-Type': 'application/grpc-web+proto',
      'Accept': 'application/grpc-web+proto',
      'x-grpc-web': '1',
      if (metadata != null) ...metadata,
    };
  }

  static void _checkTrailerStatus(Map<String, String> trailers) {
    final statusStr = trailers['grpc-status'];
    final status = statusStr != null ? int.tryParse(statusStr) ?? 0 : 0;
    if (status != 0) {
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
        return 3; // INVALID_ARGUMENT
      case 401:
        return 16; // UNAUTHENTICATED
      case 403:
        return 7; // PERMISSION_DENIED
      case 404:
        return 5; // NOT_FOUND
      case 408:
        return 4; // DEADLINE_EXCEEDED
      case 429:
        return 8; // RESOURCE_EXHAUSTED
      case 500:
        return 13; // INTERNAL
      case 501:
        return 12; // UNIMPLEMENTED
      case 503:
        return 14; // UNAVAILABLE
      case 504:
        return 4; // DEADLINE_EXCEEDED
      default:
        return 2; // UNKNOWN
    }
  }
}
