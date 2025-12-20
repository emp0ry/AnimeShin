import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum MangaReaderMode {
  webScroll,
  tapScroll,
  book;

  static MangaReaderMode fromString(String? v) {
    switch ((v ?? '').trim()) {
      case 'tap':
        return MangaReaderMode.tapScroll;
      case 'book':
        return MangaReaderMode.book;
      case 'web':
      default:
        return MangaReaderMode.webScroll;
    }
  }

  String get value {
    return switch (this) {
      MangaReaderMode.webScroll => 'web',
      MangaReaderMode.tapScroll => 'tap',
      MangaReaderMode.book => 'book',
    };
  }
}

class MangaReaderPrefs {
  const MangaReaderPrefs({
    required this.mode,
    required this.zoom,
    required this.autoProgress,
  });

  final MangaReaderMode mode;
  final double zoom;
  final bool autoProgress;

  MangaReaderPrefs copyWith({
    MangaReaderMode? mode,
    double? zoom,
    bool? autoProgress,
  }) {
    return MangaReaderPrefs(
      mode: mode ?? this.mode,
      zoom: zoom ?? this.zoom,
      autoProgress: autoProgress ?? this.autoProgress,
    );
  }
}

class MangaReaderPrefsNotifier extends Notifier<MangaReaderPrefs> {
  static const _kMode = 'manga.reader.mode.v1';
  static const _kZoom = 'manga.reader.zoom.v1';
  static const _kAutoProgress = 'manga.reader.auto_progress.v1';

  late SharedPreferences _sp;

  final Completer<void> _loaded = Completer<void>();
  Future<void> ready() => _loaded.future;

  @override
  MangaReaderPrefs build() {
    _load();
    return const MangaReaderPrefs(
      mode: MangaReaderMode.webScroll,
      zoom: 1.0,
      autoProgress: true,
    );
  }

  Future<void> _load() async {
    _sp = await SharedPreferences.getInstance();

    final mode = MangaReaderMode.fromString(_sp.getString(_kMode));
    final zoom = (_sp.getDouble(_kZoom) ?? 1.0).clamp(1.0, 5.0);
    final auto = _sp.getBool(_kAutoProgress) ?? true;

    state = MangaReaderPrefs(mode: mode, zoom: zoom, autoProgress: auto);
    if (!_loaded.isCompleted) _loaded.complete();
  }

  Future<void> setMode(MangaReaderMode mode) async {
    state = state.copyWith(mode: mode);
    await _sp.setString(_kMode, mode.value);
  }

  Future<void> setZoom(double zoom) async {
    final z = zoom.clamp(1.0, 5.0);
    state = state.copyWith(zoom: z);
    await _sp.setDouble(_kZoom, z);
  }

  Future<void> setAutoProgress(bool v) async {
    state = state.copyWith(autoProgress: v);
    await _sp.setBool(_kAutoProgress, v);
  }
}

final mangaReaderPrefsProvider =
    NotifierProvider<MangaReaderPrefsNotifier, MangaReaderPrefs>(
  MangaReaderPrefsNotifier.new,
);
