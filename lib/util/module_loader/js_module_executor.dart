import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:animeshin/util/module_loader/js_sources_runtime.dart';
import 'package:animeshin/util/module_loader/module_search_utils.dart';
import 'package:animeshin/util/module_loader/sources_module.dart';
import 'package:animeshin/util/module_loader/sources_module_loader.dart';

class JsModuleTile {
  const JsModuleTile({
    required this.title,
    required this.image,
    required this.href,
  });

  final String title;
  final String image;
  final String href;
}

class JsModuleEpisode {
  const JsModuleEpisode({
    required this.number,
    required this.title,
    required this.image,
    required this.href,
    this.durationSeconds,
    this.openingStart,
    this.openingEnd,
    this.endingStart,
    this.endingEnd,
  });

  final int number;
  final String title;
  final String image;
  final String href;

  final int? durationSeconds;
  final int? openingStart;
  final int? openingEnd;
  final int? endingStart;
  final int? endingEnd;
}

class JsStreamCandidate {
  const JsStreamCandidate({
    required this.title,
    required this.streamUrl,
    this.url480,
    this.url720,
    this.url1080,
    this.headers,
    this.subtitleUrl,
  });

  final String title;
  final String streamUrl;

  /// Optional per-quality URLs exposed by some modules (for true quality switching).
  final String? url480;
  final String? url720;
  final String? url1080;
  final Map<String, String>? headers;
  final String? subtitleUrl;
}

class JsStreamSelection {
  const JsStreamSelection({
    required this.streams,
    this.subtitleUrl,
  });

  final List<JsStreamCandidate> streams;
  final String? subtitleUrl;
}

class JsModuleExecutor {
  JsModuleExecutor({JsSourcesRuntime? runtime})
      : _runtime = runtime ?? JsSourcesRuntime.instance;

  final JsSourcesRuntime _runtime;
  final SourcesModuleLoader _modules = SourcesModuleLoader();

  static final HttpClient _http = HttpClient()
    ..userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
    ..autoUncompress = true;

  Future<SourcesModuleDescriptor?> _desc(String moduleId) =>
      _modules.findById(moduleId);

  static bool _boolMeta(Map<String, dynamic>? meta, String key) {
    final v = meta?[key];
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true';
    return false;
  }

  static String? _stringMeta(Map<String, dynamic>? meta, String key) {
    final v = meta?[key];
    if (v is String && v.trim().isNotEmpty) return v;
    return null;
  }

  static Map<String, String> _defaultHeaders({String? referer}) {
    final h = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
      'Accept': 'text/html,application/json;q=0.9,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.9',
    };
    if (referer != null && referer.trim().isNotEmpty) {
      h['Referer'] = referer.trim();
    }
    return h;
  }

  static Future<String> _httpRequest(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final uri = Uri.parse(url);
    final req = await _http.openUrl(method, uri).timeout(timeout);
    final h = headers ?? const <String, String>{};
    h.forEach(req.headers.set);
    if (body != null && body.isNotEmpty) {
      req.add(utf8.encode(body));
    }

    final resp = await req.close().timeout(timeout);
    final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    final contentType = resp.headers.value(HttpHeaders.contentTypeHeader);
    return decodeHttpBodyBytes(Uint8List.fromList(bytes),
        contentTypeHeader: contentType);
  }

  static Future<String> _fetchText(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final uri = Uri.parse(url);
    final req = await _http.getUrl(uri).timeout(timeout);
    final h = headers ?? const <String, String>{};
    h.forEach(req.headers.set);
    final resp = await req.close().timeout(timeout);
    final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    final contentType = resp.headers.value(HttpHeaders.contentTypeHeader);
    return decodeHttpBodyBytes(Uint8List.fromList(bytes),
        contentTypeHeader: contentType);
  }

  static Future<_HttpTextResponse> _fetchTextWithStatus(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final uri = Uri.parse(url);
    final req = await _http.getUrl(uri).timeout(timeout);
    final h = headers ?? const <String, String>{};
    h.forEach(req.headers.set);
    final resp = await req.close().timeout(timeout);
    final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    final contentType = resp.headers.value(HttpHeaders.contentTypeHeader);
    return _HttpTextResponse(
      statusCode: resp.statusCode,
      body: decodeHttpBodyBytes(Uint8List.fromList(bytes),
          contentTypeHeader: contentType),
      contentTypeHeader: contentType,
    );
  }

  void _debugPrintModuleSearch({
    required String moduleId,
    required String stage,
    Map<String, dynamic>? meta,
    String? url,
    int? httpStatus,
    String? httpSnippet,
    String? raw,
  }) {
    if (!kDebugMode) return;
    final asyncJs = _boolMeta(meta, 'asyncJS');
    debugPrint(
        '[JsModuleExecutor] search debug stage=$stage module=$moduleId asyncJS=$asyncJs url=${url ?? ''} status=${httpStatus ?? ''}');
    if (httpSnippet != null && httpSnippet.trim().isNotEmpty) {
      debugPrint('[JsModuleExecutor] http snippet:\n$httpSnippet');
    }
    if (raw != null) {
      final t = raw.trim();
      final head = t.length > 600 ? t.substring(0, 600) : t;
      debugPrint('[JsModuleExecutor] raw(head): $head');
    }
  }

  Future<void> _debugPrintModuleRuntimeState(String moduleId) async {
    if (!kDebugMode) return;
    try {
      final exports = await _runtime.getModuleExportsJson(moduleId);
      if (exports != null) {
        debugPrint('[JsModuleExecutor] module exports keys: $exports');
      }
      final logs = await _runtime.getLogsJson(moduleId);
      if (logs != null && logs.trim().isNotEmpty && logs != '[]') {
        final head = logs.length > 2000 ? logs.substring(0, 2000) : logs;
        debugPrint('[JsModuleExecutor] module logs(head): $head');
      }
      final lastFetch = await _runtime.getLastFetchDebugJson(moduleId);
      if (lastFetch != null && lastFetch.trim().isNotEmpty) {
        debugPrint('[JsModuleExecutor] last fetch: $lastFetch');
      }
    } catch (e) {
      debugPrint('[JsModuleExecutor] debug state read failed: $e');
    }
  }

  Future<List<JsModuleTile>> searchResults(
    String moduleId,
    String query,
  ) async {
    final d = await _desc(moduleId);
    final meta = d?.meta;
    final asyncJs = _boolMeta(meta, 'asyncJS');

    String? raw;

    const fallbackFnNames = <String>[
      'searchResults',
      'search',
      'searchAnime',
      'searchAnimes',
      'searchResult',
      'default',
    ];

    Future<String?> callNamed(String fn, List<Object?> args) async {
      return _runtime.callStringArgs(moduleId, fn, args);
    }

    // Helper: call search with fallback function names if missing.
    Future<String?> callSearchWithFallback(List<Object?> args) async {
      String? last;
      for (final fn in fallbackFnNames) {
        last = await callNamed(fn, args);
        if (last == null) continue;
        // If the function exists, we either get a real result or some other error.
        if (!last.startsWith('__JS_ERROR__:missing_function:')) {
          return last;
        }
      }
      return last;
    }

    // 1) Primary strategy: honor module meta.
    String? html;
    String? fetchedUrl;
    int? httpStatus;
    String? httpSnippet;
    if (!asyncJs) {
      final template = _stringMeta(meta, 'searchBaseUrl');
      if (template == null) return const [];
      final url = buildModuleSearchUrl(template, query);
      fetchedUrl = url;
      final resp = await _fetchTextWithStatus(
        url,
        headers: _defaultHeaders(referer: _stringMeta(meta, 'baseUrl')),
      );
      httpStatus = resp.statusCode;
      html = resp.body;
      httpSnippet = html.isEmpty
          ? ''
          : (html.length > 600 ? html.substring(0, 600) : html);
      raw = await callSearchWithFallback(<Object?>[html]);
    } else {
      raw = await callSearchWithFallback(<Object?>[query]);
    }

    if (raw == null) {
      _debugPrintModuleSearch(
        moduleId: moduleId,
        stage: 'null-raw',
        meta: meta,
        url: fetchedUrl,
        httpStatus: httpStatus,
        httpSnippet: httpSnippet,
      );
      await _debugPrintModuleRuntimeState(moduleId);
      return const [];
    }
    if (raw.startsWith('__JS_ERROR__:')) {
      _debugPrintModuleSearch(
        moduleId: moduleId,
        stage: 'js-error',
        meta: meta,
        url: fetchedUrl,
        httpStatus: httpStatus,
        httpSnippet: httpSnippet,
        raw: raw,
      );
      await _debugPrintModuleRuntimeState(moduleId);
      throw StateError(raw);
    }

    List<JsModuleTile> decodeTiles(String body) {
      final decoded = _tryJsonDecode(body);

      // Direct list.
      if (decoded is List) {
        return _tilesFromList(decoded);
      }

      // Heuristic extraction (API-style responses).
      final extracted = extractModuleResults(decoded);
      if (extracted.isNotEmpty) {
        final out = <JsModuleTile>[];
        for (final item in extracted) {
          final title = (item['name'] ?? '').toString().trim();
          final href = (item['url'] ?? '').toString().trim();
          final rawMap = item['raw'];
          String image = '';
          if (rawMap is Map) {
            image = _pickFirstString(rawMap, const [
              'image',
              'img',
              'poster',
              'posterUrl',
              'thumbnail',
              'thumb',
              'cover',
              'coverUrl',
              'banner',
            ]);
          }
          if (title.isEmpty || href.isEmpty) continue;
          out.add(JsModuleTile(title: title, image: image, href: href));
        }
        return out;
      }

      return const [];
    }

    // 2) Decode result.
    var out = decodeTiles(raw);

    // 3) Universal fallback for meta mismatches:
    // Some modules expect `query` even when `asyncJS` is false (or vice versa).
    // Only do extra calls when we got zero results.
    if (out.isEmpty) {
      _debugPrintModuleSearch(
        moduleId: moduleId,
        stage: 'empty-results-primary',
        meta: meta,
        url: fetchedUrl,
        httpStatus: httpStatus,
        httpSnippet: httpSnippet,
        raw: raw,
      );
      await _debugPrintModuleRuntimeState(moduleId);

      // If we used HTML first, try passing query.
      if (!asyncJs) {
        final raw2 = await callSearchWithFallback(<Object?>[query]);
        if (raw2 != null && !raw2.startsWith('__JS_ERROR__:')) {
          final out2 = decodeTiles(raw2);
          if (out2.isNotEmpty) return out2;
        }
      } else {
        // If we used query first and have a template, try the HTML mode.
        final template = _stringMeta(meta, 'searchBaseUrl');
        if (template != null) {
          final url = buildModuleSearchUrl(template, query);
          final resp2 = await _fetchTextWithStatus(
            url,
            headers: _defaultHeaders(referer: _stringMeta(meta, 'baseUrl')),
          );
          final html2 = resp2.body;
          final raw2 = await callSearchWithFallback(<Object?>[html2]);
          if (raw2 != null && !raw2.startsWith('__JS_ERROR__:')) {
            final out2 = decodeTiles(raw2);
            if (out2.isNotEmpty) return out2;
          }
        }
      }
    }

    return out;
  }

  static List<JsModuleTile> _tilesFromList(List list) {
    final out = <JsModuleTile>[];
    for (final item in list) {
      if (item is! Map) continue;

      final title = _pickFirstString(item, const [
        'title',
        'name',
        'animeTitle',
        'label',
      ]).trim();

      final href = _pickFirstString(item, const [
        'href',
        'url',
        'link',
        'path',
      ]).trim();

      final image = _pickFirstString(item, const [
        'image',
        'img',
        'poster',
        'posterUrl',
        'thumbnail',
        'thumb',
        'cover',
        'coverUrl',
        'banner',
      ]).trim();

      if (title.isEmpty || href.isEmpty) continue;
      out.add(JsModuleTile(title: title, image: image, href: href));
    }
    return out;
  }

  static String _pickFirstString(Map map, List<String> keys) {
    for (final k in keys) {
      final v = map[k];
      if (v is String && v.trim().isNotEmpty) return v;
      if (v is num || v is bool) {
        final s = v.toString();
        if (s.trim().isNotEmpty) return s;
      }
    }
    return '';
  }

  Future<List<JsModuleEpisode>> extractEpisodes(
    String moduleId,
    String href,
  ) async {
    final d = await _desc(moduleId);
    final meta = d?.meta;
    final asyncJs = _boolMeta(meta, 'asyncJS');

    String? raw;
    if (asyncJs) {
      raw = await _runtime.callStringArgs(
        moduleId,
        'extractEpisodes',
        <Object?>[href],
      );
    } else {
      final html = await _fetchText(
        href,
        headers: _defaultHeaders(referer: _stringMeta(meta, 'baseUrl')),
      );
      raw = await _runtime.callStringArgs(
        moduleId,
        'extractEpisodes',
        <Object?>[html],
      );
    }

    if (raw == null) return const [];
    if (raw.startsWith('__JS_ERROR__:')) {
      throw StateError(raw);
    }

    final decoded = _tryJsonDecode(raw);
    if (decoded is! List) return const [];

    final out = <JsModuleEpisode>[];
    for (final item in decoded) {
      if (item is! Map) continue;

      final hrefEp = (item['href'] ?? '').toString().trim();
      if (hrefEp.isEmpty) continue;

      final number = _parseInt(item['number']) ?? 0;
      final title = (item['title'] ?? 'Episode $number').toString().trim();
      final image = (item['image'] ?? '').toString().trim();

      final durationSeconds = _parseInt(item['duration']);

      int? openingStart;
      int? openingEnd;
      final opening = item['opening'];
      if (opening is Map) {
        openingStart = _parseInt(opening['start']);
        openingEnd = _parseInt(opening['stop'] ?? opening['end']);
      }

      int? endingStart;
      int? endingEnd;
      final ending = item['ending'];
      if (ending is Map) {
        endingStart = _parseInt(ending['start']);
        endingEnd = _parseInt(ending['stop'] ?? ending['end']);
      }

      out.add(
        JsModuleEpisode(
          number: number,
          title: title,
          image: image,
          href: hrefEp,
          durationSeconds: durationSeconds,
          openingStart: openingStart,
          openingEnd: openingEnd,
          endingStart: endingStart,
          endingEnd: endingEnd,
        ),
      );
    }

    out.sort((a, b) => a.number.compareTo(b.number));

    if (out.isEmpty) {
      // Many modules swallow JS/network errors and return [];
      // try to surface the last fetch diagnostics instead.
      try {
        final dbgRaw = await _runtime.getLastFetchDebugJson(moduleId);
        if (dbgRaw != null && dbgRaw.trim().isNotEmpty) {
          final dbg = jsonDecode(dbgRaw);
          if (dbg is Map) {
            final status = dbg['status'];
            final error = dbg['error']?.toString().trim();
            final url = dbg['url']?.toString().trim();
            final snippet = dbg['snippet']?.toString();
            final statusCode = (status is int)
                ? status
                : (status is num ? status.toInt() : null);

            if ((statusCode != null && statusCode >= 400) ||
                (error != null && error.isNotEmpty)) {
              throw StateError(
                'Module request failed'
                '${statusCode != null ? ' (HTTP $statusCode)' : ''}'
                '${url != null && url.isNotEmpty ? '\n$url' : ''}'
                '${error != null && error.isNotEmpty ? '\n$error' : ''}'
                '${snippet != null && snippet.trim().isNotEmpty ? '\n\n$snippet' : ''}',
              );
            }
          }
        }
      } catch (e) {
        if (e is StateError) rethrow;
        // Ignore: keep empty episodes.
      }
    }

    return out;
  }

  Future<List<String>> extractPages(
    String moduleId,
    String chapterHref,
  ) async {
    final d = await _desc(moduleId);
    final meta = d?.meta;
    final asyncJs = _boolMeta(meta, 'asyncJS');

    String? raw;
    if (asyncJs) {
      raw = await _runtime.callStringArgs(
        moduleId,
        'extractPages',
        <Object?>[chapterHref],
        timeout: const Duration(seconds: 60),
      );
    } else {
      final html = await _httpRequest(
        chapterHref,
        headers: _defaultHeaders(referer: _stringMeta(meta, 'baseUrl')),
      );
      raw = await _runtime.callStringArgs(
        moduleId,
        'extractPages',
        <Object?>[html],
      );
    }

    if (raw == null) return const <String>[];
    if (raw.startsWith('__JS_ERROR__:')) {
      throw StateError(raw);
    }

    final decoded = _tryJsonDecode(raw);
    if (decoded is! List) return const <String>[];
    final out = <String>[];
    for (final item in decoded) {
      if (item == null) continue;
      final s = item.toString().trim();
      if (s.isEmpty) continue;
      out.add(s);
    }

    if (out.isEmpty) {
      try {
        final dbgRaw = await _runtime.getLastFetchDebugJson(moduleId);
        if (dbgRaw != null && dbgRaw.trim().isNotEmpty) {
          final dbg = jsonDecode(dbgRaw);
          if (dbg is Map) {
            final status = dbg['status'];
            final error = dbg['error']?.toString().trim();
            final url = dbg['url']?.toString().trim();
            final snippet = dbg['snippet']?.toString();
            final statusCode = (status is int)
                ? status
                : (status is num ? status.toInt() : null);

            if ((statusCode != null && statusCode >= 400) ||
                (error != null && error.isNotEmpty)) {
              throw StateError(
                'Module request failed'
                '${statusCode != null ? ' (HTTP $statusCode)' : ''}'
                '${url != null && url.isNotEmpty ? '\n$url' : ''}'
                '${error != null && error.isNotEmpty ? '\n$error' : ''}'
                '${snippet != null && snippet.trim().isNotEmpty ? '\n\n$snippet' : ''}',
              );
            }
          }
        }
      } catch (e) {
        if (e is StateError) rethrow;
      }
    }

    return out;
  }

  Future<List<String>> extractPagesChunk(
    String moduleId,
    String chapterHref, {
    required int offset,
    required int limit,
  }) async {
    final d = await _desc(moduleId);
    final meta = d?.meta;
    final asyncJs = _boolMeta(meta, 'asyncJS');

    String? raw;
    if (asyncJs) {
      raw = await _runtime.callStringArgs(
        moduleId,
        'extractPages',
        <Object?>[chapterHref, offset, limit],
        timeout: const Duration(seconds: 60),
      );
    } else {
      final pages = await extractPages(moduleId, chapterHref);
      if (offset >= pages.length) return const <String>[];
      final end = (offset + limit).clamp(0, pages.length);
      return pages.sublist(offset, end);
    }

    if (raw == null) return const <String>[];
    if (raw.startsWith('__JS_ERROR__:')) {
      throw StateError(raw);
    }

    final decoded = _tryJsonDecode(raw);
    if (decoded is! List) return const <String>[];
    final out = <String>[];
    for (final item in decoded) {
      if (item == null) continue;
      final s = item.toString().trim();
      if (s.isEmpty) continue;
      out.add(s);
    }
    return out;
  }

  /// Optional module hook. If the JS module exports `getVoiceovers(episodeHref)`
  /// it should return a JSON array of strings like ["SUB", "DUB"].
  Future<List<String>> getVoiceovers(
    String moduleId,
    String episodeHref,
  ) async {
    String? raw;
    try {
      raw = await _runtime.callStringArgs(
        moduleId,
        'getVoiceovers',
        <Object?>[episodeHref],
      );
    } catch (_) {
      raw = null;
    }

    if (raw == null) return const <String>[];
    if (raw.startsWith('__JS_ERROR__:')) return const <String>[];

    final decoded = _tryJsonDecode(raw);
    if (decoded is! List) return const <String>[];

    final out = <String>[];
    for (final v in decoded) {
      final t = (v ?? '').toString().trim();
      if (t.isEmpty) continue;
      if (!out.contains(t)) out.add(t);
    }
    return out;
  }

  Future<JsStreamCandidate?> extractStream(
    String moduleId,
    String episodeHref, {
    String? preferredTitle,
  }) async {
    final selection = await extractStreams(moduleId, episodeHref);
    if (selection.streams.isEmpty) return null;

    if (preferredTitle != null && preferredTitle.trim().isNotEmpty) {
      final want = preferredTitle.trim().toLowerCase();
      for (final s in selection.streams) {
        final t = s.title.trim().toLowerCase();
        if (t == want || t.contains(want) || want.contains(t)) {
          return s;
        }
      }
    }

    return selection.streams.first;
  }

  Future<JsStreamSelection> extractStreams(
    String moduleId,
    String episodeHref,
    {
      String? voiceover,
    }
  ) async {
    final d = await _desc(moduleId);
    final meta = d?.meta;
    final asyncJs = _boolMeta(meta, 'asyncJS');
    final streamAsyncJs = _boolMeta(meta, 'streamAsyncJS');

    String? raw;
    if (asyncJs || streamAsyncJs) {
      raw = await _runtime.callStringArgs(
        moduleId,
        'extractStreamUrl',
        <Object?>[
          episodeHref,
          if (voiceover != null && voiceover.trim().isNotEmpty) voiceover.trim(),
        ],
      );
    } else {
      final html = await _fetchText(
        episodeHref,
        headers: _defaultHeaders(referer: _stringMeta(meta, 'baseUrl')),
      );
      raw = await _runtime.callStringArgs(
        moduleId,
        'extractStreamUrl',
        <Object?>[
          html,
          if (voiceover != null && voiceover.trim().isNotEmpty) voiceover.trim(),
        ],
      );
    }

    if (raw == null) {
      return const JsStreamSelection(streams: <JsStreamCandidate>[]);
    }
    if (raw.startsWith('__JS_ERROR__:')) {
      throw StateError(raw);
    }

    // 1) Plain URL string.
    if (_looksLikeUrl(raw)) {
      return JsStreamSelection(
        streams: <JsStreamCandidate>[
          JsStreamCandidate(title: 'Stream', streamUrl: raw)
        ],
      );
    }

    final decoded = _tryJsonDecode(raw);

    // 2) { streams: [ {title, streamUrl, headers } ], subtitles: "..." }
    if (decoded is Map) {
      final subtitle =
          (decoded['subtitles'] ?? decoded['subtitle'])?.toString();

      final streams = decoded['streams'];
      if (streams is List) {
        final all = _parseStreams(streams, subtitleUrl: subtitle);
        if (all.isNotEmpty) {
          return JsStreamSelection(streams: all, subtitleUrl: subtitle);
        }
      }

      // 3) { title, streamUrl, headers }
      final streamUrl =
          (decoded['streamUrl'] ?? decoded['url'] ?? '').toString().trim();
      if (streamUrl.isNotEmpty) {
        return JsStreamSelection(
          streams: <JsStreamCandidate>[
            JsStreamCandidate(
              title: (decoded['title'] ?? 'Stream').toString(),
              streamUrl: streamUrl,
              headers: _mapStringString(decoded['headers']),
              subtitleUrl: subtitle,
            ),
          ],
          subtitleUrl: subtitle,
        );
      }
    }

    // 4) [ { title, streamUrl, headers } ]
    if (decoded is List) {
      final all = _parseStreams(decoded);
      if (all.isNotEmpty) {
        return JsStreamSelection(streams: all);
      }
    }

    return const JsStreamSelection(streams: <JsStreamCandidate>[]);
  }

  static List<JsStreamCandidate> _parseStreams(
    List streams, {
    String? subtitleUrl,
  }) {
    final out = <JsStreamCandidate>[];

    // 1) Common Sora-style shape: ["Server", "https://...", "MP4", "https://..."]
    // Also tolerate: ["https://...", "https://..."]
    String? asNonEmptyString(Object? v) {
      final s = (v ?? '').toString().trim();
      return s.isEmpty ? null : s;
    }

    void addUrlCandidate({required String title, required String url}) {
      final u = url.trim();
      if (u.isEmpty) return;
      out.add(
        JsStreamCandidate(
          title: title.trim().isEmpty ? 'Stream' : title.trim(),
          streamUrl: u,
          subtitleUrl: subtitleUrl,
        ),
      );
    }

    // If the list contains no maps at all, try to interpret it as pairs/urls.
    final hasMap = streams.any((e) => e is Map);
    if (!hasMap) {
      for (var i = 0; i < streams.length; i++) {
        final a = asNonEmptyString(streams[i]);
        if (a == null) continue;

        final isAUrl = _looksLikeUrl(a);
        if (i + 1 < streams.length) {
          final b = asNonEmptyString(streams[i + 1]);
          if (b != null) {
            final isBUrl = _looksLikeUrl(b);
            // Pair: title + url
            if (!isAUrl && isBUrl) {
              addUrlCandidate(title: a, url: b);
              i += 1;
              continue;
            }
          }
        }

        // Single URL entry.
        if (isAUrl) {
          addUrlCandidate(title: 'Stream', url: a);
        }
      }

      return out;
    }

    for (final s in streams) {
      if (s is! Map) continue;
      final url = (s['streamUrl'] ?? s['url'] ?? '').toString().trim();
      if (url.isEmpty) continue;

      String? q(String key) {
        final v = s[key];
        if (v is String && v.trim().isNotEmpty) return v.trim();
        return null;
      }

      out.add(
        JsStreamCandidate(
          title: (s['title'] ?? 'Stream').toString(),
          streamUrl: url,
          url480: q('url480'),
          url720: q('url720'),
          url1080: q('url1080'),
          headers: _mapStringString(s['headers']),
          subtitleUrl: subtitleUrl,
        ),
      );
    }
    return out;
  }

  static Map<String, String>? _mapStringString(Object? v) {
    if (v is! Map) return null;
    final out = <String, String>{};
    for (final e in v.entries) {
      final k = e.key?.toString();
      if (k == null) continue;
      out[k] = (e.value ?? '').toString();
    }
    return out.isEmpty ? null : out;
  }

  static int? _parseInt(Object? v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static bool _looksLikeUrl(String s) {
    final t = s.trim();
    return t.startsWith('http://') ||
        t.startsWith('https://') ||
        t.startsWith('//');
  }

  static Object? _tryJsonDecode(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    if (!(t.startsWith('{') || t.startsWith('['))) return null;
    try {
      return jsonDecode(t);
    } catch (_) {
      return null;
    }
  }
}

class _HttpTextResponse {
  const _HttpTextResponse({
    required this.statusCode,
    required this.body,
    this.contentTypeHeader,
  });

  final int statusCode;
  final String body;
  final String? contentTypeHeader;
}
