// Builds MAL XML payloads from your domain objects (Collection + Entry → MAL XML).
// IMPORTANT: For FullCollection we must flatten ALL lists, not just collection.list.

import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/export/myanimelist/mal_exporter.dart';
import 'package:animeshin/feature/export/myanimelist/mal_adapter.dart'; // entryToMalAnime/entryToMalManga

List<Entry> _orderedEntries(Collection collection) {
  final Iterable<Entry> allEntries = switch (collection) {
    FullCollection c => c.lists.expand((l) => l.entries),
    PreviewCollection c => c.list.entries,
  };

  final groups = <String, List<Entry>>{};
  for (final e in allEntries) {
    final key = e.listStatus?.name ?? 'unknown';
    groups.putIfAbsent(key, () => []).add(e);
  }

  return [
    ...(groups['current']   ?? []).reversed,
    ...(groups['repeating'] ?? []).reversed,
    ...(groups['completed'] ?? []).reversed,
    ...(groups['paused']    ?? []).reversed,
    ...(groups['dropped']   ?? []).reversed,
    ...(groups['planning']  ?? []).reversed,
  ];
}

/// Build MAL XML from a Collection. When [ofAnime] is true -> anime list,
/// otherwise -> manga list. Returns null if there are no exportable items.
MalXmlPayload? buildMalFromCollection({
  required Collection collection,
  required String username,
  required bool ofAnime,
}) {
  final entries = _orderedEntries(collection);

  if (ofAnime) {
    final items = <MalAnimeItem>[];
    for (final e in entries) {
      final m = entryToMalAnime(e);
      if (m != null) items.add(m);
    }
    if (items.isEmpty) return null;

    return MalXmlExporter.build(
      listType: MalListType.anime,
      username: username,
      animeItems: items,
      appName: 'AnimeShin', // appVersion comes from persistence_model.dart
    );
  } else {
    final items = <MalMangaItem>[];
    for (final e in entries) {
      final m = entryToMalManga(e);
      if (m != null) items.add(m);
    }
    if (items.isEmpty) return null;

    return MalXmlExporter.build(
      listType: MalListType.manga,
      username: username,
      mangaItems: items,
      appName: 'AnimeShin',
    );
  }
}
