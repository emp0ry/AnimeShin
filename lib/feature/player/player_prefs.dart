import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:animeshin/feature/player/player_config.dart';

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
    required this.autoProgress,
    required this.subtitlesEnabled,
    required this.subtitleFontSize,
    required this.subtitleColor,
    required this.subtitleOutlineSize,
    required this.desktopVolume,
  });

  // Playback
  final double speed; // global playback rate
  final int seekForward;
  final int seekBackward;

  // UX prefs
  final PlayerQuality preferredQuality;
  final bool autoSkipOpening;
  final bool autoSkipEnding;
  final bool autoNextEpisode;
  final bool autoProgress;
  final bool subtitlesEnabled;
  final int subtitleFontSize;
  /// mpv-compatible RGB hex without '#', e.g. "FFFFFF".
  final String subtitleColor;
  /// mpv border size (outline thickness).
  final int subtitleOutlineSize;
  final double desktopVolume;

  PlayerPrefs copyWith({
    double? speed,
    int? seekForward,
    int? seekBackward,
    PlayerQuality? preferredQuality,
    bool? autoSkipOpening,
    bool? autoSkipEnding,
    bool? autoNextEpisode,
    bool? autoProgress,
    bool? subtitlesEnabled,
    int? subtitleFontSize,
    String? subtitleColor,
    int? subtitleOutlineSize,
    double? desktopVolume,
  }) {
    return PlayerPrefs(
      speed: speed ?? this.speed,
      seekForward: seekForward ?? this.seekForward,
      seekBackward: seekBackward ?? this.seekBackward,
      preferredQuality: preferredQuality ?? this.preferredQuality,
      autoSkipOpening: autoSkipOpening ?? this.autoSkipOpening,
      autoSkipEnding: autoSkipEnding ?? this.autoSkipEnding,
      autoNextEpisode: autoNextEpisode ?? this.autoNextEpisode,
      autoProgress: autoProgress ?? this.autoProgress,
      subtitlesEnabled: subtitlesEnabled ?? this.subtitlesEnabled,
      subtitleFontSize: subtitleFontSize ?? this.subtitleFontSize,
      subtitleColor: subtitleColor ?? this.subtitleColor,
      subtitleOutlineSize: subtitleOutlineSize ?? this.subtitleOutlineSize,
      desktopVolume: desktopVolume ?? this.desktopVolume,
    );
  }
}

class PlayerPrefsNotifier extends Notifier<PlayerPrefs> {
  // legacy keys (kept if you already had some of them earlier)
  static const _kSpeed = 'player.speed.v4';
  static const _kSeekFwd = 'player.seek_fwd.v4';
  static const _kSeekBack = 'player.seek_back.v4';
  static const _kPreferredQuality =
      'player.quality.preferred.v4'; // "1080p"|"720p"|"480p"
  static const _kAutoSkipOpening = 'player.auto.skip.opening.v4';
  static const _kAutoSkipEnding = 'player.auto.skip.ending.v4';
  static const _kAutoNextEpisode = 'player.auto.next.episode.v4';
  static const _kAutoProgress = 'player.auto.progress.v4';
  static const _kSubtitlesEnabled = 'player.subtitles.enabled.v4';
  static const _kSubtitleFontSize = 'player.subtitles.font_size.v1';
  static const _kSubtitleColor = 'player.subtitles.color.v1';
  static const _kSubtitleOutlineSize = 'player.subtitles.outline_size.v1';
  static const _kDesktopVolume = 'player.desktop.volume.v4';

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
      preferredQuality: PlayerQuality.p1080,
      autoSkipOpening: true,
      autoSkipEnding: true,
      autoNextEpisode: true,
      autoProgress: true,
      subtitlesEnabled: true,
      subtitleFontSize: 55,
      subtitleColor: 'FFFFFF',
      subtitleOutlineSize: 2,
      desktopVolume: 100.0,
    );
  }

  Future<void> _load() async {
    _sp = await SharedPreferences.getInstance();

    final s = _sp.getDouble(_kSpeed) ?? 1.0;
    final f = _sp.getInt(_kSeekFwd) ?? 5;
    final b = _sp.getInt(_kSeekBack) ?? 5;
    final q = PlayerQuality.fromLabel(_sp.getString(_kPreferredQuality));
    final op = _sp.getBool(_kAutoSkipOpening) ?? true;
    final ed = _sp.getBool(_kAutoSkipEnding) ?? true;
    final nx = _sp.getBool(_kAutoNextEpisode) ?? true;
    final ap = _sp.getBool(_kAutoProgress) ?? true;
    final subs = _sp.getBool(_kSubtitlesEnabled) ?? true;
    final subSize = _sp.getInt(_kSubtitleFontSize) ?? 55;
    final subColor = _sp.getString(_kSubtitleColor) ?? 'FFFFFF';
    final subOutline = _sp.getInt(_kSubtitleOutlineSize) ?? 2;
    final dvl = _sp.getDouble(_kDesktopVolume) ?? 100.0;

    state = PlayerPrefs(
      speed: s,
      seekForward: f,
      seekBackward: b,
      preferredQuality: q,
      autoSkipOpening: op,
      autoSkipEnding: ed,
      autoNextEpisode: nx,
      autoProgress: ap,
      subtitlesEnabled: subs,
      subtitleFontSize: subSize,
      subtitleColor: subColor,
      subtitleOutlineSize: subOutline,
      desktopVolume: dvl,
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

  Future<void> setSeekStepSeconds(int seconds) async {
    final v = seconds.clamp(1, 600);
    state = state.copyWith(seekForward: v, seekBackward: v);
    await _sp.setInt(_kSeekFwd, v);
    await _sp.setInt(_kSeekBack, v);
  }

  // ----- quality & auto-prefs -----

  Future<void> setPreferredQuality(PlayerQuality q) async {
    state = state.copyWith(preferredQuality: q);
    await _sp.setString(_kPreferredQuality, q.label);
  }

  // Back-compat for existing call sites.
  Future<void> setPreferredQualityLabel(String q) =>
      setPreferredQuality(PlayerQuality.fromLabel(q));

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

  Future<void> setAutoProgress(bool v) async {
    state = state.copyWith(autoProgress: v);
    await _sp.setBool(_kAutoProgress, v);
  }

  Future<void> setSubtitlesEnabled(bool v) async {
    state = state.copyWith(subtitlesEnabled: v);
    await _sp.setBool(_kSubtitlesEnabled, v);
  }

  Future<void> setSubtitleFontSize(int v) async {
    final vv = v.clamp(10, 120);
    state = state.copyWith(subtitleFontSize: vv);
    await _sp.setInt(_kSubtitleFontSize, vv);
  }

  Future<void> setSubtitleColor(String rgbHexNoHash) async {
    final cleaned = rgbHexNoHash.trim().toUpperCase();
    if (cleaned.length != 6) return;
    state = state.copyWith(subtitleColor: cleaned);
    await _sp.setString(_kSubtitleColor, cleaned);
  }

  Future<void> setSubtitleOutlineSize(int v) async {
    final vv = v.clamp(0, 10);
    state = state.copyWith(subtitleOutlineSize: vv);
    await _sp.setInt(_kSubtitleOutlineSize, vv);
  }

  Future<void> setDesktopVolume(double v) async {
    state = state.copyWith(desktopVolume: v);
    await _sp.setDouble(_kDesktopVolume, v);
  }
}

final playerPrefsProvider =
    NotifierProvider<PlayerPrefsNotifier, PlayerPrefs>(PlayerPrefsNotifier.new);
