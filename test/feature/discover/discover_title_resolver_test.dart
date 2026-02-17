import 'package:animeshin/feature/discover/discover_model.dart';
import 'package:animeshin/feature/discover/discover_title_resolver.dart';
import 'package:animeshin/feature/viewer/persistence_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DiscoverMediaItem item({
    String primary = 'Primary',
    String? russian,
    String? shikiRomaji,
  }) {
    return DiscoverMediaItem(
      {
        'id': 1,
        'idMal': 11,
        'type': 'ANIME',
        'title': {
          'userPreferred': primary,
          'english': null,
          'romaji': null,
          'native': null,
          'russian': russian,
          'shikimoriRomaji': shikiRomaji,
        },
        'synonyms': const <String>[],
        'coverImage': const {'extraLarge': 'x', 'large': 'x', 'medium': 'x'},
        'format': null,
        'status': null,
        'averageScore': 0,
        'popularity': 0,
        'startDate': const {'year': null},
        'isAdult': false,
        'mediaListEntry': null,
      },
      ImageQuality.high,
    );
  }

  test('ruTitle OFF -> no secondary title', () {
    final media = item(russian: 'Русский');
    expect(
      discoverSecondaryTitle(media, showRussianTitle: false),
      isNull,
    );
  });

  test('ruTitle ON + russian present -> russian secondary', () {
    final media = item(russian: 'Русский');
    expect(
      discoverSecondaryTitle(media, showRussianTitle: true),
      'Русский',
    );
  });

  test('russian missing + shikimori romaji present -> shikimori secondary', () {
    final media = item(shikiRomaji: 'Shiki Romaji');
    expect(
      discoverSecondaryTitle(media, showRussianTitle: true),
      'Shiki Romaji',
    );
  });

  test('secondary equal to primary -> hidden', () {
    final media = item(primary: 'Same Name', russian: ' same name ');
    expect(
      discoverSecondaryTitle(media, showRussianTitle: true),
      isNull,
    );
  });
}
