// TODO: Add "skip" popup buttons if auto-skip is disabled.

import 'dart:async';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ionicons/ionicons.dart';

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
import 'package:url_launcher/url_launcher.dart';

// desktop fullscreen
import 'package:window_manager/window_manager.dart';

// === Local HLS Proxy ===
import 'package:animeshin/feature/player/local_hls_proxy.dart';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({
    super.key,
    required this.args,
    required this.item,
    this.startupBannerText,
    this.startFullscreen = false,
  });

  final PlayerArgs args;
  final Entry? item;
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

  // Local HLS proxy
  final LocalHlsProxy _proxy = LocalHlsProxy();
  bool _proxyReady = false; // set true after start()

  // Subs / timers
  StreamSubscription<Duration>? _subPos;
  StreamSubscription<bool>? _subCompleted;
  StreamSubscription<double>? _subRate;
  StreamSubscription<double>? _subVolume; // <- listen volume changes

  bool _bannerVisible = false;
  String _bannerText = '';
  Duration? _undoSeekFrom;
  DateTime? _autoSkipBlockedUntil;
  Timer? _bannerTimer;
  Timer? _autosaveTimer;
  Timer? _volumePersistDebounce; // <- debounce saves to prefs

  // Quality
  String? _chosenUrl; // stores the ORIGINAL remote HLS URL (master or media)
  String _currentQuality = '1080p';

  // Prefs (cached)
  double _speed = 1.0;
  bool _autoSkipOpening = true;
  bool _autoSkipEnding = true;
  bool _autoNextEpisode = true;
  double _desktopVolume = 100.0;

  late ProviderSubscription<PlayerPrefs> _prefsSub;

  // --- Jump detection / logging-only ------------------------------------------

  Duration _lastPos = Duration.zero;
  bool _plannedSeek = false;

  // Left for diagnostics (no corrective actions are taken).
  bool _reopeningGuard = false;
  DateTime? _jumpWindowStartedAt;
  int _consecutiveJumpCount = 0;
  DateTime? _quarantineUntil;

  bool get _inQuarantine =>
      _quarantineUntil != null && DateTime.now().isBefore(_quarantineUntil!);

  // ---------- Platform helpers ----------

  bool get _isDesktop =>
      !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.linux ||
              defaultTargetPlatform == TargetPlatform.macOS);

  bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  bool get _isMobile =>
      !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS);

  bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  // Lifecycle guard flags
  bool _isDisposed = false;

  // Helper: only do player ops while the widget is alive & not navigating away.
  bool get _alive => mounted && !_navigatingAway && !_isDisposed;

  // Cursor overlay control
  final CursorAutoHideController _cursorHideController = CursorAutoHideController();
  OverlayEntry? _cursorOverlayEntry;
  final ValueNotifier<bool> _cursorForceVisible = ValueNotifier<bool>(false);

  // Place near other helpers
  Future<void> _restoreFromIOSDismiss({
    required Duration target,
    required double rate,
    required bool wasPlaying,
  }) async {
    if (!_alive) return;

    // Wait until the player reports either a valid duration or stable positions.
    final settle = Completer<void>();
    late final StreamSubscription subDur;
    late final StreamSubscription subPos;

    bool hasDuration = false;
    int posTicksOver500ms = 0;

    // Safety timeout — don't hang forever.
    final timeout = Future<void>.delayed(const Duration(seconds: 8), () {});

    subDur = _player.stream.duration.listen((d) {
      if (!_alive) {
        if (!settle.isCompleted) settle.complete();
        subDur.cancel();
        return;
      }
      if (d > Duration.zero) {
        hasDuration = true;
        if (!settle.isCompleted) settle.complete();
      }
    });

    subPos = _player.stream.position.listen((p) {
      if (!_alive) {
        if (!settle.isCompleted) settle.complete();
        subPos.cancel();
        return;
      }
      // If duration is still zero, use position ticks heuristic as a fallback.
      if (p > const Duration(milliseconds: 500)) {
        posTicksOver500ms++;
        if (!hasDuration && posTicksOver500ms >= 2 && !settle.isCompleted) {
          settle.complete();
        }
      }
    });

    await Future.any([settle.future, timeout]);
    await subDur.cancel();
    await subPos.cancel();

    if (!_alive) return;

    // Block auto-skip for a short window so we don't immediately jump again.
    _autoSkipBlockedUntil = DateTime.now().add(const Duration(seconds: 3));

    // Do the "double seek" for extra reliability (like in _openAt).
    await _seekPlanned(target, reason: 'ios_dismiss_restore');
    await Future.delayed(const Duration(milliseconds: 80));
    await _seekPlanned(target, reason: 'ios_dismiss_restore_confirm');

    // Re-apply rate (the native VC may have changed it).
    try { await _player.setRate(rate); } catch (_) {}

    // Resume only after we are at the right place.
    if (wasPlaying && _alive) {
      try { await _player.play(); } catch (_) {}
    }
  }

  void _insertCursorOverlayIfNeeded() {
    if (!_isDesktop || _cursorOverlayEntry != null) return;
    final ctx = _controlsCtx;
    if (ctx == null || !ctx.mounted) return;

    final overlay = Overlay.of(ctx);
    if (!overlay.mounted) return;

    _cursorOverlayEntry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: ValueListenableBuilder<bool>(
          valueListenable: _cursorForceVisible,
          builder: (_, force, __) {
            return _CursorAutoHideOverlay(
              idle: const Duration(seconds: 3),
              forceVisible: force,
              controller: _cursorHideController,
            );
          },
        ),
      ),
    );
    // overlay.insert(_cursorOverlayEntry!);

    // // Kick countdown right after insertion
    // _cursorHideController.kick();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _cursorOverlayEntry == null) return;
      try {
        overlay.insert(_cursorOverlayEntry!);
        _cursorHideController.kick();
      } catch (_) {
      }
    });
  }

  void _removeCursorOverlayIfAny() {
    _cursorOverlayEntry?.remove();
    _cursorOverlayEntry = null;
  }

  /// Opens AniLiberty support page in the system browser.
  Future<void> _openSupport() async {
    const url = 'https://anilibria.top/support';
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to open the support page')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to open: $e')),
      );
    }
  }

  void _hideCursorInstant() {
    if (_isDesktop) _cursorHideController.hideNow();
  }

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
    _subVolume?.cancel();
    _subVolume = null;
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    _bannerTimer?.cancel();
    _bannerTimer = null;
    _volumePersistDebounce?.cancel();
    _volumePersistDebounce = null;
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

  // --- mpv property helper (NativePlayer only) --------------------------------
  Future<void> _setMpv(String property, String value) async {
    // IMPORTANT: _player must be constructed before this is called.
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty(property, value);
      } catch (e) {
        _log('setProperty("$property","$value") failed: $e');
      }
    }
  }

  // Place near other helpers
  Future<void> _setVolumeSafe(double v) async {
    // Never call player methods if page is leaving or disposed
    if (!_alive) return;
    try {
      await _player.setVolume(v);
    } catch (e) {
      _log('setVolume skipped (not alive): $e');
    }
  }

  @override
  void initState() {
    super.initState();

    // 1) Create player first. Do NOT call _setMpv() before this point.
    _player = Player(
      configuration: PlayerConfiguration(
        vo: 'gpu',
        title: 'AnimeShin',
        logLevel: MPVLogLevel.error, // keep only error-level from mpv core
        bufferSize: _isWindows ? 128 * 1024 * 1024 : 64 * 1024 * 1024,
        async: _isWindows ? false : true,
      ),
    );
    _video = VideoController(_player);

    // 2) Safe mpv tweaks (HLS host-switch & log filtering).
    unawaited(_setMpv(
      'stream-lavf-o',
      // Keep-alive off + safe reconnects. Avoid multiple_requests here.
      'http_persistent=0:reconnect=1:reconnect_streamed=1:reconnect_on_http_error=4xx,5xx',
    ));
    unawaited(_setMpv('msg-level', 'ffmpeg=error'));

    // Preferences subscription — no awaits inside the callback.
    _prefsSub = ref.listenManual<PlayerPrefs>(
      playerPrefsProvider,
      (prev, next) async {
        if (!mounted || _navigatingAway) return;

        _autoSkipOpening = next.autoSkipOpening;
        _autoSkipEnding = next.autoSkipEnding;
        _autoNextEpisode = next.autoNextEpisode;
        _speed = next.speed;

        // Apply desktop volume from prefs when it changes externally.
        if (_isDesktop) {
          final prevVol = prev?.desktopVolume ?? _desktopVolume;
          _desktopVolume = next.desktopVolume;

          // Bail if player is already gone
          if (!_alive) return;

          // Read current volume only while alive
          final currentVol = _player.state.volume;

          // Update volume only if it actually changed (debounce)
          if ((prevVol - next.desktopVolume).abs() > 0.1 &&
              (currentVol - _desktopVolume).abs() > 0.1) {
            unawaited(_setVolumeSafe(_desktopVolume));
          }
        }

        _safeSetState(() {});

        // If preferred quality changed, reopen at the same position.
        if (prev?.preferredQuality != next.preferredQuality) {
          final newUrl = _pickUrlForQuality(next.preferredQuality);
          if (newUrl != null && newUrl.isNotEmpty && newUrl != _chosenUrl) {
            final pos = _player.state.position;
            final wasPlaying = _player.state.playing;
            _currentQuality = next.preferredQuality;
            _chosenUrl = newUrl;

            // Ensure proxy is running before we generate proxied URL.
            if (!_proxyReady) {
              try {
                await _proxy.start();
                _proxyReady = true;
              } catch (e) {
                _log('proxy start failed in prefs listener: $e');
              }
            }

            final toOpen = _proxyReady
                ? _proxy.playlistUrl(Uri.parse(newUrl)).toString()
                : newUrl;

            unawaited(() async {
              final resume = pos + const Duration(milliseconds: 300);
              await _openAt(toOpen, position: resume, play: wasPlaying);
              if (_isDesktop) {
                await _setVolumeSafe(_desktopVolume);
              }
              if (_alive) {
                try {
                  await _player.setRate(_speed);
                } catch (_) {}
              }
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
          final map = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
          final posSec = (map['position'] as num?)?.toDouble() ?? 0.0;
          final rate = (map['rate'] as num?)?.toDouble() ?? _speed;
          final wasPlaying = (map['wasPlaying'] as bool?) ?? true;

          final target = Duration(milliseconds: (posSec * 1000).round());
          // Keep local speed in sync with the native VC.
          _speed = rate;

          // Mark episode as completed if user exited literally at the end.
          if (_player.state.duration > Duration.zero &&
            target >= _player.state.duration - const Duration(seconds: 1)) {
            unawaited(_saveProgress(clearIfCompleted: true));
          }

          // Robust restore (wait → double seek → rate → resume).
          await _restoreFromIOSDismiss(
            target: target,
            rate: rate,
            wasPlaying: wasPlaying,
          );

          _safeSetState(() {}); // refresh any UI that shows speed/position
          break;

        case 'ios_player_completed':
          await _saveProgress(clearIfCompleted: true);
          if (_autoNextEpisode) {
            _hideCursorInstant();
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
    // Mark as leaving & disposed ASAP so any pending futures bail out.
    _navigatingAway = true;
    _isDisposed = true;

    // Stop timers & streams first.
    _prefsSub.close();
    _detachListeners();
    unawaited(_saveProgress());

    // Stop proxy (safe to call even if not running).
    unawaited(_proxy.stop());

    // Do NOT access player state asynchronously anymore.
    try {
      _player.dispose();
    } catch (_) {}

    // Break reference to now-deactivated controls subtree.
    _controlsCtx = null;

    _removeCursorOverlayIfAny();
    _cursorForceVisible.dispose();

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
      _chosenUrl = url; // store remote (original) URL
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
    _desktopVolume = prefs.desktopVolume;

    _currentQuality = _pickInitialQualityAndUrl();

    if (_chosenUrl == null || _chosenUrl!.isEmpty) {
      _snack('No HLS URL available.');
      return;
    }

    // Start local proxy BEFORE building proxied URL to avoid LateInitializationError.
    if (!_proxyReady) {
      try {
        await _proxy.start();
        _proxyReady = true;
      } catch (e) {
        _log('proxy start failed: $e');
      }
    }

    // Build proxied URL (no trimming, no t=..., to keep absolute progress bar)
    final toOpen = _proxyReady
        ? _proxy.playlistUrl(Uri.parse(_chosenUrl!)).toString()
        : _chosenUrl!;

    await _openAt(
      toOpen,
      // We still perform a normal seek — progress bar remains absolute.
      position: await _restoreSavedPosition(),
      play: true,
    );

    // Apply persisted desktop volume & speed right after the first open.
    if (_isDesktop) {
      await _setVolumeSafe(_desktopVolume);
      WidgetsBinding.instance.addPostFrameCallback((_) {
      _cursorForceVisible.value = false; // no force
      _cursorHideController.kick();      // start the single 3s countdown
    });
    }
    if (_alive) {
      try {
        await _player.setRate(_speed);
      } catch (_) {}
    }

    // Persist progress periodically.
    _autosaveTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());

    // Save desktop volume back to prefs when user changes it via controls.
    _subVolume = _player.stream.volume.listen((v) {
      if (!_isDesktop) return;
      // mpv volume is 0..100.0; store as-is.
      _desktopVolume = v;
      _safeSetState(() {}); // update UI if you later show it
      _volumePersistDebounce?.cancel();
      _volumePersistDebounce = Timer(const Duration(milliseconds: 300), () {
        unawaited(
          ref
              .read(playerPrefsProvider.notifier)
              .setDesktopVolume(_desktopVolume),
        );
      });
    });

    _subPos = _player.stream.position.listen((pos) {
      // Log-only jump detector: report suspicious forward leaps but do nothing.
      final prev = _lastPos;
      _lastPos = pos;

      if (_player.state.duration != Duration.zero &&
          !_plannedSeek &&
          prev > Duration.zero &&
          !_inQuarantine &&
          !_player.state.buffering) {
        final diff = pos - prev;

        // Threshold raised to 3.5s to avoid timer hiccups on Windows.
        if (diff > const Duration(milliseconds: 3500)) {
          final now = DateTime.now();
          if (_jumpWindowStartedAt == null ||
              now.difference(_jumpWindowStartedAt!) >
                  const Duration(seconds: 2)) {
            _jumpWindowStartedAt = now;
            _consecutiveJumpCount = 1;
          } else {
            _consecutiveJumpCount++;
          }

          final bigLeap = diff >= const Duration(seconds: 30);
          final burst = _consecutiveJumpCount >= 3;

          _log('! unexpected jump detected: +${diff.inMilliseconds}ms '
              '(prev=$prev → now=$pos, bigLeap=$bigLeap, burst=$burst)');

          // IMPORTANT: No corrective actions here (logging-only requirement).
        }
      }

      // DO NOT force setVolume here. It causes fighting with user changes.
      _maybeAutoSkip(pos);
      _safeSetState(() {});
    });

    _subCompleted = _player.stream.completed.listen((done) {
      if (!done) return;
      unawaited(_saveProgress(clearIfCompleted: true));
      if (_autoNextEpisode) {
        _hideCursorInstant();
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
      _showBanner(widget.startupBannerText!, affectCursor: false);
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

  /// Wrapper that marks an intentional seek so our jump-detector won't flag it.
  Future<void> _seekPlanned(Duration to, {String? reason}) async {
    if (!_alive) return; // bail if page is leaving/disposed
    _plannedSeek = true;
    try {
      await _player.seek(to);
      _log('seek(planned) to=$to reason=${reason ?? "n/a"}');
    } catch (e) {
      // Avoid crashing if seek races with dispose
      _log('seek skipped (not alive): $e');
    } finally {
      await Future.delayed(const Duration(milliseconds: 50));
      _plannedSeek = false;
    }
  }

  /// Open URL & robustly wait for HLS to settle before seeking.
  Future<void> _openAt(
    String url, {
    required Duration position,
    required bool play,
  }) async {
    if (!_alive) return;

    // Do not force close; some CDNs misbehave & expose only the first HLS segment.
    try {
      await _player.open(
        Media(
          url,
          httpHeaders: const {
            // Keep a desktop-like UA to avoid odd CDN variants.
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
          },
        ),
        play: play,
      );
    } catch (e) {
      _log('open failed (not alive?): $e');
      return;
    }

    if (!_alive) return;

    // Robust HLS settle: wait for either a valid duration OR first stable positions.
    final settle = Completer<void>();
    late final StreamSubscription subDur;
    late final StreamSubscription subPos;

    final timeout = Future<void>.delayed(const Duration(seconds: 12), () {});
    bool hasDuration = false;
    int posTicksOver500ms = 0;

    subDur = _player.stream.duration.listen((d) {
      if (!_alive) {
        if (!settle.isCompleted) settle.complete();
        subDur.cancel();
        return;
      }
      if (d > Duration.zero) {
        hasDuration = true;
        if (!settle.isCompleted) {
          settle.complete();
        }
      }
    });

    subPos = _player.stream.position.listen((p) {
      if (!_alive) {
        if (!settle.isCompleted) settle.complete();
        subDur.cancel();
        return;
      }
      if (p > const Duration(milliseconds: 500)) {
        posTicksOver500ms++;
        if (!hasDuration && posTicksOver500ms >= 2 && !settle.isCompleted) {
          settle.complete();
        }
      }
    });

    await Future.any([settle.future, timeout]);
    await subDur.cancel();
    await subPos.cancel();

    if (!_alive) return;

    if (position > Duration.zero) {
      await _seekPlanned(position, reason: 'openAt_restore');
      await Future.delayed(const Duration(milliseconds: 60));
      await _seekPlanned(position, reason: 'openAt_restore_confirm');
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

    // Ensure proxy is running
    if (!_proxyReady) {
      try {
        await _proxy.start();
        _proxyReady = true;
      } catch (e) {
        _log('proxy start failed in changeQuality: $e');
      }
    }

    final toOpen =
        _proxyReady ? _proxy.playlistUrl(Uri.parse(url)).toString() : url;

    final resume = pos + const Duration(milliseconds: 300);
    await _openAt(toOpen, position: resume, play: wasPlaying);

    // Re-apply persisted desktop volume after reopen.
    if (_isDesktop) {
      await _setVolumeSafe(_desktopVolume);
    }
    if (_alive) {
      try {
        await _player.setRate(_speed);
      } catch (_) {}
    }

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
      // IMPORTANT: pass the ORIGINAL remote URL to native iOS player.
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
      if (_controlsCtx != null && !_wasFullscreen) {
        try {
          await enterFullscreen(_controlsCtx!);
          _wasFullscreen = true;
        } catch (_) {}
      }
      if (wasPlaying && _alive) {
        try {
          await _player.play();
        } catch (_) {}
      }
    }
  }

  // ---------- Auto-skip / next ----------

  void _maybeAutoSkip(Duration pos) {
    final dur = _player.state.duration;
    if (dur == Duration.zero) return;
    if (_reopeningGuard || _inQuarantine) return;

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
    await _seekPlanned(to, reason: 'auto_skip');
    _showBanner(banner, affectCursor: false);
    _hideCursorInstant();
  }

  Future<void> _undoSkip() async {
    if (_undoSeekFrom == null) return;
    await _seekPlanned(_undoSeekFrom!, reason: 'undo_skip');
    _undoSeekFrom = null;
    _autoSkipBlockedUntil = DateTime.now().add(const Duration(seconds: 10));
  }

  Future<void> _openNextEpisode() async {
    if (_navigatingAway) return;
    _hideCursorInstant();
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
            item: widget.item,
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

  void _showBanner(String text, { Duration hideAfter = const Duration(seconds: 3), bool affectCursor = true}) {
    if (_navigatingAway) return;
    _bannerTimer?.cancel();
    _bannerText = text;
    _bannerVisible = true;

    // Only force cursor visible if requested.
    _cursorForceVisible.value = affectCursor;

    _safeSetState(() {});
    _bannerTimer = Timer(hideAfter, _hideBanner);
  }

  void _hideBanner() {
    if (!_bannerVisible) return;
    _bannerVisible = false;
    _undoSeekFrom = null;

    _cursorForceVisible.value = false;

    _safeSetState(() {});
    Future.delayed(const Duration(milliseconds: 1), _cursorHideController.kick);
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
          if (_alive) {
            try { await _player.setRate(r); } catch (_) {}
          }
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
      // Support button that opens AniLiberty support page
      IconButton(
        icon: const Icon(Ionicons.heart),
        tooltip: 'Support AniLiberty',
        onPressed: _openSupport,
      ),
      const SizedBox(width: 2), // Add a small right inset so actions aren't flush to the edge
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

    Widget wrapDesktopCursorHider(Widget child) {
      if (!_isDesktop) return child;

      return Stack(
        fit: StackFit.expand,
        children: [
          child,
          Positioned.fill(
            child: ValueListenableBuilder<bool>(
              valueListenable: _cursorForceVisible,
              builder: (_, force, __) {
                return _CursorAutoHideOverlay(
                  idle: const Duration(seconds: 3),
                  forceVisible: force,
                  controller: _cursorHideController,
                );
              },
            ),
          ),
        ],
      );
    }

    Widget buildPlayerStack() {
      return Stack(
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

                // Start in fullscreen (lib) only for non-iOS platforms.
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
                        await _enterNativeFullscreen();
                        _insertCursorOverlayIfNeeded();
                        _cursorHideController.kick();
                        // await _enterNativeFullscreen(); // request native overlays (non-iOS)
                        _log('entered fullscreen on new page');
                      } catch (_) {}
                    }
                  });
                }
              },
            ),
            onEnterFullscreen: () async {
              if (_isIOS) return;
              _log('onEnterFullscreen() fired (lib)');
              _wasFullscreen = true;
              if (!mounted || _navigatingAway) return;
              await _enterNativeFullscreen();

              // Insert cursor overlay on desktop while fullscreen is active.
              _insertCursorOverlayIfNeeded();
              _cursorHideController.kick();

              _log('native fullscreen requested from onEnterFullscreen()');
            },
            onExitFullscreen: () async {
              if (_isIOS) return;
              _log('onExitFullscreen() fired (lib)');
              _wasFullscreen = false;
              if (!mounted || _navigatingAway) return;
              await _exitNativeFullscreen();

              // Remove cursor overlay when leaving fullscreen.
              _removeCursorOverlayIfAny();

              _log('native fullscreen exit requested from onExitFullscreen()');
            },
          ),
          banner,
        ],
      );
    }

    // Predictive back: use onPopInvokedWithResult (non-deprecated).
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) async {
        // Capture the navigator before the async break:
        final navigator = Navigator.of(context);

        _navigatingAway = true;
        _detachListeners();

        if (!_isDisposed) {
          try { await _player.stop(); } catch (_) {}
        }

        if (didPop) return;
        if (!mounted || !navigator.mounted) return;

        navigator.maybePop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          // title: Text(widget.args.title),
          title: Text('Episode ${widget.args.ordinal}'),
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          centerTitle: false,
          titleSpacing: 0,
          actions: actions,
        ),
        body: Padding(
          padding: _isMobile && !_wasFullscreen
              ? const EdgeInsets.only(bottom: 56, left: 56, right: 56)
              : EdgeInsets.zero,
          child: wrapDesktopCursorHider(
            buildPlayerStack(),
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

/// Controller to restart cursor auto-hide countdown from outside.
class CursorAutoHideController {
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);
  final ValueNotifier<int> _hideNowTick = ValueNotifier<int>(0);
  void kick() => _tick.value++;
  void hideNow() => _hideNowTick.value++;
}

// Transparent overlay that auto-hides the mouse cursor after [idle].
// Lives inside the video controls Overlay while fullscreen is active.
class _CursorAutoHideOverlay extends StatefulWidget {
  const _CursorAutoHideOverlay({
    this.idle = const Duration(seconds: 3),
    this.forceVisible = false,
    this.controller,
  });

  final Duration idle;
  final bool forceVisible;
  final CursorAutoHideController? controller;
  @override
  State<_CursorAutoHideOverlay> createState() => _CursorAutoHideOverlayState();
}

class _CursorAutoHideOverlayState extends State<_CursorAutoHideOverlay> {
  bool _visible = true;
  Timer? _t;
  VoidCallback? _controllerSub;
  VoidCallback? _hideNowSub;

  // Start/Restart countdown
  void _bump() {
    _t?.cancel();
    if (!_visible) setState(() => _visible = true);
    if (widget.forceVisible) return; // keep visible while overlays are shown
    _t = Timer(widget.idle, () {
      if (!mounted) return;
      setState(() => _visible = false);
    });
  }

  @override
  void initState() {
    super.initState();
    _bump(); // start countdown on mount
    // Subscribe to external kicks
    _controllerSub = () => _bump();
    widget.controller?._tick.addListener(_controllerSub!);

    // Instantly hide the cursor on command
    _hideNowSub = () {
      _t?.cancel();
      if (_visible) setState(() => _visible = false);
    };
    widget.controller?._hideNowTick.addListener(_hideNowSub!);
  }

  @override
  void didUpdateWidget(covariant _CursorAutoHideOverlay old) {
    super.didUpdateWidget(old);
    // Rewire controller listener if controller instance changed
    if (old.controller != widget.controller) {
      if (old.controller != null && _controllerSub != null) {
        old.controller!._tick.removeListener(_controllerSub!);
        old.controller!._hideNowTick.removeListener(_hideNowSub!);
      }
      if (widget.controller != null) {
        widget.controller!._tick.addListener(_controllerSub!);
        widget.controller!._hideNowTick.addListener(_hideNowSub!);
      }
    }

    // When forceVisible turns ON -> show cursor now.
    if (widget.forceVisible && !_visible) {
      setState(() => _visible = true);
    }
    // When forceVisible turns OFF -> do nothing here.
    // IMPORTANT: The parent will decide when to start the countdown (via controller.kick()).
  }

  @override
  void dispose() {
    _t?.cancel();
    if (widget.controller != null) {
      if (_controllerSub != null) {
        widget.controller!._tick.removeListener(_controllerSub!);
      }
      if (_hideNowSub != null) {
        widget.controller!._hideNowTick.removeListener(_hideNowSub!); // NEW
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerHover: (_) => _bump(),
      onPointerMove: (_) => _bump(),
      onPointerDown: (_) => _bump(),
      onPointerSignal: (_) => _bump(),
      child: MouseRegion(
        opaque: false,
        cursor: (widget.forceVisible || _visible)
            ? SystemMouseCursors.basic
            : SystemMouseCursors.none,
        child: const SizedBox.expand(),
      ),
    );
  }
}