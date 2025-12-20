import 'package:animeshin/util/module_loader/module_search_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('module_search_utils', () {
    test('buildModuleSearchUrl replaces %s and encodes query', () {
      final url = buildModuleSearchUrl(
        'https://api.example.com/search?q=%s',
        'Soul Land 2',
      );
      expect(url, 'https://api.example.com/search?q=Soul%20Land%202');
    });

    test('extractModuleResults handles title map shapes', () {
      final decoded = {
        'results': [
          {
            'id': 1,
            'title': {'main': 'Soul Land 2', 'english': 'Douluo Dalu 2'},
          },
        ],
      };

      final items = extractModuleResults(decoded);
      expect(items, hasLength(1));
      expect(items.first['name'], 'Soul Land 2');
    });

    test('extractModuleResults handles nested items list', () {
      final decoded = {
        'data': {
          'items': [
            {'animeId': 'x', 'name': 'One Piece'},
          ],
        },
      };

      final items = extractModuleResults(decoded);
      expect(items, hasLength(1));
      expect(items.first['name'], 'One Piece');
      expect(items.first['id'], 'x');
    });

    test('tryJsonDecode returns null for non-JSON', () {
      expect(tryJsonDecode('<html>nope</html>'), isNull);
      expect(tryJsonDecode(''), isNull);
    });

    test('tryJsonDecode handles BOM/whitespace', () {
      final decoded = tryJsonDecode('\uFEFF  \n {"ok":true}');
      expect(decoded, isA<Map>());
      expect((decoded as Map)['ok'], true);
    });
  });
}
