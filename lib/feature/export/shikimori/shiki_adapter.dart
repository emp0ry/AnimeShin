// Adapters: your Entry -> Shikimori JSON item.
// - Title preference: english > romaji > native > first fallback.
// - Status mapping: AniList ListStatus -> Shikimori keywords.
// - Score mapping: your ScoreFormat -> /10 int.

import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/export/shikimori/shiki_models.dart';
import 'package:animeshin/feature/media/media_models.dart';

/// Pick the best human-facing title for export (english > romaji > native > first).
String _pickPreferredTitle(Entry e) {
  final eng = e.titleEnglish?.trim();
  if (eng != null && eng.isNotEmpty) return eng;

  final rom = e.titleRomaji?.trim();
  if (rom != null && rom.isNotEmpty) return rom;

  final nat = e.titleNative?.trim();
  if (nat != null && nat.isNotEmpty) return nat;

  return e.titles.isNotEmpty ? e.titles.first : 'Unknown';
}

/// Optionally pick a Russian title if you store it somewhere.
/// If you later add `e.titleRussian`, just return it here.
/// For now we keep null to avoid guessing a wrong index in `e.titles`.
String? _pickRussianTitle(Entry e) {
  return e.titleRussian;
}

/// Map AniList ListStatus -> Shikimori status (anime).
String _alStatusToShikiAnime(ListStatus? s) {
  switch (s) {
    case ListStatus.current:   return 'watching';
    case ListStatus.completed: return 'completed';
    case ListStatus.paused:    return 'on_hold';
    case ListStatus.dropped:   return 'dropped';
    case ListStatus.planning:  return 'planned';
    case ListStatus.repeating: return 'rewatching';
    default:                   return 'watching';
  }
}

/// Map AniList ListStatus -> Shikimori status (manga).
String _alStatusToShikiManga(ListStatus? s) {
  switch (s) {
    case ListStatus.current:   return 'reading';
    case ListStatus.completed: return 'completed';
    case ListStatus.paused:    return 'on_hold';
    case ListStatus.dropped:   return 'dropped';
    case ListStatus.planning:  return 'planned';
    case ListStatus.repeating: return 'rereading';
    default:                   return 'reading';
  }
}

/// Convert your score (with selected ScoreFormat) to /10 integer for Shikimori.
int toShikiScore10({
  required ScoreFormat scoreFormat,
  required double rawScore,
}) {
  switch (scoreFormat) {
    case ScoreFormat.point100:       // 0..100
      return (rawScore / 10.0).round().clamp(0, 10);
    case ScoreFormat.point10Decimal: // 0.0..10.0
      return rawScore.round().clamp(0, 10);
    case ScoreFormat.point10:        // 0..10
      return rawScore.round().clamp(0, 10);
    case ScoreFormat.point5:         // 0..5
      return (rawScore * 2).round().clamp(0, 10);
    case ScoreFormat.point3:         // 0..3 (smileys)
      // 0->0, 1->3, 2->7, 3->10.
      return (rawScore * (10.0 / 3.0)).round().clamp(0, 10);
  }
}

/// Entry -> ShikiAnimeItem
ShikiAnimeItem? entryToShikiAnime(Entry e, ScoreFormat format) {
  // Use MAL id as surrogate "target_id"; Shikimori importer can resolve it.
  // If you have native Shikimori id, replace `e.malId` with that.
  if (e.malId == 0) return null;

  return ShikiAnimeItem(
    targetTitle: e.titleShikimoriRomaji ?? '',
    targetTitleRu: e.titleRussian ?? '',
    targetId: e.malId,
    score: toShikiScore10(scoreFormat: format, rawScore: e.score),
    status: _alStatusToShikiAnime(e.listStatus),
    rewatches: e.repeat,
    episodes: e.progress,
    text: e.notes.isEmpty ? null : e.notes,
    isFav: e.isFavorite,
  );
}

/// Entry -> ShikiMangaItem
ShikiMangaItem? entryToShikiManga(Entry e, ScoreFormat format) {
  if (e.malId == 0) return null;

  return ShikiMangaItem(
    targetTitle: _pickPreferredTitle(e),
    targetTitleRu: _pickRussianTitle(e),
    targetId: e.malId,
    score: toShikiScore10(scoreFormat: format, rawScore: e.score),
    status: _alStatusToShikiManga(e.listStatus),
    rewatches: e.repeat,
    volumes: 0,            // you don't store read volumes yet
    chapters: e.progress,  // reading progress for manga
    text: e.notes.isEmpty ? null : e.notes,
  );
}
