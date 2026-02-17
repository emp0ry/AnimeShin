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

  /// Optional per-quality URLs exposed by some modules.
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

class JsVoiceoverProbe {
  const JsVoiceoverProbe({
    required this.voiceoverTitles,
    this.prefetchedSelection,
  });

  final List<String> voiceoverTitles;
  final JsStreamSelection? prefetchedSelection;
}

class JsModuleExecutor {
  JsModuleExecutor({
    JsSourcesRuntime? runtime,
    SourcesModuleLoader? modules,
  })  : _runtime = runtime ?? JsSourcesRuntime.instance,
        _modules = modules ?? sharedSourcesModuleLoader;

  final JsSourcesRuntime _runtime;
  final SourcesModuleLoader _modules;

  static final HttpClient _http = HttpClient()
    ..userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
    ..autoUncompress = true
    ..maxConnectionsPerHost = 8
    ..idleTimeout = const Duration(seconds: 15);

  Future<SourcesModuleDescriptor?> _desc(String moduleId) =>
      _modules.findById(moduleId);

  static bool _boolMeta(Map<String, dynamic>? meta, String key) {
    final v = meta?[key];
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true';
    return false;
  }

  /// Strict Sora mode selection.
  /// Only asyncJS controls the input type for functions.
  static bool _isAsyncModule(Map<String, dynamic>? meta) {
    return _boolMeta(meta, 'asyncJS');
  }

  static String? _stringMeta(Map<String, dynamic>? meta, String key) {
    final v = meta?[key];
    if (v is String && v.trim().isNotEmpty) return v;
    return null;
  }

  static int? _intMeta(Map<String, dynamic>? meta, String key) {
    final v = meta?[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) {
      final t = v.trim();
      if (t.isEmpty) return null;
      return int.tryParse(t);
    }
    return null;
  }

  static Duration _streamExtractTimeout(Map<String, dynamic>? meta) {
    const defaultMs = 45000;
    const minMs = 5000;
    const maxMs = 180000;

    var timeoutMs = _intMeta(meta, 'streamTimeoutMs') ??
        _intMeta(meta, 'streamTimeoutMS') ??
        _intMeta(meta, 'streamTimeoutMillis');
    if (timeoutMs == null) {
      final sec = _intMeta(meta, 'streamTimeoutSec') ??
          _intMeta(meta, 'streamTimeoutSeconds');
      if (sec != null) timeoutMs = sec * 1000;
    }

    final effective = (timeoutMs ?? defaultMs).clamp(minMs, maxMs).toInt();
    return Duration(milliseconds: effective);
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

  Future<String?> _callFirstAvailable(
    String moduleId,
    List<String> fnNames,
    List<Object?> args, {
    Duration? timeout,
  }) async {
    String? last;
    for (final fn in fnNames) {
      last = await _runtime.callStringArgs(
        moduleId,
        fn,
        args,
        timeout: timeout ?? const Duration(seconds: 20),
      );
      if (last == null) continue;
      if (!last.startsWith('__JS_ERROR__:missing_function:')) return last;
    }
    return last;
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
    final bytes = await consolidateHttpClientResponseBytes(resp).timeout(timeout);
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
    final bytes = await consolidateHttpClientResponseBytes(resp).timeout(timeout);
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
    final bytes = await consolidateHttpClientResponseBytes(resp).timeout(timeout);
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
    final asyncJs = _isAsyncModule(meta);
    debugPrint(
        '[JsModuleExecutor] stage=$stage module=$moduleId asyncJS=$asyncJs url=${url ?? ''} status=${httpStatus ?? ''}');
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
    final asyncJs = _isAsyncModule(meta);

    String? raw;

    const fallbackFnNames = <String>[
      'searchResults',
      'search',
      'searchContent',
      'searchManga',
      'searchMangas',
      'searchMangaResult',
      'searchMangaResults',
      'searchAnime',
      'searchAnimes',
      'searchResult',
      'default',
    ];

    Future<String?> callNamed(String fn, List<Object?> args) async {
      return _runtime.callStringArgs(moduleId, fn, args);
    }

    Future<String?> callSearchWithFallback(List<Object?> args) async {
      String? last;
      for (final fn in fallbackFnNames) {
        last = await callNamed(fn, args);
        if (last == null) continue;
        if (!last.startsWith('__JS_ERROR__:missing_function:')) {
          return last;
        }
      }
      return last;
    }

    String? fetchedUrl;
    int? httpStatus;
    String? httpSnippet;

    if (asyncJs) {
      raw = await callSearchWithFallback(<Object?>[query]);
    } else {
      final template = _stringMeta(meta, 'searchBaseUrl');
      if (template == null) {
        // No template means the module is misconfigured for normal mode.
        // Keep a best-effort call with keyword, but do not treat it as async mode.
        raw = await callSearchWithFallback(<Object?>[query]);
      } else {
        final url = buildModuleSearchUrl(template, query);
        fetchedUrl = url;
        final resp = await _fetchTextWithStatus(
          url,
          headers: _defaultHeaders(referer: _stringMeta(meta, 'baseUrl')),
        );
        httpStatus = resp.statusCode;
        final html = resp.body;
        httpSnippet = html.isEmpty
            ? ''
            : (html.length > 600 ? html.substring(0, 600) : html);
        raw = await callSearchWithFallback(<Object?>[html]);
      }
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

      if (decoded is List) {
        return _tilesFromList(decoded);
      }

      final extracted = extractModuleResults(decoded);
      if (extracted.isNotEmpty) {
        final out = <JsModuleTile>[];
        for (final item in extracted) {
          final title = (item['name'] ?? '').toString().trim();
          final href = (item['url'] ?? item['id'] ?? '').toString().trim();
          final rawMap = item['raw'];

          String image = '';
          if (rawMap is Map) {
            image = _pickFirstString(rawMap, const [
              'image',
              'img',
              'imageURL',
              'imageUrl',
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

    final out = decodeTiles(raw);
    if (out.isEmpty) {
      _debugPrintModuleSearch(
        moduleId: moduleId,
        stage: 'empty-results',
        meta: meta,
        url: fetchedUrl,
        httpStatus: httpStatus,
        httpSnippet: httpSnippet,
        raw: raw,
      );
      await _debugPrintModuleRuntimeState(moduleId);
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
        'id',
        'mangaId',
        'malId',
      ]).trim();

      final image = _pickFirstString(item, const [
        'image',
        'img',
        'imageURL',
        'imageUrl',
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
    final asyncJs = _isAsyncModule(meta);

    const episodeFns = <String>[
      'extractEpisodes',
      'extractChapters',
      'extractChapterList',
      'getChapters',
      'getChapterList',
    ];

    String? raw;
    final hrefLooksLikeUrl = _looksLikeUrl(href);

    if (asyncJs || !hrefLooksLikeUrl) {
      raw = await _callFirstAvailable(
        moduleId,
        episodeFns,
        <Object?>[href],
      );
    } else {
      final html = await _fetchText(
        href,
        headers: _defaultHeaders(referer: _stringMeta(meta, 'baseUrl')),
      );
      raw = await _callFirstAvailable(
        moduleId,
        episodeFns,
        <Object?>[html],
      );
    }

    if (raw == null) return const [];
    if (raw.startsWith('__JS_ERROR__:')) {
      if (raw.startsWith('__JS_ERROR__:missing_function:')) {
        return const [];
      }
      throw StateError(raw);
    }

    final decoded = _tryJsonDecode(raw);
    final out = <JsModuleEpisode>[];

    List<Object?> flatten(Object? node) {
      final list = <Object?>[];
      void addAny(Object? n) {
        if (n is List) {
          for (final e in n) {
            if (e is List && e.length >= 2 && e[1] is List) {
              for (final sub in (e[1] as List)) {
                list.add(sub);
              }
            } else {
              list.add(e);
            }
          }
        }
      }

      if (node is List) addAny(node);
      if (node is Map) {
        for (final v in node.values) {
          addAny(v);
        }
      }
      return list;
    }

    final items = flatten(decoded);
    for (final item in items) {
      if (item is! Map) continue;

      final hrefEp =
          (item['href'] ?? item['url'] ?? item['id'] ?? '').toString().trim();
      if (hrefEp.isEmpty) continue;

      final numRaw = item['number'] ??
          item['chapter'] ??
          item['episode'] ??
          item['ep'];
      final parsedInt = _parseInt(numRaw);
      final parsedDouble = _parseDouble(numRaw);
      final number =
          parsedInt ?? (parsedDouble != null ? parsedDouble.round() : 0);

      final title =
          (item['title'] ?? item['name'] ?? 'Episode $number').toString().trim();
      final image =
          (item['image'] ?? item['img'] ?? item['imageURL'] ?? '').toString().trim();

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

  Future<JsStreamSelection> extractStreams(
    String moduleId,
    String episodeHref, {
    String? voiceover,
  }) async {
    final d = await _desc(moduleId);
    final meta = d?.meta;

    final asyncJs = _isAsyncModule(meta);
    final streamAsyncJs = _boolMeta(meta, 'streamAsyncJS') ||
        _boolMeta(meta, 'streamAsyncJs');
    final streamTimeout = _streamExtractTimeout(meta);

    String? raw;

    if (asyncJs) {
      // Async JS mode: extractStreamUrl receives episode URL or episode id.
      raw = await _runtime.callStringArgs(
        moduleId,
        'extractStreamUrl',
        <Object?>[
          episodeHref,
          if (voiceover != null && voiceover.trim().isNotEmpty) voiceover.trim(),
        ],
        timeout: streamTimeout,
      );
    } else {
      // Normal mode and streamAsyncJS mode: extractStreamUrl receives HTML.
      // streamAsyncJS changes how the module gets the final stream, but input is still HTML.
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
        timeout: streamTimeout,
      );

      // If the module is marked streamAsyncJS, keep strict behavior and do not retry with episodeHref.
      // If it is not streamAsyncJS, you may optionally retry with episodeHref for badly-configured modules.
      if (!streamAsyncJs &&
          (raw == null || raw.startsWith('__JS_ERROR__:missing_function:'))) {
        raw = await _runtime.callStringArgs(
          moduleId,
          'extractStreamUrl',
          <Object?>[
            episodeHref,
            if (voiceover != null && voiceover.trim().isNotEmpty) voiceover.trim(),
          ],
          timeout: streamTimeout,
        );
      }
    }

    if (raw == null) {
      return const JsStreamSelection(streams: <JsStreamCandidate>[]);
    }
    if (raw.startsWith('__JS_ERROR__:')) {
      throw StateError(raw);
    }

    // Plain URL string.
    final plain = raw.trim();
    if (_looksLikeUrl(plain)) {
      final u = _normalizeUrl(plain);
      return JsStreamSelection(
        streams: <JsStreamCandidate>[
          JsStreamCandidate(title: 'Stream', streamUrl: u),
        ],
      );
    }

    final decoded = _tryJsonDecode(raw);

    // { streams: [...], subtitles: "..." }
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

      // { title, streamUrl, headers }
      final streamUrl =
          (decoded['streamUrl'] ?? decoded['url'] ?? '').toString().trim();
      if (streamUrl.isNotEmpty) {
        return JsStreamSelection(
          streams: <JsStreamCandidate>[
            JsStreamCandidate(
              title: (decoded['title'] ?? 'Stream').toString(),
              streamUrl: _normalizeUrl(streamUrl),
              headers: _mapStringString(decoded['headers']),
              subtitleUrl: subtitle,
            ),
          ],
          subtitleUrl: subtitle,
        );
      }
    }

    // [ { title, streamUrl, headers } ] or mixed list.
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

    String? asNonEmptyString(Object? v) {
      final s = (v ?? '').toString().trim();
      return s.isEmpty ? null : s;
    }

    void addUrlCandidate({required String title, required String url}) {
      final u = _normalizeUrl(url.trim());
      if (u.isEmpty) return;
      out.add(
        JsStreamCandidate(
          title: title.trim().isEmpty ? 'Stream' : title.trim(),
          streamUrl: u,
          subtitleUrl: subtitleUrl,
        ),
      );
    }

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
            if (!isAUrl && isBUrl) {
              addUrlCandidate(title: a, url: b);
              i += 1;
              continue;
            }
          }
        }

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
          streamUrl: _normalizeUrl(url),
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

  static double? _parseDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static bool _looksLikeUrl(String s) {
    final t = s.trim();
    return t.startsWith('http://') || t.startsWith('https://') || t.startsWith('//');
  }

  static String _normalizeUrl(String u) {
    final t = u.trim();
    if (t.startsWith('//')) return 'https:$t';
    return t;
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

  List<String> _decodeVoiceoverTitles(String raw) {
    final decoded = _tryJsonDecode(raw);
    final titles = <String>[];

    if (decoded is List) {
      for (final item in decoded) {
        final s = (item ?? '').toString().trim();
        if (s.isNotEmpty) titles.add(s);
      }
    } else if (decoded is Map) {
      final list =
          decoded['voiceovers'] ?? decoded['dubbings'] ?? decoded['translations'];
      if (list is List) {
        for (final item in list) {
          final s = (item ?? '').toString().trim();
          if (s.isNotEmpty) titles.add(s);
        }
      }
    } else {
      // Sometimes modules return a plain string list joined by separators.
      final s = raw.trim();
      if (s.isNotEmpty && s.length < 1000) {
        final split = s.split(RegExp(r'[,\n;|]+')).map((e) => e.trim());
        for (final t in split) {
          if (t.isNotEmpty) titles.add(t);
        }
      }
    }

    // Deduplicate case-insensitively.
    final unique = <String>[];
    final seen = <String>{};
    for (final t in titles) {
      final k = t.toLowerCase();
      if (seen.add(k)) unique.add(t);
    }

    // Never return pure quality labels as voiceovers.
    unique.removeWhere(_isPureQualityLabel);
    return unique;
  }

  Future<List<String>> _getVoiceoversDirect(
    String moduleId,
    String episodeHref,
  ) async {
    final d = await _desc(moduleId);
    final meta = d?.meta;
    final asyncJs = _isAsyncModule(meta);

    // First: try a dedicated JS function if the module provides it.
    // Many Sora softsub sources implement getVoiceovers(url) or getVoiceOver(url).
    const fnNames = <String>[
      'getVoiceovers',
      'getVoiceOver',
      'getVoiceover',
      'getDubbings',
      'getTranslations',
    ];

    String? raw;

    if (asyncJs) {
      raw = await _callFirstAvailable(moduleId, fnNames, <Object?>[episodeHref]);
    } else {
      // Non-async modules: call with HTML when possible.
      if (_looksLikeUrl(episodeHref)) {
        final html = await _fetchText(
          episodeHref,
          headers: _defaultHeaders(referer: _stringMeta(meta, 'baseUrl')),
        );
        raw = await _callFirstAvailable(moduleId, fnNames, <Object?>[html]);
      } else {
        // If href is not a URL, best-effort pass through.
        raw = await _callFirstAvailable(moduleId, fnNames, <Object?>[episodeHref]);
      }
    }

    // Missing function or empty response means no dedicated voiceover endpoint.
    if (raw == null ||
        raw.startsWith('__JS_ERROR__:missing_function:') ||
        raw.trim().isEmpty) {
      return const <String>[];
    }

    if (raw.startsWith('__JS_ERROR__:')) {
      // Hard error inside JS.
      throw StateError(raw);
    }

    return _decodeVoiceoverTitles(raw);
  }

  Future<List<String>> getVoiceovers(
    String moduleId,
    String episodeHref, {
    bool allowInferenceFallback = true,
  }) async {
    final direct = await _getVoiceoversDirect(moduleId, episodeHref);
    if (direct.isNotEmpty || !allowInferenceFallback) return direct;

    try {
      final selection = await extractStreams(moduleId, episodeHref);
      return _inferVoiceoversFromStreams(selection.streams);
    } catch (_) {
      return const <String>[];
    }
  }

  Future<JsVoiceoverProbe> probeVoiceovers(
    String moduleId,
    String episodeHref,
  ) async {
    final direct = await getVoiceovers(
      moduleId,
      episodeHref,
      allowInferenceFallback: false,
    );
    if (direct.isNotEmpty) {
      return JsVoiceoverProbe(voiceoverTitles: direct);
    }

    try {
      final selection = await extractStreams(moduleId, episodeHref);
      final inferred = _inferVoiceoversFromStreams(selection.streams);
      return JsVoiceoverProbe(
        voiceoverTitles: inferred,
        prefetchedSelection: selection.streams.isEmpty ? null : selection,
      );
    } catch (_) {
      return const JsVoiceoverProbe(voiceoverTitles: <String>[]);
    }
  }

  static bool _isPureQualityLabel(String t) {
    final s = t.trim().toLowerCase();
    if (s.isEmpty) return false;
    return RegExp(r'^\s*(2160|1440|1080|720|480|360)\s*p\s*$').hasMatch(s) ||
        RegExp(r'^\s*(2160|1440|1080|720|480|360)p\s*$').hasMatch(s);
  }

  static List<String> _inferVoiceoversFromStreams(List<JsStreamCandidate> streams) {
    final out = <String>[];
    final seen = <String>{};

    for (final s in streams) {
      final raw = s.title.trim();
      if (raw.isEmpty) continue;
      if (_isPureQualityLabel(raw)) continue;

      final base = _stripDecorations(raw).toLowerCase();
      if (base.isEmpty) continue;

      if (seen.add(base)) out.add(raw);
    }

    return out;
  }

  static String _stripDecorations(String raw) {
    var out = raw.trim();
    if (out.isEmpty) return out;

    if (out.contains('|')) {
      final parts = out.split('|').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      if (parts.isNotEmpty) out = parts.first;
    }

    out = out.replaceAll(RegExp(r'\s*\([^)]*\)'), ' ');
    out = out.replaceAll(RegExp(r'\s*\[[^\]]*\]'), ' ');
    out = out.replaceAll(RegExp(r'\b(2160|1440|1080|720|480|360)\s*p\b', caseSensitive: false), ' ');
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();

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
    final asyncJs = _isAsyncModule(meta);

    // Some modules may implement chunked pages directly.
    const chunkFns = <String>[
      'extractPagesChunk',
      'extractImagesChunk',
      'extractPageChunk',
    ];

    String? raw;

    if (asyncJs) {
      raw = await _callFirstAvailable(
        moduleId,
        chunkFns,
        <Object?>[chapterHref, offset, limit],
      );
    } else {
      if (_looksLikeUrl(chapterHref)) {
        // Use _httpRequest to avoid unused warning and to keep behavior consistent.
        final html = await _httpRequest(
          chapterHref,
          headers: _defaultHeaders(referer: _stringMeta(meta, 'baseUrl')),
        );
        raw = await _callFirstAvailable(
          moduleId,
          chunkFns,
          <Object?>[html, offset, limit],
        );
      } else {
        raw = await _callFirstAvailable(
          moduleId,
          chunkFns,
          <Object?>[chapterHref, offset, limit],
        );
      }
    }

    // If chunk function is missing, fallback: extract full pages and slice.
    if (raw == null || raw.startsWith('__JS_ERROR__:missing_function:')) {
      final all = await extractAllPages(moduleId, chapterHref);
      final start = offset.clamp(0, all.length);
      final end = (start + limit).clamp(0, all.length);
      return all.sublist(start, end);
    }

    if (raw.startsWith('__JS_ERROR__:')) {
      throw StateError(raw);
    }

    final decoded = _tryJsonDecode(raw);
    final pages = _parsePagesList(decoded);

    if (pages.isEmpty) return const <String>[];

    // If module returned full list by mistake, still slice safely.
    final start = offset.clamp(0, pages.length);
    final end = (start + limit).clamp(0, pages.length);
    return pages.sublist(start, end);
  }

  Future<List<String>> extractAllPages(
    String moduleId,
    String chapterHref,
  ) async {
    final d = await _desc(moduleId);
    final meta = d?.meta;
    final asyncJs = _isAsyncModule(meta);

    const fullFns = <String>[
      'extractPages',
      'extractImages',
      'extractPageUrls',
      'extractMangaPages',
    ];

    String? raw;

    if (asyncJs) {
      raw = await _callFirstAvailable(moduleId, fullFns, <Object?>[chapterHref]);
    } else {
      if (_looksLikeUrl(chapterHref)) {
        final html = await _httpRequest(
          chapterHref,
          headers: _defaultHeaders(referer: _stringMeta(meta, 'baseUrl')),
        );
        raw = await _callFirstAvailable(moduleId, fullFns, <Object?>[html]);
      } else {
        raw = await _callFirstAvailable(moduleId, fullFns, <Object?>[chapterHref]);
      }
    }

    if (raw == null) return const <String>[];
    if (raw.startsWith('__JS_ERROR__:')) {
      if (raw.startsWith('__JS_ERROR__:missing_function:')) return const <String>[];
      throw StateError(raw);
    }

    final decoded = _tryJsonDecode(raw);
    return _parsePagesList(decoded);
  }

  static List<String> _parsePagesList(Object? decoded) {
    final out = <String>[];

    void addUrl(Object? v) {
      final s = (v ?? '').toString().trim();
      if (s.isEmpty) return;
      out.add(_normalizeUrl(s));
    }

    if (decoded is List) {
      for (final item in decoded) {
        if (item is String || item is num) {
          addUrl(item);
        } else if (item is Map) {
          // Some modules return [{ url: "..." }, ...]
          addUrl(item['url'] ?? item['image'] ?? item['src']);
        }
      }
    } else if (decoded is Map) {
      final list = decoded['pages'] ?? decoded['images'] ?? decoded['data'];
      if (list is List) {
        for (final item in list) {
          if (item is String || item is num) {
            addUrl(item);
          } else if (item is Map) {
            addUrl(item['url'] ?? item['image'] ?? item['src']);
          }
        }
      }
    }

    // Deduplicate while keeping order.
    final unique = <String>[];
    final seen = <String>{};
    for (final u in out) {
      if (seen.add(u)) unique.add(u);
    }
    return unique;
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
