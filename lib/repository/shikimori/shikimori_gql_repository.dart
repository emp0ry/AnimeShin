import 'dart:convert';
import 'package:http/http.dart' as http;

/// Simple Shikimori GraphQL client specialized for batch fetch by MAL IDs.
/// Returns a map: malId -> object { russian, name, url }.
class ShikimoriGqlRepository {
  // Public GQL endpoint per docs.
  static const _endpoint = 'https://shikimori.one/api/graphql';

  final http.Client _client;
  ShikimoriGqlRepository({http.Client? client})
      : _client = client ?? http.Client();

  /// Fetch entities by MAL IDs in chunks (max 50 per request).
  /// - [ofAnime] controls whether to hit `animes` or `mangas`.
  /// - Returns `Map<int, Map>` with fields at least {russian, name, url}.
  Future<Map<int, Map<String, dynamic>>> fetchByMalIdsBatch(
    List<int> malIds, {
    required bool ofAnime,
    int chunkSize = 50,
  }) async {
    final result = <int, Map<String, dynamic>>{};
    if (malIds.isEmpty) return result;

    for (var i = 0; i < malIds.length; i += chunkSize) {
      final chunk = malIds.sublist(i, (i + chunkSize).clamp(0, malIds.length));
      final idsStr = chunk.join(', ');
      final type = ofAnime ? 'animes' : 'mangas';
      // We explicitly set limit to the chunk size to avoid default (=2).
      final query = '''
        query {
          $type(ids: "$idsStr", limit: ${chunk.length}) {
            malId
            name
            russian
            url
          }
        }
      ''';

      final resp = await _client.post(
        Uri.parse(_endpoint),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'query': query}),
      );
      if (resp.statusCode != 200) {
        // You may log/throw here if needed.
        continue;
      }

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final data = json['data'] as Map<String, dynamic>?;
      if (data == null) continue;

      final list = data[type] as List<dynamic>? ?? const [];
      for (final raw in list) {
        final m = raw as Map<String, dynamic>;
        // malId can come as number or string; normalize to int if possible.
        final malRaw = m['malId'];
        final mal =
            (malRaw is int) ? malRaw : int.tryParse(malRaw?.toString() ?? '');
        if (mal == null) continue;

        result[mal] = {
          'russian': m['russian'],
          'name': m['name'],
          'url': m['url'],
        };
      }
    }

    return result;
  }

  /// Optional: call when you know you won't reuse the repository again.
  void dispose() {
    _client.close();
  }
}
