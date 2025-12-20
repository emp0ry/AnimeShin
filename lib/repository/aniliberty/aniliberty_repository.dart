import 'dart:convert';
import 'package:animeshin/repository/get_valid_url.dart';
import 'package:http/http.dart' as http;

// Primary AniLiberty host plus legacy AniLibria domains still serving the API.
const aniLibertyUrls = [
  'https://aniliberty.top',
  'https://anilibria.top',
  'https://anilibria.wtf',
];

String toKebabCase(String input) => input
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

class AnilibertyRepository {
  // Base endpoints for the AniLiberty API (served on AniLiberty/AniLibria hosts)
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
        throw Exception('Failed to load AniLiberty list');
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
        throw Exception('Failed to load AniLiberty list');
      }

      final batchResult = json.decode(response.body) as Map<String, dynamic>;
      if (batchResult['data'] is List) {
        (allResult['data'] as List).addAll(batchResult['data']);
      }
    }

    return allResult;
  }

  /// Fetch single release by alias from AniLiberty (AniLiberty/AniLibria host)
  ///
  /// Endpoint shape:
  ///   GET https://aniliberty.top/api/v1/anime/releases/{alias}?include=..&exclude=..
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
      throw Exception('Failed to load AniLiberty release for alias: $alias');
    }

    final body = json.decode(response.body);
    if (body is Map<String, dynamic>) return body;
    return null;
  }

}