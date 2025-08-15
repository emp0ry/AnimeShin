// TODO: Add "skip" popup buttons if auto-skip is disabled.
// TODO: Remember on windows volume on player

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// media_kit
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// prefs / playback
import 'package:animeshin/feature/player/playback_store.dart';
import 'package:animeshin/feature/player/player_prefs.dart';

// watch types / data
import 'package:animeshin/feature/watch/watch_types.dart';
import 'package:animeshin/feature/watch/anilibria_mapper.dart';
import 'package:animeshin/repository/anilibria/anilibria_repository.dart';

// desktop fullscreen
import 'package:window_manager/window_manager.dart';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({
    super.key,
    required this.args,
    this.startupBannerText,
    this.startFullscreen = false,
  });

  final PlayerArgs args;
  final String? startupBannerText;
  final bool startFullscreen;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  // --- Platform / channels -----------------------------------------------------

  static const MethodChannel _iosNativePlayer =
      MethodChannel('native_ios_player');

  // --- Media -------------------------------------------------------------------

  late final Player _player;
  late final VideoController _video;

  // Fullscreen helpers (media_kit's internal fullscreen needs a controls subtree context).
  BuildContext? _controlsCtx;
  bool _startFsHandled = false;
  bool _wasFullscreen = false;

  // Navigation / lifecycle guards
  bool _navigatingAway = false;

  // Repo / persistence
  final _repo = AnilibriaRepository();
  final _playback = const PlaybackStore();

  // Subs / timers
  StreamSubscription<Duration>? _subPos;
  StreamSubscription<bool>? _subCompleted;
  StreamSubscription<double>? _subRate;

  bool _bannerVisible = false;
  String _bannerText = '';
  Duration? _undoSeekFrom;
  DateTime? _autoSkipBlockedUntil;
  Timer? _bannerTimer;
  Timer? _autosaveTimer;

  // Quality
  String? _chosenUrl;
  String _currentQuality = '1080p';

  // Prefs (cached)
  double _speed = 1.0;
  bool _autoSkipOpening = true;
  bool _autoSkipEnding = true;
  bool _autoNextEpisode = true;

  late ProviderSubscription<PlayerPrefs> _prefsSub;

  // ---------- Platform helpers ----------

  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  void _log(String msg) {
    // Scoped log with page identity for easier tracing across rebuilds.
    debugPrint(
        '[PlayerPage#${identityHashCode(this)} @${DateTime.now().toIso8601String()}] $msg');
  }

  // Safe setState: ignore updates when widget is unmounted or we're navigating away.
  void _safeSetState(VoidCallback fn) {
    if (!mounted || _navigatingAway) return;
    setState(fn);
  }

  void _detachListeners() {
    _subPos?.cancel();
    _subPos = null;
    _subCompleted?.cancel();
    _subCompleted = null;
    _subRate?.cancel();
    _subRate = null;
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    _bannerTimer?.cancel();
    _bannerTimer = null;
  }

  Future<void> _enterNativeFullscreen() async {
    try {
      if (_isDesktop) {
        await windowManager.setFullScreen(true);
      } else if (!_isIOS) {
        // Do not touch SystemChrome on iOS; native VC handles overlays there.
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    } catch (_) {}
  }

  Future<void> _exitNativeFullscreen() async {
    try {
      if (_isDesktop) {
        await windowManager.setFullScreen(false);
      } else if (!_isIOS) {
        // Do not touch SystemChrome on iOS; native VC handles overlays there.
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    } catch (_) {}
  }

  bool get _libIsFullscreen =>
      _controlsCtx != null && isFullscreen(_controlsCtx!);

  // ---------- Lifecycle ----------

  @override
  void initState() {
    super.initState();

    final vo = 'gpu'; // Good default for all platforms incl. iOS/Android/desktop
    _player = Player(configuration: PlayerConfiguration(vo: vo));
    _video = VideoController(_player);

    // Preferences subscription — no awaits inside the callback.
    _prefsSub = ref.listenManual<PlayerPrefs>(
      playerPrefsProvider,
      (prev, next) {
        if (!mounted || _navigatingAway) return;

        _autoSkipOpening = next.autoSkipOpening;
        _autoSkipEnding = next.autoSkipEnding;
        _autoNextEpisode = next.autoNextEpisode;
        _speed = next.speed;
        _safeSetState(() {});

        if (prev?.preferredQuality != next.preferredQuality) {
          final newUrl = _pickUrlForQuality(next.preferredQuality);
          if (newUrl != null && newUrl.isNotEmpty && newUrl != _chosenUrl) {
            final pos = _player.state.position;
            final wasPlaying = _player.state.playing;
            _currentQuality = next.preferredQuality;
            _chosenUrl = newUrl;
            // Re-open on the new URL off the microtask queue.
            unawaited(() async {
              await _openAt(newUrl, position: pos, play: wasPlaying);
              await _player.setRate(_speed);
            }());
          }
        }
      },
      fireImmediately: true,
    );

    // iOS native-player callbacks: sync position/speed back & handle completion.
    _maybeAttachIOSCallbacks();

    _init();
  }

  void _maybeAttachIOSCallbacks() {
    if (!_isIOS) return;
    _iosNativePlayer.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'ios_player_dismissed':
          // User closed native AVPlayer — bring state back to Flutter player.
          final map = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
          final posSec = (map['position'] as num?)?.toDouble() ?? 0.0;
          final rate = (map['rate'] as num?)?.toDouble() ?? _speed;
          final wasPlaying = (map['wasPlaying'] as bool?) ?? true;

          // Seek & match rate; resume only if it was playing in native.
          await _player.seek(Duration(milliseconds: (posSec * 1000).round()));
          await _player.setRate(rate);
          _speed = rate;
          if (wasPlaying) {
            await _player.play();
          }
          _safeSetState(() {});
          break;

        case 'ios_player_completed':
          // AVPlayer reached end. The iOS VC auto-dismisses; we continue flow here.
          await _saveProgress(clearIfCompleted: true);
          if (_autoNextEpisode) {
            unawaited(_openNextEpisode());
          } else {
            _showBanner('Completed');
          }
          break;

        default:
          break;
      }
    });
  }

  @override
  void dispose() {
    _log('dispose() start; _wasFullscreen=$_wasFullscreen, libIsFullscreen=$_libIsFullscreen');
    _navigatingAway = true;
    _prefsSub.close();
    _detachListeners();
    unawaited(_saveProgress());
    _player.dispose();
    _log('dispose() done');
    super.dispose();
  }

  // ---------- Quality helpers ----------

  String? _pickUrlForQuality(String quality) {
    switch (quality) {
      case '1080p':
        return widget.args.url1080 ?? widget.args.url720 ?? widget.args.url480;
      case '720p':
        return widget.args.url720 ?? widget.args.url1080 ?? widget.args.url480;
      case '480p':
        return widget.args.url480 ?? widget.args.url720 ?? widget.args.url1080;
      default:
        return widget.args.url1080 ?? widget.args.url720 ?? widget.args.url480;
    }
  }

  String _pickInitialQualityAndUrl() {
    final pref = ref.read(playerPrefsProvider).preferredQuality;
    final url = _pickUrlForQuality(pref);
    if (url != null && url.isNotEmpty) {
      _chosenUrl = url;
    }
    return pref;
  }

  // ---------- Bootstrap ----------

  Future<void> _init() async {
    await ref.read(playerPrefsProvider.notifier).ready();

    final prefs = ref.read(playerPrefsProvider);
    _speed = prefs.speed;
    _autoSkipOpening = prefs.autoSkipOpening;
    _autoSkipEnding = prefs.autoSkipEnding;
    _autoNextEpisode = prefs.autoNextEpisode;

    _currentQuality = _pickInitialQualityAndUrl();

    if (_chosenUrl == null || _chosenUrl!.isEmpty) {
      _snack('No HLS URL available.');
      return;
    }

    await _openAt(
      _chosenUrl!,
      position: await _restoreSavedPosition(),
      play: true,
    );

    await _player.setRate(_speed);

    _autosaveTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());

    _subPos = _player.stream.position.listen((pos) {
      _maybeAutoSkip(pos);
      _safeSetState(() {});
    });

    _subCompleted = _player.stream.completed.listen((done) {
      if (!done) return;
      unawaited(_saveProgress(clearIfCompleted: true));
      if (_autoNextEpisode) {
        unawaited(_openNextEpisode());
      } else {
        _showBanner('Completed');
      }
    });

    _subRate = _player.stream.rate.listen((r) {
      _speed = r;
      _safeSetState(() {});
      unawaited(ref.read(playerPrefsProvider.notifier).setSpeed(r));
    });

    if (widget.startupBannerText?.isNotEmpty == true) {
      _showBanner(widget.startupBannerText!);
    }
  }

  // ---------- Persistence ----------

  Future<Duration> _restoreSavedPosition() async {
    final saved = await _playback.read(widget.args.alias, widget.args.ordinal);
    if (saved == null || saved <= 0) return Duration.zero;
    return Duration(seconds: saved);
  }

  Future<void> _saveProgress({bool clearIfCompleted = false}) async {
    if (_navigatingAway) return;
    final pos = _player.state.position;
    final dur = _player.state.duration;
    if (dur.inSeconds <= 0) return;

    final isCompleted = pos.inMilliseconds >= (dur.inMilliseconds * 0.98);
    if (clearIfCompleted || isCompleted) {
      await _playback.clearEpisode(widget.args.alias, widget.args.ordinal);
    } else {
      await _playback.save(
          widget.args.alias, widget.args.ordinal, pos.inSeconds);
    }
  }

  // ---------- Media helpers ----------

  Future<void> _openAt(
    String url, {
    required Duration position,
    required bool play,
  }) async {
    await _player.open(Media(url), play: play);

    // Wait for non-zero duration via stream (up to 5s) to avoid early seek on HLS.
    final completer = Completer<void>();
    late final StreamSubscription sub;
    sub = _player.stream.duration.listen((d) {
      if (d > Duration.zero && !completer.isCompleted) {
        completer.complete();
        sub.cancel();
      }
    });
    // Fallback timeout
    unawaited(Future.delayed(const Duration(seconds: 5)).then((_) {
      if (!completer.isCompleted) completer.complete();
    }));
    await completer.future;

    if (position > Duration.zero) {
      await _player.seek(position);
    }
  }

  Future<void> _changeQuality(String label) async {
    final String? url = switch (label) {
      '1080p' => widget.args.url1080,
      '720p' => widget.args.url720,
      '480p' => widget.args.url480,
      _ => _pickUrlForQuality(label),
    };

    if (url == null || url.isEmpty || url == _chosenUrl) return;

    final wasPlaying = _player.state.playing;
    final pos = _player.state.position;

    _chosenUrl = url;
    _currentQuality = label;

    await _openAt(url, position: pos, play: wasPlaying);
    unawaited(ref
        .read(playerPrefsProvider.notifier)
        .setPreferredQuality(_currentQuality));
    await _player.setRate(_speed);

    _safeSetState(() {});
  }

  // ---------- iOS native player button ----------

  Future<void> _presentIOSNativePlayer() async {
    if (!_isIOS) return;
    if (_chosenUrl == null || _chosenUrl!.isEmpty) return;

    // Pause Flutter-side playback before handing off.
    final wasPlaying = _player.state.playing;
    await _player.pause();

    final args = <String, dynamic>{
      'url': _chosenUrl!,
      'position': _player.state.position.inSeconds.toDouble(),
      'rate': _speed,
      'title': widget.args.title,
      // Pass skip ranges so native player can auto-skip as well.
      'openingStart': widget.args.openingStart?.toDouble(),
      'openingEnd': widget.args.openingEnd?.toDouble(),
      'endingStart': widget.args.endingStart?.toDouble(),
      'endingEnd': widget.args.endingEnd?.toDouble(),
      'wasPlaying': wasPlaying,
    };

    try {
      await _iosNativePlayer.invokeMethod<void>('present', args);
      // No further action here; callbacks will sync back on dismiss/completion.
    } on PlatformException catch (e) {
      _log('iOS native player failed: ${e.code}: ${e.message}');
      // Fallback to lib fullscreen if native failed.
      if (_controlsCtx != null && !_libIsFullscreen) {
        try {
          await enterFullscreen(_controlsCtx!);
          _wasFullscreen = true;
        } catch (_) {}
      }
      // Resume playback in Flutter if native failed right away.
      if (wasPlaying) {
        await _player.play();
      }
    }
  }

  // ---------- Auto-skip / next ----------

  void _maybeAutoSkip(Duration pos) {
    final dur = _player.state.duration;
    if (dur == Duration.zero) return;

    if (_autoSkipBlockedUntil != null &&
        DateTime.now().isBefore(_autoSkipBlockedUntil!)) {
      return;
    }

    if (_autoSkipOpening &&
        widget.args.openingStart != null &&
        widget.args.openingEnd != null) {
      final s = widget.args.openingStart! + 1;
      final e = widget.args.openingEnd!;
      if (pos.inSeconds >= s && pos.inSeconds <= s + 5) {
        _skipTo(Duration(seconds: s), Duration(seconds: e),
            banner: 'Skipped Opening');
        return;
      }
    }

    if (_autoSkipEnding &&
        widget.args.endingStart != null &&
        widget.args.endingEnd != null) {
      final s = widget.args.endingStart! + 1;
      final e = widget.args.endingEnd!;
      if (pos.inSeconds >= s && pos.inSeconds <= s + 5) {
        _skipTo(Duration(seconds: s), Duration(seconds: e),
            banner: 'Skipped Ending');
        return;
      }
    }
  }

  Future<void> _skipTo(Duration from, Duration to,
      {required String banner}) async {
    _undoSeekFrom = from;
    await _player.seek(to);
    _showBanner(banner, showUndo: true);
  }

  Future<void> _undoSkip() async {
    if (_undoSeekFrom == null) return;
    await _player.seek(_undoSeekFrom!);
    _undoSeekFrom = null;
    _autoSkipBlockedUntil = DateTime.now().add(const Duration(seconds: 10));
  }

  Future<void> _openNextEpisode() async {
    if (_navigatingAway) return;
    _autoSkipBlockedUntil = null;
    _log('_openNextEpisode() called');

    final wasFs = _wasFullscreen;
    _log('_openNextEpisode(); wasFs=$wasFs');

    if (wasFs && _controlsCtx != null) {
      _log('exiting only lib fullscreen (keep native on)');
      try {
        await exitFullscreen(_controlsCtx!);
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 60));
    }

    try {
      _log('fetching next episode...');
      final raw = await _repo.fetchByAlias(alias: widget.args.alias);
      if (raw == null) {
        _log('fetch returned null, aborting');
        return;
      }
      final rel = mapAniLibriaRelease(raw);

      final nextOrd = widget.args.ordinal + 1;
      final next = rel.episodes.firstWhere(
        (e) => e.ordinal == nextOrd,
        orElse: () => rel.episodes.last,
      );
      _log('current=${widget.args.ordinal}, picked next=${next.ordinal}');

      if (next.ordinal == widget.args.ordinal) {
        _log('no next episode available');
        _showBanner('Next episode not available');
        return;
      }

      if (!mounted) {
        _log('not mounted anymore, aborting');
        return;
      }

      _navigatingAway = true;
      _detachListeners();

      _log('pushReplacement (startFullscreen=$wasFs)...');
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PlayerPage(
            args: PlayerArgs(
              alias: rel.alias,
              ordinal: next.ordinal,
              title: rel.title ?? rel.alias,
              url480: next.hls480,
              url720: next.hls720,
              url1080: next.hls1080,
              duration: next.duration,
              openingStart: next.openingStart,
              openingEnd: next.openingEnd,
              endingStart: next.endingStart,
              endingEnd: next.endingEnd,
            ),
            startupBannerText: 'Now playing: Episode ${next.ordinal}',
            startFullscreen: wasFs,
          ),
        ),
      );
      _log('pushReplacement issued');
    } catch (e, st) {
      _log('failed to open next episode: $e\n$st');
      _navigatingAway = false;
      _showBanner('Failed to open next episode');
    }
  }

  // ---------- Banners ----------

  void _showBanner(
    String text, {
    bool showUndo = false,
    Duration hideAfter = const Duration(seconds: 3),
  }) {
    if (_navigatingAway) return;
    _bannerTimer?.cancel();
    _bannerText = text;
    _bannerVisible = true;
    _safeSetState(() {});
    _bannerTimer = Timer(hideAfter, _hideBanner);
  }

  void _hideBanner() {
    if (!_bannerVisible) return;
    _bannerVisible = false;
    _undoSeekFrom = null;
    _safeSetState(() {});
  }

  // ---------- UI ----------

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[
      // iOS Native Player button (only visible on iOS)
      if (_isIOS)
        IconButton(
          tooltip: 'Open iOS Player',
          icon: const Icon(Icons.play_circle_fill),
          onPressed: _presentIOSNativePlayer,
        ),

      // Quality
      PopupMenuButton<String>(
        tooltip: 'Quality',
        onSelected: (q) async {
          unawaited(
              ref.read(playerPrefsProvider.notifier).setPreferredQuality(q));
          await _changeQuality(q);
        },
        itemBuilder: (_) {
          PopupMenuItem<String> item(String label) => PopupMenuItem<String>(
                value: label,
                child: Row(
                  children: [
                    if (_currentQuality == label)
                      const Icon(Icons.check, size: 16)
                    else
                      const SizedBox(width: 16),
                    const SizedBox(width: 8),
                    Text(label),
                  ],
                ),
              );
          return [item('1080p'), item('720p'), item('480p')];
        },
        child: Row(
          children: [
            const Icon(Icons.high_quality),
            const SizedBox(width: 6),
            Text(_currentQuality),
            const SizedBox(width: 12),
          ],
        ),
      ),

      // Speed
      PopupMenuButton<double>(
        tooltip: 'Speed',
        initialValue: _speed,
        onSelected: (r) async {
          unawaited(ref.read(playerPrefsProvider.notifier).setSpeed(r));
          await _player.setRate(r);
        },
        itemBuilder: (_) => const <double>[
          0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2
        ].map<PopupMenuEntry<double>>(
          (s) => PopupMenuItem<double>(value: s, child: Text('${s}x')),
        ).toList(),
        child: Row(
          children: [
            const Icon(Icons.speed),
            const SizedBox(width: 6),
            Text(
                '${_speed.toStringAsFixed(_speed == _speed.roundToDouble() ? 0 : 2)}x'),
            const SizedBox(width: 12),
          ],
        ),
      ),

      // Preferences toggles
      PopupMenuButton<String>(
        tooltip: 'Preferences',
        onSelected: (_) {},
        itemBuilder: (_) => [
          CheckedPopupMenuItem<String>(
            value: 'skip_op',
            checked: _autoSkipOpening,
            onTap: () {
              _autoSkipOpening = !_autoSkipOpening;
              unawaited(ref
                  .read(playerPrefsProvider.notifier)
                  .setAutoSkipOpening(_autoSkipOpening));
              _safeSetState(() {});
            },
            child: const Text('Auto-skip Opening'),
          ),
          CheckedPopupMenuItem<String>(
            value: 'skip_ed',
            checked: _autoSkipEnding,
            onTap: () {
              _autoSkipEnding = !_autoSkipEnding;
              unawaited(ref
                  .read(playerPrefsProvider.notifier)
                  .setAutoSkipEnding(_autoSkipEnding));
              _safeSetState(() {});
            },
            child: const Text('Auto-skip Ending'),
          ),
          CheckedPopupMenuItem<String>(
            value: 'auto_next',
            checked: _autoNextEpisode,
            onTap: () {
              _autoNextEpisode = !_autoNextEpisode;
              unawaited(ref
                  .read(playerPrefsProvider.notifier)
                  .setAutoNextEpisode(_autoNextEpisode));
              _safeSetState(() {});
            },
            child: const Text('Auto next episode'),
          ),
        ],
        child: const Padding(
          padding: EdgeInsets.only(right: 8),
          child: Icon(Icons.settings),
        ),
      ),
    ];

    final banner = _bannerVisible
        ? Positioned(
            right: 16,
            top: 16,
            child: Material(
              color: Colors.black.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_bannerText,
                        style: const TextStyle(color: Colors.white)),
                    if (_undoSeekFrom != null) ...[
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: _undoSkip,
                        child: const Text('UNDO'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    // Predictive back: use onPopInvokedWithResult (non-deprecated).
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) async {
        // Capture the navigator before the async break:
        final navigator = Navigator.of(context);

        _navigatingAway = true;
        _detachListeners();

        await _player.stop();

        // We do nothing if we have already been hit by the system
        if (didPop) return;

        // Check both State and NavigatorState itself
        if (!mounted || !navigator.mounted) return;

        navigator.maybePop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(widget.args.title),
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          actions: actions,
        ),
        body: Padding(
          padding: _isMobile ? const EdgeInsets.only(bottom: 24) : EdgeInsets.zero,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Use a tiny bridge to get a context INSIDE the controls subtree.
              Video(
                controller: _video,
                controls: (state) => _ControlsCtxBridge(
                  state: state,
                  onReady: (ctx) {
                    if (_navigatingAway) return;
                    _controlsCtx ??= ctx;
                    _log(
                        'controls onReady; startFullscreen=${widget.startFullscreen}, handled=$_startFsHandled');

                    // Start in fullscreen (lib) only for non‑iOS platforms.
                    if (widget.startFullscreen && !_startFsHandled && !_isIOS) {
                      _startFsHandled = true;
                      WidgetsBinding.instance.endOfFrame.then((_) async {
                        if (!mounted || _navigatingAway) return;
                        final c = _controlsCtx;
                        if (c == null || !c.mounted) return;

                        if (!isFullscreen(c)) {
                          try {
                            await enterFullscreen(c); // lib fullscreen
                            _wasFullscreen = true;
                            await _enterNativeFullscreen(); // request native overlays (non‑iOS)
                            _log('entered fullscreen on new page');
                          } catch (_) {}
                        }
                      });
                    }
                  },
                ),
                onEnterFullscreen: () async {
                  // On iOS we use only the native player button; ignore lib fullscreen.
                  if (_isIOS) return;
                  _log('onEnterFullscreen() fired (lib)');
                  _wasFullscreen = true;
                  if (!mounted || _navigatingAway) return;
                  await _enterNativeFullscreen();
                  _log('native fullscreen requested from onEnterFullscreen()');
                },
                onExitFullscreen: () async {
                  if (_isIOS) return;
                  _log('onExitFullscreen() fired (lib)');
                  _wasFullscreen = false;
                  if (!mounted || _navigatingAway) return;
                  await _exitNativeFullscreen();
                  _log('native fullscreen exit requested from onExitFullscreen()');
                },
              ),
              banner,
            ],
          ),
        ),
      ),
    );
  }
}

// A tiny widget that returns default controls AND gives parent a context
// that sits INSIDE the Video controls subtree (so fullscreen helpers work).
class _ControlsCtxBridge extends StatefulWidget {
  const _ControlsCtxBridge({
    required this.state,
    required this.onReady,
  });

  final VideoState state;
  final void Function(BuildContext ctx) onReady;

  @override
  State<_ControlsCtxBridge> createState() => _ControlsCtxBridgeState();
}

class _ControlsCtxBridgeState extends State<_ControlsCtxBridge> {
  bool _notified = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_notified) {
      _notified = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onReady(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // NOTE: If you need to hide the fullscreen button on iOS,
    // switch to custom controls and omit the fullscreen action.
    return AdaptiveVideoControls(widget.state);
  }
}
