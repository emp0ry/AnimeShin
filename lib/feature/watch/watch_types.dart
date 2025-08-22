import 'package:flutter/foundation.dart';

/// Immutable release model used by WatchPage/PlayerPage.
@immutable
class AniRelease {
  const AniRelease({
    required this.id,
    required this.url,
    required this.title,
    required this.posterUrl,
    required this.episodes,
  });

  final int id;
  final String url;
  final String? title;
  final String? posterUrl; // not used for tiles (tiles use episode.preview)
  final List<AniEpisode> episodes;

  AniEpisode? episodeByOrdinal(int ordinal) {
    try {
      return episodes.firstWhere((e) => e.ordinal == ordinal);
    } catch (_) {
      return null;
    }
  }
}

@immutable
class AniEpisode {
  const AniEpisode({
    required this.ordinal,
    required this.name,
    required this.hls480,
    required this.hls720,
    required this.hls1080,
    required this.duration,         // seconds
    required this.openingStart,     // seconds or null
    required this.openingEnd,       // seconds or null
    required this.endingStart,      // seconds or null
    required this.endingEnd,        // seconds or null
    required this.previewSrc,       // absolute url to preview image
  });

  final int ordinal;
  final String? name;
  final String? hls480;
  final String? hls720;
  final String? hls1080;
  final int? duration;
  final int? openingStart;
  final int? openingEnd;
  final int? endingStart;
  final int? endingEnd;
  final String? previewSrc;
}

/// Arguments passed from WatchPage -> PlayerPage.
class PlayerArgs {
  const PlayerArgs({
    required this.id,
    required this.url,
    required this.ordinal,
    required this.title,
    this.url480,
    this.url720,
    this.url1080,
    this.duration,
    this.openingStart,
    this.openingEnd,
    this.endingStart,
    this.endingEnd,
  });

  final int id;
  final String url;
  final int ordinal;
  final String title;

  final String? url480;
  final String? url720;
  final String? url1080;

  /// seconds
  final int? duration;
  final int? openingStart;
  final int? openingEnd;
  final int? endingStart;
  final int? endingEnd;
}

enum AnimeVoice {aniliberty, aniv, sameband}