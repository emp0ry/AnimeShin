import 'package:animeshin/feature/watch/watch_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Saves playback position per (id, ordinal) pair.
/// Key: "pb:<id>:<ordinal>" -> int seconds
class PlaybackStore {
  const PlaybackStore();

  String _key(AnimeVoice animeVoice, int id, int ordinal) => 'pb:$animeVoice:$id:$ordinal';

  Future<void> save(AnimeVoice animeVoice, int id, int ordinal, int seconds) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_key(animeVoice, id, ordinal), seconds);
  }

  Future<int?> read(AnimeVoice animeVoice, int id, int ordinal) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getInt(_key(animeVoice, id, ordinal));
  }

  Future<void> clearEpisode(AnimeVoice animeVoice, int id, int ordinal) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_key(animeVoice, id, ordinal));
  }
}
