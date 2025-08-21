import 'package:intl/intl.dart';
import 'package:animeshin/feature/media/media_models.dart'; // MediaFormat, etc.
import 'package:animeshin/feature/export/myanimelist/mal_exporter.dart'; // types above
import 'package:animeshin/feature/collection/collection_models.dart'; // Collection, Entry, etc.

/// Quick date formatter to 'yyyy-MM-dd' or null.
String? _fmtYmd(DateTime? d) =>
    d == null ? null : DateFormat('yyyy-MM-dd').format(d);

/// Convert your double score to MAL 0..10 integer.
/// If score > 10 but <= 100 (AniList /100), scale down.
int _toMalScore10(num score) {
  if (score.isNaN) return 0;
  final s = score.toDouble();
  if (s <= 10.0) return s.round().clamp(0, 10);
  if (s <= 100.0) return (s / 10.0).round().clamp(0, 10);
  // fallback: large values -> reduce to 0..10
  return (s / 10.0).round().clamp(0, 10);
}

/// Map ListStatus → MAL (anime)
String _listStatusToMalAnime(ListStatus? s) {
  switch (s) {
    case ListStatus.current:   return 'Watching';
    case ListStatus.completed: return 'Completed';
    case ListStatus.paused:    return 'On-Hold';
    case ListStatus.dropped:   return 'Dropped';
    case ListStatus.planning:  return 'Plan to Watch';
    case ListStatus.repeating: return 'Watching'; // MAL has separate rewatching flag, not status
    default:                   return 'Watching';
  }
}

/// Map ListStatus → MAL (manga)
String _listStatusToMalManga(ListStatus? s) {
  switch (s) {
    case ListStatus.current:   return 'Reading';
    case ListStatus.completed: return 'Completed';
    case ListStatus.paused:    return 'On-Hold';
    case ListStatus.dropped:   return 'Dropped';
    case ListStatus.planning:  return 'Plan to Read';
    case ListStatus.repeating: return 'Reading';
    default:                   return 'Reading';
  }
}

/// Map your MediaFormat → MAL (anime types)
String _formatToMalAnimeType(MediaFormat? f) {
  switch (f?.value.toUpperCase()) {
    case 'TV':        return 'TV';
    case 'TV_SHORT':  return 'TV';       // MAL has no TV Short; best effort
    case 'OVA':       return 'OVA';
    case 'MOVIE':     return 'Movie';
    case 'SPECIAL':   return 'Special';
    case 'ONA':       return 'ONA';
    case 'MUSIC':     return 'Music';
    default:          return 'Unknown';
  }
}

/// Map your MediaFormat → MAL (manga types)
String _formatToMalMangaType(MediaFormat? f) {
  switch (f?.value.toUpperCase()) {
    case 'MANGA':      return 'Manga';
    case 'NOVEL':
    case 'LIGHT_NOVEL':return 'Novel';
    case 'ONE_SHOT':   return 'One-shot';
    case 'DOUJIN':     return 'Doujinshi';
    case 'MANHWA':     return 'Manhwa';
    case 'MANHUA':     return 'Manhua';
    default:           return 'Unknown';
  }
}

// Small helper to pick best MAL-facing title.
// Priority: english > romaji > native > first of titles > 'Unknown'
String _pickPreferredTitle(Entry e) {
  // prefer explicit fields
  final eng = e.titleEnglish?.trim();
  if (eng != null && eng.isNotEmpty) return eng;

  final rom = e.titleRomaji?.trim();
  if (rom != null && rom.isNotEmpty) return rom;

  final nat = e.titleNative?.trim();
  if (nat != null && nat.isNotEmpty) return nat;

  // fallback to the very first in the list (AniList userPreferred)
  if (e.titles.isNotEmpty) return e.titles.first;

  return 'Unknown';
}

/// Build MAL anime item from your Entry (skip if malId == 0).
MalAnimeItem? entryToMalAnime(Entry e) {
  if (e.malId == 0) return null;

  final title = _pickPreferredTitle(e);
  final isRewatching = e.listStatus == ListStatus.repeating;

  return MalAnimeItem(
    malId: e.malId,
    title: title,
    seriesType: _formatToMalAnimeType(e.format),
    episodesTotal: e.progressMax ?? 0,
    myStatus: _listStatusToMalAnime(e.listStatus),
    myWatchedEpisodes: e.progress,
    myScore: _toMalScore10(e.score),
    myStartDate: _fmtYmd(e.watchStart),
    myFinishDate: _fmtYmd(e.watchEnd),
    myComments: e.notes,
    myRewatching: isRewatching ? 1 : 0,
    myRewatchingEp: 0,
    timesWatched: e.repeat,
    updateOnImport: 1,
  );
}
/// Build MAL manga item from your Entry (skip if malId == 0).
MalMangaItem? entryToMalManga(Entry e) {
  if (e.malId == 0) return null;

  final title = _pickPreferredTitle(e);
  final isRereading = e.listStatus == ListStatus.repeating;

  return MalMangaItem(
    malId: e.malId,
    title: title,
    seriesType: _formatToMalMangaType(e.format),
    chaptersTotal: e.progressMax ?? 0,
    volumesTotal: 0,
    myStatus: _listStatusToMalManga(e.listStatus),
    myReadChapters: e.progress,
    myReadVolumes: 0,
    myScore: _toMalScore10(e.score),
    myStartDate: _fmtYmd(e.watchStart),
    myFinishDate: _fmtYmd(e.watchEnd),
    myComments: e.notes,
    myRereading: isRereading ? 1 : 0,
    myRereadingChap: 0,
    timesRead: e.repeat,
    updateOnImport: 1,
  );
}
