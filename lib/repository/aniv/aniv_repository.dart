// aniv_repository.dart
import 'dart:async';
import 'dart:convert';
import 'package:animeshin/repository/anilibria/anilibria_repository.dart';
import 'package:animeshin/repository/get_valid_url.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;

const aniVUrls = [
  'https://animevost.org',
  'https://v9.vost.pw/',
];

/// Normalizes a title for comparison (strip non [a-z0-9], lowercase).
String normalizeTitle(String title) {
  return title.replaceAll(RegExp(r'[^a-z0-9]'), '').toLowerCase();
}

/// Converts any string to a kebab-case slug.
String toKebabCase(String input) => input
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

/// Simple episode model returned by AniV playlist API.
class AniVEpisode {
  final String name;
  final Uri? fhd;
  final Uri? hd;
  final Uri? std;
  final Uri? preview;

  const AniVEpisode({
    required this.name,
    this.fhd,
    this.hd,
    this.std,
    this.preview,
  });

  factory AniVEpisode.fromJson(Map<String, dynamic> j) {
    Uri? _u(String? s) => (s == null || s.isEmpty) ? null : Uri.tryParse(s);
    return AniVEpisode(
      name: (j['name'] ?? '').toString(),
      fhd: _u(j['fhd'] as String?),
      hd: _u(j['hd'] as String?),
      std: _u(j['std'] as String?),
      preview: _u(j['preview'] as String?),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'fhd': fhd?.toString(),
        'hd': hd?.toString(),
        'std': std?.toString(),
        'preview': preview?.toString(),
      };
}

class AniVRepository {
  // Base endpoints
  static final Uri _playlistUrl = Uri.parse('https://api.animevost.org/v1/playlist');

  AniVRepository({
    this.defaultHeaders,
    this.timeout = const Duration(seconds: 20),
    this.userAgent = 'AnimeShin/1.0 (+https://github.com/animeshin) DartHttpClient',
  });

  /// Default headers for all requests (e.g., {'Cookie': 'PHPSESSID=...'}).
  final Map<String, String>? defaultHeaders;

  /// Network timeout used for all requests.
  final Duration timeout;

  /// User-Agent header sent with requests to be a bit more "browser-like".
  final String userAgent;

  /// Builds headers for a specific call, merging defaults and per-call headers.
  Map<String, String> _buildHeaders([Map<String, String>? headers]) {
    final h = <String, String>{
      // 'User-Agent': userAgent,
      // Keep Accept broad to avoid server-side blocks.
      'Accept': 'text/html,application/json;q=0.9,*/*;q=0.8',
    };
    if (defaultHeaders != null) h.addAll(defaultHeaders!);
    if (headers != null) h.addAll(headers);
    return h;
  }

  /// Sends a multipart/form-data POST and returns the raw response body as UTF-8.
  Future<String> _postMultipartText(
    Uri url, {
    required Map<String, String> fields,
    Map<String, String>? headers,
  }) async {
    final req = http.MultipartRequest('POST', url);
    req.headers.addAll(_buildHeaders(headers));
    fields.forEach((k, v) {
      req.fields.putIfAbsent(k, () => v);
    });
    final streamed = await req.send().timeout(timeout);
    final bytes = await streamed.stream.toBytes();
    final body = utf8.decode(bytes);
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw http.ClientException(
        'HTTP ${streamed.statusCode} ${streamed.reasonPhrase ?? ''}',
        url,
      );
    }
    return body;
  }

  /// Sends an application/x-www-form-urlencoded POST and decodes JSON.
  Future<dynamic> _postUrlEncodedJson(
    Uri url, {
    required Map<String, String> fields,
    Map<String, String>? headers,
  }) async {
    final h = _buildHeaders(headers)
      ..putIfAbsent('Content-Type', () => 'application/x-www-form-urlencoded');
    final resp =
        await http.post(url, headers: h, body: fields).timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw http.ClientException(
        'HTTP ${resp.statusCode} ${resp.reasonPhrase ?? ''}',
        url,
      );
    }
    return json.decode(resp.body);
  }

  // ---------------------------------------------------------------------------
  // 1) Search: submit the DLE search form and parse result links
  // ---------------------------------------------------------------------------

  /// Searches AniV by a human-readable [title] and returns found links.
  ///
  /// Server expects a form with:
  ///   do=search, subaction=search, story=<title>
  ///
  /// If the site insists on PHPSESSID, provide it via [headers], e.g.:
  ///   headers: {'Cookie': 'PHPSESSID=...'}
  Future<List<Uri>> searchLinksByTitle(
    String title, {
    Map<String, String>? headers,
  }) async {
    final chosenUrl = await pickApiBaseUrl(aniLibertyUrls);
    final Uri searchUrl = Uri.parse(chosenUrl!);
    // Use multipart first (mirrors your curl); some setups prefer it.
    final html = await _postMultipartText(
      searchUrl,
      headers: headers,
      fields: const {
        'do': 'search',
        'subaction': 'search',
      }..putIfAbsent('story', () => title),
    );

    final doc = html_parser.parse(html);
    // CSS: #dle-content .shortstory .shortstoryHead h2 a
    final nodes = doc
        .querySelectorAll('#dle-content .shortstory .shortstoryHead h2 a');

    final links = <Uri>[];
    for (final a in nodes) {
      final href = a.attributes['href']?.trim();
      if (href == null || href.isEmpty) continue;
      // Convert relative to absolute if needed.
      final uri = Uri.tryParse(href);
      if (uri == null) continue;
      if (uri.hasScheme) {
        links.add(uri);
      } else {
        links.add(searchUrl.resolveUri(uri));
      }
    }
    return links;
  }

  /// Tries to extract numeric ID from an AniV content URL.
  ///
  /// Works with patterns like:
  int? extractIdFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    // Try to match "/<digits>-..." or "/<digits>.html" in the path.
    final m = RegExp(r'/(\d+)(?:[-\.])').firstMatch(uri.path);
    if (m != null) {
      final idStr = m.group(1);
      if (idStr != null) {
        final id = int.tryParse(idStr);
        if (id != null) return id;
      }
    }

    // Fallback: parse last segment for pure digits.
    if (uri.pathSegments.isNotEmpty) {
      final last = uri.pathSegments.last;
      final digits = RegExp(r'^\d+$');
      if (digits.hasMatch(last)) {
        return int.tryParse(last);
      }
      final beforeDot = last.split('.').first;
      final dashPart = beforeDot.split('-').first;
      final id = int.tryParse(dashPart);
      if (id != null) return id;
    }

    return null;
  }

  /// Searches by [title] and returns the first numeric id found, if any.
  Future<int?> searchFirstIdByTitle(
    String title, {
    Map<String, String>? headers,
  }) async {
    final links = await searchLinksByTitle(title, headers: headers);
    for (final u in links) {
      final id = extractIdFromUrl(u.toString());
      if (id != null) return id;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 2) Playlist: hit the official API and parse episodes
  // ---------------------------------------------------------------------------

  /// Fetches the playlist for a given AniV numeric [id].
  /// Returns a list of [AniVEpisode].
  Future<List<AniVEpisode>> fetchPlaylist(
    int id, {
    Map<String, String>? headers,
  }) async {
    // Try x-www-form-urlencoded first (usually fine); if that fails, you can
    // swap to multipart below.
    dynamic jsonBody;
    try {
      jsonBody = await _postUrlEncodedJson(
        _playlistUrl,
        headers: headers,
        fields: {'id': '$id'},
      );
    } on http.ClientException {
      // Fallback to multipart in case the server rejects urlencoded.
      final text = await _postMultipartText(
        _playlistUrl,
        headers: headers,
        fields: {'id': '$id'},
      );
      jsonBody = json.decode(text);
    }

    if (jsonBody is! List) {
      throw StateError('Unexpected playlist payload: ${jsonBody.runtimeType}');
    }

    return jsonBody
        .whereType<Map<String, dynamic>>()
        .map(AniVEpisode.fromJson)
        .toList(growable: false);
  }

  /// Convenience: obtain playlist by a full AniV content [url].
  Future<List<AniVEpisode>> fetchPlaylistByUrl(
    String url, {
    Map<String, String>? headers,
  }) async {
    final id = extractIdFromUrl(url);
    if (id == null) {
      throw ArgumentError.value(url, 'url', 'Cannot extract numeric id');
    }
    return fetchPlaylist(id, headers: headers);
  }

  /// Full flow convenience: search by [title] → take first result → fetch playlist.
  ///
  /// If nothing found, returns empty list (no throw).
  Future<List<AniVEpisode>> fetchPlaylistByTitle(
    String title, {
    Map<String, String>? headers,
  }) async {
    final id = await searchFirstIdByTitle(title, headers: headers);
    if (id == null) return const [];
    return fetchPlaylist(id, headers: headers);
  }

  /// Search AniV by [title] and return a list of maps:
  /// [{"name": ..., "id": ...}, ...]
  Future<List<Map<String, dynamic>>> searchByTitle(String title, {Map<String, String>? headers}) async {
    // Prepare form fields
    final fields = {
      'do': 'search',
      'subaction': 'search',
      'story': title,
    };

    // Send request
    final req = http.MultipartRequest('POST', Uri.parse('https://animevost.org/'));
    req.fields.addAll(fields);
    if (headers != null) req.headers.addAll(headers);

    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();

    // Parse HTML
    final doc = html_parser.parse(body);

    // Extract links
    final nodes = doc.querySelectorAll('#dle-content .shortstory .shortstoryHead h2 a');

    final results = <Map<String, dynamic>>[];
    for (final a in nodes) {
      final url = a.attributes['href']?.trim();
      final name = a.text.trim();
      if (url != null && url.isNotEmpty) {
        final id = extractIdFromUrl(url);
        if (id != null) {
          results.add({
            'name': name,
            'id': id,
          });
        }
      }
    }

    return results;
  }
}
