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
  // --- iOS native player channel (used only when user taps "iOS Player") -----
  static const MethodChannel _iosNativePlayer = MethodChannel('native_ios_player');

  // --- Media ------------------------------------------------------------------
  late final Player _player;
  late final VideoController _video;

  // Context from inside the controls subtree (required by media_kit fullscreen helpers).
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

  void _log(String msg) {
    // Scoped log with page identity for easier tracing across rebuilds.
    debugPrint('[PlayerPage#${identityHashCode(this)} @${DateTime.now().toIso8601String()}] $msg');
  }

  // Safe setState: ignore updates when widget is unmounted or we're navigating away.
  void _safeSetState(VoidCallback fn) {
    if (!mounted || _navigatingAway) return;
    setState(fn);
  }

  void _detachListeners() {
    _subPos?.cancel(); _subPos = null;
    _subCompleted?.cancel(); _subCompleted = null;
    _subRate?.cancel(); _subRate = null;
    _autosaveTimer?.cancel(); _autosaveTimer = null;
    _bannerTimer?.cancel(); _bannerTimer = null;
  }

  Future<void> _enterNativeFullscreen() async {
    try {
      if (_isDesktop) {
        await windowManager.setFullScreen(true);
      } else {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    } catch (_) {}
  }

  Future<void> _exitNativeFullscreen() async {
    try {
      if (_isDesktop) {
        await windowManager.setFullScreen(false);
      } else {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    } catch (_) {}
  }

  bool get _libIsFullscreen => _controlsCtx != null && isFullscreen(_controlsCtx!);

  // ---------- Lifecycle ----------

  @override
  void initState() {
    super.initState();

    // Choose a sane VO per platform.
    final vo = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'gpu',
      TargetPlatform.iOS     => 'gpu',
      TargetPlatform.windows ||
      TargetPlatform.linux  ||
      TargetPlatform.macOS   => 'gpu',
      _                      => 'null',
    };

    _player = Player(configuration: PlayerConfiguration(vo: vo));
    _video = VideoController(_player);

    // iOS: listen to callbacks from native AVPlayerViewController.
    _iosNativePlayer.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'ios_player_dismissed': {
          // Native AVPlayer was closed; sync position/rate back to our player.
          final args = (call.arguments as Map?) ?? const {};
          final double pos = (args['position'] as num?)?.toDouble() ?? 0.0;
          final double rate = (args['rate'] as num?)?.toDouble() ?? 1.0;
          final bool wasPlaying = (args['wasPlaying'] as bool?) ?? true;
          try {
            await _player.seek(Duration(milliseconds: (pos * 1000).round()));
            await _player.setRate(rate);
            if (wasPlaying) {
              await _player.play();
            }
          } catch (_) {}
          break;
        }
        case 'ios_player_completed': {
          // Native reached the end; just return to our player (no native-next).
          await _saveProgress(clearIfCompleted: true);
          if (_autoNextEpisode) {
            // We open the next inside our Flutter player (not native).
            unawaited(_openNextEpisode());
          } else {
            _showBanner('Completed');
          }
          break;
        }
        default:
          break;
      }
    });

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
            unawaited(() async {
              await _openAt(newUrl, position: pos, play: wasPlaying);
              await _player.setRate(_speed);
            }());
          }
        }
      },
      fireImmediately: true,
    );

    _init();
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

    _autosaveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());

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
      await _playback.save(widget.args.alias, widget.args.ordinal, pos.inSeconds);
    }
  }

  // ---------- Media helpers ----------

  Future<void> _openAt(
    String url, {
    required Duration position,
    required bool play,
  }) async {
    await _player.open(Media(url), play: play);

    // Wait a bit for duration, then seek.
    final started = DateTime.now();
    while (_player.state.duration == Duration.zero &&
        DateTime.now().difference(started) < const Duration(milliseconds: 2000)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    if (position > Duration.zero) {
      await _player.seek(position);
    }
  }

  Future<void> _changeQuality(String label) async {
    final String? url = switch (label) {
      '1080p' => widget.args.url1080,
      '720p'  => widget.args.url720,
      '480p'  => widget.args.url480,
      _       => _pickUrlForQuality(label),
    };

    if (url == null || url.isEmpty || url == _chosenUrl) return;

    final wasPlaying = _player.state.playing;
    final pos = _player.state.position;

    _chosenUrl = url;
    _currentQuality = label;

    await _openAt(url, position: pos, play: wasPlaying);
    unawaited(ref.read(playerPrefsProvider.notifier).setPreferredQuality(_currentQuality));
    await _player.setRate(_speed);

    _safeSetState(() {});
  }

  // ---------- iOS: present native AVPlayer on explicit user action ----------

  Future<void> _presentIOSNativePlayer() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    if (_chosenUrl == null || _chosenUrl!.isEmpty) return;

    final wasPlaying = _player.state.playing;
    final posSec = _player.state.position.inMilliseconds / 1000.0;

    // Pause Flutter-side playback before handing off.
    await _player.pause();

    final args = <String, dynamic>{
      'url': _chosenUrl!,
      'position': posSec,
      'rate': _speed,
      'title': widget.args.title,
      'openingStart': widget.args.openingStart,
      'openingEnd': widget.args.openingEnd,
      'endingStart': widget.args.endingStart,
      'endingEnd': widget.args.endingEnd,
      'wasPlaying': wasPlaying,
    };

    try {
      await _iosNativePlayer.invokeMethod<void>('present', args);
      // After dismissal, native side will call back 'ios_player_dismissed' with position/rate/wasPlaying.
    } on PlatformException catch (e) {
      _log('iOS native player failed: ${e.code}: ${e.message}');
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
        _skipTo(Duration(seconds: s), Duration(seconds: e), banner: 'Skipped Opening');
        return;
      }
    }

    if (_autoSkipEnding &&
        widget.args.endingStart != null &&
        widget.args.endingEnd != null) {
      final s = widget.args.endingStart! + 1;
      final e = widget.args.endingEnd!;
      if (pos.inSeconds >= s && pos.inSeconds <= s + 5) {
        _skipTo(Duration(seconds: s), Duration(seconds: e), banner: 'Skipped Ending');
        return;
      }
    }
  }

  Future<void> _skipTo(Duration from, Duration to, {required String banner}) async {
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
      _log('exiting only lib fullscreen');
      try { await exitFullscreen(_controlsCtx!); } catch (_) {}
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

      final navigator = Navigator.of(context); // cache before async
      _log('pushReplacement (startFullscreen=$wasFs)...');
      navigator.pushReplacement(
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
      // iOS native player button (explicit "Play in iOS Player")
      if (defaultTargetPlatform == TargetPlatform.iOS)
        Padding(
          padding: const EdgeInsets.only(right: 8.0),
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: _presentIOSNativePlayer,
            icon: const Icon(Icons.ios_share),
            label: const Text('iOS Player'),
          ),
        ),

      // Quality
      PopupMenuButton<String>(
        tooltip: 'Quality',
        onSelected: (q) async {
          unawaited(ref.read(playerPrefsProvider.notifier).setPreferredQuality(q));
          await _changeQuality(q);
        },
        itemBuilder: (_) {
          PopupMenuItem<String> item(String label) => PopupMenuItem<String>(
            value: label,
            child: Row(
              children: [
                if (_currentQuality == label) const Icon(Icons.check, size: 16) else const SizedBox(width: 16),
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
        itemBuilder: (_) => const <double>[0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
            .map<PopupMenuEntry<double>>((s) => PopupMenuItem<double>(value: s, child: Text('${s}x')))
            .toList(),
        child: Row(
          children: [
            const Icon(Icons.speed),
            const SizedBox(width: 6),
            Text('${_speed.toStringAsFixed(_speed == _speed.roundToDouble() ? 0 : 2)}x'),
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
              unawaited(ref.read(playerPrefsProvider.notifier).setAutoSkipOpening(_autoSkipOpening));
              _safeSetState(() {});
            },
            child: const Text('Auto-skip Opening'),
          ),
          CheckedPopupMenuItem<String>(
            value: 'skip_ed',
            checked: _autoSkipEnding,
            onTap: () {
              _autoSkipEnding = !_autoSkipEnding;
              unawaited(ref.read(playerPrefsProvider.notifier).setAutoSkipEnding(_autoSkipEnding));
              _safeSetState(() {});
            },
            child: const Text('Auto-skip Ending'),
          ),
          CheckedPopupMenuItem<String>(
            value: 'auto_next',
            checked: _autoNextEpisode,
            onTap: () {
              _autoNextEpisode = !_autoNextEpisode;
              unawaited(ref.read(playerPrefsProvider.notifier).setAutoNextEpisode(_autoNextEpisode));
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_bannerText, style: const TextStyle(color: Colors.white)),
                    if (_undoSeekFrom != null) ...[
                      const SizedBox(width: 12),
                      TextButton(onPressed: _undoSkip, child: const Text('UNDO')),
                    ],
                  ],
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    // Use PopScope with non-deprecated onPopInvokedWithResult to support predictive back.
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) async {
        // Stop & free the player whenever this route is actually popping.
        if (didPop) {
          await _stopAndRelease();
        } else {
          // If the framework decided not to pop, you may still try a soft pop.
          final nav = Navigator.of(context); // cache nav before any await
          await _stopAndRelease();
          if (mounted) {
            nav.maybePop();
          }
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(widget.args.title),
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          actions: actions,
        ),
        body: Stack(
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
                  _log('controls onReady; startFullscreen=${widget.startFullscreen}, handled=$_startFsHandled');

                  if (widget.startFullscreen && !_startFsHandled) {
                    _startFsHandled = true;
                    WidgetsBinding.instance.endOfFrame.then((_) async {
                      if (!mounted || _navigatingAway) return;
                      final c = _controlsCtx;
                      if (c == null || !c.mounted) return;

                      // On iOS we now keep regular lib fullscreen by default.
                      if (!isFullscreen(c)) {
                        try {
                          await enterFullscreen(c); // lib fullscreen
                          _wasFullscreen = true;
                          await _enterNativeFullscreen();
                          _log('entered fullscreen on new page');
                        } catch (_) {}
                      }
                    });
                  }
                },
              ),
              onEnterFullscreen: () async {
                // Keep regular lib fullscreen on iOS too (native is optional via button).
                _log('onEnterFullscreen() fired (lib)');
                _wasFullscreen = true;
                if (!mounted || _navigatingAway) return;
                await _enterNativeFullscreen();
                _log('native fullscreen requested from onEnterFullscreen()');
              },
              onExitFullscreen: () async {
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
    );
  }

  Future<void> _stopAndRelease() async {
    // Ensure we won't schedule UI updates anymore.
    _navigatingAway = true;
    _detachListeners();
    try {
      await _player.pause();
    } catch (_) {}
    await _saveProgress();
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
    return AdaptiveVideoControls(widget.state);
  }
}
