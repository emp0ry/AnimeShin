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

  final String userAgent;
  LocalHlsProxy({
    this.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
  });

  /// Start a loopback HTTP server on any free port.
  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen(
      _handle,
      onError: (_) {},           // swallow per-connection errors
      cancelOnError: false,      // do NOT stop the whole server on one bad client
    );
  }

  /// Stop the loopback server.
  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
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
      final client = HttpClient()..userAgent = userAgent;
      client.connectionTimeout = const Duration(seconds: 10);

      final upstreamReq = await client.getUrl(uri);
      _applyUpstreamHeaders(upstreamReq, uri);
      final upstream = await upstreamReq.close();

      try {
        res.statusCode = upstream.statusCode;
        final ct = upstream.headers.value(HttpHeaders.contentTypeHeader);
        if (ct != null) {
          res.headers.set(HttpHeaders.contentTypeHeader, ct);
        } else {
          res.headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t');
        }
      } catch (_) {
        // ignore - means the headers have already been sent
      }

      await upstream.pipe(res);
    } catch (e) {
      try {
        res.statusCode = HttpStatus.badGateway;
        res.headers.contentType = ContentType.text;
        res.write('segment fetch error: $e');
      } catch (_) {
        // if the headers have already been sent, do nothing
      }
      try { await res.close(); } catch (_) {}
    } finally {
      try { await req.drain<void>(); } catch (_) {}
    }
  }

  // --------------------------- M3U8 rewriting ---------------------------------

  String _rewriteMaster(Uri baseUrl, String text, double? tSeconds) {
    final lines = const LineSplitter().convert(text);
    final out = StringBuffer();
    out.writeln('#EXTM3U');
    // Preserve all tag lines, rewrite only URIs.
    for (int i = 1; i < lines.length; i++) {
      final line = lines[i].trimRight();
      if (line.isEmpty) {
        out.writeln();
        continue;
      }
      if (line.startsWith('#')) {
        out.writeln(line);
        continue;
      }
      // Variant URI line (relative or absolute).
      final resolved = baseUrl.resolve(line);
      final proxied = playlistUrl(resolved, startSeconds: tSeconds);
      out.writeln(proxied.toString());
    }
    return out.toString();
  }

  /// For media playlists:
  /// - We DO NOT trim by time anymore.
  /// - If tSeconds is provided, inject `#EXT-X-START:TIME-OFFSET=tSeconds,PRECISE=YES`.
  /// - All segment URIs are rewritten to /seg.
  String _rewriteMedia(Uri baseUrl, String text, double? tSeconds) {
    final lines = const LineSplitter().convert(text);
    final out = StringBuffer();
    final passthroughTags = <String>[];

    // Collect & pass through non-URI tag lines as-is (excluding any existing EXT-X-START).
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (!line.startsWith('#EXT-X-START')) {
          passthroughTags.add(line);
        }
      }
    }

    out.writeln('#EXTM3U');
    // Inject EXT-X-START if requested.
    if (tSeconds != null && tSeconds > 0) {
      out.writeln(
          '#EXT-X-START:TIME-OFFSET=${tSeconds.toStringAsFixed(3)},PRECISE=YES');
    }
    // Emit other tags.
    for (final tag in passthroughTags) {
      if (tag == '#EXTM3U') continue;
      out.writeln(tag);
    }

    // Walk again to rewrite only URI lines & keep #EXTINF lines before them.
    // ignore: unused_local_variable
    double? currentDur;
    for (int i = 0; i < lines.length; i++) {
      final raw = lines[i].trimRight();
      if (raw.isEmpty) continue;

      if (raw.startsWith('#EXTINF')) {
        currentDur = RegExp(r'#EXTINF:([\d\.]+)')
            .firstMatch(raw)
            ?.group(1)
            ?.let((s) => double.tryParse(s));
        out.writeln(raw); // keep original EXTINF
        continue;
      }
      if (raw.startsWith('#')) {
        // Other tags already emitted above.
        continue;
      }

      // URI line -> rewrite.
      final resolved = baseUrl.resolve(raw);
      final prox =
          base.replace(path: '/seg', queryParameters: {'u': resolved.toString()});
      out.writeln(prox.toString());

      // Reset duration capture (not strictly required).
      currentDur = null;
    }

    // If source was VOD it likely had ENDLIST; make sure it stays present.
    if (!lines.any((l) => l.startsWith('#EXT-X-ENDLIST'))) {
      out.writeln('#EXT-X-ENDLIST');
    }
    return out.toString();
  }

  // ---------------------------- Upstream helpers ------------------------------

  Future<String> _fetchText(Uri url) async {
    final client = HttpClient()..userAgent = userAgent;
    client.connectionTimeout = const Duration(seconds: 10);
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final req = await client.getUrl(url);
        _applyUpstreamHeaders(req, url);
        final resp = await req.close();
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
