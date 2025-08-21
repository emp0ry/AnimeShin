// Builder: flattens your Collection and produces Shikimori JSON payloads.
// The ordering mirrors your MAL builder approach (group-by-status, last-added first).

import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/export/shikimori/shiki_exporter.dart';
import 'package:animeshin/feature/export/shikimori/shiki_models.dart';
import 'package:animeshin/feature/export/shikimori/shiki_adapter.dart';

/// Same status grouping order as in your MAL builder:
/// Watching -> Rewatching -> Completed -> Paused -> Dropped -> Planned
List<Entry> _orderedEntries(Collection collection) {
  final Iterable<Entry> all = collection is FullCollection
      ? collection.lists.expand((l) => l.entries)
      : collection.list.entries;

  final by = <String, List<Entry>>{};
  for (final e in all) {
    final k = e.listStatus?.name ?? 'unknown';
    by.putIfAbsent(k, () => []).add(e);
  }

  return [
    ...(by['current']   ?? const <Entry>[]).reversed,
    ...(by['repeating'] ?? const <Entry>[]).reversed,
    ...(by['completed'] ?? const <Entry>[]).reversed,
    ...(by['paused']    ?? const <Entry>[]).reversed,
    ...(by['dropped']   ?? const <Entry>[]).reversed,
    ...(by['planning']  ?? const <Entry>[]).reversed,
  ];
}

/// Build Shikimori JSON from your Collection.
/// Returns null if nothing exportable is found.
ShikiJsonPayload? buildShikiFromCollection({
  required Collection collection,
  required bool ofAnime,
}) {
  // Score format is needed to convert your raw score to /10.
  final scoreFormat = collection.scoreFormat;

  final entries = _orderedEntries(collection);

  if (ofAnime) {
    final items = <ShikiAnimeItem>[];
    for (final e in entries) {
      final it = entryToShikiAnime(e, scoreFormat);
      if (it != null) items.add(it);
    }
    if (items.isEmpty) return null;

    return ShikiExporter.build(
      type: ShikiListType.anime,
      animes: items,
      mangas: const [],
    );
  } else {
    final items = <ShikiMangaItem>[];
    for (final e in entries) {
      final it = entryToShikiManga(e, scoreFormat);
      if (it != null) items.add(it);
    }
    if (items.isEmpty) return null;

    return ShikiExporter.build(
      type: ShikiListType.manga,
      animes: const [],
      mangas: items,
    );
  }
}
