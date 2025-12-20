import 'package:animeshin/feature/player/player_config.dart';
import 'package:animeshin/feature/player/player_quality_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlayerQuality.fromLabel', () {
    test('parses known labels case-insensitively', () {
      expect(PlayerQuality.fromLabel('1080p'), PlayerQuality.p1080);
      expect(PlayerQuality.fromLabel('720P'), PlayerQuality.p720);
      expect(PlayerQuality.fromLabel('  480p  '), PlayerQuality.p480);
    });

    test('defaults to 1080p on unknown', () {
      expect(PlayerQuality.fromLabel(null), PlayerQuality.p1080);
      expect(PlayerQuality.fromLabel(''), PlayerQuality.p1080);
      expect(PlayerQuality.fromLabel('nope'), PlayerQuality.p1080);
    });
  });

  group('pickUrlForQuality', () {
    test('picks preferred quality first', () {
      final url = pickUrlForQuality(
        quality: PlayerQuality.p720,
        url1080: 'u1080',
        url720: 'u720',
        url480: 'u480',
      );
      expect(url, 'u720');
    });

    test('falls back in the expected order', () {
      final url = pickUrlForQuality(
        quality: PlayerQuality.p1080,
        url1080: null,
        url720: 'u720',
        url480: 'u480',
      );
      expect(url, 'u720');
    });

    test('treats "null" string and blanks as absent', () {
      final url = pickUrlForQuality(
        quality: PlayerQuality.p1080,
        url1080: '  null  ',
        url720: '   ',
        url480: 'u480',
      );
      expect(url, 'u480');
    });
  });

  group('pickInitialQualityAndUrl', () {
    test('returns preferred quality and chosen url', () {
      final r = pickInitialQualityAndUrl(
        preferredQuality: PlayerQuality.p480,
        url1080: 'u1080',
        url720: 'u720',
        url480: 'u480',
      );
      expect(r.quality, PlayerQuality.p480);
      expect(r.chosenUrl, 'u480');
    });

    test('chosenUrl can be null if nothing is available', () {
      final r = pickInitialQualityAndUrl(
        preferredQuality: PlayerQuality.p480,
        url1080: '  ',
        url720: null,
        url480: 'null',
      );
      expect(r.quality, PlayerQuality.p480);
      expect(r.chosenUrl, isNull);
    });
  });
}
