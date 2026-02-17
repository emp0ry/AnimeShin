import 'dart:convert';
import 'package:http/http.dart' as http;

final russianRegex = RegExp(r'[А-Яа-яЁё]');

// Extract slug from Shikimori URL: /animes/11111-my-hero-academia -> "my-hero-academia"
// or /mangas/12345-some-manga -> "some-manga"
String slugFromShikiUrl(String url) {
  final absolute = url.startsWith('http') ? url : 'https://shikimori.one$url';
  final uri = Uri.parse(absolute);
  if (uri.pathSegments.isEmpty) return '';
  final last = uri.pathSegments.last;         // e.g. "11111-my-hero-academia"
  final dash = last.indexOf('-');
  return dash >= 0 ? last.substring(dash + 1) : last;
}

/// Minimal REST repository for Shikimori search.
/// We use it only as a fallback when we don't have MAL IDs.
class ShikimoriRestRepository {
  static const _base = 'https://shikimori.one';
  final http.Client _client;
  ShikimoriRestRepository({http.Client? client}) : _client = client ?? http.Client();

  /// Search best russian title by text query. Returns both RU title and URL if found.
  /// Uses Shikimori REST:
  ///   - /api/animes?search=...&limit=10
  ///   - /api/mangas?search=...&limit=10
  /// Notes:
  ///   * Response 'url' is relative (e.g. "/animes/56-test"); we convert it to absolute.
  ///   * Picks the best match: exact (case-insensitive) by 'name' or 'russian', else first item.
  Future<({String? ru, String? url})> searchRussianAndUrl(
    String query, {
    required bool ofAnime,
    int limit = 50,           // Shikimori allows up to 50
    bool includeAdult = true, // pass censored=false if you want adult titles too
  }) async {
    final q = query.trim();
    if (q.isEmpty) return (ru: null, url: null);

    final path = ofAnime ? '/api/animes' : '/api/mangas';
    final params = <String, String>{
      'search': q,
      'limit': limit.clamp(1, 50).toString(),
      // 'order': 'ranked',     // optional; default is ok for search
      if (includeAdult) 'censored': 'false', // allow hentai/yaoi/yuri when needed
    };

    final uri = Uri.parse('$_base$path').replace(queryParameters: params);

    final resp = await _client.get(uri, headers: {
      'User-Agent': 'animeshin (app; search russian title)',
      'Accept': 'application/json',
    });

    if (resp.statusCode != 200) {
      return (ru: null, url: null);
    }

    final list = jsonDecode(resp.body);
    if (list is! List || list.isEmpty) return (ru: null, url: null);

    // Try to find best match: exact (case-insensitive) by name or russian
    final lc = q.toLowerCase();
    Map<String, dynamic>? best = list.cast<Map<String, dynamic>?>().firstWhere(
      (m) {
        final name = (m?['name'] ?? '').toString().toLowerCase();
        final ru   = (m?['russian'] ?? '').toString().toLowerCase();
        return name == lc || ru == lc;
      },
      orElse: () => null,
    );

    // Fallback: just take the first result
    best ??= (list.first as Map<String, dynamic>);

    String? ru = (best['russian'] ?? best['name'])?.toString();
    String? url = best['url']?.toString();

    if (url != null && url.isNotEmpty && !url.startsWith('http')) {
      url = '$_base$url';
    }

    if (ru != null && ru.trim().isEmpty) ru = null;

    return (ru: ru, url: url);
  }

  Future<List<String>> searchTitleCandidates(
    String query, {
    required bool ofAnime,
    int limit = 5,
    bool includeAdult = true,
  }) async {
    final q = query.trim();
    if (q.isEmpty || limit <= 0) return const <String>[];

    final path = ofAnime ? '/api/animes' : '/api/mangas';
    final params = <String, String>{
      'search': q,
      'limit': limit.clamp(1, 50).toString(),
      if (includeAdult) 'censored': 'false',
    };
    final uri = Uri.parse('$_base$path').replace(queryParameters: params);

    final resp = await _client.get(
      uri,
      headers: {
        'User-Agent': 'animeshin (app; discover search fallback)',
        'Accept': 'application/json',
      },
    );
    if (resp.statusCode != 200) return const <String>[];

    final raw = jsonDecode(resp.body);
    if (raw is! List || raw.isEmpty) return const <String>[];

    final out = <String>[];
    final seen = <String>{};

    void addCandidate(dynamic value) {
      if (out.length >= limit) return;
      final t = value?.toString().trim();
      if (t == null || t.isEmpty) return;
      final key = t.toLowerCase();
      if (!seen.add(key)) return;
      out.add(t);
    }

    for (final item in raw) {
      if (out.length >= limit) break;
      if (item is! Map) continue;
      addCandidate(item['name']);
      addCandidate(item['russian']);
    }

    return out;
  }

  Future<Map<String, dynamic>?> fetchByMalId(int malId, {required bool ofAnime}) async {
    final endpoint = ofAnime ? 'animes' : 'mangas';
    final uri = Uri.parse('https://shikimori.one/api/$endpoint?ids=$malId&limit=1');
    final res = await _client.get(uri, headers: {
      'User-Agent': 'animeshin (app; search russian title)',
      'Accept': 'application/json',
    });

    if (res.statusCode == 200) {
      final list = jsonDecode(res.body);
      if (list is List && list.isNotEmpty) {
        return list.first as Map<String, dynamic>;
      }
    }
    return null;
  }


  void dispose() {
    _client.close();
  }
}
