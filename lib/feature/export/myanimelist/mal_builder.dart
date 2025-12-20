import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/export/myanimelist/mal_exporter.dart';
import 'package:animeshin/feature/export/myanimelist/mal_adapter.dart';

List<Entry> _orderedEntries(Collection collection) {
  final Iterable<Entry> allEntries = switch (collection) {
    FullCollection c   => c.lists.expand((l) => l.entries),
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

MalXmlPayload? buildMalFromCollection({
  required Collection collection,
  required String username,
  required bool ofAnime,
}) {
  // Use the actual score format from the collection
  final scoreFormat = collection.scoreFormat;

  final entries = _orderedEntries(collection);

  if (ofAnime) {
    final items = <MalAnimeItem>[];
    for (final e in entries) {
      // <-- pass scoreFormat so point3 maps 0→0, 1→3, 2→7, 3→10
      final m = entryToMalAnime(e, scoreFormat);
      if (m != null) items.add(m);
    }
    if (items.isEmpty) return null;

    return MalXmlExporter.build(
      listType: MalListType.anime,
      username: username,
      animeItems: items,
      appName: 'AnimeShin',
    );
  } else {
    final items = <MalMangaItem>[];
    for (final e in entries) {
      // same for manga
      final m = entryToMalManga(e, scoreFormat);
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