import 'dart:convert';
import 'package:http/http.dart' as http;

/// Normalizes a title for comparison (strip non [a-z0-9], lowercase).
String normalizeTitle(String title) {
  return title.replaceAll(RegExp(r'[^a-z0-9]'), '').toLowerCase();
}

String toKebabCase(String input) => input
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

class AnilibriaRepository {
  // Base endpoints for the new anilibria.top API
  static const _listBase = 'https://anilibria.top/api/v1/anime/releases/list';
  static const _byAliasBase = 'https://anilibria.top/api/v1/anime/releases';

  /// Builds query parameters for include/exclude lists.
  /// The API expects CSV for both.
  Map<String, String> _withIncludeExclude({
    List<String>? include,
    List<String>? exclude,
  }) {
    final map = <String, String>{};
    if (include != null && include.isNotEmpty) {
      map['include'] = include.join(',');
    }
    if (exclude != null && exclude.isNotEmpty) {
      map['exclude'] = exclude.join(',');
    }
    return map;
  }

  /// Fetch a list of releases by aliases, batching when alias count > [limit].
  ///
  /// Keeps your original behavior. Returns a JSON object like:
  /// { "data": [ ...items from all batches... ] }
  Future<Map<String, dynamic>> fetchListByAliases({
    required List<String> aliases,
    int page = 1,
    int limit = 50,
    List<String>? include,
    List<String>? exclude,
  }) async {
    // Build fixed include/exclude once
    final common = _withIncludeExclude(include: include, exclude: exclude);

    if (aliases.length <= limit) {
      final params = <String, String>{
        'aliases': aliases.join(','),
        'page': '$page',
        'limit': '$limit',
        ...common,
      };

      final uri = Uri.parse(_listBase).replace(queryParameters: params);
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        throw Exception('Failed to load Anilibria list');
      }

      return json.decode(response.body) as Map<String, dynamic>;
    }

    // Batch requests when aliases exceed limit
    final Map<String, dynamic> allResult = {'data': <dynamic>[]};

    for (var i = 0; i < aliases.length; i += limit) {
      final batch = aliases.sublist(
        i,
        i + limit > aliases.length ? aliases.length : i + limit,
      );

      final params = <String, String>{
        'aliases': batch.join(','),
        'page': '$page',
        'limit': '$limit',
        ...common,
      };

      final uri = Uri.parse(_listBase).replace(queryParameters: params);
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        throw Exception('Failed to load Anilibria list');
      }

      final batchResult = json.decode(response.body) as Map<String, dynamic>;
      if (batchResult['data'] is List) {
        (allResult['data'] as List).addAll(batchResult['data']);
      }
    }

    return allResult;
  }

  /// Search for a single alias by english title using aniliberty search.
  ///
  /// NOTE: Kept as-is (uses aniliberty search endpoint) — unchanged behavior.
  Future<String?> searchAliasByEnglishTitle({
    required String englishTitle,
    List<String>? include,
    List<String>? exclude,
  }) async {
    final normalizedQuery = normalizeTitle(englishTitle);

    final params = <String, String>{
      'query': englishTitle,
      // include/exclude are not standard on this endpoint, but we pass-through
      if (include != null && include.isNotEmpty) 'include': include.join(','),
      if (exclude != null && exclude.isNotEmpty) 'exclude': exclude.join(','),
    };

    final uri = Uri.parse(
      'https://aniliberty.top/api/v1/app/search/releases',
    ).replace(queryParameters: params);

    final response = await http.get(uri);
    if (response.statusCode != 200) return null;

    final list = json.decode(response.body) as List<dynamic>;
    for (final item in list) {
      final name = item['name'] as Map<String, dynamic>;
      final english = normalizeTitle((name['english'] ?? '').toString());
      final alternative = normalizeTitle((name['alternative'] ?? '').toString());
      if (english == normalizedQuery || alternative == normalizedQuery) {
        return item['alias'] as String?;
      }
    }
    return null;
  }

  /// Fetch single release by alias from anilibria.top
  ///
  /// Endpoint shape:
  ///   GET https://anilibria.top/api/v1/anime/releases/{alias}?include=..&exclude=..
  ///
  /// Returns the decoded JSON (usually a map with fields like "name", "episodes", etc.)
  /// or null if not found (404).
  Future<Map<String, dynamic>?> fetchByAlias({
    required String alias,
    List<String>? include,
    List<String>? exclude,
  }) async {
    // Build URL like /anime/releases/{alias}
    final base = '$_byAliasBase/$alias';
    final params = _withIncludeExclude(include: include, exclude: exclude);
    final uri = Uri.parse(base).replace(queryParameters: params);

    final response = await http.get(uri);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw Exception('Failed to load Anilibria release for alias: $alias');
    }

    final body = json.decode(response.body);
    if (body is Map<String, dynamic>) return body;
    return null;
  }

  /// Convenience helper to fetch only the last episode ordinal for an alias.
  ///
  /// Returns the `ordinal` of the last episode if available, otherwise null.
  Future<int?> fetchLastEpisodeOrdinal(String alias) async {
    final data = await fetchByAlias(
      alias: alias,
      // We only need "episodes.ordinal" to keep the payload light
      include: const ['episodes.ordinal'],
    );
    if (data == null) return null;

    final episodes = data['episodes'];
    if (episodes is List && episodes.isNotEmpty) {
      final last = episodes.last;
      if (last is Map && last['ordinal'] is int) {
        return last['ordinal'] as int;
      }
    }
    return null;
  }
}