import 'dart:convert';
import 'dart:io';

import 'package:flutter_js/flutter_js.dart';

import 'package:animeshin/util/module_loader/sources_module_loader.dart';

class JsSourcesRuntime {
  JsSourcesRuntime._();

  static final JsSourcesRuntime instance = JsSourcesRuntime._();

  final Set<String> _loadedModules = <String>{};
  JavascriptRuntime? _runtime;
  final SourcesModuleLoader _loader = SourcesModuleLoader();

  final HttpClient _httpClient = HttpClient()..autoUncompress = true;

  static String _normalizeId(String raw) {
    final t = raw.trim().toLowerCase();
    final buf = StringBuffer();
    var prevDash = false;
    for (final code in t.codeUnits) {
      final isAz = code >= 97 && code <= 122;
      final is09 = code >= 48 && code <= 57;
      if (isAz || is09) {
        buf.writeCharCode(code);
        prevDash = false;
      } else if (!prevDash) {
        buf.write('-');
        prevDash = true;
      }
    }
    var out = buf.toString();
    out = out.replaceAll(RegExp(r'-+'), '-');
    out = out.replaceAll(RegExp(r'^-+'), '');
    out = out.replaceAll(RegExp(r'-+$'), '');
    return out.isEmpty ? 'remote' : out;
  }

  JavascriptRuntime get _rt {
    final rt = _runtime;
    if (rt == null) {
      throw StateError('JsSourcesRuntime not initialized');
    }
    return rt;
  }

  Future<void> ensureInitialized() async {
    if (_runtime != null) return;

    final rt = getJavascriptRuntime();
    rt.enableHandlePromises();

    // Native HTTP bridge (Sora-style): JS calls sendMessage('HttpFetch', JSON.stringify({...}))
    // and Dart performs the request, returning { status, headers, body }.
    rt.onMessage('HttpFetch', (dynamic args) async {
      try {
        Map map;
        if (args is Map) {
          map = args;
        } else if (args is String) {
          try {
            final decoded = jsonDecode(args);
            map = (decoded is Map) ? decoded : <String, Object?>{};
          } catch (_) {
            map = <String, Object?>{};
          }
        } else {
          map = <String, Object?>{};
        }
        final url = (map['url'] ?? '').toString();
        final options = map['options'];

        if (url.trim().isEmpty) {
          return <String, Object?>{
            'status': 0,
            'headers': <String, String>{},
            'body': '',
            'error': 'missing_url',
          };
        }

        String method = 'GET';
        Object? body;
        final headers = <String, String>{};
        final timeoutMsRaw = (options is Map) ? options['timeoutMs'] : null;
        final timeoutMs = timeoutMsRaw is num ? timeoutMsRaw.toInt() : 25000;
        final timeout = Duration(milliseconds: timeoutMs.clamp(1000, 120000));

        if (options is Map) {
          final m = options['method'];
          if (m != null) method = m.toString().toUpperCase();

          final h = options['headers'];
          if (h is Map) {
            for (final e in h.entries) {
              final k = e.key?.toString();
              if (k == null) continue;
              headers[k] = (e.value ?? '').toString();
            }
          }

          final b = options['body'];
          if (b != null) body = b;
        }

        // If body came through JSON decoding, it may be a Map/List (desired).
        // If it's a String, keep as-is.
        String? bodyText;
        var inferredJsonBody = false;
        if (body != null) {
          if (body is String) {
            bodyText = body;
          } else if (body is Map || body is List) {
            bodyText = jsonEncode(body);
            inferredJsonBody = true;
          } else {
            bodyText = body.toString();
          }
        }

        final uri = Uri.parse(url);
        final req = await _httpClient.openUrl(method, uri).timeout(timeout);
        headers.forEach(req.headers.set);

        // Default UA if absent.
        final existingUa = req.headers.value('user-agent');
        if (existingUa == null || existingUa.isEmpty) {
          req.headers.set(
            'User-Agent',
            headers['User-Agent'] ?? headers['user-agent'] ??
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
          );
        }

        // Default Content-Type to JSON when appropriate unless explicitly set.
        {
          final ct = req.headers.value(HttpHeaders.contentTypeHeader);
          final looksJson = () {
            final t = bodyText?.trimLeft();
            if (t == null || t.isEmpty) return false;
            return t.startsWith('{') || t.startsWith('[');
          }();
          if ((inferredJsonBody || looksJson) && (ct == null || ct.isEmpty)) {
            req.headers.set(
              HttpHeaders.contentTypeHeader,
              'application/json; charset=utf-8',
            );
          }
        }

        if (bodyText != null && bodyText.isNotEmpty) {
          req.add(utf8.encode(bodyText));
        }

        final resp = await req.close().timeout(timeout);
        final bytes = await resp
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(timeout);

        String text;
        try {
          text = utf8.decode(bytes, allowMalformed: true);
        } catch (_) {
          text = latin1.decode(bytes, allowInvalid: true);
        }

        final outHeaders = <String, String>{};
        resp.headers.forEach((k, v) {
          if (v.isEmpty) return;
          outHeaders[k] = v.join(', ');
        });

        return jsonEncode(<String, Object?>{
          'status': resp.statusCode,
          'headers': outHeaders,
          'body': text,
          'finalUrl': uri.toString(),
        });
      } catch (e) {
        return jsonEncode(<String, Object?>{
          'status': 0,
          'headers': <String, String>{},
          'body': '',
          'error': e.toString(),
        });
      }
    });

    // Global bootstrap: module registry + a compatible fetchv2 helper.
    rt.evaluate(_bootstrapScript, sourceUrl: 'assets://js_bootstrap.js');

    _runtime = rt;
  }

  Future<void> ensureModuleLoaded(String moduleId) async {
    await ensureInitialized();
    if (_loadedModules.contains(moduleId)) return;

    final loaded = await _loader.loadModule(moduleId);
    final wrapped = _wrapModule(
      moduleId: moduleId,
      moduleCode: loaded.script,
      metaRaw: loaded.metaRaw,
    );
    _rt.evaluate(wrapped, sourceUrl: 'assets://${loaded.descriptor.jsAsset}');

    _loadedModules.add(moduleId);
  }

  Future<void> invalidateModule(String moduleId) async {
    await ensureInitialized();
    final norm = _normalizeId(moduleId);
    _loadedModules.remove(moduleId);
    _loadedModules.remove(norm);
    _loader.invalidateModule(moduleId);

    final ids = <String>{moduleId, norm}..removeWhere((e) => e.trim().isEmpty);
    for (final id in ids) {
      final escaped = id.replaceAll("'", "\\'");
      _rt.evaluate("""
(() => {
  try {
    if (globalThis.__modules) delete globalThis.__modules['$escaped'];
    if (globalThis.__moduleMeta) delete globalThis.__moduleMeta['$escaped'];
    if (globalThis.__moduleLogs) delete globalThis.__moduleLogs['$escaped'];
    if (globalThis.__lastFetchByModule) delete globalThis.__lastFetchByModule['$escaped'];
  } catch (_) {}
})()
""");
    }
  }

  Future<String?> callStringArgs(
    String moduleId,
    String functionName,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await ensureModuleLoaded(moduleId);

    final argsJs = jsonEncode(args);
    final expr = """
(async () => {
  const prevModuleId = globalThis.__currentModuleId;
  globalThis.__currentModuleId = '$moduleId';
  try {
    const mod = globalThis.__modules && globalThis.__modules['$moduleId'];
    const fn = mod && mod['$functionName'];
    if (typeof fn !== 'function') {
      return '__JS_ERROR__:missing_function:$functionName';
    }
    if (typeof globalThis.__pushLog === 'function') {
      try {
        globalThis.__pushLog('$moduleId', 'info', [
          'call',
          '$functionName',
          'args',
          $argsJs,
          'fetch',
          typeof fetch,
          'fetchv2',
          typeof fetchv2
        ]);
      } catch (_) {}
    }
    const out = await fn.apply(null, $argsJs);
    if (typeof out === 'string') return out;
    try { return JSON.stringify(out); } catch (_) { return String(out); }
  } catch (e) {
    const msg = (e && (e.message || e.toString)) ? (e.message || e.toString()) : String(e);
    return '__JS_ERROR__:' + msg;
  } finally {
    globalThis.__currentModuleId = prevModuleId;
  }
})()
""";

    final raw = _rt.evaluate(expr);
    final resolved = await _rt.handlePromise(raw, timeout: timeout);

    final s = resolved.stringResult;
    final trimmed = s.trim();
    if (trimmed.isEmpty || trimmed == 'undefined' || trimmed == 'null') {
      return null;
    }

    if (trimmed.startsWith('__JS_ERROR__:')) {
      return trimmed;
    }

    // If it is a quoted JS string, unquote via JSON decode.
    if ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
        (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
      try {
        return jsonDecode(trimmed) as String;
      } catch (_) {
        // QuickJS sometimes returns single-quoted strings which are not JSON.
        if (trimmed.startsWith("'") && trimmed.endsWith("'")) {
          final inner = trimmed.substring(1, trimmed.length - 1);
          return inner
              .replaceAll(r"\\'", "'")
              .replaceAll(r'\\n', '\n')
              .replaceAll(r'\\r', '\r')
              .replaceAll(r'\\t', '\t');
        }
      }
    }

    return trimmed;
  }

  Future<String?> callString(
    String moduleId,
    String functionName,
    Object? arg, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    return callStringArgs(
      moduleId,
      functionName,
      <Object?>[arg],
      timeout: timeout,
    );
  }

  static String _wrapModule({
    required String moduleId,
    required String moduleCode,
    required String metaRaw,
  }) {
    final escapedId = moduleId.replaceAll("'", "\\'");
    final metaJsonString = jsonEncode(metaRaw);
    return """
(function(){
  globalThis.__modules = globalThis.__modules || {};
  globalThis.__moduleMeta = globalThis.__moduleMeta || {};

  const __id = '$escapedId';
  let __meta = {};
  try { __meta = JSON.parse($metaJsonString); } catch (_) { __meta = {}; }
  globalThis.__moduleMeta[__id] = __meta;

  const exports = {};
  const module = { exports };

  const _push = function(level, args){
    try {
      if (typeof globalThis.__pushLog === 'function') {
        globalThis.__pushLog(__id, level, Array.prototype.slice.call(args));
      }
    } catch(_) {}
  };
  const console = {
    log: function(){ _push('log', arguments); },
    info: function(){ _push('info', arguments); },
    warn: function(){ _push('warn', arguments); },
    error: function(){ _push('error', arguments); }
  };

  // Bind global fetch helpers into module scope for compatibility.
  // Ensure a global console exists for modules that use it directly.
  if (!globalThis.console) {
    globalThis.console = console;
  }

  const fetch = (typeof globalThis.fetch === 'function')
    ? globalThis.fetch
    : (typeof globalThis.fetchv2 === 'function'
        ? async function(url, options){ return await globalThis.fetchv2(url, options); }
        : undefined);
  const fetchv2 = (typeof globalThis.fetchv2 === 'function')
    ? globalThis.fetchv2
    : undefined;

  const prevSource = globalThis.source;
  globalThis.source = __meta;
  try {
    (function(exports, module, meta, console, fetch, fetchv2){
      // --- Predeclare Sora-style aliases to avoid ReferenceError inside modules ---
      const __callFirst = function(list, args){
        for (let i = 0; i < list.length; i++) {
          const fn = list[i];
          if (typeof fn === 'function') return fn.apply(null, args);
        }
        return undefined;
      };

      if (typeof searchResults !== 'function') {
        var searchResults = function(){
          return __callFirst([
            (typeof searchContent === 'function') ? searchContent : null,
            (typeof search === 'function') ? search : null,
            (typeof searchResult === 'function') ? searchResult : null
          ], arguments);
        };
      }

      if (typeof extractDetails !== 'function') {
        var extractDetails = function(){
          return __callFirst([
            (typeof getContentData === 'function') ? getContentData : null
          ], arguments);
        };
      }

      if (typeof extractChapters !== 'function') {
        var extractChapters = function(){
          return __callFirst([
            (typeof getChapters === 'function') ? getChapters : null,
            (typeof getChapterList === 'function') ? getChapterList : null,
            (typeof extractChapterList === 'function') ? extractChapterList : null
          ], arguments);
        };
      }

      if (typeof getChapterImages !== 'function') {
        var getChapterImages = function(){
          return __callFirst([
            (typeof extractImages === 'function') ? extractImages : null,
            (typeof getImages === 'function') ? getImages : null
          ], arguments);
        };
      }
$moduleCode

      // --- Compatibility exports (Sora-style modules vary in naming) ---
      // Prefer canonical names expected by the Dart host, but fall back to
      // common alternatives seen across source ecosystems.
      if (typeof searchResults === 'function') {
        exports.searchResults = searchResults;
      } else if (typeof searchContent === 'function') {
        exports.searchResults = searchContent;
      } else if (typeof search === 'function') {
        exports.searchResults = search;
      } else if (typeof searchResult === 'function') {
        exports.searchResults = searchResult;
      } else if (typeof searchAnime === 'function') {
        exports.searchResults = searchAnime;
      } else if (typeof searchAnimes === 'function') {
        exports.searchResults = searchAnimes;
      }

      if (typeof extractDetails === 'function') exports.extractDetails = extractDetails;
      if (typeof getContentData === 'function') exports.extractDetails = getContentData;
      if (typeof extractEpisodes === 'function') exports.extractEpisodes = extractEpisodes;
      if (typeof extractChapters === 'function') exports.extractChapters = extractChapters;
      if (typeof extractChapterList === 'function') exports.extractChapterList = extractChapterList;
      if (typeof getChapters === 'function') exports.getChapters = getChapters;
      if (typeof getChapterList === 'function') exports.getChapters = getChapterList;
      if (typeof extractPages === 'function') exports.extractPages = extractPages;
      if (typeof extractImages === 'function') exports.extractImages = extractImages;
      if (typeof getChapterImages === 'function') exports.extractImages = getChapterImages;
      if (typeof getPages === 'function') exports.getPages = getPages;
      if (typeof getImages === 'function') exports.getImages = getImages;
      if (typeof extractStreamUrl === 'function') exports.extractStreamUrl = extractStreamUrl;
      if (typeof getVoiceovers === 'function') exports.getVoiceovers = getVoiceovers;
    })(exports, module, __meta, console, fetch, fetchv2);
  } finally {
    globalThis.source = prevSource;
  }

  let finalExports = (module && module.exports) ? module.exports : exports;
  // If a module used CommonJS and replaced module.exports, preserve any
  // function references that were attached to exports.
  try {
    [
      'searchResults',
      'extractDetails',
      'extractEpisodes',
      'extractChapters',
      'extractChapterList',
      'getChapters',
      'getChapterList',
      'extractPages',
      'extractImages',
      'getChapterImages',
      'getPages',
      'getImages',
      'extractStreamUrl',
      'getVoiceovers',
    ].forEach(function(k){
      if (!finalExports[k] && exports[k]) finalExports[k] = exports[k];
    });
  } catch (_) {}

  // --- Normalize export shapes ---
  // Some modules export:
  // - `exports.search = fn` (no `searchResults`)
  // - `exports.default = fn`
  // - `module.exports = fn`
  // Normalize these to the canonical function names expected by Dart.
  try {
    // If the module exported a bare function, wrap it.
    if (typeof finalExports === 'function') {
      finalExports = { searchResults: finalExports };
    }

    if (finalExports && typeof finalExports === 'object') {
      const sr = finalExports.searchResults;
      if (typeof sr !== 'function') {
        const cand = finalExports.search || finalExports.searchAnime || finalExports.searchAnimes || finalExports.searchResult || finalExports.default;
        if (typeof cand === 'function') {
          finalExports.searchResults = cand;
        }
      }
    }
  } catch (_) {}

  globalThis.__modules[__id] = finalExports;
})();
""";
  }

  Future<String?> getModuleExportsJson(String moduleId) async {
    await ensureInitialized();
    final expr = """
(() => {
  try {
    const mod = globalThis.__modules ? globalThis.__modules['$moduleId'] : null;
    if (!mod) return '';
    return JSON.stringify(Object.keys(mod));
  } catch(e) { return '__JS_ERROR__:' + (e && (e.message||e.toString) ? (e.message||e.toString()) : String(e)); }
})()
""";
    final res = _rt.evaluate(expr).stringResult.trim();
    if (res.isEmpty || res == 'undefined' || res == 'null') return null;
    return res;
  }

  Future<String?> getLastFetchDebugJson(String moduleId) async {
    await ensureInitialized();
    final expr = """
(() => {
  try {
    const v = globalThis.__getLastFetch ? globalThis.__getLastFetch('$moduleId') : null;
    return v ? JSON.stringify(v) : '';
  } catch(e) { return '__JS_ERROR__:' + (e && (e.message||e.toString) ? (e.message||e.toString()) : String(e)); }
})()
""";
    final res = _rt.evaluate(expr).stringResult.trim();
    if (res.isEmpty || res == 'undefined' || res == 'null') return null;
    return res;
  }

  Future<String?> getLogsJson(String moduleId) async {
    await ensureInitialized();
    final expr = """
(() => {
  try {
    const v = globalThis.__getLogs ? globalThis.__getLogs('$moduleId') : [];
    return JSON.stringify(v || []);
  } catch(e) { return '__JS_ERROR__:' + (e && (e.message||e.toString) ? (e.message||e.toString()) : String(e)); }
})()
""";
    final res = _rt.evaluate(expr).stringResult.trim();
    if (res.isEmpty || res == 'undefined' || res == 'null') return null;
    return res;
  }
}

const String _bootstrapScript = r'''
(function(){
  globalThis.__modules = globalThis.__modules || {};
  globalThis.__moduleLogs = globalThis.__moduleLogs || {};
  globalThis.__lastFetchByModule = globalThis.__lastFetchByModule || {};
  globalThis.__currentModuleId = globalThis.__currentModuleId || null;

  function __safeJsonParse(t) {
    // With the native Dart HTTP bridge, we should get clean UTF-8 strings.
    return JSON.parse(String(t));
  }

  globalThis.__pushLog = function(moduleId, level, args) {
    const id = moduleId || 'global';
    const arr = (globalThis.__moduleLogs[id] = globalThis.__moduleLogs[id] || []);
    try {
      const msg = (args || []).map(function(a){
        try { return (typeof a === 'string') ? a : JSON.stringify(a); }
        catch(_) { return String(a); }
      }).join(' ');
      arr.push({ t: Date.now(), level: level || 'log', msg: msg });
      if (arr.length > 200) arr.shift();
    } catch (_) {}
  };

  globalThis.__getLogs = function(moduleId) {
    const id = moduleId || 'global';
    return globalThis.__moduleLogs[id] || [];
  };

  globalThis.__getLastFetch = function(moduleId) {
    const id = moduleId || 'global';
    return globalThis.__lastFetchByModule[id] || null;
  };

  function __defaultRefererFor(url) {
    try {
      const u = String(url || '');
      const m = u.match(/^(https?:\/\/[^\/]+)\//i);
      if (m && m[1]) return m[1] + '/';
    } catch (_) {}
    return 'https://www.google.com/';
  }

  function __moduleBaseFor(moduleId) {
    try {
      const meta = globalThis.__moduleMeta && globalThis.__moduleMeta[moduleId];
      if (!meta) return null;
      const raw = meta.baseUrl || meta.baseURL || meta.site || meta.website || '';
      const s = String(raw || '').trim();
      if (!s) return null;
      const m = s.match(/^(https?:\/\/[^\/]+)\/?/i);
      return m && m[1] ? (m[1] + '/') : null;
    } catch (_) {}
    return null;
  }

  // fetchv2(url, headersOrOptions?, method?, body?)
  // Supports common Luna/Sora module call styles:
  // - fetchv2(url)
  // - fetchv2(url, headers)
  // - fetchv2(url, headers, method, body)
  // - fetchv2(url, { method, headers, body })
  // Always returns an object that supports .text() and .json().
  globalThis.fetchv2 = async function(url, headersOrOptions, method, body) {
    let options = {};

    if (headersOrOptions && typeof headersOrOptions === 'object') {
      const hasFetchShape =
        Object.prototype.hasOwnProperty.call(headersOrOptions, 'method') ||
        Object.prototype.hasOwnProperty.call(headersOrOptions, 'headers') ||
        Object.prototype.hasOwnProperty.call(headersOrOptions, 'body');

      if (hasFetchShape) {
        options = headersOrOptions;
      } else {
        options.headers = headersOrOptions;
        if (method) options.method = method;
        if (body !== undefined) options.body = body;
      }
    } else {
      if (method) options.method = method;
      if (body !== undefined) options.body = body;
    }

    if (!options.method) options.method = method || 'GET';
    if (!options.headers) options.headers = {};

    const moduleId = globalThis.__currentModuleId || 'global';

    // Some hosts are picky; provide a reasonable default UA if absent.
    if (!options.headers['User-Agent'] && !options.headers['user-agent']) {
      options.headers['User-Agent'] =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
    }

    if (!options.headers['Accept'] && !options.headers['accept']) {
      options.headers['Accept'] = 'text/html,application/json;q=0.9,*/*;q=0.8';
    }
    if (!options.headers['Accept-Language'] && !options.headers['accept-language']) {
      options.headers['Accept-Language'] = 'en-US,en;q=0.9';
    }
    if (!options.headers['Referer'] && !options.headers['referer']) {
      const base = __moduleBaseFor(moduleId);
      options.headers['Referer'] = base || __defaultRefererFor(url);
    }
    if (!options.headers['Origin'] && !options.headers['origin']) {
      const ref = options.headers['Referer'] || options.headers['referer'];
      try {
        const m = String(ref || '').match(/^(https?:\/\/[^\/]+)\//i);
        if (m && m[1]) options.headers['Origin'] = m[1];
      } catch (_) {}
    }

    const startTs = Date.now();
    globalThis.__lastFetchByModule[moduleId] = {
      url: String(url),
      status: null,
      ok: null,
      ms: null,
      error: null,
      snippet: null,
      len: null,
      tail: null
    };

    // Native fetch via Dart bridge.
    const nativeRaw = await sendMessage('HttpFetch', JSON.stringify({ url: String(url), options: options }));
    let native = nativeRaw;
    try {
      if (typeof nativeRaw === 'string') native = __safeJsonParse(nativeRaw);
    } catch (_) {
      native = {};
    }

    // Wrap to ensure a consistent API and capture debug info.
    let textPromise = null;
    const wrapped = {
      status: (native && typeof native.status === 'number') ? native.status : 0,
      ok: (native && typeof native.status === 'number') ? (native.status >= 200 && native.status < 300) : false,
      headers: (native && native.headers) ? native.headers : {},
      text: function() {
        if (textPromise) return textPromise;
        if (native && typeof native.body === 'string') {
          textPromise = Promise.resolve(native.body);
        } else {
          textPromise = Promise.resolve('');
        }
        return textPromise.then(function(t){
          try {
            const entry = globalThis.__lastFetchByModule[moduleId] || {};
            entry.status = wrapped.status;
            entry.ok = wrapped.ok;
            entry.ms = Date.now() - startTs;
            entry.snippet = (t && t.length > 240) ? t.substring(0,240) : t;
            entry.len = (t && typeof t.length === 'number') ? t.length : null;
            entry.tail = (t && t.length > 120) ? t.substring(t.length - 120) : t;
            if (native && native.error) entry.error = String(native.error);
            globalThis.__lastFetchByModule[moduleId] = entry;
          } catch(_) {}
          return t;
        }).catch(function(e){
          try {
            const entry = globalThis.__lastFetchByModule[moduleId] || {};
            entry.status = wrapped.status;
            entry.ok = wrapped.ok;
            entry.ms = Date.now() - startTs;
            entry.error = String(e);
            globalThis.__lastFetchByModule[moduleId] = entry;
          } catch(_) {}
          throw e;
        });
      },
      json: function() {
        return this.text().then(function(t) {
          try {
            return __safeJsonParse(t);
          } catch (e) {
            try {
              const entry = globalThis.__lastFetchByModule[moduleId] || {};
              entry.error = String(e);
              globalThis.__lastFetchByModule[moduleId] = entry;
            } catch(_) {}
            throw e;
          }
        });
      }
    };

    // Populate lastFetch immediately (even if module only calls .json()).
    try {
      const entry0 = globalThis.__lastFetchByModule[moduleId] || {};
      entry0.status = wrapped.status;
      entry0.ok = wrapped.ok;
      entry0.ms = Date.now() - startTs;
      if (native && native.error) entry0.error = String(native.error);
      globalThis.__lastFetchByModule[moduleId] = entry0;
    } catch(_) {}

    return wrapped;
  };

  // Sora modules frequently use `fetch()` expecting a *string* response.
  // Provide a compatible implementation that returns a String object (so it can
  // be used both as a string and as a response-like object with .text()/.json()).
  globalThis.fetch = async function(url, options) {
    const r = await globalThis.fetchv2(url, options);
    const t = await r.text();
    const s = new String(t);
    s.status = r.status;
    s.ok = r.ok;
    s.headers = r.headers;
    s.text = async function(){ return String(s); };
    s.json = async function(){ return __safeJsonParse(String(s)); };
    return s;
  };
})();
''';
