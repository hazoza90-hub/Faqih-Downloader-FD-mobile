import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

Uint8List generateTestPayload(int length, {int seed = 42}) {
  final rng = math.Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = rng.nextInt(256);
  }
  return bytes;
}

String sha256HexOf(List<int> bytes) => sha256.convert(bytes).toString();

/// Real local loopback HTTP server supporting Range 206, delays, HTML, and errors.
class MockRangeServer {
  MockRangeServer._(this._server, this.payload);

  final HttpServer _server;
  final Uint8List payload;

  bool rejectHeadWith405 = false;
  bool supportRanges = true;
  bool unknownContentLength = false;
  bool serveHtml = false;
  int? forceErrorStatus;
  String? contentDisposition;
  String? redirectPath;
  Duration chunkDelay = Duration.zero;
  int streamSliceSize = 32 * 1024;

  int headCount = 0;
  int getCount = 0;
  int rangeGetCount = 0;
  final List<String> requestedRanges = <String>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';
  String fileUrl([String path = '/file.bin']) => '$baseUrl$path';

  static Future<MockRangeServer> start(Uint8List payload) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mock = MockRangeServer._(server, payload);
    server.listen(mock._handleRequest);
    return mock;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handleRequest(HttpRequest req) async {
    final resp = req.response;
    try {
      if (redirectPath != null && req.uri.path != redirectPath) {
        resp.statusCode = HttpStatus.movedTemporarily;
        resp.headers.set(HttpHeaders.locationHeader, redirectPath!);
        await resp.close();
        return;
      }

      if (forceErrorStatus != null) {
        resp.statusCode = forceErrorStatus!;
        await resp.close();
        return;
      }

      if (serveHtml) {
        resp.statusCode = HttpStatus.ok;
        resp.headers.contentType = ContentType.html;
        resp.write('<html><body>Not a binary file</body></html>');
        await resp.close();
        return;
      }

      if (req.method == 'HEAD') {
        headCount++;
        if (rejectHeadWith405) {
          resp.statusCode = HttpStatus.methodNotAllowed;
          await resp.close();
          return;
        }
        _applyCommonHeaders(resp);
        resp.statusCode = HttpStatus.ok;
        if (!unknownContentLength) {
          resp.contentLength = payload.length;
        }
        await resp.close();
        return;
      }

      getCount++;
      _applyCommonHeaders(resp);

      final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
      if (supportRanges && rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        rangeGetCount++;
        requestedRanges.add(rangeHeader);
        final parts = rangeHeader.substring(6).split('-');
        final start = int.tryParse(parts[0].trim()) ?? 0;
        final end = parts.length > 1 && parts[1].trim().isNotEmpty
            ? math.min(int.parse(parts[1].trim()), payload.length - 1)
            : payload.length - 1;

        if (start < 0 || start >= payload.length || end < start) {
          resp.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          resp.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${payload.length}');
          await resp.close();
          return;
        }

        final sliceLen = end - start + 1;
        resp.statusCode = HttpStatus.partialContent;
        resp.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${payload.length}',
        );
        resp.contentLength = sliceLen;
        await _streamRange(resp, start, end);
        return;
      }

      resp.statusCode = HttpStatus.ok;
      if (!unknownContentLength) {
        resp.contentLength = payload.length;
      }
      await _streamRange(resp, 0, payload.length - 1);
    } catch (_) {
      try {
        await resp.close();
      } catch (_) {}
    }
  }

  void _applyCommonHeaders(HttpResponse resp) {
    resp.headers.contentType = ContentType.binary;
    if (supportRanges) {
      resp.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    }
    if (contentDisposition != null) {
      resp.headers.set('content-disposition', contentDisposition!);
    }
  }

  Future<void> _streamRange(HttpResponse resp, int start, int end) async {
    var cursor = start;
    while (cursor <= end) {
      final chunkEnd = math.min(cursor + streamSliceSize, end + 1);
      resp.add(payload.sublist(cursor, chunkEnd));
      await resp.flush();
      cursor = chunkEnd;
      if (chunkDelay > Duration.zero && cursor <= end) {
        await Future<void>.delayed(chunkDelay);
      }
    }
    await resp.close();
  }
}
