import 'dart:convert';
import 'dart:typed_data';

/// Build a search URL from a module template.
///
/// - If [template] contains `%s`, it will be replaced with an URL-encoded [query].
/// - Otherwise, `?q=` (or `&q=`) will be appended.
String buildModuleSearchUrl(String template, String query) {
  final encoded = Uri.encodeComponent(query);
  if (template.contains('%s')) {
    return template.replaceAll('%s', encoded);
  }

  // If the template already ends with a parameter assignment like
  //   https://site/search?q=
  // or
  //   https://site/search?query=
  // then just append the encoded query.
  if (RegExp(r'[?&][^=]+=$').hasMatch(template)) {
    return '$template$encoded';
  }

  final sep = template.contains('?') ? '&' : '?';
  return '$template${sep}q=$encoded';
}

/// Extracts a likely results list from various common API response shapes.
///
/// This intentionally uses heuristics because each module can return different
/// JSON schemas.
List<Map<String, dynamic>> extractModuleResults(Object? decoded) {
  final rawList = _pickBestList(decoded) ?? const [];
  final out = <Map<String, dynamic>>[];

  for (final item in rawList) {
    if (item is! Map) continue;
    final m = item.cast<String, dynamic>();

    final id = _deepGet(m, const ['id']) ??
        _deepGet(m, const ['malId']) ??
        _deepGet(m, const ['animeId']) ??
        _deepGet(m, const ['releaseId']);

    final name = _extractTitle(m);
    if (name == null || name.trim().isEmpty) continue;

    final url = _stringish(
      m['url'] ?? m['link'] ?? m['href'] ?? _deepGet(m, const ['url']),
    );

    out.add({
      'id': id,
      'name': name.trim(),
      'url': url ?? '',
      'raw': m,
    });
  }

  return out;
}

/// Attempts to JSON-decode [body]. Returns null on failure.
Object? tryJsonDecode(String body) {
  final cleaned = _cleanPossibleJson(body);
  if (cleaned.isEmpty) return null;
  if (cleaned.startsWith('<')) return null;
  try {
    return jsonDecode(cleaned);
  } catch (_) {
    return null;
  }
}

/// Decodes HTTP [bytes] into a string, attempting to respect `charset=` from the
/// response `Content-Type` header.
///
/// Falls back to UTF-8 (allowMalformed) if the charset is missing/unknown.
String decodeHttpBodyBytes(Uint8List bytes, {String? contentTypeHeader}) {
  final contentType = (contentTypeHeader ?? '').toLowerCase();
  final match = RegExp(r'charset\s*=\s*([^\s;]+)').firstMatch(contentType);
  final charset = match?.group(1)?.trim().toLowerCase();

  final encoding =
      (charset == null || charset.isEmpty) ? null : Encoding.getByName(charset);

  if (encoding != null) {
    try {
      return _stripBom(encoding.decode(bytes));
    } catch (_) {
      // Ignore and fall back.
    }
  }

  return _stripBom(utf8.decode(bytes, allowMalformed: true));
}

List<Object?>? _pickBestList(Object? node) {
  // Direct list.
  if (node is List) return node;

  if (node is Map) {
    final map = node.cast<String, dynamic>();

    // Prefer common keys.
    const preferredKeys = [
      'results',
      'items',
      'list',
      'data',
      'animes',
      'anime',
      'releases',
      'content',
      'docs',
    ];

    for (final k in preferredKeys) {
      final v = map[k];
      final list = _firstList(v);
      if (list != null) return list;
    }

    // Sometimes nested: { data: { items: [] } }
    for (final k in preferredKeys) {
      final v = map[k];
      if (v is Map) {
        final list = _pickBestList(v);
        if (list != null) return list;
      }
    }

    // Fallback: first list anywhere.
    return _firstList(map);
  }

  return null;
}

List<Object?>? _firstList(Object? node) {
  if (node is List) return node;
  if (node is Map) {
    for (final v in node.values) {
      final found = _firstList(v);
      if (found != null) return found;
    }
  }
  return null;
}

String? _extractTitle(Map<String, dynamic> m) {
  // Handle title/name fields that can be strings or objects.
  final candidates = <Object?>[
    m['name'],
    m['title'],
    m['ruTitle'],
    m['enTitle'],
    m['russianTitle'],
    m['englishTitle'],
    m['mainTitle'],
    _deepGet(m, const ['name', 'main']),
    _deepGet(m, const ['title', 'main']),
    _deepGet(m, const ['title', 'ru']),
    _deepGet(m, const ['title', 'russian']),
    _deepGet(m, const ['title', 'english']),
    _deepGet(m, const ['title', 'en']),
  ];

  for (final c in candidates) {
    final v = _stringish(c);
    if (v != null && v.trim().isNotEmpty) return v;
  }

  // Special: titles can be a list.
  final titles = m['titles'];
  if (titles is List && titles.isNotEmpty) {
    final v = _stringish(titles.first);
    if (v != null && v.trim().isNotEmpty) return v;
  }

  // Special: { title: { main: ..., english: ..., alternative: ... } }
  final titleObj = m['title'];
  if (titleObj is Map) {
    const keys = ['main', 'ru', 'russian', 'english', 'en', 'romaji', 'alt'];
    for (final k in keys) {
      final v = _stringish(titleObj[k]);
      if (v != null && v.trim().isNotEmpty) return v;
    }
  }

  return null;
}

Object? _deepGet(Map<String, dynamic> m, List<String> path) {
  Object? cur = m;
  for (final key in path) {
    if (cur is Map) {
      cur = cur[key];
    } else {
      return null;
    }
  }
  return cur;
}

String? _stringish(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return null;
}

String _cleanPossibleJson(String s) {
  // Trim leading whitespace to handle responses like "\n\n{...}".
  final trimmedLeft = s.replaceFirst(RegExp(r'^\s+'), '');
  return _stripBom(trimmedLeft);
}

String _stripBom(String s) {
  if (s.isEmpty) return s;
  // U+FEFF BOM.
  return s.codeUnitAt(0) == 0xFEFF ? s.substring(1) : s;
}
