import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/notification/notifications_model.dart';
import 'package:animeshin/feature/settings/settings_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Settings parser', () {
    test('ignores unknown list and notification types', () {
      final settings = Settings({
        'mediaListOptions': {
          'scoreFormat': 'POINT_10',
          'rowOrder': 'TITLE',
          'animeList': {
            'advancedScoring': [],
            'customLists': [],
          },
          'mangaList': {
            'customLists': [],
          },
        },
        'options': {
          'disabledListActivity': [
            {'type': 'CURRENT', 'disabled': true},
            {'type': 'NOT_A_REAL_STATUS', 'disabled': true},
            {'type': null, 'disabled': true},
            null,
            7,
          ],
          'notificationOptions': [
            {'type': 'AIRING', 'enabled': true},
            {'type': 'NOT_A_REAL_NOTIFICATION', 'enabled': true},
            {'type': null, 'enabled': true},
            null,
            9,
          ],
        },
      });

      expect(settings.disabledListActivity.length, 1);
      expect(settings.disabledListActivity[ListStatus.current], isTrue);

      expect(settings.notificationOptions.length, 1);
      expect(settings.notificationOptions[NotificationType.airing], isTrue);
    });
  });
}
