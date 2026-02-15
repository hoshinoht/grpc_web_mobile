# grpc_web_mobile

A self-contained gRPC-Web client for Dart/Flutter that sends gRPC requests over HTTP/1.1 using `package:http`. Designed for environments where HTTP/2 is not available (e.g. Cloudflare Tunnels) but a gRPC-Web enabled server is. Intended for non-web Flutter platforms.

## Features

- Unary and server-streaming RPCs
- **Interceptors** — chain-of-responsibility pattern for auth, logging, error handling, etc.
- **Retry with exponential backoff** — configurable policy with jitter and deadline awareness
- **Deadline propagation** — per-call timeout/deadline sent via `grpc-timeout` header
- **CallOptions** — per-call metadata, timeout, and deadline (mergeable)
- **Base64 text mode** — `application/grpc-web-text` support for proxies that require it
- **HTTP compression** — sends `Accept-Encoding: gzip` for response compression
- **Named status codes** — `GrpcStatus` constants for all 17 gRPC status codes
- Works on any Flutter platform (no dependency on `package:grpc`)
- Minimal dependencies: `http` and `protobuf`

## Folder layout

```
grpc_web.dart              # barrel file — exports all public types
src/
  client.dart              # GrpcWebClient with interceptor chain
  codec.dart               # binary + base64 frame encoding/decoding
  error.dart               # GrpcWebError exception
  status_codes.dart        # GrpcStatus named constants
  call_options.dart        # CallOptions (metadata, timeout, deadline)
  interceptor.dart         # GrpcWebInterceptor abstract class
  retry.dart               # RetryPolicy + RetryInterceptor
```

## Requirements

- Dart SDK compatible with your app
- Dependencies:
  - `http: ^1.1.0`
  - `protobuf: ^6.0.0`

## Installation

This directory is self-contained. You can:

1. Copy the `grpc_web/` folder into your app and import locally, or
2. Extract it into a standalone package by adding a `pubspec.yaml` with the dependencies above.

## Quick start

```dart
import 'grpc_web/grpc_web.dart';

final client = GrpcWebClient(
  baseUrl: 'https://api.example.com',
  retryPolicy: RetryPolicy(),          // optional: auto-retry on UNAVAILABLE
  interceptors: [MyAuthInterceptor()], // optional: custom interceptors
);

final response = await client.unaryCall(
  '/my.package.MyService/MyMethod',
  myRequest,
  MyResponse.fromBuffer,
  options: CallOptions(
    metadata: {'authorization': 'Bearer $token'},
    timeout: Duration(seconds: 5),
  ),
);

client.close();
```

## Server streaming

```dart
await for (final event in client.serverStreamingCall(
  '/my.package.MyService/StreamMethod',
  streamRequest,
  StreamResponse.fromBuffer,
  options: CallOptions(metadata: {'authorization': 'Bearer $token'}),
)) {
  print(event);
}
```

## API overview

### `GrpcWebClient`

```dart
final client = GrpcWebClient(
  baseUrl: 'https://api.example.com',
  timeout: Duration(seconds: 10),    // default timeout for all calls
  useTextMode: false,                 // true for grpc-web-text (base64)
  interceptors: [],                   // custom interceptors
  retryPolicy: RetryPolicy(),        // retry configuration
  httpClient: myHttpClient,          // optional custom http.Client
);
```

- `unaryCall<T>()` — Sends one request, returns one response.
  - `path`: full method path, e.g. `'/pkg.Service/Method'`
  - `request`: protobuf request message
  - `responseDeserializer`: e.g. `MyResponse.fromBuffer`
  - `options`: optional `CallOptions` (metadata, timeout, deadline)
- `serverStreamingCall<T>()` — Sends one request, yields a stream of responses. Same parameters.
- `close()` — Closes the underlying HTTP client.

### `CallOptions`

Per-call options that override client defaults:

```dart
final options = CallOptions(
  metadata: {'authorization': 'Bearer $token'},
  timeout: Duration(seconds: 5),
  deadline: DateTime.now().add(Duration(seconds: 30)),
);

// Merge two option sets (latter takes precedence):
final merged = baseOptions.mergedWith(overrideOptions);
```

When both `timeout` and `deadline` are set, the tighter constraint wins. The resolved timeout is sent to the server via the `grpc-timeout` header.

### `GrpcWebInterceptor`

Implement to intercept and modify calls:

```dart
class AuthInterceptor extends GrpcWebInterceptor {
  @override
  Future<T> interceptUnary<T extends GeneratedMessage>(
    String path, GeneratedMessage request,
    T Function(List<int>) deserializer, CallOptions options,
    UnaryInvoker<T> next,
  ) {
    final authedOptions = CallOptions(
      metadata: {'authorization': 'Bearer $token'},
    );
    return next(path, request, deserializer, options.mergedWith(authedOptions));
  }

  @override
  Stream<T> interceptStreaming<T extends GeneratedMessage>(
    String path, GeneratedMessage request,
    T Function(List<int>) deserializer, CallOptions options,
    StreamingInvoker<T> next,
  ) {
    final authedOptions = CallOptions(
      metadata: {'authorization': 'Bearer $token'},
    );
    return next(path, request, deserializer, options.mergedWith(authedOptions));
  }
}
```

### `RetryPolicy`

Automatic retry for failed unary calls with exponential backoff and jitter:

```dart
final policy = RetryPolicy(
  maxAttempts: 3,                              // default: 3
  initialBackoff: Duration(milliseconds: 100), // default: 100ms
  maxBackoff: Duration(seconds: 5),            // default: 5s
  backoffMultiplier: 2.0,                      // default: 2.0
  retryableStatusCodes: {                      // default: UNAVAILABLE, DEADLINE_EXCEEDED
    GrpcStatus.unavailable,
    GrpcStatus.deadlineExceeded,
  },
);
```

Retry is only applied to unary calls. Streaming calls are passed through without retry since retrying a partially consumed stream is unsafe. The retry interceptor respects call deadlines and stops retrying when the deadline would be exceeded.

### `GrpcStatus`

Named constants for all gRPC status codes:

```dart
GrpcStatus.ok               // 0
GrpcStatus.cancelled         // 1
GrpcStatus.unknown           // 2
GrpcStatus.invalidArgument   // 3
GrpcStatus.deadlineExceeded  // 4
GrpcStatus.notFound          // 5
GrpcStatus.alreadyExists     // 6
GrpcStatus.permissionDenied  // 7
GrpcStatus.resourceExhausted // 8
GrpcStatus.failedPrecondition // 9
GrpcStatus.aborted           // 10
GrpcStatus.outOfRange        // 11
GrpcStatus.unimplemented     // 12
GrpcStatus.internal          // 13
GrpcStatus.unavailable       // 14
GrpcStatus.dataLoss          // 15
GrpcStatus.unauthenticated   // 16
```

### Codec utilities

Binary mode:
- `encodeGrpcWebFrame()` — encodes a protobuf payload into a gRPC-Web data frame
- `decodeGrpcWebResponse()` — decodes a full response into data + trailers
- `decodeGrpcWebStream()` — parses a streamed response into data frames
- `parseTrailers()` — parses trailers from a trailers frame payload

Text mode (base64):
- `encodeGrpcWebTextFrame()` — base64-encodes a binary frame
- `decodeGrpcWebTextResponse()` — decodes a base64 response body
- `decodeGrpcWebTextStream()` — streaming base64 decode with frame extraction

### Errors

`GrpcWebError` is thrown when the server returns a non-zero `grpc-status` or when a non-200 HTTP response maps to a gRPC error code.

```dart
try {
  final response = await client.unaryCall(
    '/pkg.Service/Method',
    request,
    MyResponse.fromBuffer,
  );
} on GrpcWebError catch (e) {
  print(e.code);    // gRPC status code (int)
  print(e.message); // server error message
  print(e.details); // optional error details
}
```

## gRPC-Web protocol notes

- Binary mode uses `Content-Type: application/grpc-web+proto`
- Text mode uses `Content-Type: application/grpc-web-text` (base64-encoded frames)
- Data frames use flag `0x00`, trailer frames use flag `0x80`
- Trailers are parsed and checked for `grpc-status` and `grpc-message`
- Trailers-only responses (empty body with `grpc-status` in HTTP headers) are handled
- `grpc-timeout` header is sent with the resolved timeout in gRPC format (e.g. `5000m`)
- `Accept-Encoding: gzip` is sent so proxies/servers can compress responses

## Limitations

- **No client streaming or bidirectional streaming** — this is a fundamental protocol limitation of gRPC-Web over HTTP/1.1, not a missing feature
- **No per-message compression** — `grpc-encoding` is not supported by the gRPC-Web protocol; HTTP-level gzip compression is used instead
- **Binary protobuf only** — no JSON transcoding
- Server must have gRPC-Web middleware enabled (e.g. ASP.NET `UseGrpcWeb()`)

## Examples

```dart
import 'grpc_web/grpc_web.dart';

// Full-featured client setup
final client = GrpcWebClient(
  baseUrl: 'https://api.example.com',
  timeout: Duration(seconds: 10),
  retryPolicy: RetryPolicy(maxAttempts: 3),
  interceptors: [AuthInterceptor(), LoggingInterceptor()],
);

// Unary call with per-call options
final request = MyRequest()
  ..id = '123'
  ..includeDetails = true;

final response = await client.unaryCall(
  '/my.package.MyService/GetItem',
  request,
  MyResponse.fromBuffer,
  options: CallOptions(
    metadata: {'x-request-id': 'abc-123'},
    deadline: DateTime.now().add(Duration(seconds: 30)),
  ),
);

print(response);
client.close();
```

## Contributing

- Keep the API surface minimal and dependency-free.
- Add tests for frame parsing and trailer handling if you extend the codec.

## License

Add your preferred license here.
