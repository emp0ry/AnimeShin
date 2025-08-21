import 'package:animeshin/repository/sameband/sameband_repository.dart';

import 'watch_types.dart';

/// Map Sameband episodes into AniRelease.
/// Instead of numeric id we keep the source url.
AniRelease mapSameBandRelease(
  List<SamebandEpisode> items,
  String url,
  String? title,
) {
  final episodes = <AniEpisode>[];
  int i = 0;

  for (final item in items) {
    i += 1;

    episodes.add(AniEpisode(
      ordinal: i,
      name: item.title,
      hls480: item.r480?.toString() ?? '',
      hls720: item.r720?.toString() ?? '',
      hls1080: item.r1080?.toString() ?? '',
      duration: item.duration?.inSeconds,
      openingStart: null,
      openingEnd: null,
      endingStart: null,
      endingEnd: null,
      previewSrc: item.poster?.toString() ?? '',
    ));
  }

  episodes.sort((a, b) => a.ordinal.compareTo(b.ordinal));

  return AniRelease(
    id: 0,            // For Sameband we don't use numeric id
    url: url,         // Keep original url
    title: title,
    posterUrl: '',    // Poster can be filled separately if needed
    episodes: episodes,
  );
}
