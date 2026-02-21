import 'dart:convert';
import 'dart:io';

import 'package:animeshin/feature/player/local_hls_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalHlsProxy segment transport', () {
    test('retries a segment on timeout and eventually succeeds', () async {
      final events = <HlsProxyEvent>[];
      final proxy = LocalHlsProxy(
        traceId: 'test-timeout',
        onEvent: events.add,
        segmentTimeout: const Duration(milliseconds: 80),
        segmentMaxRetries: 2,
        retryBackoffBaseMs: 5,
      );
      await proxy.start();
      addTearDown(() async => proxy.stop());

      int hits = 0;
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => upstream.close(force: true));
      upstream.listen((req) async {
        hits++;
        if (hits == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          req.response
            ..statusCode = HttpStatus.ok
            ..add(const <int>[1, 2, 3]);
          await req.response.close();
          return;
        }
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t')
          ..add(const <int>[9, 8, 7, 6]);
        await req.response.close();
      });

      final upstreamUrl =
          Uri.parse('http://127.0.0.1:${upstream.port}/segment-timeout.ts');
      final proxyUrl = proxy.base.replace(
        path: '/seg',
        queryParameters: {'u': upstreamUrl.toString()},
      );

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final req = await client.getUrl(proxyUrl);
      final resp = await req.close();
      final body = await _readBytes(resp);

      expect(resp.statusCode, HttpStatus.ok);
      expect(body, const <int>[9, 8, 7, 6]);
      expect(hits, 2);
      expect(
        events.any(
          (e) =>
              e.type == HlsProxyEventType.segmentRetry &&
              (e.errorType == 'timeout' || e.errorType == 'socket'),
        ),
        isTrue,
      );
    });

    test('retries a segment when upstream sends truncated response', () async {
      final events = <HlsProxyEvent>[];
      final proxy = LocalHlsProxy(
        traceId: 'test-short-read',
        onEvent: events.add,
        segmentTimeout: const Duration(seconds: 2),
        segmentMaxRetries: 2,
        retryBackoffBaseMs: 5,
      );
      await proxy.start();
      addTearDown(() async => proxy.stop());

      final rawServer =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => rawServer.close());

      int hits = 0;
      rawServer.listen((socket) async {
        hits++;
        try {
          await socket.first;
        } catch (_) {}

        if (hits == 1) {
          socket.add(
            utf8.encode(
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: video/mp2t\r\n'
              'Content-Length: 10\r\n'
              'Connection: close\r\n'
              '\r\n'
              '12345',
            ),
          );
        } else {
          socket.add(
            utf8.encode(
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: video/mp2t\r\n'
              'Content-Length: 6\r\n'
              'Connection: close\r\n'
              '\r\n'
              'ABCDEF',
            ),
          );
        }
        await socket.flush();
        await socket.close();
      });

      final upstreamUrl =
          Uri.parse('http://127.0.0.1:${rawServer.port}/truncated.ts');
      final proxyUrl = proxy.base.replace(
        path: '/seg',
        queryParameters: {'u': upstreamUrl.toString()},
      );

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final req = await client.getUrl(proxyUrl);
      final resp = await req.close();
      final body = await _readBytes(resp);

      expect(resp.statusCode, HttpStatus.ok);
      expect(body, utf8.encode('ABCDEF'));
      expect(hits, 2);
      expect(
        events.any(
          (e) =>
              e.type == HlsProxyEventType.segmentRetry &&
              (e.errorType == 'short_read' || e.errorType == 'http_exception'),
        ),
        isTrue,
      );
    });

    test('forwards Range headers and preserves HTTP 206 response', () async {
      final proxy = LocalHlsProxy(
        traceId: 'test-range',
        segmentMaxRetries: 0,
      );
      await proxy.start();
      addTearDown(() async => proxy.stop());

      String? capturedRange;
      String? capturedIfRange;
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => upstream.close(force: true));
      upstream.listen((req) async {
        capturedRange = req.headers.value(HttpHeaders.rangeHeader);
        capturedIfRange = req.headers.value('If-Range');
        req.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t')
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 2-5/10')
          ..add(const <int>[2, 3, 4, 5]);
        await req.response.close();
      });

      final upstreamUrl =
          Uri.parse('http://127.0.0.1:${upstream.port}/range.ts');
      final proxyUrl = proxy.base.replace(
        path: '/seg',
        queryParameters: {'u': upstreamUrl.toString()},
      );

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final req = await client.getUrl(proxyUrl);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=2-5');
      req.headers.set('If-Range', '"etag-1"');
      final resp = await req.close();
      final body = await _readBytes(resp);

      expect(capturedRange, 'bytes=2-5');
      expect(capturedIfRange, '"etag-1"');
      expect(resp.statusCode, HttpStatus.partialContent);
      expect(resp.headers.value(HttpHeaders.contentRangeHeader), 'bytes 2-5/10');
      expect(body, const <int>[2, 3, 4, 5]);
    });

    test('uses non-persistent upstream segment connections by default', () async {
      final proxy = LocalHlsProxy(
        traceId: 'test-upstream-close',
        segmentMaxRetries: 0,
      );
      await proxy.start();
      addTearDown(() async => proxy.stop());

      String? capturedConnection;
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => upstream.close(force: true));
      upstream.listen((req) async {
        capturedConnection = req.headers.value(HttpHeaders.connectionHeader);
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t')
          ..add(const <int>[1, 2, 3]);
        await req.response.close();
      });

      final upstreamUrl = Uri.parse('http://127.0.0.1:${upstream.port}/close.ts');
      final proxyUrl = proxy.base.replace(
        path: '/seg',
        queryParameters: {'u': upstreamUrl.toString()},
      );

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final req = await client.getUrl(proxyUrl);
      final resp = await req.close();
      await _readBytes(resp);

      expect(resp.statusCode, HttpStatus.ok);
      expect(capturedConnection?.toLowerCase(), 'close');
    });
  });

  group('LocalHlsProxy playlist rewrite', () {
    test('rewrites master and media playlists to local proxy paths', () async {
      final proxy = LocalHlsProxy(traceId: 'test-rewrite');
      await proxy.start();
      addTearDown(() async => proxy.stop());

      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => upstream.close(force: true));
      upstream.listen((req) async {
        if (req.uri.path == '/master.m3u8') {
          req.response
            ..statusCode = HttpStatus.ok
            ..headers.set(
              HttpHeaders.contentTypeHeader,
              'application/vnd.apple.mpegurl',
            )
            ..write(
              '#EXTM3U\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=640x360\n'
              'media/low.m3u8\n',
            );
          await req.response.close();
          return;
        }
        if (req.uri.path == '/media/low.m3u8') {
          req.response
            ..statusCode = HttpStatus.ok
            ..headers.set(
              HttpHeaders.contentTypeHeader,
              'application/vnd.apple.mpegurl',
            )
            ..write(
              '#EXTM3U\n'
              '#EXT-X-TARGETDURATION:6\n'
              '#EXTINF:6.0,\n'
              'seg-1.ts\n'
              '#EXTINF:6.0,\n'
              'seg-2.ts\n',
            );
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final masterUpstream =
          Uri.parse('http://127.0.0.1:${upstream.port}/master.m3u8');
      final masterProxy = proxy.base.replace(
        path: '/m3u8',
        queryParameters: {'u': masterUpstream.toString()},
      );

      final masterResp = await (await client.getUrl(masterProxy)).close();
      final masterBody = utf8.decode(await _readBytes(masterResp));
      expect(masterResp.statusCode, HttpStatus.ok);
      expect(masterBody, contains('/m3u8?u='));

      final mediaUpstream =
          Uri.parse('http://127.0.0.1:${upstream.port}/media/low.m3u8');
      final mediaProxy = proxy.base.replace(
        path: '/m3u8',
        queryParameters: {'u': mediaUpstream.toString()},
      );

      final mediaResp = await (await client.getUrl(mediaProxy)).close();
      final mediaBody = utf8.decode(await _readBytes(mediaResp));
      expect(mediaResp.statusCode, HttpStatus.ok);
      expect(mediaBody, contains('/seg?u='));
    });
  });
}

Future<List<int>> _readBytes(HttpClientResponse response) async {
  final out = <int>[];
  await for (final chunk in response) {
    out.addAll(chunk);
  }
  return out;
}
