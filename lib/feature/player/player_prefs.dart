import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Global player preferences persisted via SharedPreferences.
class PlayerPrefs {
  const PlayerPrefs({
    required this.speed,
    required this.seekForward,
    required this.seekBackward,
    required this.preferredQuality,
    required this.autoSkipOpening,
    required this.autoSkipEnding,
    required this.autoNextEpisode,
  });

  // Playback
  final double speed; // global playback rate
  final int seekForward;
  final int seekBackward;

  // UX prefs
  final String preferredQuality; // "1080p" | "720p" | "480p"
  final bool autoSkipOpening;
  final bool autoSkipEnding;
  final bool autoNextEpisode;

  PlayerPrefs copyWith({
    double? speed,
    int? seekForward,
    int? seekBackward,
    String? preferredQuality,
    bool? autoSkipOpening,
    bool? autoSkipEnding,
    bool? autoNextEpisode,
  }) {
    return PlayerPrefs(
      speed: speed ?? this.speed,
      seekForward: seekForward ?? this.seekForward,
      seekBackward: seekBackward ?? this.seekBackward,
      preferredQuality: preferredQuality ?? this.preferredQuality,
      autoSkipOpening: autoSkipOpening ?? this.autoSkipOpening,
      autoSkipEnding: autoSkipEnding ?? this.autoSkipEnding,
      autoNextEpisode: autoNextEpisode ?? this.autoNextEpisode,
    );
  }
}

class PlayerPrefsNotifier extends Notifier<PlayerPrefs> {
  // legacy keys (kept if you already had some of them earlier)
  static const _kSpeed = 'player.speed.v3';
  static const _kSeekFwd = 'player.seek_fwd.v3';
  static const _kSeekBack = 'player.seek_back.v3';
  static const _kPreferredQuality = 'player.quality.preferred.v3'; // "1080p"|"720p"|"480p"
  static const _kAutoSkipOpening = 'player.auto.skip.opening.v3';
  static const _kAutoSkipEnding = 'player.auto.skip.ending.v3';
  static const _kAutoNextEpisode = 'player.auto.next.episode.v3';

  late SharedPreferences _sp;

  final Completer<void> _loaded = Completer<void>();
  Future<void> ready() => _loaded.future;

  @override
  PlayerPrefs build() {
    // return defaults immediately; then async _load() will patch state.
    _load();
    return const PlayerPrefs(
      speed: 1.0,
      seekForward: 5,
      seekBackward: 5,
      preferredQuality: '1080p',
      autoSkipOpening: true,
      autoSkipEnding: true,
      autoNextEpisode: true,
    );
  }

  Future<void> _load() async {
    _sp = await SharedPreferences.getInstance();

    final s = _sp.getDouble(_kSpeed) ?? 1.0;
    final f = _sp.getInt(_kSeekFwd) ?? 5;
    final b = _sp.getInt(_kSeekBack) ?? 5;
    final q = _sp.getString(_kPreferredQuality) ?? '1080p';
    final op = _sp.getBool(_kAutoSkipOpening) ?? true;
    final ed = _sp.getBool(_kAutoSkipEnding) ?? true;
    final nx = _sp.getBool(_kAutoNextEpisode) ?? true;

    state = PlayerPrefs(
      speed: s,
      seekForward: f,
      seekBackward: b,
      preferredQuality: q,
      autoSkipOpening: op,
      autoSkipEnding: ed,
      autoNextEpisode: nx,
    );

    if (!_loaded.isCompleted) _loaded.complete();
  }

  // ----- playback -----

  Future<void> setSpeed(double v) async {
    state = state.copyWith(speed: v);
    await _sp.setDouble(_kSpeed, v);
  }

  Future<void> setSeekForward(int v) async {
    state = state.copyWith(seekForward: v);
    await _sp.setInt(_kSeekFwd, v);
  }

  Future<void> setSeekBackward(int v) async {
    state = state.copyWith(seekBackward: v);
    await _sp.setInt(_kSeekBack, v);
  }

  // ----- quality & auto-prefs -----

  Future<void> setPreferredQuality(String q) async {
    // sanitize input
    const allowed = {'1080p', '720p', '480p'};
    final value = allowed.contains(q) ? q : '1080p';
    state = state.copyWith(preferredQuality: value);
    await _sp.setString(_kPreferredQuality, value);
  }

  Future<void> setAutoSkipOpening(bool v) async {
    state = state.copyWith(autoSkipOpening: v);
    await _sp.setBool(_kAutoSkipOpening, v);
  }

  Future<void> setAutoSkipEnding(bool v) async {
    state = state.copyWith(autoSkipEnding: v);
    await _sp.setBool(_kAutoSkipEnding, v);
  }

  Future<void> setAutoNextEpisode(bool v) async {
    state = state.copyWith(autoNextEpisode: v);
    await _sp.setBool(_kAutoNextEpisode, v);
  }
}

final playerPrefsProvider =
    NotifierProvider<PlayerPrefsNotifier, PlayerPrefs>(PlayerPrefsNotifier.new);
