import 'dart:convert';
import 'dart:typed_data';

import 'error.dart';

/// A decoded gRPC-Web response containing concatenated data and trailers.
class GrpcWebResponse {
  /// Concatenated payload bytes from all data frames.
  final Uint8List data;

  /// Parsed trailer headers (keys lowercased).
  final Map<String, String> trailers;

  GrpcWebResponse(this.data, this.trailers);
}

// ---------------------------------------------------------------------------
// Binary mode (application/grpc-web+proto)
// ---------------------------------------------------------------------------

/// Encodes a protobuf payload into a single gRPC-Web data frame.
///
/// Frame format: `[0x00] [4-byte big-endian length] [payload]`
Uint8List encodeGrpcWebFrame(Uint8List data) {
  final frame = Uint8List(5 + data.length);
  frame[0] = 0x00; // data frame flag
  frame[1] = (data.length >> 24) & 0xFF;
  frame[2] = (data.length >> 16) & 0xFF;
  frame[3] = (data.length >> 8) & 0xFF;
  frame[4] = data.length & 0xFF;
  frame.setRange(5, 5 + data.length, data);
  return frame;
}

/// Decodes a complete gRPC-Web response body into data + trailers.
///
/// A response may contain one or more data frames (flag `0x00`) followed
/// by a trailers frame (flag `0x80`). Data frame payloads are concatenated.
///
/// Throws [FormatException] on truncated or malformed frames.
GrpcWebResponse decodeGrpcWebResponse(Uint8List responseBytes) {
  final dataChunks = <Uint8List>[];
  Map<String, String> trailers = {};
  int offset = 0;

  while (offset < responseBytes.length) {
    if (offset + 5 > responseBytes.length) {
      throw FormatException(
        'Truncated gRPC-Web frame header at offset $offset '
        '(need 5 bytes, have ${responseBytes.length - offset})',
      );
    }

    final flag = responseBytes[offset];
    final length = (responseBytes[offset + 1] << 24) |
        (responseBytes[offset + 2] << 16) |
        (responseBytes[offset + 3] << 8) |
        responseBytes[offset + 4];
    offset += 5;

    if (offset + length > responseBytes.length) {
      throw FormatException(
        'gRPC-Web frame at offset ${offset - 5} declares length $length '
        'but only ${responseBytes.length - offset} bytes available',
      );
    }

    final payload = responseBytes.sublist(offset, offset + length);
    offset += length;

    if (flag & 0x80 != 0) {
      trailers = parseTrailers(payload);
    } else {
      dataChunks.add(Uint8List.fromList(payload));
    }
  }

  // Concatenate all data chunks
  final totalLength =
      dataChunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
  final data = Uint8List(totalLength);
  int pos = 0;
  for (final chunk in dataChunks) {
    data.setRange(pos, pos + chunk.length, chunk);
    pos += chunk.length;
  }

  return GrpcWebResponse(data, trailers);
}

/// Decodes a byte stream into individual gRPC-Web data frame payloads.
///
/// Yields each data frame's payload as it becomes available.
/// When a trailers frame is encountered the stream completes.
/// If the trailers contain a non-zero `grpc-status`, throws [GrpcWebError].
Stream<Uint8List> decodeGrpcWebStream(Stream<List<int>> byteStream) async* {
  final buffer = BytesBuilder(copy: false);

  await for (final chunk in byteStream) {
    buffer.add(chunk);

    while (true) {
      final bytes = buffer.toBytes();
      if (bytes.length < 5) break;

      final flag = bytes[0];
      final length = (bytes[1] << 24) |
          (bytes[2] << 16) |
          (bytes[3] << 8) |
          bytes[4];

      if (bytes.length < 5 + length) break;

      final payload = Uint8List.fromList(bytes.sublist(5, 5 + length));

      // Rebuild buffer with remaining bytes
      final remaining = bytes.sublist(5 + length);
      buffer.clear();
      if (remaining.isNotEmpty) {
        buffer.add(remaining);
      }

      if (flag & 0x80 != 0) {
        // Trailers frame — check grpc-status and complete
        final trailers = parseTrailers(payload);
        final statusStr = trailers['grpc-status'];
        final status = statusStr != null ? int.tryParse(statusStr) ?? 0 : 0;
        if (status != 0) {
          throw GrpcWebError(
            status,
            trailers['grpc-message'] ?? 'Unknown error',
          );
        }
        return;
      } else {
        yield payload;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Text mode (application/grpc-web-text)
// ---------------------------------------------------------------------------

/// Encodes a gRPC-Web frame into base64 for the `grpc-web-text` content type.
///
/// [binaryFrame] should already be a framed payload from [encodeGrpcWebFrame].
Uint8List encodeGrpcWebTextFrame(Uint8List binaryFrame) {
  return Uint8List.fromList(base64.encode(binaryFrame).codeUnits);
}

/// Decodes a complete `grpc-web-text` response body (base64-encoded binary
/// frames) into data + trailers.
GrpcWebResponse decodeGrpcWebTextResponse(Uint8List responseBytes) {
  final decoded = base64.decode(String.fromCharCodes(responseBytes));
  return decodeGrpcWebResponse(Uint8List.fromList(decoded));
}

/// Decodes a `grpc-web-text` byte stream into individual data frame payloads.
///
/// Base64 data arrives in chunks that may not align to 4-byte boundaries,
/// so this buffers until complete base64 segments are available, then decodes
/// and extracts binary gRPC frames.
Stream<Uint8List> decodeGrpcWebTextStream(
  Stream<List<int>> byteStream,
) async* {
  final base64Buffer = StringBuffer();
  final binaryBuffer = BytesBuilder(copy: false);

  await for (final chunk in byteStream) {
    base64Buffer.write(String.fromCharCodes(chunk));

    // Decode in multiples of 4 characters (base64 block size).
    final buffered = base64Buffer.toString();
    final usable = buffered.length - (buffered.length % 4);
    if (usable == 0) continue;

    final decoded = base64.decode(buffered.substring(0, usable));
    base64Buffer.clear();
    if (usable < buffered.length) {
      base64Buffer.write(buffered.substring(usable));
    }

    binaryBuffer.add(decoded);

    // Extract complete binary frames from the decoded bytes.
    while (true) {
      final bytes = binaryBuffer.toBytes();
      if (bytes.length < 5) break;

      final flag = bytes[0];
      final length = (bytes[1] << 24) |
          (bytes[2] << 16) |
          (bytes[3] << 8) |
          bytes[4];

      if (bytes.length < 5 + length) break;

      final payload = Uint8List.fromList(bytes.sublist(5, 5 + length));

      final remaining = bytes.sublist(5 + length);
      binaryBuffer.clear();
      if (remaining.isNotEmpty) {
        binaryBuffer.add(remaining);
      }

      if (flag & 0x80 != 0) {
        final trailers = parseTrailers(payload);
        final statusStr = trailers['grpc-status'];
        final status = statusStr != null ? int.tryParse(statusStr) ?? 0 : 0;
        if (status != 0) {
          throw GrpcWebError(
            status,
            trailers['grpc-message'] ?? 'Unknown error',
          );
        }
        return;
      } else {
        yield payload;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Trailer parsing
// ---------------------------------------------------------------------------

/// Parses a trailers frame payload into a header map.
///
/// Format: `"key: value\r\n"` pairs. Keys are lowercased.
Map<String, String> parseTrailers(Uint8List payload) {
  final text = utf8.decode(payload);
  final trailers = <String, String>{};
  for (final line in text.split('\r\n')) {
    if (line.isEmpty) continue;
    final colonIndex = line.indexOf(':');
    if (colonIndex == -1) continue;
    final key = line.substring(0, colonIndex).trim().toLowerCase();
    final value = line.substring(colonIndex + 1).trim();
    trailers[key] = value;
  }
  return trailers;
}
