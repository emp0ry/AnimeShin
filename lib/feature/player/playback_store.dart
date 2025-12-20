import 'package:animeshin/feature/watch/watch_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Saves playback position per (id, ordinal) pair.
/// Key: `pb:{id}:{ordinal}` -> int seconds
/// Key: `pbt:{id}:{ordinal}` -> int epoch millis (last watched)
class PlaybackStore {
  const PlaybackStore();

  String _key(AnimeVoice animeVoice, int id, int ordinal) =>
      'pb:$animeVoice:$id:$ordinal';

  String _tsKey(AnimeVoice animeVoice, int id, int ordinal) =>
      'pbt:$animeVoice:$id:$ordinal';

  static int _nowEpochMs() => DateTime.now().millisecondsSinceEpoch;

  Future<void> saveEntry(
    AnimeVoice animeVoice,
    int id,
    int ordinal, {
    required int seconds,
    int? lastWatchedEpochMs,
  }) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_key(animeVoice, id, ordinal), seconds);
    await sp.setInt(
      _tsKey(animeVoice, id, ordinal),
      lastWatchedEpochMs ?? _nowEpochMs(),
    );
  }

  Future<PlaybackEntry?> readEntry(AnimeVoice animeVoice, int id, int ordinal) async {
    final sp = await SharedPreferences.getInstance();
    final seconds = sp.getInt(_key(animeVoice, id, ordinal));
    if (seconds == null) return null;
    final last = sp.getInt(_tsKey(animeVoice, id, ordinal));
    return PlaybackEntry(
      seconds: seconds,
      lastWatchedEpochMs: last,
    );
  }

  Future<void> save(
      AnimeVoice animeVoice, int id, int ordinal, int seconds) async {
    await saveEntry(animeVoice, id, ordinal, seconds: seconds);
  }

  Future<int?> read(AnimeVoice animeVoice, int id, int ordinal) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getInt(_key(animeVoice, id, ordinal));
  }

  Future<void> clearEpisode(AnimeVoice animeVoice, int id, int ordinal) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_key(animeVoice, id, ordinal));
    await sp.remove(_tsKey(animeVoice, id, ordinal));
  }
}

class PlaybackEntry {
  const PlaybackEntry({required this.seconds, required this.lastWatchedEpochMs});

  final int seconds;
  final int? lastWatchedEpochMs;
}
