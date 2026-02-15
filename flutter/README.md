# grpc_web_android

A small, self-contained gRPC-Web client for Dart/Flutter that sends gRPC requests over HTTP/1.1 using `package:http`. It is designed for environments where HTTP/2 is not available (for example, Cloudflare Tunnels) but a gRPC-Web enabled server is, and is intended for non-web Flutter services.

## Features

- Unary and server-streaming RPCs
- Works on any Flutter platform (no dependency on `package:grpc`)
- Minimal dependencies: `http` and `protobuf`
- Handles gRPC-Web frames and trailers

## Folder layout

```
grpc_web.dart
src/
  client.dart
  codec.dart
  error.dart
```

## Requirements

- Dart SDK compatible with your app
- Dependencies:
  - `http: ^1.1.0`
  - `protobuf: ^6.0.0`

## Installation

This directory is self-contained. You can:

1) Copy the `grpc_web_android` folder into your app, and then import locally, or
2) Extract it into a standalone package by adding a `pubspec.yaml` with the dependencies above.

## Quick start

```dart
import 'grpc_web.dart';

final client = GrpcWebClient(baseUrl: 'https://api.example.com');

final response = await client.unaryCall(
  '/my.package.MyService/MyMethod',
  myRequest,
  MyResponse.fromBuffer,
  metadata: {'authorization': 'Bearer $token'},
);

client.close();
```

## Server streaming

```dart
await for (final event in client.serverStreamingCall(
  '/my.package.MyService/StreamMethod',
  streamRequest,
  StreamResponse.fromBuffer,
  metadata: {'authorization': 'Bearer $token'},
)) {
  print(event);
}
```

## API overview

### `GrpcWebClient`

Create a client with a base URL that points to your gRPC-Web endpoint:

```dart
final client = GrpcWebClient(
  baseUrl: 'https://api.example.com',
  timeout: const Duration(seconds: 10),
);
```

- `unaryCall<T>()`
  - Sends a single request message and returns one response.
  - Parameters:
    - `path`: full method path, e.g. `'/pkg.Service/Method'`
    - `request`: protobuf request message
    - `responseDeserializer`: `MyResponse.fromBuffer`
    - `metadata`: optional HTTP headers (auth tokens, trace IDs)
- `serverStreamingCall<T>()`
  - Sends a single request message and yields a stream of responses.
  - Parameters are the same as `unaryCall`.
- `close()`
  - Closes the underlying HTTP client. Call when done.

### Codec utilities

- `encodeGrpcWebFrame()` encodes a protobuf payload into a gRPC-Web data frame.
- `decodeGrpcWebResponse()` decodes a full gRPC-Web response into data + trailers.
- `decodeGrpcWebStream()` parses a streamed response into data frames.
- `parseTrailers()` parses trailers from a trailers frame payload.

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
  // e.code is the gRPC status code
  // e.message is the server message
}
```

## gRPC-Web notes

- Requests are sent with `Content-Type: application/grpc-web+proto`.
- The client supports data frames (`0x00`) and trailers frames (`0x80`).
- Trailers are parsed and checked for `grpc-status` and `grpc-message`.
- If a server returns a trailers-only response, unary calls will check headers
  for `grpc-status`.

## Limitations

- Client streaming and bidirectional streaming are not implemented.
- Compression is not implemented.
- Only binary protobuf payloads are supported (no JSON transcoding).

## Examples

Assuming you have generated protobuf classes with `protoc` and `package:protobuf`:

```dart
final client = GrpcWebClient(baseUrl: 'https://api.example.com');

final request = MyRequest()
  ..id = '123'
  ..includeDetails = true;

final response = await client.unaryCall(
  '/my.package.MyService/GetItem',
  request,
  MyResponse.fromBuffer,
);

print(response);
client.close();
```

## Contributing

- Keep the API surface minimal and dependency-free.
- Add tests for frame parsing and trailer handling if you extend the codec.

## License

Add your preferred license here.
