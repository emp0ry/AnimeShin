import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Lightweight local HLS proxy:
/// - Rewrites master & media playlists to localhost URLs.
/// - If t=<seconds> is provided, DOES NOT trim — injects EXT-X-START:TIME-OFFSET instead.
/// - Adds UA/Referer to upstream, retries on transient failures.
/// - Streams segments without Range to avoid glide-skips on some CDNs.
/// - Designed to run only on the local device (loopback).
class LocalHlsProxy {
  HttpServer? _server;
  int? _port;
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

  final String userAgent;
  LocalHlsProxy({
    this.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
  });

  Future<void> start() async {
    if (_server != null) return;
    _client = HttpClient()
      ..userAgent = userAgent
      ..connectionTimeout = const Duration(seconds: 10);
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen(_handle, onError: (_) {}, cancelOnError: false);
  }

  Future<void> stop() async {
    final s = _server; _server = null;
    try { await s?.close(force: true); } catch (_) {}
    try { _client?.close(force: true); } catch (_) {}
    _client = null;
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
    final tParam = req.uri.queryParameters['t'];
    final tSeconds = tParam != null ? double.tryParse(tParam) : null;
    final src = Uri.parse(u);

    try {
      final text = await _fetchText(src);
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
      return req.response.close();
    } catch (e) {
      req.response.statusCode = 502;
      req.response.headers.set(HttpHeaders.contentTypeHeader, 'text/plain');
      req.response.write('proxy error: $e');
      return req.response.close();
    }
  }

  Future<void> _handleSegment(HttpRequest req) async {
    final res = req.response;
    try {
      final uRaw = req.uri.queryParameters['u'];
      if (uRaw == null) {
        res.statusCode = HttpStatus.badRequest;
        await res.close();
        return;
      }

      final uri = Uri.parse(uRaw);
      final upstreamReq = await _client!.getUrl(uri);
      _applyUpstreamHeaders(upstreamReq, uri);
      final upstream = await upstreamReq.close();

      try {
        res.statusCode = upstream.statusCode;

        // Content-Type
        final ct = upstream.headers.value(HttpHeaders.contentTypeHeader);
        if (ct != null) {
          res.headers.set(HttpHeaders.contentTypeHeader, ct);
        } else {
          res.headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t');
        }

        final len = upstream.contentLength;
        if (len >= 0) {
          res.contentLength = len;
          // res.headers.set(HttpHeaders.contentLengthHeader, '$len');
        }
      } catch (_) { }

      await upstream.pipe(res);
    } catch (e) {
      try {
        res.statusCode = HttpStatus.badGateway;
        res.headers.contentType = ContentType.text;
        res.write('segment fetch error: $e');
      } catch (_) {}
      try { await res.close(); } catch (_) {}
    } finally {
      try { await req.drain<void>(); } catch (_) {}
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
        line = _rewriteTagUriAttribute(baseUrl, line, isPlaylist: true, tSeconds: tSeconds);
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
      if (!headerDone && isSegmentStart && tSeconds != null && tSeconds > 0 && !sawStartTag && !injectedStart) {
        out.writeln('#EXT-X-START:TIME-OFFSET=${tSeconds.toStringAsFixed(3)},PRECISE=YES');
        injectedStart = true;
      }
      if (isSegmentStart) headerDone = true;

      if (line.startsWith('#')) {
        if (line.startsWith('#EXT-X-KEY') ||
            line.startsWith('#EXT-X-MAP') ||
            line.startsWith('#EXT-X-PRELOAD-HINT') ||
            line.startsWith('#EXT-X-PART')) {
          line = _rewriteTagUriAttribute(baseUrl, line, isPlaylist: false, tSeconds: null);
        } else if (line.startsWith('#EXT-X-RENDITION-REPORT')) {
          // points to another playlist; rewrite as playlist
          line = _rewriteTagUriAttribute(baseUrl, line, isPlaylist: true, tSeconds: tSeconds);
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
      final prox = base.replace(path: '/seg', queryParameters: {'u': resolved.toString()});
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
    return line.replaceAllMapped(RegExp(r'URI="([^"]+)"', caseSensitive: false), (m) {
      final raw = m.group(1)!;
      final resolved = baseUrl.resolve(raw);
      final prox = isPlaylist
          ? playlistUrl(resolved, startSeconds: tSeconds)
          : base.replace(path: '/seg', queryParameters: {'u': resolved.toString()});
      return 'URI="${prox.toString()}"';
    });
  }

  // ---------------------------- Upstream helpers ------------------------------

  Future<String> _fetchText(Uri url) async {
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final req = await _client!.getUrl(url);
        _applyUpstreamHeaders(req, url);
        final resp = await req.close();
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw HttpException('upstream status ${resp.statusCode}', uri: url);
        }
        final body = await resp.transform(utf8.decoder).join();
        return body;
      } catch (_) {
        if (attempt == 3) rethrow;
        await Future.delayed(Duration(milliseconds: 120 * attempt));
      }
    }
    throw StateError('unreachable');
  }

  void _applyUpstreamHeaders(HttpClientRequest r, Uri u) {
    // Conservative Referer to avoid CDN anti-leech filters.
    r.headers.set('Referer', '${u.scheme}://${u.host}/');
    r.headers.set('Cache-Control', 'no-cache');
    r.headers.set('Pragma', 'no-cache');
  }
}

extension<T> on T {
  R let<R>(R Function(T it) f) => f(this);
}
