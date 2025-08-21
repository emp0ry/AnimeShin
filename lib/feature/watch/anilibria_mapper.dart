import 'watch_types.dart';

/// Map Anilibria REST v1 release json to our models.
/// Expected shape is the full object from /api/v1/anime/releases/{alias}
AniRelease mapAniLibriaRelease(Map<String, dynamic> json) {
  String abs_(String base, String path) {
    if (path.startsWith('http')) return path;
    if (!base.endsWith('/')) base = '$base/';
    if (path.startsWith('/')) path = path.substring(1);
    return '$base$path';
  }

  String? readTitle(Map<String, dynamic> map) {
    final name = map['name'];
    if (name is Map && name['main'] is String && (name['main'] as String).trim().isNotEmpty) {
      return name['main'] as String;
    }
    if (name is Map && name['english'] is String && (name['english'] as String).trim().isNotEmpty) {
      return name['english'] as String;
    }
    return null;
  }

  final id = (json['id'] as num?)?.toInt() ?? 0;
  // final alias = (json['alias'] ?? '').toString();
  final title = readTitle(json);

  String? posterUrl;
  final poster = json['poster'];
  if (poster is Map) {
    final optimized = poster['optimized'];
    final posterMap = optimized is Map ? optimized : poster;
    if (posterMap['src'] is String) {
      posterUrl = abs_('https://anilibria.top', posterMap['src'] as String);
    }
  }

  final episodesJson = (json['episodes'] as List? ?? const []);
  final episodes = <AniEpisode>[];
  for (final item in episodesJson) {
    if (item is! Map) continue;

    int? int_(dynamic x) {
      if (x == null) return null;
      if (x is num) return x.toInt();
      if (x is String) return int.tryParse(x);
      return null;
    }

    // Per-episode preview image
    String? previewSrc;
    final preview = item['preview'];
    if (preview is Map) {
      final optimized = preview['optimized'];
      final previewMap = optimized is Map ? optimized : preview;
      if (previewMap['src'] is String) {
        previewSrc = abs_('https://anilibria.top', previewMap['src'] as String);
      }
    }

    episodes.add(AniEpisode(
      // id: (item['id'] ?? '').toString(),
      ordinal: int_(item['ordinal']) ?? 0,
      name: (item['name'] as String?)?.trim(),
      hls480: (item['hls_480'] as String?)?.trim(),
      hls720: (item['hls_720'] as String?)?.trim(),
      hls1080: (item['hls_1080'] as String?)?.trim(),
      duration: int_(item['duration']),
      openingStart: int_((item['opening'] as Map?)?['start']),
      openingEnd: int_((item['opening'] as Map?)?['stop']),
      endingStart: int_((item['ending'] as Map?)?['start']),
      endingEnd: int_((item['ending'] as Map?)?['stop']),
      previewSrc: previewSrc,
    ));
  }

  episodes.sort((a, b) => a.ordinal.compareTo(b.ordinal));

  return AniRelease(
    id: id,
    url: '',
    title: title,
    posterUrl: posterUrl,
    episodes: episodes,
  );
}
