import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:animeshin/feature/player/player_config.dart';

enum HlsProxyEventType {
  playlistFetch,
  segmentFetch,
  segmentRetry,
  segmentFail,
  segmentOk,
}

class HlsProxyEvent {
  const HlsProxyEvent({
    required this.type,
    required this.timestamp,
    required this.traceId,
    required this.requestId,
    required this.segmentUrlHash,
    required this.retry,
    this.statusCode,
    this.bytesExpected,
    this.bytesReceived,
    this.latencyMs,
    this.errorType,
  });

  final HlsProxyEventType type;
  final DateTime timestamp;
  final String traceId;
  final int requestId;
  final String segmentUrlHash;
  final int? statusCode;
  final int? bytesExpected;
  final int? bytesReceived;
  final int? latencyMs;
  final int retry;
  final String? errorType;
}

/// Lightweight local HLS proxy:
/// - Rewrites master & media playlists to localhost URLs.
/// - If `t=<seconds>` is provided, DOES NOT trim — injects EXT-X-START:TIME-OFFSET instead.
/// - Adds UA/Referer to upstream, retries on transient failures.
/// - Retries segment fetches with bounded backoff and timeout guards.
/// - Designed to run only on the local device (loopback).
class LocalHlsProxy {
  HttpServer? _server;
  int? _port;
  int _nextRequestId = 1;
  bool get isRunning => _server != null;
  Uri get base {
    final p = _port;
    if (p == null) {
      // Guard to avoid LateInitializationError if called too early.
      throw StateError('LocalHlsProxy is not started yet.');
    }
    return Uri.parse('http://127.0.0.1:$p/');
  }

  // Reuse a single client to keep cookies & connections alive.
  HttpClient? _client;

  // mpv/media_kit may send custom httpHeaders only on the initial playlist open.
  // Subsequent segment requests to localhost can omit them. Cache the last seen
  // forward-headers from /m3u8 and reuse for /seg when missing.
  Map<String, String>? _lastForwardHeaders;

  final String userAgent;
  final Duration segmentTimeout;
  final int segmentMaxRetries;
  final int retryBackoffBaseMs;
  final bool shortReadRetryEnabled;
  final bool upstreamPersistentConnections;
  final void Function(HlsProxyEvent event)? onEvent;
  String? traceId;

  LocalHlsProxy({
    this.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
    this.segmentTimeout = PlayerTuning.hlsSegmentTimeout,
    this.segmentMaxRetries = PlayerTuning.hlsSegmentMaxRetries,
    this.retryBackoffBaseMs = PlayerTuning.hlsRetryBackoffBaseMs,
    this.shortReadRetryEnabled = PlayerTuning.hlsShortReadRetryEnabled,
    this.upstreamPersistentConnections =
        PlayerTuning.hlsUpstreamPersistentConnections,
    this.onEvent,
    this.traceId,
  });

  Future<void> start() async {
    if (_server != null) return;
    _client ??= _createClient();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen(_handle, onError: (_) {}, cancelOnError: false);
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    try {
      await s?.close(force: true);
    } catch (_) {}
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }

  HttpClient _createClient() {
    return HttpClient()
      ..userAgent = userAgent
      ..connectionTimeout = const Duration(seconds: 10);
  }

  HttpClient _requireClient() {
    _client ??= _createClient();
    return _client!;
  }

  void _resetClient() {
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = _createClient();
  }

  /// Parse an HLS master playlist and suggest an mpv `hls-bitrate` cap.
  ///
  /// mpv picks the highest `BANDWIDTH` that is <= cap. To force a specific
  /// variant, we return a cap that is:
  /// - >= selected variant BANDWIDTH
  /// - < next higher variant BANDWIDTH (when possible)
  ///
  /// Returns null if the playlist doesn't look like a master or no suitable
  /// BANDWIDTH values are found.
  Future<int?> suggestHlsBitrateCap(
    Uri masterUrl, {
    required int targetHeight,
    Map<String, String>? headers,
  }) async {
    // Ensure HttpClient exists even if the proxy server isn't started yet.
    _requireClient();

    final text = await _fetchText(masterUrl, headers: headers);
    if (!text.contains('#EXTM3U') || !text.contains('#EXT-X-STREAM-INF')) {
      return null;
    }

    final lines = const LineSplitter().convert(text);
    final variants = <_HlsVariant>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;

      final bw = _parseIntAttr(line, 'BANDWIDTH');
      if (bw == null || bw <= 0) continue;

      final res = _parseStringAttr(line, 'RESOLUTION');
      final height = _heightFromResolution(res);
      if (height == null || height <= 0) continue;

      variants.add(_HlsVariant(height: height, bandwidth: bw));
    }

    if (variants.isEmpty) return null;

    // Prefer the highest height <= targetHeight. If none, fall back to the
    // lowest available ("best effort" downscale).
    variants.sort((a, b) {
      final byHeight = a.height.compareTo(b.height);
      if (byHeight != 0) return byHeight;
      return a.bandwidth.compareTo(b.bandwidth);
    });

    _HlsVariant selected = variants.first;
    for (final v in variants) {
      if (v.height <= targetHeight) selected = v;
    }

    // Find the next higher bandwidth (not height) so we can cap below it.
    final bws = variants.map((v) => v.bandwidth).toSet().toList()..sort();
    int? nextHigherBw;
    for (final bw in bws) {
      if (bw > selected.bandwidth) {
        nextHigherBw = bw;
        break;
      }
    }

    if (nextHigherBw != null && nextHigherBw > selected.bandwidth) {
      // Cap just below the next higher stream.
      return nextHigherBw - 1;
    }

    // If we can't separate (or selected is highest), return its bandwidth.
    return selected.bandwidth;
  }

  static int? _parseIntAttr(String line, String key) {
    final m = RegExp('$key=(\\d+)', caseSensitive: false).firstMatch(line);
    if (m == null) return null;
    return int.tryParse(m.group(1) ?? '');
  }

  static String? _parseStringAttr(String line, String key) {
    final m = RegExp('$key=([^,\\r\\n]+)', caseSensitive: false)
        .firstMatch(line);
    return m?.group(1)?.trim();
  }

  static int? _heightFromResolution(String? resolution) {
    if (resolution == null) return null;
    final m = RegExp(r'(\\d+)x(\\d+)', caseSensitive: false)
        .firstMatch(resolution);
    if (m == null) return null;
    return int.tryParse(m.group(2) ?? '');
  }

  /// Build proxied URL for a given remote m3u8.
  /// If [startSeconds] is provided, the generated playlist will include EXT-X-START.
  Uri playlistUrl(Uri remote, {double? startSeconds}) {
    if (!isRunning) {
      throw StateError('LocalHlsProxy.playlistUrl called before start().');
    }
    final qp = <String, String>{'u': remote.toString()};
    if (startSeconds != null && startSeconds > 0) {
      qp['t'] = startSeconds.toStringAsFixed(3);
    }
    return base.replace(path: '/m3u8', queryParameters: qp);
  }

  // ---------------------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (path == '/m3u8') {
      return _handlePlaylist(req);
    }
    if (path == '/seg') {
      return _handleSegment(req);
    }
    if (path == '/ping') {
      req.response
        ..statusCode = 200
        ..headers.set(HttpHeaders.contentTypeHeader, 'text/plain')
        ..write('ok');
      return req.response.close();
    }
    req.response.statusCode = 404;
    return req.response.close();
  }

  Future<void> _handlePlaylist(HttpRequest req) async {
    final u = req.uri.queryParameters['u'];
    if (u == null) {
      req.response.statusCode = 400;
      return req.response.close();
    }
    final requestId = _nextRequestId++;
    final tParam = req.uri.queryParameters['t'];
    final tSeconds = tParam != null ? double.tryParse(tParam) : null;
    final src = Uri.parse(u);

    final forward = _extractForwardHeaders(req);
    if (forward.isNotEmpty) {
      _cacheForwardHeaders(forward);
    }

    final sw = Stopwatch()..start();
    try {
      final fetched = await _fetchTextResult(
        src,
        headers: forward.isNotEmpty ? forward : _lastForwardHeaders,
      );
      final text = fetched.body;
      final isMaster = text.contains('#EXT-X-STREAM-INF');

      String body;
      if (isMaster) {
        body = _rewriteMaster(src, text, tSeconds);
      } else {
        body = _rewriteMedia(src, text, tSeconds);
      }

      req.response.headers
          .set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
      req.response.write(body);
      _emitEvent(
        HlsProxyEventType.playlistFetch,
        requestId: requestId,
        uri: src,
        statusCode: fetched.statusCode,
        bytesReceived: utf8.encode(body).length,
        latencyMs: sw.elapsedMilliseconds,
        retry: 0,
      );
      return req.response.close();
    } catch (e) {
      req.response.statusCode = 502;
      req.response.headers.set(HttpHeaders.contentTypeHeader, 'text/plain');
      req.response.write('proxy error: $e');
      _emitEvent(
        HlsProxyEventType.playlistFetch,
        requestId: requestId,
        uri: src,
        statusCode: (e is _UpstreamHttpStatusException) ? e.statusCode : 502,
        latencyMs: sw.elapsedMilliseconds,
        retry: 0,
        errorType: _errorTypeOf(e),
      );
      return req.response.close();
    }
  }

  Future<void> _handleSegment(HttpRequest req) async {
    final res = req.response;
    final requestId = _nextRequestId++;
    Uri? targetUri;
    try {
      final uRaw = req.uri.queryParameters['u'];
      if (uRaw == null) {
        res.statusCode = HttpStatus.badRequest;
        await res.close();
        return;
      }

      final uri = Uri.parse(uRaw);
      targetUri = uri;
      final forward = _extractForwardHeaders(req);
      if (forward.isNotEmpty) {
        _cacheForwardHeaders(forward);
      }
      final headers = <String, String>{
        ...?_lastForwardHeaders,
        ...forward,
      };

      final attempts = (segmentMaxRetries < 0 ? 0 : segmentMaxRetries) + 1;
      for (int attempt = 1; attempt <= attempts; attempt++) {
        final retry = attempt - 1;
        final sw = Stopwatch()..start();
        _emitEvent(
          HlsProxyEventType.segmentFetch,
          requestId: requestId,
          uri: uri,
          retry: retry,
        );

        try {
          final upstreamReq =
              await _requireClient().getUrl(uri).timeout(segmentTimeout);
          upstreamReq.persistentConnection = upstreamPersistentConnections;
          if (!upstreamPersistentConnections) {
            upstreamReq.headers.set(HttpHeaders.connectionHeader, 'close');
          }
          _applyUpstreamHeaders(
            upstreamReq,
            uri,
            headers: headers.isEmpty ? null : headers,
          );
          final upstream = await upstreamReq.close().timeout(segmentTimeout);
          final payload =
              await _readAllBytes(upstream).timeout(segmentTimeout);

          final expected = payload.expectedLength;
          final received = payload.bytes.length;
          final status = upstream.statusCode;

          if (expected != null &&
              expected >= 0 &&
              expected != received) {
            throw _ShortReadException(
              statusCode: status,
              expectedBytes: expected,
              receivedBytes: received,
            );
          }

          if (_isRetriableStatus(status) && attempt < attempts) {
            _emitEvent(
              HlsProxyEventType.segmentRetry,
              requestId: requestId,
              uri: uri,
              statusCode: status,
              bytesExpected: expected,
              bytesReceived: received,
              latencyMs: sw.elapsedMilliseconds,
              retry: retry,
              errorType: 'http_$status',
            );
            await _beforeRetry(attempt);
            continue;
          }

          res.statusCode = status;
          _copyResponseHeaders(upstream.headers, res.headers);
          res.contentLength = received;
          if (received > 0) {
            res.add(payload.bytes);
          }
          await res.close();

          final isSuccess = status >= 200 && status < 300;
          _emitEvent(
            isSuccess ? HlsProxyEventType.segmentOk : HlsProxyEventType.segmentFail,
            requestId: requestId,
            uri: uri,
            statusCode: status,
            bytesExpected: expected,
            bytesReceived: received,
            latencyMs: sw.elapsedMilliseconds,
            retry: retry,
            errorType: isSuccess ? null : 'http_$status',
          );
          return;
        } catch (e) {
          final errorType = _errorTypeOf(e);
          final canRetryShortRead = e is! _ShortReadException || shortReadRetryEnabled;
          final retriable =
              _isRetriableError(e) && canRetryShortRead && attempt < attempts;

          if (retriable) {
            _emitEvent(
              HlsProxyEventType.segmentRetry,
              requestId: requestId,
              uri: uri,
              statusCode: (e is _ShortReadException) ? e.statusCode : null,
              bytesExpected: (e is _ShortReadException) ? e.expectedBytes : null,
              bytesReceived: (e is _ShortReadException) ? e.receivedBytes : null,
              latencyMs: sw.elapsedMilliseconds,
              retry: retry,
              errorType: errorType,
            );
            await _beforeRetry(attempt);
            continue;
          }

          res.statusCode = HttpStatus.badGateway;
          res.headers.contentType = ContentType.text;
          res.write('segment fetch error: $errorType');
          await res.close();
          _emitEvent(
            HlsProxyEventType.segmentFail,
            requestId: requestId,
            uri: uri,
            statusCode: (e is _ShortReadException) ? e.statusCode : HttpStatus.badGateway,
            bytesExpected: (e is _ShortReadException) ? e.expectedBytes : null,
            bytesReceived: (e is _ShortReadException) ? e.receivedBytes : null,
            latencyMs: sw.elapsedMilliseconds,
            retry: retry,
            errorType: errorType,
          );
          return;
        }
      }
    } catch (e) {
      try {
        res.statusCode = HttpStatus.badGateway;
        res.headers.contentType = ContentType.text;
        res.write('segment fetch error: $e');
      } catch (_) {}
      try {
        await res.close();
      } catch (_) {}
      if (targetUri != null) {
        _emitEvent(
          HlsProxyEventType.segmentFail,
          requestId: requestId,
          uri: targetUri,
          statusCode: HttpStatus.badGateway,
          retry: 0,
          errorType: _errorTypeOf(e),
        );
      }
    } finally {
      try {
        await req.drain<void>();
      } catch (_) {}
    }
  }

  // --------------------------- M3U8 rewriting ---------------------------------

  String _rewriteMaster(Uri baseUrl, String text, double? tSeconds) {
    final lines = const LineSplitter().convert(text);
    final out = StringBuffer();

    for (int i = 0; i < lines.length; i++) {
      var line = lines[i].trimRight();

      if (line.startsWith('#EXT-X-MEDIA') ||
          line.startsWith('#EXT-X-I-FRAME-STREAM-INF') ||
          line.startsWith('#EXT-X-SESSION-DATA') ||
          line.startsWith('#EXT-X-SESSION-KEY') ||
          line.startsWith('#EXT-X-IMAGE-STREAM-INF')) {
        // Rewrite URI="..." inside attribute-based tags (audio/subs/iframes).
        line = _rewriteTagUriAttribute(baseUrl, line,
            isPlaylist: true, tSeconds: tSeconds);
        out.writeln(line);
        continue;
      }

      if (line.startsWith('#EXT-X-STREAM-INF')) {
        // Next line is a variant playlist URI; rewrite it.
        out.writeln(line);
        if (i + 1 < lines.length) {
          final next = lines[++i].trimRight();
          if (next.isEmpty || next.startsWith('#')) {
            out.writeln(next);
          } else {
            final resolved = baseUrl.resolve(next);
            final proxied = playlistUrl(resolved, startSeconds: tSeconds);
            out.writeln(proxied.toString());
          }
        }
        continue;
      }

      if (line.isEmpty || line.startsWith('#')) {
        out.writeln(line);
      } else {
        // Some masters simply list URIs.
        final resolved = baseUrl.resolve(line);
        final proxied = playlistUrl(resolved, startSeconds: tSeconds);
        out.writeln(proxied.toString());
      }
    }

    return out.toString();
  }

  String _rewriteMedia(Uri baseUrl, String text, double? tSeconds) {
    final lines = const LineSplitter().convert(text);
    final out = StringBuffer();

    bool sawStartTag = false;
    bool injectedStart = false;
    bool headerDone = false;

    for (int i = 0; i < lines.length; i++) {
      var line = lines[i].trimRight();

      // Track if original has EXT-X-START
      if (line.startsWith('#EXT-X-START')) {
        sawStartTag = true;
      }

      // Detect the moment we hit the first segment area.
      final isSegmentStart = line.startsWith('#EXTINF') ||
          line.startsWith('#EXT-X-PART') ||
          (!line.startsWith('#') && line.isNotEmpty);

      // Inject EXT-X-START right before the first segment/part if requested & absent.
      if (!headerDone &&
          isSegmentStart &&
          tSeconds != null &&
          tSeconds > 0 &&
          !sawStartTag &&
          !injectedStart) {
        out.writeln(
            '#EXT-X-START:TIME-OFFSET=${tSeconds.toStringAsFixed(3)},PRECISE=YES');
        injectedStart = true;
      }
      if (isSegmentStart) headerDone = true;

      if (line.startsWith('#')) {
        if (line.startsWith('#EXT-X-KEY') ||
            line.startsWith('#EXT-X-MAP') ||
            line.startsWith('#EXT-X-PRELOAD-HINT') ||
            line.startsWith('#EXT-X-PART')) {
          line = _rewriteTagUriAttribute(baseUrl, line,
              isPlaylist: false, tSeconds: null);
        } else if (line.startsWith('#EXT-X-RENDITION-REPORT')) {
          // points to another playlist; rewrite as playlist
          line = _rewriteTagUriAttribute(baseUrl, line,
              isPlaylist: true, tSeconds: tSeconds);
        }
        out.writeln(line);
        continue;
      }

      if (line.isEmpty) {
        out.writeln();
        continue;
      }

      // Plain segment URI line -> proxy to /seg
      final resolved = baseUrl.resolve(line);
      final prox = base
          .replace(path: '/seg', queryParameters: {'u': resolved.toString()});
      out.writeln(prox.toString());
    }

    // NOTE: Do NOT forcibly add #EXT-X-ENDLIST here.
    return out.toString();
  }

  String _rewriteTagUriAttribute(
    Uri baseUrl,
    String line, {
    required bool isPlaylist,
    double? tSeconds,
  }) {
    // Replace URI="..." preserving all other attributes.
    return line.replaceAllMapped(RegExp(r'URI="([^"]+)"', caseSensitive: false),
        (m) {
      final raw = m.group(1)!;
      final resolved = baseUrl.resolve(raw);
      final prox = isPlaylist
          ? playlistUrl(resolved, startSeconds: tSeconds)
          : base.replace(
              path: '/seg', queryParameters: {'u': resolved.toString()});
      return 'URI="${prox.toString()}"';
    });
  }

  // ---------------------------- Upstream helpers ------------------------------

  Future<String> _fetchText(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    final result = await _fetchTextResult(url, headers: headers);
    return result.body;
  }

  Future<_TextFetchResult> _fetchTextResult(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final req = await _requireClient().getUrl(url);
        _applyUpstreamHeaders(req, url, headers: headers);
        final resp = await req.close();
        final status = resp.statusCode;
        final body = await resp.transform(utf8.decoder).join();
        if (status < 200 || status >= 300) {
          throw _UpstreamHttpStatusException(statusCode: status, uri: url);
        }
        return _TextFetchResult(body: body, statusCode: status);
      } catch (_) {
        if (attempt == 3) rethrow;
        await Future.delayed(Duration(milliseconds: 120 * attempt));
      }
    }
    throw StateError('unreachable');
  }

  Future<_SegmentPayload> _readAllBytes(HttpClientResponse upstream) async {
    final expected =
        upstream.contentLength >= 0 ? upstream.contentLength : null;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in upstream) {
      bytes.add(chunk);
    }
    return _SegmentPayload(
      bytes: bytes.takeBytes(),
      expectedLength: expected,
    );
  }

  bool _isRetriableStatus(int statusCode) {
    return statusCode == HttpStatus.requestTimeout ||
        statusCode == HttpStatus.tooManyRequests ||
        (statusCode >= 500 && statusCode < 600);
  }

  bool _isRetriableError(Object error) {
    if (error is TimeoutException) return true;
    if (error is SocketException) return true;
    if (error is HttpException) return true;
    if (error is _ShortReadException) return true;
    return false;
  }

  Future<void> _beforeRetry(int attempt) async {
    final backoff = Duration(
      milliseconds: retryBackoffBaseMs * attempt,
    );
    _resetClient();
    if (backoff > Duration.zero) {
      await Future.delayed(backoff);
    }
  }

  void _cacheForwardHeaders(Map<String, String> headers) {
    final sanitized = <String, String>{};
    headers.forEach((k, v) {
      final lk = k.toLowerCase();
      if (lk == 'range' || lk == 'if-range') return;
      sanitized[k] = v;
    });
    if (sanitized.isEmpty) return;
    _lastForwardHeaders = {
      ...?_lastForwardHeaders,
      ...sanitized,
    };
  }

  static Map<String, String> _extractForwardHeaders(HttpRequest req) {
    // Forward only a safe/necessary subset of headers.
    // Many HLS providers require Referer/Origin; some use cookies.
    const allow = <String>{
      'referer',
      'origin',
      'user-agent',
      'accept',
      'accept-language',
      'cookie',
      'authorization',
      'range',
      'if-range',
    };

    final out = <String, String>{};
    for (final name in allow) {
      final v = req.headers.value(name);
      if (v == null) continue;
      final t = v.trim();
      if (t.isEmpty) continue;
      // Normalize canonical casing.
      final key = switch (name) {
        'referer' => 'Referer',
        'origin' => 'Origin',
        'user-agent' => 'User-Agent',
        'accept' => 'Accept',
        'accept-language' => 'Accept-Language',
        'cookie' => 'Cookie',
        'authorization' => 'Authorization',
        'range' => 'Range',
        'if-range' => 'If-Range',
        _ => name,
      };
      out[key] = t;
    }
    return out;
  }

  void _applyUpstreamHeaders(
    HttpClientRequest r,
    Uri u, {
    required Map<String, String>? headers,
  }) {
    // Always avoid caching.
    r.headers.set('Cache-Control', 'no-cache');
    r.headers.set('Pragma', 'no-cache');

    // Forward provided headers first.
    headers?.forEach((k, v) {
      if (v.trim().isEmpty) return;
      // Skip headers that HttpClient manages or that can break proxying.
      final lk = k.toLowerCase();
      if (lk == 'host' || lk == 'connection' || lk == 'content-length') return;
      r.headers.set(k, v);
    });

    // If caller did not specify Referer, fall back to conservative host referer.
    if (r.headers.value('Referer') == null) {
      r.headers.set('Referer', '${u.scheme}://${u.host}/');
    }
  }

  void _copyResponseHeaders(HttpHeaders from, HttpHeaders to) {
    const blocked = <String>{
      'connection',
      'transfer-encoding',
      'content-length',
      'keep-alive',
      'proxy-connection',
      'trailer',
      'upgrade',
    };

    from.forEach((name, values) {
      final lower = name.toLowerCase();
      if (blocked.contains(lower)) return;
      for (final value in values) {
        to.add(name, value);
      }
    });

    if (to.value(HttpHeaders.contentTypeHeader) == null) {
      to.set(HttpHeaders.contentTypeHeader, 'video/mp2t');
    }
  }

  void _emitEvent(
    HlsProxyEventType type, {
    required int requestId,
    required Uri uri,
    required int retry,
    int? statusCode,
    int? bytesExpected,
    int? bytesReceived,
    int? latencyMs,
    String? errorType,
  }) {
    final callback = onEvent;
    if (callback == null) return;
    callback(
      HlsProxyEvent(
        type: type,
        timestamp: DateTime.now(),
        traceId: traceId ?? 'no-trace',
        requestId: requestId,
        segmentUrlHash: _hashUri(uri),
        retry: retry,
        statusCode: statusCode,
        bytesExpected: bytesExpected,
        bytesReceived: bytesReceived,
        latencyMs: latencyMs,
        errorType: errorType,
      ),
    );
  }

  static String _errorTypeOf(Object error) {
    if (error is TimeoutException) return 'timeout';
    if (error is SocketException) return 'socket';
    if (error is HttpException) return 'http_exception';
    if (error is _ShortReadException) return 'short_read';
    if (error is _UpstreamHttpStatusException) return 'upstream_http_status';
    return error.runtimeType.toString();
  }

  static String _hashUri(Uri uri) {
    // FNV-1a 32-bit; deterministic & cheap for log correlation.
    const fnvPrime = 0x01000193;
    int hash = 0x811C9DC5;
    final s = uri.toString();
    for (final codeUnit in s.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * fnvPrime) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}

class _HlsVariant {
  final int height;
  final int bandwidth;
  const _HlsVariant({required this.height, required this.bandwidth});
}

class _TextFetchResult {
  const _TextFetchResult({
    required this.body,
    required this.statusCode,
  });

  final String body;
  final int statusCode;
}

class _SegmentPayload {
  const _SegmentPayload({
    required this.bytes,
    required this.expectedLength,
  });

  final List<int> bytes;
  final int? expectedLength;
}

class _UpstreamHttpStatusException implements Exception {
  const _UpstreamHttpStatusException({
    required this.statusCode,
    required this.uri,
  });

  final int statusCode;
  final Uri uri;

  @override
  String toString() => 'Upstream HTTP status $statusCode for $uri';
}

class _ShortReadException implements Exception {
  const _ShortReadException({
    required this.statusCode,
    required this.expectedBytes,
    required this.receivedBytes,
  });

  final int? statusCode;
  final int expectedBytes;
  final int receivedBytes;

  @override
  String toString() {
    return 'Short read: expected=$expectedBytes received=$receivedBytes '
        '(status=${statusCode ?? "unknown"})';
  }
}
