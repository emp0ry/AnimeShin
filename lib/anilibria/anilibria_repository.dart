
// lib/anilibria/anilibria_repository.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:animeshin/util/text_utils.dart';

class AnilibriaRepository {
  static const _baseUrl = 'https://anilibria.top/api/v1/anime/releases/list';
  static const _searchUrl = 'https://anilibria.top/api/v1/app/search/releases';

  final Map<String, String?> _aliasCache = {};

  String _cacheKey(String r, String? e) =>
      '${normalizeForCompare(r)}|${normalizeForCompare(e ?? '')}';

  /// Fetch releases by known [aliases]. Automatically chunks the request when [aliases] > [limit].
  Future<Map<String, dynamic>> fetchListByAliases({
    required List<String> aliases,
    int page = 1,
    int limit = 50,
    List<String>? include,
    List<String>? exclude,
  }) async {
    if (aliases.length <= limit) {
      final params = <String, String>{
        'aliases': aliases.join(','),
        'page': '$page',
        'limit': '$limit',
      };
      if (include != null && include.isNotEmpty) params['include'] = include.join(',');
      if (exclude != null && exclude.isNotEmpty) params['exclude'] = exclude.join(',');
      final uri = Uri.parse(_baseUrl).replace(queryParameters: params);
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        throw Exception('Failed to load Anilibria list');
      }
      return json.decode(response.body) as Map<String, dynamic>;
    }

    final Map<String, dynamic> allResult = {'data': <dynamic>[]};
    for (var i = 0; i < aliases.length; i += limit) {
      final batch = aliases.sublist(i, i + limit > aliases.length ? aliases.length : i + limit);
      final params = <String, String>{
        'aliases': batch.join(','),
        'page': '$page',
        'limit': '$limit',
      };
      if (include != null && include.isNotEmpty) params['include'] = include.join(',');
      if (exclude != null && exclude.isNotEmpty) params['exclude'] = exclude.join(',');
      final uri = Uri.parse(_baseUrl).replace(queryParameters: params);
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final batchResult = json.decode(response.body) as Map<String, dynamic>;
        if (batchResult['data'] is List) {
          allResult['data'].addAll(batchResult['data']);
        }
      }
    }
    return allResult;
  }

  /// Tries to find the best matching alias using both romaji and english titles.
  /// Returns the alias string if a confident match is found, otherwise null.
  Future<String?> searchBestAlias({
    required String romajiTitle,
    String? englishTitle,
    String? fallbackType, // "TV", "Movie", etc. if you have it
    int? fallbackYear,
  }) async {
  final ck = _cacheKey(romajiTitle, englishTitle);
  if (_aliasCache.containsKey(ck)) {
    return _aliasCache[ck];
  }

  final queries = <String>[];
  if (romajiTitle.trim().isNotEmpty) queries.add(romajiTitle);
  if (englishTitle != null && englishTitle.trim().isNotEmpty) queries.add(englishTitle);

    // Extract query signals once
    final qPart = extractNumberAfter(queries.first, ['part', 'season', 'sezon', 'сезон']);
    final qSeason = extractNumberAfter(queries.first, ['season', 'сезон']);
    final qYear = fallbackYear ?? extractYear(queries.first);
    final qKind = fallbackType != null
        ? _kindFromString(fallbackType)
        : classifyKind(queries.first);

    String? bestAlias;
    double bestScore = 0;

    for (final q in queries) {
      final uri = Uri.parse(_searchUrl).replace(queryParameters: {'query': q});
      final resp = await http.get(uri);
      if (resp.statusCode != 200) continue;
      final list = (json.decode(resp.body) as List).cast<Map<String, dynamic>>();
      final normalizedQ = normalizeForCompare(q);

      for (final item in list) {
        final name = (item['name'] as Map<String, dynamic>?) ?? const {};
        final english = (name['english'] ?? '').toString();
        final alternative = (name['alternative'] ?? '').toString();
        final alias = (item['alias'] ?? '').toString();

        // Fast path: exact normalized match
        if (normalizeForCompare(english) == normalizedQ ||
            normalizeForCompare(alternative) == normalizedQ) {
          return alias;
        }

        // Candidate signals
        final cPart = extractNumberAfter('$english $alternative', ['part', 'season', 'sezon', 'сезон']);
        final cSeason = extractNumberAfter('$english $alternative', ['season', 'сезон']);
        final cYear = extractYear('$english $alternative');
        final cKind = classifyKind('$english $alternative');

        // Base score: token overlap
        double score = [
          tokenOverlapScore(q, english),
          tokenOverlapScore(q, alternative),
        ].reduce((a, b) => a > b ? a : b);

        // Boosts (only help)
        if (qYear != null && cYear != null && qYear == cYear) score += 0.10;
        if (qKind != TitleKind.unknown && cKind == qKind) score += 0.10;

        // Part/Season logic — must match if present, or penalize heavily
        final wantPart = qPart ?? qSeason;     // tolerate either wording
        final gotPart  = cPart ?? cSeason;

        if (wantPart != null && gotPart != null) {
          if (wantPart == gotPart) score += 0.25;     // strong confirmation
          else score -= 0.50;                         // different parts → likely wrong
        }

        // If candidate explicitly says "Special"/"Movie" but query looks like TV (or vice versa), penalize
        if (qKind != TitleKind.unknown && cKind != TitleKind.unknown && qKind != cKind) {
          score -= 0.25;
        }

        // Track best
        if (score > bestScore) {
          bestScore = score;
          bestAlias = alias;
        }
      }
    }

    final result = bestScore >= 0.70 ? bestAlias : null;
    _aliasCache[ck] = result;
    return result;

    // Require higher confidence now that we consider parts
    return bestScore >= 0.70 ? bestAlias : null;
  }

  TitleKind _kindFromString(String s) {
    switch (s.toLowerCase()) {
      case 'movie': return TitleKind.movie;
      case 'ova': return TitleKind.ova;
      case 'ona': return TitleKind.ona;
      case 'special': return TitleKind.special;
      case 'tv': return TitleKind.tv;
      default: return TitleKind.unknown;
    }
  }
}
