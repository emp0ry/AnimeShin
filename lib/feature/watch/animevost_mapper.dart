import 'package:animeshin/repository/animevost/animevost_repository.dart';

import 'watch_types.dart';

/// Map AnimeVost REST v1 release json to our models.
/// Expected shape is the full object from /api/v1/anime/releases/{alias}
AniRelease mapAnimeVostRelease(List<AnimeVostEpisode> items, int id, String? title) {
  final episodes = <AniEpisode>[];
  int i = 0;
  for (final item in items) {
    i += 1;

    episodes.add(AniEpisode(
      ordinal: i, // int.parse(item.name.split(' ')[0])
      name: item.name,
      hls480: item.std.toString(),
      hls720: item.hd.toString(),
      hls1080: item.fhd.toString(),
      duration: null,
      openingStart: null,
      openingEnd: null,
      endingStart: null,
      endingEnd: null,
      previewSrc: item.preview.toString(),
    ));
  }

  episodes.sort((a, b) => a.ordinal.compareTo(b.ordinal));

  return AniRelease(
    id: id,
    url: '',
    title: title,
    posterUrl: '',
    episodes: episodes,
  );
}
