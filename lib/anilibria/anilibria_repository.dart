import 'dart:convert';
import 'package:http/http.dart' as http;

class AnilibriaRepository {
  static const _baseUrl = 'https://anilibria.top/api/v1/anime/releases/list';

  Future<Map<String, dynamic>> fetchListByAliases({
    required List<String> aliases,
    int page = 1,
    int limit = 10,
    List<String>? include,
    List<String>? exclude,
  }) async {
    final params = <String, String>{
      'aliases': aliases.join(','),
      'page': '$page',
      'limit': '$limit',
    };

    if (include != null && include.isNotEmpty) {
      params['include'] = include.join(',');
    }
    if (exclude != null && exclude.isNotEmpty) {
      params['exclude'] = exclude.join(',');
    }

    final uri = Uri.parse(_baseUrl).replace(queryParameters: params);

    // print('DEBUG: uri for Anilibria: $uri');

    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception('Failed to load Anilibria list');
    }

    return json.decode(response.body) as Map<String, dynamic>;
  }
}
