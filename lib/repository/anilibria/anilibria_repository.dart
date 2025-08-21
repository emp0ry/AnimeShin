import 'dart:convert';
import 'package:animeshin/repository/get_valid_url.dart';
import 'package:http/http.dart' as http;

const aniLibertyUrls = [
  'https://aniliberty.top',
  'https:/anilibria.top',
  'https://anilibria.wtf',
];

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
  static const _listBase = '/api/v1/anime/releases/list';
  static const _byAliasBase = '/api/v1/anime/releases';

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

      final chosenBase = await pickApiBaseUrl(aniLibertyUrls);
      final uri = Uri.parse(chosenBase!+_listBase).replace(queryParameters: params);
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

      final chosenBase = await pickApiBaseUrl(aniLibertyUrls);
      final uri = Uri.parse(chosenBase!+_listBase).replace(queryParameters: params);
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

  /// Search for a alias by title using aniliberty search.
  Future<String?> searchAliasByTitle({
    required String title,
  }) async {
    final params = <String, String>{
      'query': title,
      'include': 'alias',
    };

    final uri = Uri.parse(
      'https://anilibria.top/api/v1/app/search/releases',
    ).replace(queryParameters: params);

    final response = await http.get(uri);
    if (response.statusCode != 200) return null;

    final list = json.decode(response.body);
    for (final item in list) {
      return item['alias'] as String?;
    }
    return null;
  }

  /// Search AniLiberty by [title] and return a list of maps:
  Future<List<Map<String, dynamic>>> searchByTitle(String title,  List<String>? include, List<String>? exclude, {Map<String, String>? headers}) async {
    final common = _withIncludeExclude(include: include, exclude: exclude);
    
    final params = <String, String>{
      'query': title,
      ...common,
    };

    final uri = Uri.parse(
      'https://anilibria.top/api/v1/app/search/releases',
    ).replace(queryParameters: params);

    final response = await http.get(uri);
    if (response.statusCode != 200) return const [];

      // Decode as UTF-8 to avoid mojibake on Cyrillic titles
      final body = utf8.decode(response.bodyBytes);

      final decoded = json.decode(body);
      if (decoded is! List) return const [];

      // Strongly cast each element to Map<String, dynamic>
      return decoded
          .whereType<Map>() // filter non-maps just in case
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
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
    final chosenBase = await pickApiBaseUrl(aniLibertyUrls);
    final base = '$chosenBase$_byAliasBase/$alias';
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

  Future<Map<String, dynamic>?> fetchById({
    required int id,
    List<String>? include,
    List<String>? exclude,
  }) async {
    // Build URL like /anime/releases/{alias}
    final chosenBase = await pickApiBaseUrl(aniLibertyUrls);
    final base = '$chosenBase$_byAliasBase/$id';
    final params = _withIncludeExclude(include: include, exclude: exclude);
    final uri = Uri.parse(base).replace(queryParameters: params);

    final response = await http.get(uri);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw Exception('Failed to load Anilibria release for id: $id');
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