import 'package:intl/intl.dart';
import 'package:animeshin/feature/media/media_models.dart';
import 'package:animeshin/feature/export/myanimelist/mal_exporter.dart';
import 'package:animeshin/feature/collection/collection_models.dart';

String? _fmtYmd(DateTime? d) =>
    d == null ? null : DateFormat('yyyy-MM-dd').format(d);

int _toMalScore10({ required ScoreFormat scoreFormat, required double rawScore }) {
  if (rawScore.isNaN || !rawScore.isFinite) return 0;
  double normalized;
  switch (scoreFormat) {
    case ScoreFormat.point100:       normalized = rawScore / 10.0; break;
    case ScoreFormat.point10Decimal: normalized = rawScore; break;
    case ScoreFormat.point10:        normalized = rawScore; break;
    case ScoreFormat.point5:         normalized = rawScore * 2.0; break;
    case ScoreFormat.point3:         normalized = rawScore * (10.0 / 3.0); break;
  }
  final r = normalized.round();
  if (r < 0) return 0;
  if (r > 10) return 10;
  return r;
}

String _listStatusToMalAnime(ListStatus? s) {
  switch (s) {
    case ListStatus.current:   return 'Watching';
    case ListStatus.completed: return 'Completed';
    case ListStatus.paused:    return 'On-Hold';
    case ListStatus.dropped:   return 'Dropped';
    case ListStatus.planning:  return 'Plan to Watch';
    case ListStatus.repeating: return 'Watching';
    default:                   return 'Watching';
  }
}

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

String _formatToMalAnimeType(MediaFormat? f) {
  switch (f?.value.toUpperCase()) {
    case 'TV': return 'TV';
    case 'TV_SHORT': return 'TV';
    case 'OVA': return 'OVA';
    case 'MOVIE': return 'Movie';
    case 'SPECIAL': return 'Special';
    case 'ONA': return 'ONA';
    case 'MUSIC': return 'Music';
    default: return 'Unknown';
  }
}

String _formatToMalMangaType(MediaFormat? f) {
  switch (f?.value.toUpperCase()) {
    case 'MANGA': return 'Manga';
    case 'NOVEL':
    case 'LIGHT_NOVEL': return 'Novel';
    case 'ONE_SHOT': return 'One-shot';
    case 'DOUJIN': return 'Doujinshi';
    case 'MANHWA': return 'Manhwa';
    case 'MANHUA': return 'Manhua';
    default: return 'Unknown';
  }
}

String _pickPreferredTitle(Entry e) {
  final eng = e.titleEnglish?.trim();
  if (eng != null && eng.isNotEmpty) return eng;
  final rom = e.titleRomaji?.trim();
  if (rom != null && rom.isNotEmpty) return rom;
  final nat = e.titleNative?.trim();
  if (nat != null && nat.isNotEmpty) return nat;
  return e.titles.isNotEmpty ? e.titles.first : 'Unknown';
}

// Keep OPTIONAL positional param for backward compatibility.
// mal_builder now passes the real format so point3 scales correctly.
MalAnimeItem? entryToMalAnime(Entry e, [ScoreFormat format = ScoreFormat.point10]) {
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
    myScore: _toMalScore10(scoreFormat: format, rawScore: e.score),
    myStartDate: _fmtYmd(e.watchStart),
    myFinishDate: _fmtYmd(e.watchEnd),
    myComments: e.notes,
    myRewatching: isRewatching ? 1 : 0,
    myRewatchingEp: 0,
    timesWatched: e.repeat,
    updateOnImport: 1,
  );
}

MalMangaItem? entryToMalManga(Entry e, [ScoreFormat format = ScoreFormat.point10]) {
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
    myScore: _toMalScore10(scoreFormat: format, rawScore: e.score),
    myStartDate: _fmtYmd(e.watchStart),
    myFinishDate: _fmtYmd(e.watchEnd),
    myComments: e.notes,
    myRereading: isRereading ? 1 : 0,
    myRereadingChap: 0,
    timesRead: e.repeat,
    updateOnImport: 1,
  );
}