import 'package:shared_preferences/shared_preferences.dart';

/// Saves playback position per (alias, ordinal) pair.
/// Key: "pb:<alias>:<ordinal>" -> int seconds
class PlaybackStore {
  const PlaybackStore();

  String _key(String alias, int ordinal) => 'pb:$alias:$ordinal';

  Future<void> save(String alias, int ordinal, int seconds) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_key(alias, ordinal), seconds);
  }

  Future<int?> read(String alias, int ordinal) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getInt(_key(alias, ordinal));
  }

  Future<void> clearEpisode(String alias, int ordinal) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_key(alias, ordinal));
  }
}
