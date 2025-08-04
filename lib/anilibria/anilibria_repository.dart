import 'dart:convert';
import 'package:http/http.dart' as http;

class AnilibriaRepository {
  static const _baseUrl = 'https://anilibria.top/api/v1/anime/releases/list';

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

      if (include != null && include.isNotEmpty) {
        params['include'] = include.join(',');
      }
      if (exclude != null && exclude.isNotEmpty) {
        params['exclude'] = exclude.join(',');
      }

      final uri = Uri.parse(_baseUrl).replace(queryParameters: params);

      final response = await http.get(uri);
      if (response.statusCode != 200) {
        throw Exception('Failed to load Anilibria list');
      }

      return json.decode(response.body) as Map<String, dynamic>;
    }

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
      };

      if (include != null && include.isNotEmpty) {
        params['include'] = include.join(',');
      }
      if (exclude != null && exclude.isNotEmpty) {
        params['exclude'] = exclude.join(',');
      }

      final uri = Uri.parse(_baseUrl).replace(queryParameters: params);

      final response = await http.get(uri);
      if (response.statusCode != 200) {
        throw Exception('Failed to load Anilibria list');
      }

      final batchResult = json.decode(response.body) as Map<String, dynamic>;
      if (batchResult['data'] is List) {
        allResult['data'].addAll(batchResult['data']);
      }
    }

    return allResult;
  }
}
