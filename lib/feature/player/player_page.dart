import 'dart:async';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/collection/collection_provider.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// media_kit
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// prefs / playback
import 'package:animeshin/feature/player/playback_store.dart';
import 'package:animeshin/feature/player/player_prefs.dart';
import 'package:animeshin/feature/player/subtitle_style_dialog.dart';
import 'package:animeshin/feature/player/player_config.dart';
import 'package:animeshin/feature/player/player_appbar_actions.dart';
import 'package:animeshin/feature/player/player_quality_helpers.dart';
import 'package:animeshin/feature/player/player_banner_overlay.dart';
import 'package:animeshin/feature/player/player_cursor_overlay.dart';
import 'package:animeshin/feature/player/player_controls_ctx_bridge.dart';
import 'package:animeshin/feature/player/player_audio_recovery.dart';
import 'package:animeshin/feature/player/player_resume_lock.dart';
import 'package:animeshin/feature/player/player_seek_coordinator.dart';
import 'package:animeshin/feature/player/player_transport_trace.dart';

// watch types / data
import 'package:animeshin/feature/watch/watch_types.dart';
import 'package:animeshin/util/module_loader/js_module_executor.dart';

// desktop fullscreen
import 'package:window_manager/window_manager.dart';

// === Local HLS Proxy ===
import 'package:animeshin/feature/player/local_hls_proxy.dart';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({
    super.key,
    required this.args,
    required this.item,
    required this.sync,
    required this.animeVoice,
    this.startupBannerText,
    this.startFullscreen = false,
    this.startWithProxy = true,
  });

  final PlayerArgs args;
  final Entry? item;
  final bool sync;
  final String? startupBannerText;
  final bool startFullscreen;
  final bool startWithProxy;
  final AnimeVoice animeVoice;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class NoSwipeBackMaterialPageRoute<T> extends MaterialPageRoute<T> {
  NoSwipeBackMaterialPageRoute({
    required super.builder,
    super.settings,
    super.maintainState,
    super.fullscreenDialog,
  });

  @override
  bool get popGestureEnabled => false;
}

enum _AutoSkipKind { opening, ending }

class _PlayerPageState extends ConsumerState<PlayerPage>
    with WidgetsBindingObserver {
  // Disable unexpected jump detector logging.
  static const bool _enableJumpDetector = kDebugMode;
  static int _traceSequence = 0;
  // --- Platform / channels -----------------------------------------------------

  static const MethodChannel _iosNativePlayer =
      MethodChannel('native_ios_player');
  static const MethodChannel _mobileFullscreen =
      MethodChannel('mobile_fullscreen');

  // --- Media -------------------------------------------------------------------

  late final Player _player;
  late final VideoController _video;
  VideoState? _mediaKitVideoState;

  // Fullscreen helpers (media_kit's internal fullscreen needs a controls subtree context).
  BuildContext? _controlsCtxNormal;
  BuildContext? _controlsCtxFullscreen;
  OverlayEntry? _fullscreenBannerOverlayEntry;
  bool _startFsHandled = false;
  bool _wasFullscreen = false;
  bool _nativeFsInFlight = false;
  bool _nativeFsActive = false;

  // Navigation / lifecycle guards
  bool _navigatingAway = false;

  // Repo / persistence
  final _playback = const PlaybackStore();
  final JsModuleExecutor _jsExec = JsModuleExecutor();

  // Local HLS proxy
  late final LocalHlsProxy _proxy;
  bool _proxyReady = false; // set true after start()

  // Subs / timers
  StreamSubscription<Duration>? _subPos;
  StreamSubscription<bool>? _subCompleted;
  StreamSubscription<bool>? _subBuffering;
  StreamSubscription<double>? _subRate;
  StreamSubscription<double>? _subVolume; // <- listen volume changes
  StreamSubscription<bool>? _subPlaying;
  bool? _lastBufferingState;

  bool _bannerVisible = false;
  String _bannerText = '';
  Duration? _undoSeekFrom;
  DateTime? _autoSkipBlockedUntil;
  Timer? _bannerTimer;
  Timer? _autosaveTimer;
  Timer? _volumePersistDebounce; // <- debounce saves to prefs
  Timer? _uiHideTimer;
  Timer?
      _qualityReopenTimer; // <- re-enable quality reaction after initial load
  Timer? _audioHealthTimer;
  Timer? _seekQueueTimer;
  Timer? _mobileFullscreenReentryTimer;
  int _mobileFullscreenReentryAttempts = 0;

  // Quality
  String? _chosenUrl; // stores the ORIGINAL remote stream URL
  PlayerQuality _currentQuality = PlayerQuality.p1080;
  bool _suppressPrefQualityReopen = false;

  // Prefs (cached)
  double _speed = 1.0;
  int _seekStepSeconds = 5;
  bool _autoSkipOpening = true;
  bool _autoSkipEnding = true;
  bool _autoNextEpisode = true;
  bool _autoProgress = true;
  bool _subtitlesEnabled = true;
  int _subtitleFontSize = 55;
  String _subtitleColor = 'FFFFFF';
  int _subtitleOutlineSize = 2;
  double _desktopVolume = 100.0;

  // Subtitles: prevent duplicate attachments per media open.
  bool _hasOpenedMedia = false;
  int _openSerial = 0;
  int _subtitleAppliedSerial = -1;
  String? _subtitleAppliedUrl;

  late ProviderSubscription<PlayerPrefs> _prefsSub;

  // --- Jump detection / logging-only ------------------------------------------

  Duration _lastPos = Duration.zero;
  int _lastUiPosSecond = -1;
  bool _plannedSeek = false;
  bool _seekPumpRunning = false;
  bool _audioRecoveryInFlight = false;
  DateTime? _lastAudioStateLogAt;
  DateTime? _lastPausedAudioHealthCheckAt;
  DateTime? _pausedAt;
  Duration? _resumeAnchorPosition;
  DateTime? _lastSeekAt;
  bool _longPauseBufferResetDone = false;
  bool _resumeAnchorTxnInFlight = false;
  DateTime? _lastFullscreenTransitionAt;
  String? _lastFullscreenTransitionType;
  Completer<void>? _pendingSeekCompleter;
  final SeekCoordinator _seekCoordinator = SeekCoordinator(
    coalesceWindow: PlayerTuning.seekCoalesceWindow,
    duplicateTolerance: PlayerTuning.seekVerifyTolerance,
  );
  final ResumeLockController _resumeLockController = ResumeLockController(
    applyAfterPause: PlayerTuning.resumeAnchorApplyAfterPause,
    mismatchThreshold: PlayerTuning.resumeAnchorMismatchThreshold,
    maxCorrection: PlayerTuning.resumeAnchorMaxCorrection,
  );
  final AudioDropDetector _audioDropDetector = AudioDropDetector(
    confirmWindow: PlayerTuning.audioDropConfirmWindow,
    cooldown: PlayerTuning.audioReselectCooldown,
  );
  // --- Auto-skip guard flags (Android-friendly) ---
  bool _openingSkipped = false;
  bool _endingSkipped = false;
  _AutoSkipKind? _lastSkipKind;

  // Left for diagnostics (no corrective actions are taken).
  final bool _reopeningGuard = false;
  DateTime? _jumpWindowStartedAt;
  int _consecutiveJumpCount = 0;
  DateTime? _quarantineUntil;
  final PlayerTransportCorrelator _transportCorrelator =
      PlayerTransportCorrelator(
    correlationWindow: PlayerTuning.hlsJumpCorrelationWindow,
  );
  late final String _transportTraceId = _makeTransportTraceId();

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

  bool get _lockMobileMediaKitFullscreen => _isMobile;

  bool get _shouldStartMediaKitFullscreen =>
      widget.startFullscreen || _lockMobileMediaKitFullscreen;

  // Lifecycle guard flags
  bool _isDisposed = false;

  // Native iOS player state (avoid Flutter subs while native player is active).
  bool _iosNativeActive = false;

  // Helper: only do player ops while the widget is alive & not navigating away.
  bool get _alive => mounted && !_navigatingAway && !_isDisposed;

  // Cursor overlay control
  final CursorAutoHideController _cursorHideController =
      CursorAutoHideController();
  OverlayEntry? _cursorOverlayEntry;
  final ValueNotifier<bool> _cursorForceVisible = ValueNotifier<bool>(false);

  bool _uiVisible = true;
  final ValueNotifier<bool> _uiVisibleNotifier = ValueNotifier<bool>(true);
  final ValueNotifier<int> _controlsOverlayRevision = ValueNotifier<int>(0);

  // Mirrors effective progress; updated locally after successful persist
  int? _knownProgress;
  bool _saveInFlight = false;
  int _lastSavedOrdinal = -1;
  int _lastSavedSecond = -1;
  bool _lastSavedWasCleared = false;

  // Prevents double increment for the same episode
  bool _autoIncDoneForThisEp = false;
  int? _autoIncGuardForOrdinal;

  // Proxy fallback for truncated HLS manifests (e.g., only first segment loads).
  bool _proxyFallbackAttempted = false;
  bool _openedViaProxy = false;

  final Duration _tailGuardMinutes = Duration(minutes: 3);

  // Clamp any absolute seek target to [0, duration] safely.
  Duration _clampSeekAbsolute(Duration target) {
    // If player has no duration yet, just prevent negatives.
    final d = _player.state.duration;
    if (d == Duration.zero) {
      return target.isNegative ? Duration.zero : target;
    }

    // Bound to [0, d].
    if (target.isNegative) return Duration.zero;
    if (target > d) return d;
    return target;
  }

  bool _looksLikeHlsUrl(String url) {
    return classifyStreamUrl(url) == StreamUrlKind.hls;
  }

  bool _shouldStartWithProxyForUrl(String url) {
    return shouldStartWithProxy(
      startWithProxy: widget.startWithProxy,
      url: url,
    );
  }

  bool _shouldAllowProxyFallbackForUrl(String url) {
    return shouldAllowProxyFallback(
      startWithProxy: widget.startWithProxy,
      url: url,
    );
  }

  Future<bool> _ensureProxyReady({required String reason}) async {
    if (_proxyReady) return true;
    try {
      await _proxy.start();
      _proxyReady = true;
      return true;
    } catch (e) {
      _log('proxy start failed in $reason: $e');
      return false;
    }
  }

  Future<({String toOpen, bool openedViaProxy})> _resolveOpenTransport(
    String originalUrl, {
    required String reason,
  }) async {
    if (!_shouldStartWithProxyForUrl(originalUrl)) {
      return (toOpen: originalUrl, openedViaProxy: false);
    }

    final ready = await _ensureProxyReady(reason: reason);
    if (!ready) return (toOpen: originalUrl, openedViaProxy: false);

    try {
      final proxied = _proxy.playlistUrl(Uri.parse(originalUrl)).toString();
      return (toOpen: proxied, openedViaProxy: true);
    } catch (e) {
      _log('proxy url build failed in $reason: $e');
      return (toOpen: originalUrl, openedViaProxy: false);
    }
  }

  int? _durationHintSeconds() {
    final hints = <int?>[
      widget.args.duration,
      widget.args.endingEnd,
      widget.args.endingStart,
    ].whereType<int>();
    if (hints.isEmpty) return null;
    return hints.reduce((a, b) => a > b ? a : b);
  }

  bool _shouldFallbackToProxy(Duration duration) {
    if (duration.inSeconds <= 0) return false;
    final hint = _durationHintSeconds();
    if (hint == null || hint < 60) return false;
    return duration.inSeconds <= 15;
  }

  int _progressBaselineForOrdinal(int ordinal, int? raw) {
    final safeRaw = raw ?? 0;
    final baseline = ordinal > 0 ? ordinal - 1 : 0;
    return safeRaw < baseline ? baseline : safeRaw;
  }

  // Build the record tag required by collectionProvider
  CollectionTag _buildCollectionTag({required bool ofAnime}) {
    final viewerId = ref.read(viewerIdProvider);
    if (viewerId == null) {
      // Defensive: if user is not loaded yet, just fallback (no crash).
      // You can also early-return and skip remote persist in _persistAniListProgress.
      return (userId: 0, ofAnime: ofAnime);
    }
    return (userId: viewerId, ofAnime: ofAnime);
  }

  /// Persist progress to AniList via collection provider.
  /// Optimistically updates the current entry and rolls back on error.
  Future<String?> _persistAniListProgress(int newProgress,
      {bool setAsCurrent = false}) async {
    if (widget.item == null || !widget.sync) return null;

    final tag = _buildCollectionTag(ofAnime: true);
    if (tag.userId == 0) return null; // skip if viewer not ready

    final notifier = ref.read(collectionProvider(tag).notifier);

    final tmp = widget.item!;
    final prev = tmp.progress;
    final max = tmp.progressMax;
    final next = (newProgress).clamp(0, (max ?? 1 << 20)); // clamp just in case
    tmp.progress = next;

    final err = await notifier.saveEntryProgress(tmp, setAsCurrent);
    if (err != null) {
      tmp.progress = prev;
      return err;
    }

    _knownProgress = next;
    return null;
  }

  Future<void> _maybeAutoIncrementProgress(Duration pos) async {
    if (!_autoProgress) return;
    final item = widget.item;
    final ordinal = widget.args.ordinal;
    if (item == null || ordinal <= 0) return;

    var duration = _player.state.duration;
    if (duration == Duration.zero) {
      final d = widget.args.duration;
      if (d != null && d > 0) {
        duration = Duration(seconds: d);
      }
    }
    if (duration == Duration.zero) return;

    final current =
        _progressBaselineForOrdinal(ordinal, _knownProgress ?? item.progress);
    final max = item.progressMax;

    // If we are not moving forward, do nothing; never decrement progress.
    if (ordinal <= current) {
      _autoIncDoneForThisEp = true;
      _autoIncGuardForOrdinal = ordinal;
      return;
    }

    // Prevent duplicate increments for this ordinal
    if (_autoIncDoneForThisEp && _autoIncGuardForOrdinal == ordinal) return;

    // Decide threshold: 5s before ED if tagged; otherwise by tail guard (e.g., 3 min)
    bool passedThreshold = false;
    final endingStart = widget.args.endingStart;
    if (endingStart != null && endingStart > 0) {
      final triggerAtMs = endingStart * 1000 - 5000; // 5s before ED
      passedThreshold = triggerAtMs > 0
          ? pos.inMilliseconds >= triggerAtMs
          : (duration - pos) <= _tailGuardMinutes;
    } else {
      passedThreshold = (duration - pos) <= _tailGuardMinutes;
    }
    if (!passedThreshold) return;

    // We jumped forward (e.g., from 5 to watching 8) -> set progress to 'ordinal'
    final next = ordinal.clamp(0, max ?? 1 << 20);

    // Arm guard BEFORE awaiting to avoid double runs
    _autoIncDoneForThisEp = true;
    _autoIncGuardForOrdinal = ordinal;

    final err = await _persistAniListProgress(next, setAsCurrent: false);
    if (mounted && err != null) {
      // Allow retry if failed
      _autoIncDoneForThisEp = false;
      _autoIncGuardForOrdinal = null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update progress: $err')),
      );
    } else {
      _knownProgress = next; // mirror locally on success
    }
  }

  // Place near other helpers
  Future<void> _restoreFromIOSDismiss({
    required Duration target,
    required double rate,
    required bool wasPlaying,
  }) async {
    if (!_alive) return;

    // Reset auto-skip flags for a fresh media open (quality change / next episode).
    _openingSkipped = false;
    _endingSkipped = false;

    // Wait until the player reports a valid duration (no position fallback).
    final settle = Completer<void>();
    late final StreamSubscription subDur;
    bool iosSettleTimeoutFired = false;

    // Safety timeout — don't hang forever.
    final timeout = Future<void>.delayed(const Duration(seconds: 10), () {
      if (!settle.isCompleted) {
        iosSettleTimeoutFired = true;
        settle.complete();
      }
    });

    _log('iOS restore: waiting for duration settle...');
    subDur = _player.stream.duration.listen(
      (d) {
        if (!_alive) {
          if (!settle.isCompleted) settle.complete();
          subDur.cancel();
          return;
        }
        _log('iOS restore: duration update ${d.inSeconds}s');
        if (d > const Duration(seconds: 3)) {
          if (!settle.isCompleted) {
            _log(
                'iOS restore settled with duration: ${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}');
            settle.complete();
          }
        }
      },
      onError: (error) {
        _log('ERROR in iOS duration stream: $error');
        if (!settle.isCompleted) settle.complete();
      },
      onDone: () {
        _log('iOS duration stream closed prematurely');
        if (!settle.isCompleted) settle.complete();
      },
    );

    await Future.any([settle.future, timeout]);
    await subDur.cancel();

    if (iosSettleTimeoutFired) {
      _log('iOS settle TIMEOUT (10s) - no valid duration reported');
    }

    if (!_alive) return;

    // Reset auto-skip flags for a fresh media open (quality change / next episode).
    _openingSkipped = false;
    _endingSkipped = false;

    // Block auto-skip for a short window so we don't immediately jump again.
    _autoSkipBlockedUntil =
        DateTime.now().add(PlayerTuning.iosAutoSkipBlockAfterRestore);

    final tgt = _clampSeekAbsolute(target);
    await _seekPlanned(tgt, reason: 'ios_dismiss_restore');

    // Re-apply rate (the native VC may have changed it).
    try {
      await _player.setRate(rate);
    } catch (_) {}

    // Resume only after we are at the right place.
    if (wasPlaying && _alive) {
      await _playTracked(reason: 'ios_dismiss_restore_resume');
    }
  }

  void _insertCursorOverlayIfNeeded() {
    if (!_isDesktop || _cursorOverlayEntry != null) return;
    final ctx = _activeControlsCtx(preferFullscreen: true);
    if (ctx == null || !ctx.mounted) return;

    final overlay = Overlay.of(ctx);
    if (!overlay.mounted) return;

    _cursorOverlayEntry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: ValueListenableBuilder<bool>(
          valueListenable: _cursorForceVisible,
          builder: (_, force, __) {
            return PlayerCursorAutoHideOverlay(
              idle: PlayerTuning.cursorIdleHide,
              forceVisible: force,
              controller: _cursorHideController,
              onPointerActivity: _handlePlayerPointerActivity,
              onPointerEnter: _handlePlayerPointerActivity,
              onPointerExit: _handlePlayerPointerExit,
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
      } catch (_) {}
    });
  }

  void _removeCursorOverlayIfAny() {
    final entry = _cursorOverlayEntry;
    _cursorOverlayEntry = null;
    if (entry == null) return;
    try {
      if (entry.mounted) {
        entry.remove();
      }
    } catch (e) {
      _log('cursor overlay remove failed: $e');
    }
  }

  bool _isFullscreenBannerHostActive() {
    final fsCtx = _controlsCtxFullscreen;
    if (fsCtx == null || !fsCtx.mounted) return false;
    try {
      return isFullscreen(fsCtx);
    } catch (_) {
      return false;
    }
  }

  Widget _buildBannerWidget() {
    if (!_bannerVisible) return const SizedBox.shrink();

    return PlayerBannerOverlay(
      visible: _bannerVisible,
      text: _bannerText,
      showUndo: _undoSeekFrom != null,
      onUndo: _undoSkip,
    );
  }

  void _removeFullscreenBannerOverlayIfAny() {
    final entry = _fullscreenBannerOverlayEntry;
    _fullscreenBannerOverlayEntry = null;
    if (entry == null) return;
    try {
      if (entry.mounted) {
        entry.remove();
      }
    } catch (e) {
      _log('fullscreen banner overlay remove failed: $e');
    }
  }

  void _syncFullscreenBannerOverlay() {
    final fsCtx = _controlsCtxFullscreen;
    if (!_bannerVisible || fsCtx == null || !fsCtx.mounted) {
      _removeFullscreenBannerOverlayIfAny();
      return;
    }

    final inFullscreen = _isFullscreenBannerHostActive();
    if (!inFullscreen) {
      _removeFullscreenBannerOverlayIfAny();
      return;
    }

    final overlay = Overlay.maybeOf(fsCtx);
    if (overlay == null || !overlay.mounted) {
      _removeFullscreenBannerOverlayIfAny();
      return;
    }

    final existing = _fullscreenBannerOverlayEntry;
    if (existing != null) {
      existing.markNeedsBuild();
      return;
    }

    final entry = OverlayEntry(builder: (_) => _buildBannerWidget());
    _fullscreenBannerOverlayEntry = entry;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_fullscreenBannerOverlayEntry != entry) return;
      if (!_bannerVisible) {
        _removeFullscreenBannerOverlayIfAny();
        return;
      }
      final ctx = _controlsCtxFullscreen;
      if (ctx == null || !ctx.mounted) {
        _removeFullscreenBannerOverlayIfAny();
        return;
      }
      final currentOverlay = Overlay.maybeOf(ctx);
      if (!_isFullscreenBannerHostActive() ||
          currentOverlay == null ||
          !currentOverlay.mounted) {
        _removeFullscreenBannerOverlayIfAny();
        return;
      }
      try {
        currentOverlay.insert(entry);
      } catch (e) {
        _log('fullscreen banner overlay insert failed: $e');
        _removeFullscreenBannerOverlayIfAny();
      }
    });
  }

  void _setUiVisibility(bool visible) {
    if (_uiVisible == visible) return;
    _uiVisible = visible;
    _uiVisibleNotifier.value = visible;
    _safeSetState(() {});
  }

  void _bumpUiVisibility() {
    _setUiVisibility(true);
    _uiHideTimer?.cancel();
    _uiHideTimer = Timer(PlayerTuning.cursorIdleHide, () {
      if (!mounted || _navigatingAway) return;
      _setUiVisibility(false);
    });
  }

  void _hideUiVisibility() {
    _uiHideTimer?.cancel();
    _setUiVisibility(false);
  }

  void _handlePlayerPointerActivity() {
    _bumpUiVisibility();
    if (_isDesktop) _cursorHideController.kick();
  }

  void _handlePlayerPointerExit() {
    if (_isDesktop) _hideUiVisibility();
  }

  void _handleControlsPointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _handlePlayerPointerActivity();
    }
  }

  void _handleControlsPointerHover(PointerHoverEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _handlePlayerPointerActivity();
    }
  }

  void _handleControlsPointerEnter(PointerEnterEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _handlePlayerPointerActivity();
    }
  }

  void _handleControlsPointerExit(PointerExitEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _handlePlayerPointerExit();
    }
  }

  void _handleControlsPointerDown(
    BuildContext controlsContext,
    PointerDownEvent event,
  ) {
    _handlePlayerPointerActivity();
  }

  Future<void> _invokeMobileFullscreen(String method) async {
    try {
      await _mobileFullscreen.invokeMethod<void>(method);
    } on MissingPluginException {
      // Older platform builds can ignore the native fullscreen helper.
    } catch (e) {
      _log('mobile fullscreen channel "$method" failed: $e');
    }
  }

  Future<void> _reapplyMobileNativeFullscreen({required String reason}) async {
    if (!_isMobile || !_nativeFsActive || _navigatingAway) return;
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: const <SystemUiOverlay>[],
    );
    await _invokeMobileFullscreen('enter');
    _log('reapplied native mobile fullscreen ($reason)');
  }

  void _scheduleMobileNativeFullscreenReapply() {
    if (!_isMobile) return;
    for (final delay in const [
      Duration(milliseconds: 250),
      Duration(milliseconds: 900),
    ]) {
      unawaited(Future<void>.delayed(delay, () async {
        if (!mounted || !_nativeFsActive || _navigatingAway) return;
        await _reapplyMobileNativeFullscreen(
          reason: 'delayed_${delay.inMilliseconds}ms',
        );
      }));
    }
  }

  void _hideCursorInstant() {
    if (_isDesktop) _cursorHideController.hideNow();
  }

  BuildContext? _activeControlsCtx({required bool preferFullscreen}) {
    final full = _controlsCtxFullscreen;
    if (preferFullscreen && full != null && full.mounted) return full;
    final normal = _controlsCtxNormal;
    if (normal != null && normal.mounted) return normal;
    if (!preferFullscreen && full != null && full.mounted) return full;
    return null;
  }

  Future<void> _enterMediaKitFullscreenFrom(
    BuildContext? ctx, {
    VideoState? state,
    required String reason,
  }) async {
    if (!mounted || _navigatingAway) return;
    if ((ctx == null || !ctx.mounted) && (state == null || !state.mounted)) {
      return;
    }

    final videoState = state ?? _mediaKitVideoState;

    var alreadyFullscreen = false;
    try {
      alreadyFullscreen = videoState?.isFullscreen() ?? false;
    } catch (_) {}
    if (!alreadyFullscreen && ctx != null && ctx.mounted) {
      try {
        alreadyFullscreen = isFullscreen(ctx);
      } catch (_) {}
    }
    if (alreadyFullscreen) {
      _wasFullscreen = true;
      if (!_nativeFsActive) {
        await _enterNativeFullscreen();
      }
      return;
    }

    try {
      if (videoState != null && videoState.mounted) {
        await videoState.enterFullscreen();
      } else if (ctx != null && ctx.mounted) {
        await enterFullscreen(ctx);
      } else {
        return;
      }
      _wasFullscreen = true;
      await Future.delayed(PlayerTuning.nativeFullscreenDelay);
      if (!mounted || _navigatingAway) return;
      if (!_nativeFsActive) {
        await _enterNativeFullscreen();
      }
      _insertCursorOverlayIfNeeded();
      _cursorHideController.kick();
      _log('entered fullscreen ($reason)');
    } catch (e) {
      _log('enter fullscreen failed ($reason): $e');
    } finally {
      if (_lockMobileMediaKitFullscreen &&
          !_navigatingAway &&
          !_hasMediaKitFullscreenContext()) {
        _scheduleMobileFullscreenReentry();
      }
    }
  }

  bool _hasMediaKitFullscreenContext() {
    final videoState = _mediaKitVideoState;
    if (videoState != null && videoState.mounted) {
      try {
        if (videoState.isFullscreen()) return true;
      } catch (_) {}
    }

    for (final ctx in [_controlsCtxFullscreen, _controlsCtxNormal]) {
      if (ctx == null || !ctx.mounted) continue;
      try {
        if (isFullscreen(ctx)) return true;
      } catch (_) {}
    }
    return false;
  }

  void _cancelMobileFullscreenReentry() {
    _mobileFullscreenReentryTimer?.cancel();
    _mobileFullscreenReentryTimer = null;
    _mobileFullscreenReentryAttempts = 0;
  }

  void _scheduleMobileFullscreenReentry() {
    if (!_lockMobileMediaKitFullscreen || _navigatingAway) return;
    if (_hasMediaKitFullscreenContext()) {
      _cancelMobileFullscreenReentry();
      return;
    }
    if (_mobileFullscreenReentryAttempts >=
        PlayerTuning.mobileFullscreenReentryMaxAttempts) {
      _log('mobile fullscreen reentry gave up');
      return;
    }

    _mobileFullscreenReentryTimer?.cancel();
    _mobileFullscreenReentryTimer = Timer(
      PlayerTuning.mobileFullscreenReentryDelay,
      () {
        if (!mounted || _navigatingAway) return;
        if (_hasMediaKitFullscreenContext()) {
          _cancelMobileFullscreenReentry();
          return;
        }

        _mobileFullscreenReentryAttempts++;
        final ctx = _activeControlsCtx(preferFullscreen: false);
        final videoState = _mediaKitVideoState;
        if ((ctx == null || !ctx.mounted) &&
            (videoState == null || !videoState.mounted)) {
          _scheduleMobileFullscreenReentry();
          return;
        }

        unawaited(
          _enterMediaKitFullscreenFrom(
            ctx,
            state: videoState,
            reason: 'mobile_lock_reentry',
          ).whenComplete(_scheduleMobileFullscreenReentry),
        );
      },
    );
  }

  Map<ShortcutActivator, VoidCallback> _desktopKeyboardShortcuts() {
    void seekBy(Duration delta, {required String reason}) {
      if (!_alive) return;
      final tgt = _player.state.position + delta;
      unawaited(_seekPlanned(tgt, reason: reason));
    }

    void setVolumeDelta(double delta) {
      if (!_alive) return;
      final volume = _player.state.volume + delta;
      unawaited(_player.setVolume(volume.clamp(0.0, 100.0)));
    }

    void toggleFullscreenShortcut() {
      if (_isIOS) return;
      final ctx = _activeControlsCtx(preferFullscreen: true);
      if (ctx == null || !ctx.mounted) return;
      unawaited(toggleFullscreen(ctx));
    }

    void exitFullscreenShortcut() {
      if (_isIOS) return;
      final ctx = _activeControlsCtx(preferFullscreen: true);
      if (ctx == null || !ctx.mounted) return;
      unawaited(exitFullscreen(ctx));
    }

    return <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.mediaPlay): () {
        if (_alive) unawaited(_playTracked(reason: 'mk_media_play'));
      },
      const SingleActivator(LogicalKeyboardKey.mediaPause): () {
        if (_alive) unawaited(_pauseTracked(reason: 'mk_media_pause'));
      },
      const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () {
        if (_alive) unawaited(_playOrPauseTracked(reason: 'mk_media_toggle'));
      },
      const SingleActivator(LogicalKeyboardKey.mediaTrackNext): () {
        if (_alive) unawaited(_player.next());
      },
      const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): () {
        if (_alive) unawaited(_player.previous());
      },
      const SingleActivator(LogicalKeyboardKey.space): () {
        if (_alive) unawaited(_playOrPauseTracked(reason: 'mk_space_toggle'));
      },
      const SingleActivator(LogicalKeyboardKey.keyJ): () {
        seekBy(const Duration(seconds: -10), reason: 'mk_key_j');
      },
      const SingleActivator(LogicalKeyboardKey.keyI): () {
        seekBy(const Duration(seconds: 10), reason: 'mk_key_i');
      },
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
        if (_seekStepSeconds <= 0) return;
        seekBy(Duration(seconds: -_seekStepSeconds), reason: 'mk_key_left');
      },
      const SingleActivator(LogicalKeyboardKey.arrowRight): () {
        if (_seekStepSeconds <= 0) return;
        seekBy(Duration(seconds: _seekStepSeconds), reason: 'mk_key_right');
      },
      const SingleActivator(LogicalKeyboardKey.arrowUp): () {
        setVolumeDelta(5.0);
      },
      const SingleActivator(LogicalKeyboardKey.arrowDown): () {
        setVolumeDelta(-5.0);
      },
      const SingleActivator(LogicalKeyboardKey.keyF): toggleFullscreenShortcut,
      const SingleActivator(LogicalKeyboardKey.escape): exitFullscreenShortcut,
    };
  }

  void _log(String msg) {
    // Scoped log with page identity for easier tracing across rebuilds.
    debugPrint(
        '[PlayerPage#${identityHashCode(this)} @${DateTime.now().toIso8601String()}] $msg');
  }

  String _makeTransportTraceId() {
    _traceSequence++;
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final seq = _traceSequence.toRadixString(36);
    return 'pp-$ts-$seq';
  }

  void _emitTransportEvent(PlayerTransportEvent event) {
    if (!kDebugMode) return;
    _log('[transport] ${event.toDebugLine()}');
  }

  void _onProxyEvent(HlsProxyEvent event) {
    _transportCorrelator.registerProxyEvent(event);
    _emitTransportEvent(
      PlayerTransportEvent(
        timestamp: event.timestamp,
        traceId: _transportTraceId,
        type: PlayerTransportEventType.proxyEvent,
        note: 'proxy:${event.type.name} req=${event.requestId} '
            'status=${event.statusCode?.toString() ?? "-"} '
            'retry=${event.retry} '
            'bytes=${event.bytesReceived?.toString() ?? "-"}'
            '/${event.bytesExpected?.toString() ?? "-"} '
            'err=${event.errorType ?? "-"} '
            'hash=${event.segmentUrlHash}',
      ),
    );
  }

  // Safe setState: ignore updates when widget is unmounted or we're navigating away.
  void _safeSetState(VoidCallback fn) {
    if (!mounted || _navigatingAway) return;
    setState(fn);
    _controlsOverlayRevision.value++;
  }

  void _detachListeners() {
    _subPos?.cancel();
    _subPos = null;
    _subCompleted?.cancel();
    _subCompleted = null;
    _subBuffering?.cancel();
    _subBuffering = null;
    _subRate?.cancel();
    _subRate = null;
    _subVolume?.cancel();
    _subVolume = null;
    _subPlaying?.cancel();
    _subPlaying = null;
    _lastBufferingState = null;
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    _bannerTimer?.cancel();
    _bannerTimer = null;
    _volumePersistDebounce?.cancel();
    _volumePersistDebounce = null;
    _uiHideTimer?.cancel();
    _uiHideTimer = null;
    _qualityReopenTimer?.cancel();
    _qualityReopenTimer = null;
    _audioHealthTimer?.cancel();
    _audioHealthTimer = null;
    _seekQueueTimer?.cancel();
    _seekQueueTimer = null;
    _cancelMobileFullscreenReentry();
    _completeSeekCompleter(_pendingSeekCompleter);
    _pendingSeekCompleter = null;
    _seekCoordinator.reset();
    _resumeLockController.reset();
    _seekPumpRunning = false;
    _audioRecoveryInFlight = false;
    _lastAudioStateLogAt = null;
    _lastPausedAudioHealthCheckAt = null;
    _pausedAt = null;
    _resumeAnchorPosition = null;
    _longPauseBufferResetDone = false;
    _resumeAnchorTxnInFlight = false;
    _lastFullscreenTransitionAt = null;
    _lastFullscreenTransitionType = null;
    _audioDropDetector.reset();
  }

  Future<void> _enterNativeFullscreen() async {
    try {
      if (_nativeFsInFlight) return;
      _nativeFsInFlight = true;
      if (_isDesktop) {
        final isFs = await windowManager.isFullScreen();
        if (!isFs) {
          await windowManager.setFullScreen(true);
        }
        _nativeFsActive = true;
      } else if (_isMobile) {
        await SystemChrome.setPreferredOrientations(
          const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ],
        );
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: const <SystemUiOverlay>[],
        );
        await _invokeMobileFullscreen('enter');
        _nativeFsActive = true;
        _scheduleMobileNativeFullscreenReapply();
      }
    } catch (_) {
    } finally {
      _nativeFsInFlight = false;
    }
  }

  Future<void> _exitNativeFullscreen() async {
    try {
      if (_nativeFsInFlight) return;
      _nativeFsInFlight = true;
      if (_isDesktop) {
        final isFs = await windowManager.isFullScreen();
        if (isFs) {
          await windowManager.setFullScreen(false);
        }
        _nativeFsActive = false;
      } else if (_isMobile) {
        await _invokeMobileFullscreen('exit');
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
        _nativeFsActive = false;
      }
    } catch (_) {
    } finally {
      _nativeFsInFlight = false;
    }
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

  Future<void> _mpvCommand(List<String> args) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      final dyn = platform as dynamic;
      await dyn.command(args);
    } catch (e) {
      _log('command(${args.join(" ")}) failed: $e');
    }
  }

  Future<void> _applySubtitleStyle() async {
    if (!_alive) return;
    // We only customize mpv rendering (desktop NativePlayer).
    if (!_isDesktop) return;

    String rgb = _subtitleColor.trim().toUpperCase();
    if (rgb.length != 6) rgb = 'FFFFFF';

    String toAssColorBgr(String rrggbb) {
      // ASS uses &HAABBGGRR&. We keep alpha=00 (opaque).
      final rr = rrggbb.substring(0, 2);
      final gg = rrggbb.substring(2, 4);
      final bb = rrggbb.substring(4, 6);
      return '&H00$bb$gg$rr&';
    }

    // These are mpv options exposed as properties.
    // Note: For many subtitle formats (ASS/SSA), mpv may preserve embedded styling.
    // Force override to make our color/outline reliably apply.
    await _setMpv('sub-ass-override', 'force');
    await _setMpv(
      'sub-ass-style-overrides',
      [
        'Fontsize=$_subtitleFontSize',
        'PrimaryColour=${toAssColorBgr(rgb)}',
        'Outline=$_subtitleOutlineSize',
        'OutlineColour=${toAssColorBgr('000000')}',
      ].join(','),
    );

    // Also set generic subtitle options for non-ASS formats.
    await _setMpv('sub-font-size', _subtitleFontSize.toString());
    await _setMpv('sub-color', '#$rgb');
    await _setMpv('sub-border-size', _subtitleOutlineSize.toString());
    await _setMpv('sub-border-color', '#000000');
  }

  Future<dynamic> _getMpv(String property, {bool logError = true}) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return null;
    try {
      final dyn = platform as dynamic;
      return await dyn.getProperty(property);
    } catch (e) {
      if (logError) {
        _log('getProperty("$property") failed: $e');
      }
      return null;
    }
  }

  String? _normalizeAid(dynamic raw) {
    if (raw == null) return null;
    final aid = raw.toString().trim();
    if (aid.isEmpty) return null;
    if (aid.toLowerCase() == 'auto') return null;
    return aid;
  }

  bool _toBool(dynamic raw, {bool fallback = false}) {
    if (raw == null) return fallback;
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    final text = raw.toString().trim().toLowerCase();
    if (text == 'yes' || text == 'true' || text == '1') return true;
    if (text == 'no' || text == 'false' || text == '0') return false;
    return fallback;
  }

  double? _toDouble(dynamic raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toDouble();
    return double.tryParse(raw.toString().trim());
  }

  List<Map<String, dynamic>> _audioTracks(dynamic trackList) {
    if (trackList is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final item in trackList) {
      if (item is! Map) continue;
      final map = <String, dynamic>{};
      item.forEach((key, value) {
        map[key.toString()] = value;
      });
      if (map['type']?.toString() == 'audio') {
        out.add(map);
      }
    }
    return out;
  }

  String? _selectedAidFromTracks(
    List<Map<String, dynamic>> tracks,
    dynamic aidRaw,
  ) {
    for (final track in tracks) {
      final selected = _toBool(track['selected']);
      if (!selected) continue;
      final id = _normalizeAid(track['id']);
      if (id != null) return id;
    }
    return _normalizeAid(aidRaw);
  }

  String _audioSnapshotNote(AudioStateSnapshot snapshot,
      {required String reason}) {
    final bitrate = snapshot.audioBitrate;
    final bitrateText = bitrate == null ? '-' : bitrate.toStringAsFixed(0);
    return 'reason=$reason '
        'playing=${snapshot.playing} '
        'buffering=${snapshot.buffering} '
        'volume=${snapshot.volume.toStringAsFixed(1)} '
        'muted=${snapshot.muted} '
        'tracks=${snapshot.audioTrackCount} '
        'aid=${snapshot.selectedAid ?? "-"} '
        'bitrate=$bitrateText';
  }

  bool _shouldEmitPeriodicAudioState(DateTime now) {
    final last = _lastAudioStateLogAt;
    if (last == null || now.difference(last) >= const Duration(seconds: 5)) {
      _lastAudioStateLogAt = now;
      return true;
    }
    return false;
  }

  Future<AudioStateSnapshot?> _captureAudioStateSnapshot({
    required String reason,
    required bool emitState,
  }) async {
    if (!_alive) return null;
    final state = _player.state;
    final trackListRaw = await _getMpv('track-list', logError: false);
    final aidRaw = await _getMpv('aid', logError: false);
    final muteRaw = await _getMpv('mute', logError: false);
    final bitrateRaw = await _getMpv('audio-bitrate', logError: false);

    final tracks = _audioTracks(trackListRaw);
    final snapshot = AudioStateSnapshot(
      playing: state.playing,
      buffering: state.buffering,
      volume: state.volume,
      muted: _toBool(muteRaw),
      audioTrackCount: tracks.length,
      selectedAid: _selectedAidFromTracks(tracks, aidRaw),
      audioBitrate: _toDouble(bitrateRaw),
    );

    if (emitState) {
      _emitTransportEvent(
        PlayerTransportEvent(
          timestamp: DateTime.now(),
          traceId: _transportTraceId,
          type: PlayerTransportEventType.audioState,
          position: state.position,
          note: _audioSnapshotNote(snapshot, reason: reason),
        ),
      );
    }

    return snapshot;
  }

  void _startAudioHealthWatchdog() {
    _audioHealthTimer?.cancel();
    _audioHealthTimer = null;
    if (!PlayerTuning.audioDropWatchEnabled) return;

    _audioHealthTimer = Timer.periodic(
      PlayerTuning.audioHealthPollInterval,
      (_) {
        if (!_alive) return;
        final now = DateTime.now();
        if (!_player.state.playing) {
          final lastPausedCheck = _lastPausedAudioHealthCheckAt;
          if (lastPausedCheck != null &&
              now.difference(lastPausedCheck) <
                  PlayerTuning.audioWatchdogPausedPollInterval) {
            return;
          }
          _lastPausedAudioHealthCheckAt = now;
        } else {
          _lastPausedAudioHealthCheckAt = null;
        }
        unawaited(_checkAudioHealth(reason: 'watchdog'));
      },
    );

    unawaited(_checkAudioHealth(
      reason: 'watchdog_start',
      forceLogState: true,
    ));
  }

  Future<void> _checkAudioHealth({
    required String reason,
    bool forceLogState = false,
  }) async {
    if (!PlayerTuning.audioDropWatchEnabled) return;
    if (!_alive || _audioRecoveryInFlight) return;

    final now = DateTime.now();
    final emitState = forceLogState ||
        (_player.state.playing && _shouldEmitPeriodicAudioState(now));
    final snapshot = await _captureAudioStateSnapshot(
      reason: reason,
      emitState: emitState,
    );
    if (snapshot == null || !_alive) return;

    final decision = _audioDropDetector.evaluate(snapshot, now: now);
    if (decision == AudioRecoveryDecision.none) return;

    _emitTransportEvent(
      PlayerTransportEvent(
        timestamp: DateTime.now(),
        traceId: _transportTraceId,
        type: PlayerTransportEventType.audioDropDetected,
        position: _player.state.position,
        note:
            'decision=${decision.name} ${_audioSnapshotNote(snapshot, reason: reason)}',
      ),
    );

    if (decision == AudioRecoveryDecision.reselectAid) {
      await _reselectAudioTrack(reason: reason, before: snapshot);
    }
  }

  Future<void> _reselectAudioTrack({
    required String reason,
    AudioStateSnapshot? before,
  }) async {
    if (!_alive || _audioRecoveryInFlight) return;
    _audioRecoveryInFlight = true;
    try {
      _emitTransportEvent(
        PlayerTransportEvent(
          timestamp: DateTime.now(),
          traceId: _transportTraceId,
          type: PlayerTransportEventType.audioReselectStart,
          position: _player.state.position,
          note: before == null
              ? 'reason=$reason'
              : _audioSnapshotNote(before, reason: reason),
        ),
      );

      await _setMpv('aid', 'no');
      await Future.delayed(PlayerTuning.audioReselectSettleDelay);
      if (!_alive) return;

      await _setMpv('aid', 'auto');
      await Future.delayed(PlayerTuning.audioReselectSettleDelay);
      if (!_alive) return;

      final after = await _captureAudioStateSnapshot(
        reason: 'reselect_after',
        emitState: true,
      );
      final success = after != null &&
          after.audioTrackCount > 0 &&
          after.selectedAid != null &&
          after.selectedAid!.toLowerCase() != 'no';

      _emitTransportEvent(
        PlayerTransportEvent(
          timestamp: DateTime.now(),
          traceId: _transportTraceId,
          type: PlayerTransportEventType.audioReselectEnd,
          position: _player.state.position,
          note: after == null
              ? 'reason=$reason success=false'
              : 'reason=$reason success=$success '
                  '${_audioSnapshotNote(after, reason: 'reselect_after')}',
        ),
      );
    } finally {
      _audioRecoveryInFlight = false;
    }
  }

  Future<void> _selectOnlyExternalSubtitleIfPossible() async {
    if (!_alive) return;
    if (!_subtitlesEnabled) return;

    final list = await _getMpv('track-list');
    if (list is! List) return;

    Map<String, dynamic>? external;
    for (final t in list) {
      if (t is! Map) continue;
      final type = t['type']?.toString();
      if (type != 'sub') continue;
      final isExternal = t['external'] == true;
      if (isExternal) {
        external = Map<String, dynamic>.from(t);
        break;
      }
    }
    if (external == null) return;

    final id = external['id'];
    if (id == null) return;

    // Force exactly one subtitle: pick the external one as primary; disable secondary & CC.
    unawaited(_setMpv('ccsid', 'no'));
    unawaited(_setMpv('secondary-sid', 'no'));
    unawaited(_setMpv('secondary-sub-visibility', 'no'));
    unawaited(_setMpv('sid', id.toString()));
    unawaited(_setMpv('sub-visibility', 'yes'));

    // Re-apply style after attaching (some formats load with their own style).
    unawaited(_applySubtitleStyle());
  }

  Future<void> _applyExternalSubtitleIfAny({bool force = false}) async {
    if (!_alive) return;

    // On iOS, avoid Flutter-side subs only while native player is active.
    if (_isIOS && _iosNativeActive) return;

    // Don't attempt to attach subtitles before the first media is opened.
    if (!_hasOpenedMedia) return;

    if (!_subtitlesEnabled) {
      unawaited(_setMpv('sub-auto', 'no'));
      unawaited(_setMpv('secondary-sid', 'no'));
      unawaited(_setMpv('secondary-sub-visibility', 'no'));
      unawaited(_setMpv('sub-visibility', 'no'));
      unawaited(_setMpv('sid', 'no'));
      unawaited(_setMpv('ccsid', 'no'));
      return;
    }

    // Prevent mpv from auto-selecting an embedded subtitle/CC track.
    unawaited(_setMpv('sub-auto', 'no'));
    unawaited(_setMpv('ccsid', 'no'));

    final raw = widget.args.subtitleUrl;
    if (raw == null || raw.trim().isEmpty) {
      // No external subs; just ensure we don't show a secondary track.
      unawaited(_setMpv('secondary-sid', 'no'));
      unawaited(_setMpv('secondary-sub-visibility', 'no'));
      unawaited(_setMpv('sub-visibility', 'yes'));
      return;
    }

    final url =
        raw.trim().startsWith('//') ? 'https:${raw.trim()}' : raw.trim();

    // Avoid adding the same external subtitle multiple times for the same open.
    if (!force &&
        _subtitleAppliedSerial == _openSerial &&
        _subtitleAppliedUrl == url) {
      unawaited(_setMpv('secondary-sid', 'no'));
      unawaited(_setMpv('secondary-sub-visibility', 'no'));
      unawaited(_setMpv('sub-visibility', 'yes'));
      return;
    }

    final platform = _player.platform;
    if (platform is! NativePlayer) return;

    // Never show two subtitle tracks at once.
    unawaited(_setMpv('secondary-sid', 'no'));
    unawaited(_setMpv('secondary-sub-visibility', 'no'));

    // Ensure embedded/inband subtitles are not simultaneously selected.
    unawaited(_setMpv('sid', 'no'));

    // Prefer mpv command, fallback to property in case command isn't available.
    try {
      final dyn = platform as dynamic;
      await dyn.command(<String>['sub-add', url, 'select']);
      await platform.setProperty('sub-visibility', 'yes');

      // If the stream also has inband subs, force-select only the external one.
      await _selectOnlyExternalSubtitleIfPossible();

      _subtitleAppliedSerial = _openSerial;
      _subtitleAppliedUrl = url;
    } catch (e) {
      _log('subtitle attach via command failed: $e');
      try {
        await platform.setProperty('sub-file', url);
        await platform.setProperty('sub-visibility', 'yes');

        await _selectOnlyExternalSubtitleIfPossible();

        _subtitleAppliedSerial = _openSerial;
        _subtitleAppliedUrl = url;
      } catch (e2) {
        _log('subtitle attach via property failed: $e2');
      }
    }
  }

  // Place near other helpers
  Future<void> _setVolumeSafe(double v) async {
    // Never call player methods if page is leaving or disposed
    if (!_alive) return;

    // Reset auto-skip flags for a fresh media open (quality change / next episode).
    _openingSkipped = false;
    _endingSkipped = false;

    try {
      await _player.setVolume(v);
    } catch (e) {
      _log('setVolume skipped (not alive): $e');
    }
  }

  Future<void> _flushDesktopVolumeToPrefs({required String reason}) async {
    if (!_isDesktop) return;

    // If a debounced write is pending, cancel it and flush immediately.
    _volumePersistDebounce?.cancel();
    _volumePersistDebounce = null;

    try {
      await ref
          .read(playerPrefsProvider.notifier)
          .setDesktopVolume(_desktopVolume);
      _log(
          'flushed desktop volume to prefs (reason=$reason, v=$_desktopVolume)');
    } catch (e) {
      _log('flush desktop volume failed: $e');
    }
  }

  void _notePausedNow() {
    final now = DateTime.now();
    _resumeAnchorTxnInFlight = false;
    _pausedAt ??= now;
    _longPauseBufferResetDone = false;
    _resumeAnchorPosition ??= _player.state.position;
    final anchor = _resumeAnchorPosition;
    final pausedAt = _pausedAt;
    if (anchor != null && pausedAt != null) {
      _resumeLockController.markPaused(
        anchorPosition: anchor,
        now: pausedAt,
      );
    }
  }

  void _notePlaybackResumed() {
    _pausedAt = null;
    _lastPausedAudioHealthCheckAt = null;
    if (!_resumeAnchorTxnInFlight) {
      _resumeAnchorPosition = null;
      _resumeLockController.clearResumeContext();
    }
  }

  void _clearResumeAnchorContext() {
    _resumeAnchorTxnInFlight = false;
    _resumeAnchorPosition = null;
    _resumeLockController.clearResumeContext();
  }

  String _recentFullscreenTransitionNote(DateTime now) {
    final ts = _lastFullscreenTransitionAt;
    if (ts == null) return '';
    final age = now.difference(ts);
    if (age.isNegative || age > const Duration(seconds: 3)) return '';
    final kind = _lastFullscreenTransitionType ?? '-';
    return ' fsRecent=$kind fsAgeMs=${age.inMilliseconds}';
  }

  Future<void> _maybeResetBuffersAfterLongPause(
      {required String reason}) async {
    final pausedAt = _pausedAt;
    if (!_alive || pausedAt == null || _longPauseBufferResetDone) return;

    final pausedFor = DateTime.now().difference(pausedAt);
    final sinceSeek =
        _lastSeekAt == null ? null : DateTime.now().difference(_lastSeekAt!);
    if (pausedFor < PlayerTuning.longPauseBufferResetAfter) return;

    _longPauseBufferResetDone = true;
    await _mpvCommand(const ['drop-buffers']);
    _emitTransportEvent(
      PlayerTransportEvent(
        timestamp: DateTime.now(),
        traceId: _transportTraceId,
        type: PlayerTransportEventType.cacheReset,
        position: _player.state.position,
        note: sinceSeek == null
            ? 'reason=$reason pausedMs=${pausedFor.inMilliseconds}'
            : 'reason=$reason pausedMs=${pausedFor.inMilliseconds} sinceSeekMs=${sinceSeek.inMilliseconds}',
      ),
    );
  }

  Future<Duration?> _prepareResumeAnchorBeforePlay({
    required String reason,
  }) async {
    if (!_alive || !PlayerTuning.resumeAnchorEnabled) return null;
    final snapshot = _resumeLockController.snapshotOnResume();
    if (snapshot == null) return null;

    final decision = _resumeLockController.decideOnResume(snapshot);
    if (decision != ResumeAnchorDecision.applyAnchor) return null;

    final anchor = _clampSeekAbsolute(snapshot.anchorPosition);
    _resumeAnchorTxnInFlight = true;
    _emitTransportEvent(
      PlayerTransportEvent(
        timestamp: DateTime.now(),
        traceId: _transportTraceId,
        type: PlayerTransportEventType.resumeAnchorStart,
        position: _player.state.position,
        targetPosition: anchor,
        note: 'reason=$reason pauseMs=${snapshot.pauseDuration.inMilliseconds}',
      ),
    );
    await _seekPlanned(anchor, reason: 'resume_anchor');
    return anchor;
  }

  Future<bool> _verifyResumeAnchorOnce({
    required Duration anchorTarget,
    required String reason,
    required Duration delay,
    required String phase,
  }) async {
    await Future.delayed(delay);
    if (!_alive) return false;

    final state = _player.state;
    final current = state.position;
    final delta = (current - anchorTarget).abs();
    _emitTransportEvent(
      PlayerTransportEvent(
        timestamp: DateTime.now(),
        traceId: _transportTraceId,
        type: PlayerTransportEventType.resumeAnchorVerify,
        position: current,
        targetPosition: anchorTarget,
        note: 'reason=$reason phase=$phase deltaMs=${delta.inMilliseconds} '
            'buffering=${state.buffering}',
      ),
    );

    if (delta <= PlayerTuning.resumeAnchorDriftTolerance) return true;
    if (state.buffering ||
        delta <= PlayerTuning.resumeAnchorMismatchThreshold) {
      return false;
    }

    final decision = _resumeLockController.decideCorrection(
      currentPosition: current,
      buffering: state.buffering,
    );
    if (decision != ResumeAnchorDecision.correctOnce) {
      _emitTransportEvent(
        PlayerTransportEvent(
          timestamp: DateTime.now(),
          traceId: _transportTraceId,
          type: PlayerTransportEventType.resumeAnchorMismatch,
          position: current,
          targetPosition: anchorTarget,
          note: 'reason=$reason phase=$phase '
              'deltaMs=${delta.inMilliseconds} correction=false',
        ),
      );
      return false;
    }

    _emitTransportEvent(
      PlayerTransportEvent(
        timestamp: DateTime.now(),
        traceId: _transportTraceId,
        type: PlayerTransportEventType.resumeAnchorMismatch,
        position: current,
        targetPosition: anchorTarget,
        note: 'reason=$reason phase=$phase '
            'deltaMs=${delta.inMilliseconds} correction=true',
      ),
    );
    await _seekPlanned(anchorTarget, reason: 'resume_anchor_correction');
    return true;
  }

  Future<bool> _verifyResumeAnchorAfterPlay({
    required Duration anchorTarget,
    required String reason,
  }) async {
    final first = await _verifyResumeAnchorOnce(
      anchorTarget: anchorTarget,
      reason: reason,
      delay: PlayerTuning.resumeAnchorVerifyDelay,
      phase: 'first',
    );
    final second = await _verifyResumeAnchorOnce(
      anchorTarget: anchorTarget,
      reason: reason,
      delay: PlayerTuning.resumeAnchorSecondVerifyDelay,
      phase: 'second',
    );
    return first && second;
  }

  Future<void> _playTracked({required String reason}) async {
    if (!_alive) return;
    await _maybeResetBuffersAfterLongPause(reason: reason);
    if (!_alive) return;

    Duration? anchorTarget;
    bool anchorSuccess = true;
    String anchorEndNote = '';
    try {
      anchorTarget = await _prepareResumeAnchorBeforePlay(reason: reason);
      if (!_alive) return;
      await _player.play();
      _notePlaybackResumed();
      if (anchorTarget != null) {
        anchorSuccess = await _verifyResumeAnchorAfterPlay(
          anchorTarget: anchorTarget,
          reason: reason,
        );
        final correctionUsed = _resumeLockController.correctionAttempts;
        anchorEndNote = 'reason=$reason success=$anchorSuccess '
            'correctionUsed=$correctionUsed';
      }
    } catch (e) {
      _log('play failed (reason=$reason): $e');
      if (anchorTarget != null) {
        anchorSuccess = false;
        anchorEndNote = 'reason=$reason success=false error=play_failed';
      }
    } finally {
      if (anchorTarget != null) {
        _emitTransportEvent(
          PlayerTransportEvent(
            timestamp: DateTime.now(),
            traceId: _transportTraceId,
            type: PlayerTransportEventType.resumeAnchorEnd,
            position: _player.state.position,
            targetPosition: anchorTarget,
            note: anchorEndNote.isEmpty
                ? 'reason=$reason success=$anchorSuccess correctionUsed='
                    '${_resumeLockController.correctionAttempts}'
                : anchorEndNote,
          ),
        );
      }
      _clearResumeAnchorContext();
    }
  }

  Future<void> _pauseTracked({required String reason}) async {
    if (!_alive) return;
    try {
      await _player.pause();
    } catch (e) {
      _log('pause failed (reason=$reason): $e');
    } finally {
      _notePausedNow();
    }
  }

  Future<void> _playOrPauseTracked({required String reason}) async {
    if (!_alive) return;
    if (_player.state.playing) {
      await _pauseTracked(reason: '${reason}_pause');
    } else {
      await _playTracked(reason: '${reason}_play');
    }
  }

  // Call this right after _player = Player(...);
  Future<void> _hardenMpvForHls() async {
    // --- Core cache knobs: make seeks & jitter resilient ---
    unawaited(_setMpv('cache', 'yes')); // enable demuxer cache
    unawaited(_setMpv('cache-secs', '30')); // ~30s target cache
    unawaited(
        _setMpv('demuxer-seekable-cache', 'yes')); // allow seeks from cache
    unawaited(_setMpv('demuxer-readahead-secs', '15')); // read ahead more data
    unawaited(_setMpv(
        'demuxer-max-back-bytes', '${64 * 1024 * 1024}')); // 64MB back buffer

    // --- Avoid aggressive frame dropping on micro stalls ---
    unawaited(
        _setMpv('hr-seek-framedrop', 'no')); // keep frames on precise seeks
    unawaited(_setMpv('framedrop', 'no')); // prefer not dropping frames

    // --- Keep timeline anchored to audio to reduce late seek teleports ---
    unawaited(_setMpv('video-sync', PlayerTuning.mpvVideoSyncMode));
    // Optional: if you see micro-judder, you can also try interpolation
    // unawaited(_setMpv('interpolation', 'yes'));
    // unawaited(_setMpv('tscale', 'oversample'));

    // --- Hardware decoding policy ---
    // Use auto-safe to allow mpv to fall back when hardware decode becomes
    // unstable on specific HLS segments after long pauses/seeks.
    unawaited(_setMpv('hwdec', 'auto-safe'));
    unawaited(_setMpv('vd-lavc-software-fallback', 'yes'));

    // --- Stabilize timestamp probing for HLS/TS (helps missing PTS) ---
    unawaited(_setMpv('demuxer-lavf-analyzeduration', '10')); // seconds
    unawaited(_setMpv('demuxer-lavf-probesize', '${50 * 1024 * 1024}'));
    // Generate missing PTS without aggressively dropping "corrupt" packets.
    // Dropping on transient HLS transport glitches can permanently hide frames.
    unawaited(_setMpv('demuxer-lavf-o', 'fflags=+genpts'));

    // --- HTTP/HLS transport safety (you already set some; keep them consolidated) ---
    final streamLavfOptions = <String>[
      // Avoid stale keep-alive connections across long pause/seek windows.
      'http_persistent=${PlayerTuning.mpvHlsPersistentConnection ? 1 : 0}',
      'reconnect=1',
      'reconnect_streamed=1',
      'reconnect_on_http_error=4xx,5xx',
    ];
    unawaited(_setMpv('stream-lavf-o', streamLavfOptions.join(':')));

    // --- Optional: tame decoder threading if you see sporadic drops on low cores ---
    // unawaited(_setMpv('vd-lavc-threads', '2'));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Suppress quality reaction during initial load to prevent race with saved position
    _suppressPrefQualityReopen = true;

    _bumpUiVisibility();

    final raw = widget.item?.progress; // real stored progress
    _knownProgress = _progressBaselineForOrdinal(widget.args.ordinal, raw);

    // Create player first. Do NOT call _setMpv() before this point.
    _player = Player(
      configuration: PlayerConfiguration(
        vo: 'gpu',
        title: 'AnimeShin',
        logLevel: MPVLogLevel.error, // keep only error-level from mpv core
        bufferSize: _isWindows
            ? PlayerTuning.windowsBufferBytes
            : PlayerTuning.otherBufferBytes,
        async: true,
      ),
    );
    _video = VideoController(_player);
    _proxy = LocalHlsProxy(
      traceId: _transportTraceId,
      onEvent: _onProxyEvent,
    );
    _log('transport trace id: $_transportTraceId');

    // // Safe mpv tweaks (HLS host-switch & log filtering).
    // unawaited(_setMpv(
    //   'stream-lavf-o',
    //   // Keep-alive off + safe reconnects. Avoid multiple_requests here.
    //   'http_persistent=0:reconnect=1:reconnect_streamed=1:reconnect_on_http_error=4xx,5xx',
    // ));
    // unawaited(_setMpv('msg-level', 'ffmpeg=error'));
    _hardenMpvForHls();

    // Preferences subscription — no awaits inside the callback.
    _prefsSub = ref.listenManual<PlayerPrefs>(
      playerPrefsProvider,
      (prev, next) async {
        if (!mounted || _navigatingAway) return;

        _autoSkipOpening = next.autoSkipOpening;
        _autoSkipEnding = next.autoSkipEnding;
        _autoNextEpisode = next.autoNextEpisode;
        _autoProgress = next.autoProgress;
        _subtitlesEnabled = next.subtitlesEnabled;
        _subtitleFontSize = next.subtitleFontSize;
        _subtitleColor = next.subtitleColor;
        _subtitleOutlineSize = next.subtitleOutlineSize;
        _speed = next.speed;
        _seekStepSeconds = next.seekForward;

        // Apply subtitle toggle only on changes (and only after first open).
        if (prev != null &&
            prev.subtitlesEnabled != next.subtitlesEnabled &&
            _alive) {
          if (_subtitlesEnabled) {
            unawaited(_setMpv('secondary-sid', 'no'));
            unawaited(_setMpv('secondary-sub-visibility', 'no'));
            unawaited(_setMpv('sub-visibility', 'yes'));
            unawaited(_applyExternalSubtitleIfAny());
          } else {
            unawaited(_setMpv('secondary-sid', 'no'));
            unawaited(_setMpv('secondary-sub-visibility', 'no'));
            unawaited(_setMpv('sub-visibility', 'no'));
            unawaited(_setMpv('sid', 'no'));
          }
        }

        // Apply subtitle styling on changes (desktop/mpv only).
        if (prev != null && _alive) {
          final styleChanged = prev.subtitleFontSize != next.subtitleFontSize ||
              prev.subtitleColor != next.subtitleColor ||
              prev.subtitleOutlineSize != next.subtitleOutlineSize;
          if (styleChanged) {
            unawaited(_applySubtitleStyle());
          }
        }

        // Apply desktop volume from prefs when it changes externally.
        if (_isDesktop) {
          final prevVol = prev?.desktopVolume ?? _desktopVolume;
          _desktopVolume = next.desktopVolume;

          // Bail if player is already gone
          if (!_alive) return;

          // Reset auto-skip flags for a fresh media open (quality change / next episode).
          _openingSkipped = false;
          _endingSkipped = false;

          // Read current volume only while alive
          final currentVol = _player.state.volume;

          // Update volume only if it actually changed (debounce)
          if ((prevVol - next.desktopVolume).abs() > 0.1 &&
              (currentVol - _desktopVolume).abs() > 0.1) {
            unawaited(_setVolumeSafe(_desktopVolume));
          }
        }

        _safeSetState(() {});

        // If preferred quality changed outside of the menu (rare), apply it.
        if (!_suppressPrefQualityReopen &&
            prev?.preferredQuality != next.preferredQuality) {
          unawaited(_changeQuality(next.preferredQuality));
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
          {
            _iosNativeActive = false;
            // Native VC was dismissed (not PiP).
            final map = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            final posSec = (map['position'] as num?)?.toDouble() ?? 0.0;
            final rate = (map['rate'] as num?)?.toDouble() ?? _speed;
            final wasPlaying = (map['wasPlaying'] as bool?) ?? true;

            final target = Duration(milliseconds: (posSec * 1000).round());
            _speed = rate;

            // If user left at the very end, clear local playback & bump AniList.
            if (_player.state.duration > Duration.zero &&
                target >= _player.state.duration - const Duration(seconds: 1)) {
              unawaited(_playback.clearEpisode(
                widget.animeVoice,
                widget.args.id,
                widget.args.ordinal,
              ));
              if (_autoProgress && widget.item != null) {
                final ord = widget.args.ordinal;
                final current = _progressBaselineForOrdinal(
                  ord,
                  _knownProgress ?? widget.item?.progress,
                );
                if (ord > current) {
                  _autoIncDoneForThisEp = true;
                  _autoIncGuardForOrdinal = ord;
                  unawaited(_persistAniListProgress(ord, setAsCurrent: false));
                }
              }
            }

            // Restore Flutter-side player (seek → rate → resume).
            await _restoreFromIOSDismiss(
              target: target,
              rate: rate,
              wasPlaying: wasPlaying,
            );
            _safeSetState(() {});
            break;
          }

        case 'ios_player_completed':
          {
            _iosNativeActive = false;
            // Clear local persisted playback for this episode.
            await _playback.clearEpisode(
              widget.animeVoice,
              widget.args.id,
              widget.args.ordinal,
            );

            // Bump AniList progress if needed.
            if (_autoProgress && widget.item != null) {
              final ord = widget.args.ordinal;
              final current = _progressBaselineForOrdinal(
                ord,
                _knownProgress ?? widget.item?.progress,
              );
              if (ord > current) {
                final err =
                    await _persistAniListProgress(ord, setAsCurrent: false);
                if (err == null) {
                  _knownProgress = ord;
                } else if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content:
                            Text('Failed to update AniList progress: $err')),
                  );
                }
              }
            }

            // Continue flow.
            if (_autoNextEpisode) {
              _hideCursorInstant();
              unawaited(_openNextEpisode());
            } else {
              _showBanner('Completed');
            }
            break;
          }

        case 'ios_pip_restored':
          {
            _iosNativeActive = false;
            // User exited PiP and native VC was restored to fullscreen.
            // Persist current position to keep Flutter-side "continue watching" in sync.
            final map = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            final posSec = (map['position'] as num?)?.toDouble() ?? 0.0;
            // We only save; playback continues in native VC.
            await _playback.saveEntry(
              widget.animeVoice,
              widget.args.id,
              widget.args.ordinal,
              seconds: posSec.round(),
            );
            break;
          }

        default:
          break;
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_nativeFsActive && _isMobile && !_navigatingAway) {
      unawaited(_reapplyMobileNativeFullscreen(reason: 'app_resumed'));
    }
    if (!_alive || !PlayerTuning.audioDropWatchEnabled) return;
    unawaited(_checkAudioHealth(
      reason: 'app_resumed',
      forceLogState: true,
    ));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    // Mark as leaving & disposed ASAP so any pending futures bail out.
    _navigatingAway = true;
    _isDisposed = true;

    // Stop timers & streams first.
    _prefsSub.close();

    // If a debounced volume write is pending, flush it so the next open uses
    // the latest user-selected value.
    if (_isDesktop && _volumePersistDebounce != null) {
      _volumePersistDebounce?.cancel();
      _volumePersistDebounce = null;
      unawaited(
        ref.read(playerPrefsProvider.notifier).setDesktopVolume(_desktopVolume),
      );
    }

    _detachListeners();
    // Avoid clearing progress on dispose; crashes can look like completion.
    unawaited(_saveProgress(allowClear: false));

    // Stop proxy (safe to call even if not running).
    unawaited(_proxy.stop());

    // Do NOT access player state asynchronously anymore.
    try {
      _player.dispose();
    } catch (_) {}

    // Break reference to now-deactivated controls subtree.
    _mediaKitVideoState = null;
    _controlsCtxNormal = null;
    _removeFullscreenBannerOverlayIfAny();
    _controlsCtxFullscreen = null;

    _removeCursorOverlayIfAny();
    unawaited(_exitNativeFullscreen());
    _cursorForceVisible.dispose();
    _uiVisibleNotifier.dispose();
    _controlsOverlayRevision.dispose();

    super.dispose();
  }

  // ---------- Quality helpers ----------

  PlayerQuality _pickInitialQualityAndUrl() {
    final pref = ref.read(playerPrefsProvider).preferredQuality;
    final result = pickInitialQualityAndUrl(
      preferredQuality: pref,
      url1080: widget.args.url1080,
      url720: widget.args.url720,
      url480: widget.args.url480,
      log: _log,
      argsIdentity: widget.args,
    );
    if (result.chosenUrl != null && result.chosenUrl!.isNotEmpty) {
      _chosenUrl = result.chosenUrl; // store remote (original) URL
    }
    return result.quality;
  }

  // ---------- Bootstrap ----------

  Future<void> _init() async {
    await ref.read(playerPrefsProvider.notifier).ready();

    final prefs = ref.read(playerPrefsProvider);
    _speed = prefs.speed;
    _seekStepSeconds = prefs.seekForward;
    _autoSkipOpening = prefs.autoSkipOpening;
    _autoSkipEnding = prefs.autoSkipEnding;
    _autoNextEpisode = prefs.autoNextEpisode;
    _autoProgress = prefs.autoProgress;
    _subtitlesEnabled = prefs.subtitlesEnabled;
    _subtitleFontSize = prefs.subtitleFontSize;
    _subtitleColor = prefs.subtitleColor;
    _subtitleOutlineSize = prefs.subtitleOutlineSize;
    _desktopVolume = prefs.desktopVolume;

    _currentQuality = _pickInitialQualityAndUrl();

    if (_chosenUrl == null || _chosenUrl!.isEmpty) {
      _snack('No stream URL available.');
      return;
    }
    final originalUrl = _chosenUrl!.trim();
    final transport = await _resolveOpenTransport(
      originalUrl,
      reason: 'init',
    );

    _proxyFallbackAttempted = false;
    _openedViaProxy = transport.openedViaProxy;

    await _openAt(
      transport.toOpen,
      // We still perform a normal seek — progress bar remains absolute.
      position: await _restoreSavedPosition(),
      play: true,
      originalUrl: originalUrl,
      openedViaProxy: _openedViaProxy,
      allowOppositeRetry: true,
    );

    // Ensure subtitle visibility matches prefs after the first open.
    if (_subtitlesEnabled) {
      unawaited(_setMpv('secondary-sid', 'no'));
      unawaited(_setMpv('secondary-sub-visibility', 'no'));
      unawaited(_setMpv('sub-visibility', 'yes'));
    } else {
      unawaited(_setMpv('secondary-sid', 'no'));
      unawaited(_setMpv('secondary-sub-visibility', 'no'));
      unawaited(_setMpv('sub-visibility', 'no'));
      unawaited(_setMpv('sid', 'no'));
    }

    // Apply subtitle styling (desktop/mpv only).
    unawaited(_applySubtitleStyle());

    // Apply persisted desktop volume & speed right after the first open.
    if (_isDesktop) {
      await _setVolumeSafe(_desktopVolume);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _cursorForceVisible.value = false; // no force
        _cursorHideController.kick(); // start the single 3s countdown
      });
    }
    if (_alive) {
      try {
        await _player.setRate(_speed);
      } catch (_) {}
    }

    // Persist progress periodically.
    _autosaveTimer =
        Timer.periodic(PlayerTuning.autosavePeriod, (_) => _saveProgress());

    // Save desktop volume back to prefs when user changes it via controls.
    _subVolume = _player.stream.volume.listen((v) {
      if (!_isDesktop) return;
      if ((v - _desktopVolume).abs() < 0.05) return;
      // mpv volume is 0..100.0; store as-is.
      _desktopVolume = v;
      _volumePersistDebounce?.cancel();
      _volumePersistDebounce = Timer(PlayerTuning.volumePersistDebounce, () {
        unawaited(
          ref
              .read(playerPrefsProvider.notifier)
              .setDesktopVolume(_desktopVolume),
        );
      });
    });

    _subBuffering = _player.stream.buffering.listen((isBuffering) {
      if (_lastBufferingState == isBuffering) return;
      _lastBufferingState = isBuffering;
      _emitTransportEvent(
        PlayerTransportEvent(
          timestamp: DateTime.now(),
          traceId: _transportTraceId,
          type: isBuffering
              ? PlayerTransportEventType.bufferingStart
              : PlayerTransportEventType.bufferingEnd,
          position: _player.state.position,
        ),
      );
      if (!isBuffering) {
        unawaited(_checkAudioHealth(
          reason: 'buffering_end',
          forceLogState: true,
        ));
      }
    });

    _subPlaying = _player.stream.playing.listen((isPlaying) {
      if (isPlaying) {
        if (!_resumeAnchorTxnInFlight) {
          unawaited(
            _maybeResetBuffersAfterLongPause(reason: 'resume_playing_stream'),
          );
        }
        _notePlaybackResumed();
      } else {
        if (!_player.state.buffering) {
          _notePausedNow();
        }
      }
    });

    _subPos = _player.stream.position.listen((pos) {
      // Log-only jump detector: report suspicious forward leaps but do nothing.
      final prev = _lastPos;
      _lastPos = pos;

      if (_enableJumpDetector &&
          _player.state.duration != Duration.zero &&
          !_plannedSeek &&
          prev > Duration.zero &&
          !_inQuarantine &&
          !_player.state.buffering) {
        final diff = pos - prev;

        // Threshold raised to 3.5s to avoid timer hiccups on Windows.
        if (diff > PlayerTuning.jumpLogThreshold) {
          final now = DateTime.now();
          if (_jumpWindowStartedAt == null ||
              now.difference(_jumpWindowStartedAt!) >
                  PlayerTuning.jumpQuarantineWindow) {
            _jumpWindowStartedAt = now;
            _consecutiveJumpCount = 1;
          } else {
            _consecutiveJumpCount++;
          }

          final bigLeap = diff >= PlayerTuning.jumpBigLeap;
          final burst = _consecutiveJumpCount >= 3;
          final correlated = _transportCorrelator.correlateJump(DateTime.now());
          final fsNote = _recentFullscreenTransitionNote(now);

          _log('! unexpected jump detected: +${diff.inMilliseconds}ms '
              '(prev=$prev → now=$pos, bigLeap=$bigLeap, burst=$burst, '
              'relatedReq=${correlated.requestId?.toString() ?? "-"}, '
              'relatedAgeMs=${correlated.age?.inMilliseconds.toString() ?? "-"}'
              '$fsNote)');
          _emitTransportEvent(
            PlayerTransportEvent(
              timestamp: DateTime.now(),
              traceId: _transportTraceId,
              type: PlayerTransportEventType.unexpectedJump,
              position: pos,
              note:
                  'deltaMs=${diff.inMilliseconds} bigLeap=$bigLeap burst=$burst$fsNote',
              relatedProxyRequestId: correlated.requestId,
              relatedProxyAge: correlated.age,
            ),
          );

          // IMPORTANT: No corrective actions here (logging-only requirement).
        }
      }

      // DO NOT force setVolume here. It causes fighting with user changes.
      _maybeAutoSkip(pos);

      // Try to bump AniList progress when near the ending / tail of the episode
      if (_autoProgress) {
        unawaited(_maybeAutoIncrementProgress(pos));
      }

      // Keep UI updates bounded (position stream can emit very frequently).
      final sec = pos.inSeconds;
      if (sec != _lastUiPosSecond) {
        _lastUiPosSecond = sec;
        _safeSetState(() {});
      }
    });

    _subCompleted = _player.stream.completed.listen((done) {
      if (!done) return;
      unawaited(_saveProgress(clearIfCompleted: true));

      // Ensure AniList progress is bumped on completion as well
      if (_autoProgress && widget.item != null) {
        final ord = widget.args.ordinal;
        final current = _progressBaselineForOrdinal(
            ord, _knownProgress ?? widget.item?.progress);
        if (ord > current) {
          unawaited(_persistAniListProgress(ord, setAsCurrent: false));
        }
      }

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

    _startAudioHealthWatchdog();

    if (widget.startupBannerText?.isNotEmpty == true) {
      _showBanner(widget.startupBannerText!, affectCursor: false);
    }

    // Re-enable quality reaction after initial playback stabilizes (HLS settle + seek)
    _qualityReopenTimer?.cancel();
    _qualityReopenTimer = Timer(const Duration(seconds: 8), () {
      if (_alive) {
        _suppressPrefQualityReopen = false;
      }
    });
  }

  // ---------- Persistence ----------

  Future<Duration> _restoreSavedPosition() async {
    if (widget.args.startFromZero) {
      _log('restore: startFromZero=true, starting fresh');
      return Duration.zero;
    }
    final entry = await _playback.readEntry(
      widget.animeVoice,
      widget.args.id,
      widget.args.ordinal,
    );
    final saved = entry?.seconds ?? 0;

    _log('restore: read from ordinal=${widget.args.ordinal}, got=${saved}s');

    // If user never watched (or only a tiny accidental start), treat as new episode.
    // This keeps new episodes starting from 0:00 while still resuming when user
    // intentionally stopped mid-episode.
    if (saved <= 15) {
      _log('restore: saved=${saved}s, starting fresh (≤15s)');
      return Duration.zero;
    }

    // If progress is very small and was last watched a long time ago, treat it as
    // a fresh start. This avoids "old" accidental progress forcing a resume.
    // Defaults: stale after 30 days, and "small" means < 3 minutes.
    final lastWatchedEpochMs = entry?.lastWatchedEpochMs;
    if (lastWatchedEpochMs != null && saved < 180) {
      final last = DateTime.fromMillisecondsSinceEpoch(lastWatchedEpochMs);
      final age = DateTime.now().difference(last);
      if (age >= const Duration(days: 30)) {
        _log(
            'restore: saved=${saved}s, age=${age.inDays}d, starting fresh (stale)');
        return Duration.zero;
      }
    }
    _log('restore: resuming at ${saved}s');
    return Duration(seconds: saved);
  }

  Future<void> _saveProgress({
    bool clearIfCompleted = false,
    bool allowClear = true,
  }) async {
    if (_navigatingAway || _saveInFlight) return;

    final pos = _player.state.position;
    final dur = _player.state.duration;
    if (dur.inSeconds <= 0) return;

    final ordinal = widget.args.ordinal;
    final sec = pos.inSeconds;
    final isCompleted = pos.inMilliseconds >= (dur.inMilliseconds * 0.98);
    if ((clearIfCompleted || isCompleted) && !allowClear) return;
    final wantsClear = (clearIfCompleted || isCompleted) && allowClear;
    if (wantsClear && _lastSavedOrdinal == ordinal && _lastSavedWasCleared) {
      return;
    }
    if (!wantsClear &&
        _lastSavedOrdinal == ordinal &&
        !_lastSavedWasCleared &&
        _lastSavedSecond == sec) {
      return;
    }

    _saveInFlight = true;
    try {
      if (wantsClear) {
        if (isCompleted) {
          _log(
              'save: episode completed, clearing position for ordinal=${widget.args.ordinal}');
        }
        await _playback.clearEpisode(
            widget.animeVoice, widget.args.id, widget.args.ordinal);
        _lastSavedOrdinal = ordinal;
        _lastSavedSecond = -1;
        _lastSavedWasCleared = true;
      } else {
        _log(
            'save: saving position=${pos.inSeconds}s to ordinal=${widget.args.ordinal}');
        await _playback.saveEntry(
          widget.animeVoice,
          widget.args.id,
          widget.args.ordinal,
          seconds: sec,
        );
        _lastSavedOrdinal = ordinal;
        _lastSavedSecond = sec;
        _lastSavedWasCleared = false;
      }
    } finally {
      _saveInFlight = false;
    }
  }

  // ---------- Media helpers ----------

  /// Wrapper that marks an intentional seek so our jump-detector won't flag it.
  Future<void> _seekPlanned(Duration to, {String? reason}) async {
    if (!_alive) return;

    final tgt = _clampSeekAbsolute(to);
    final request = SeekRequest(
      target: tgt,
      reason: reason,
      timestamp: DateTime.now(),
    );
    final result = _seekCoordinator.enqueue(request);

    switch (result.decision) {
      case SeekDecision.dropDuplicate:
        _emitTransportEvent(
          PlayerTransportEvent(
            timestamp: DateTime.now(),
            traceId: _transportTraceId,
            type: PlayerTransportEventType.seekCoalesced,
            position: _player.state.position,
            targetPosition: tgt,
            note: 'reason=${reason ?? "-"} action=drop_duplicate',
          ),
        );
        return;
      case SeekDecision.queueLatest:
        if (result.replacedPending) {
          _emitTransportEvent(
            PlayerTransportEvent(
              timestamp: DateTime.now(),
              traceId: _transportTraceId,
              type: PlayerTransportEventType.seekCoalesced,
              position: _player.state.position,
              targetPosition: tgt,
              note: 'reason=${reason ?? "-"} action=replace_pending',
            ),
          );
        } else {
          _emitTransportEvent(
            PlayerTransportEvent(
              timestamp: DateTime.now(),
              traceId: _transportTraceId,
              type: PlayerTransportEventType.seekQueued,
              position: _player.state.position,
              targetPosition: tgt,
              note: 'reason=${reason ?? "-"}',
            ),
          );
        }

        _completeSeekCompleter(_pendingSeekCompleter);
        final completer = Completer<void>();
        _pendingSeekCompleter = completer;
        _scheduleSeekPump();
        await completer.future;
        return;
      case SeekDecision.executeNow:
        await _executeSeekNow(request);
        await _pumpPendingSeekQueue();
        return;
    }
  }

  void _scheduleSeekPump() {
    _seekQueueTimer?.cancel();
    final delay = _seekCoordinator.delayUntilPendingReady();
    _seekQueueTimer = Timer(delay ?? Duration.zero, () {
      if (!_alive) return;
      unawaited(_pumpPendingSeekQueue());
    });
  }

  void _completeSeekCompleter(Completer<void>? completer) {
    if (completer == null) return;
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  Future<void> _pumpPendingSeekQueue() async {
    if (_seekPumpRunning || !_alive) return;
    _seekPumpRunning = true;
    try {
      while (_alive) {
        if (_seekCoordinator.inFlight) break;

        final pending = _seekCoordinator.takeReadyPending();
        if (pending == null) {
          final wait = _seekCoordinator.delayUntilPendingReady();
          if (wait != null) {
            _seekQueueTimer?.cancel();
            _seekQueueTimer = Timer(wait, () {
              if (!_alive) return;
              unawaited(_pumpPendingSeekQueue());
            });
          }
          break;
        }

        final completer = _pendingSeekCompleter;
        _pendingSeekCompleter = null;
        await _executeSeekNow(pending);
        _completeSeekCompleter(completer);
      }
    } finally {
      _seekPumpRunning = false;
    }
  }

  Future<void> _executeSeekNow(SeekRequest request) async {
    if (!_alive) return;

    _openingSkipped = false;
    _endingSkipped = false;

    final tgt = _clampSeekAbsolute(request.target);
    _seekCoordinator.markSeekStarted(request);
    _lastSeekAt = DateTime.now();

    _emitTransportEvent(
      PlayerTransportEvent(
        timestamp: DateTime.now(),
        traceId: _transportTraceId,
        type: PlayerTransportEventType.seekStart,
        position: _player.state.position,
        targetPosition: tgt,
        note: request.reason,
      ),
    );

    _plannedSeek = true;
    try {
      await _maybeResetBuffersAfterLongPause(
        reason: 'seek_${request.reason ?? "unknown"}',
      );
      _log(
          'seek: starting seek to ${tgt.inSeconds}s reason=${request.reason ?? "n/a"}');
      final stopwatch = Stopwatch()..start();
      await _player.seek(tgt);
      _log('seek: completed in ${stopwatch.elapsedMilliseconds}ms');
      _seekCoordinator.markSeekFinished(executedTarget: tgt);
      _emitTransportEvent(
        PlayerTransportEvent(
          timestamp: DateTime.now(),
          traceId: _transportTraceId,
          type: PlayerTransportEventType.seekEnd,
          position: _player.state.position,
          targetPosition: tgt,
          note: request.reason,
        ),
      );

      await _verifySeekResult(target: tgt, reason: request.reason);

      unawaited(_checkAudioHealth(
        reason: 'seek_end',
        forceLogState: true,
      ));
    } catch (e) {
      _seekCoordinator.markSeekFinished(executedTarget: tgt);
      _log('seek skipped (not alive): $e');
    } finally {
      await Future.delayed(const Duration(milliseconds: 300));
      _plannedSeek = false;
    }
  }

  Future<void> _verifySeekResult({
    required Duration target,
    required String? reason,
  }) async {
    await Future.delayed(PlayerTuning.seekVerifyDelay);
    if (!_alive) return;

    final state = _player.state;
    final current = state.position;
    final delta = (current - target).abs();
    _emitTransportEvent(
      PlayerTransportEvent(
        timestamp: DateTime.now(),
        traceId: _transportTraceId,
        type: PlayerTransportEventType.seekVerify,
        position: current,
        targetPosition: target,
        note:
            'reason=${reason ?? "-"} deltaMs=${delta.inMilliseconds} buffering=${state.buffering}',
      ),
    );

    if (state.buffering || delta <= PlayerTuning.seekVerifyTolerance) return;
    if (!_seekCoordinator.shouldCorrectMismatch(
      currentPosition: current,
      retryThreshold: PlayerTuning.seekMismatchRetryThreshold,
      maxCorrection: PlayerTuning.seekMismatchMaxCorrection,
    )) {
      return;
    }

    _seekCoordinator.noteCorrectionApplied();
    _emitTransportEvent(
      PlayerTransportEvent(
        timestamp: DateTime.now(),
        traceId: _transportTraceId,
        type: PlayerTransportEventType.seekMismatch,
        position: current,
        targetPosition: target,
        note: 'reason=${reason ?? "-"} deltaMs=${delta.inMilliseconds}',
      ),
    );

    try {
      await _player.seek(target);
      await Future.delayed(PlayerTuning.seekVerifyDelay);
      if (!_alive) return;
      final corrected = _player.state.position;
      final correctedDelta = (corrected - target).abs();
      _emitTransportEvent(
        PlayerTransportEvent(
          timestamp: DateTime.now(),
          traceId: _transportTraceId,
          type: PlayerTransportEventType.seekVerify,
          position: corrected,
          targetPosition: target,
          note:
              'reason=${reason ?? "-"} phase=correction deltaMs=${correctedDelta.inMilliseconds}',
        ),
      );
    } catch (e) {
      _log('seek correction failed: $e');
    }
  }

  /// Open URL & robustly wait for HLS to settle before seeking.
  Future<void> _openAt(
    String url, {
    required Duration position,
    required bool play,
    required String originalUrl,
    bool openedViaProxy = false,
    bool allowOppositeRetry = true,
  }) async {
    if (!_alive) return;

    _audioDropDetector.reset();
    _audioRecoveryInFlight = false;
    _lastAudioStateLogAt = null;
    _lastPausedAudioHealthCheckAt = null;
    _pausedAt = null;
    _resumeAnchorPosition = null;
    _longPauseBufferResetDone = false;
    _resumeAnchorTxnInFlight = false;
    _seekQueueTimer?.cancel();
    _seekQueueTimer = null;
    _completeSeekCompleter(_pendingSeekCompleter);
    _pendingSeekCompleter = null;
    _seekCoordinator.reset();
    _resumeLockController.reset();
    _seekPumpRunning = false;
    _openedViaProxy = openedViaProxy;
    final canProxyFallback = _shouldAllowProxyFallbackForUrl(originalUrl);
    final shouldWaitForHlsSettle =
        openedViaProxy || _looksLikeHlsUrl(originalUrl);

    // Reset auto-skip flags for a fresh media open (quality change / next episode).
    _openingSkipped = false;
    _endingSkipped = false;
    _autoSkipBlockedUntil = null;

    // Do not force close; some CDNs misbehave & expose only the first HLS segment.
    try {
      final headers = <String, String>{
        // Keep a desktop-like UA to avoid odd CDN variants.
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
        ...?widget.args.httpHeaders,
      };
      _log('Opening URL: $url');
      final openStopwatch = Stopwatch()..start();

      // Add a timeout to the open call itself (normally quick, but detect hanging)
      await _player
          .open(
        Media(
          url,
          httpHeaders: headers,
        ),
        play: play,
      )
          .timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          _log(
              'WARNING: player.open() timed out after 10 seconds for URL: $url');
          throw TimeoutException('player.open() took too long');
        },
      );
      _log('Opened URL in ${openStopwatch.elapsedMilliseconds}ms');
    } catch (e) {
      _log('open failed: $e');

      if (!allowOppositeRetry || !_alive) return;

      if (openedViaProxy) {
        _log('openAt: proxy open failed; reopening direct once');
        await _openAt(
          originalUrl,
          position: position,
          play: play,
          originalUrl: originalUrl,
          openedViaProxy: false,
          allowOppositeRetry: false,
        );
        return;
      }

      if (canProxyFallback) {
        final ready = await _ensureProxyReady(reason: 'openAt_retry_proxy');
        if (ready) {
          try {
            final proxied =
                _proxy.playlistUrl(Uri.parse(originalUrl)).toString();
            _log('openAt: direct open failed; reopening via proxy once');
            await _openAt(
              proxied,
              position: position,
              play: play,
              originalUrl: originalUrl,
              openedViaProxy: true,
              allowOppositeRetry: false,
            );
            return;
          } catch (e2) {
            _log('openAt: proxy retry build failed: $e2');
          }
        }
      }

      return;
    }

    _hasOpenedMedia = true;
    _openSerial++;
    _subtitleAppliedSerial = -1;
    _subtitleAppliedUrl = null;

    // Prevent mpv from auto-selecting embedded subs/CC after opening.
    unawaited(_setMpv('sub-auto', 'no'));
    unawaited(_setMpv('ccsid', 'no'));

    // Never show two subtitle tracks at once.
    unawaited(_setMpv('secondary-sid', 'no'));
    unawaited(_setMpv('secondary-sub-visibility', 'no'));

    // Drop any inband subtitle selection before we attach external.
    unawaited(_setMpv('sid', 'no'));

    // Attach external subtitles after opening (module-provided).
    await _applyExternalSubtitleIfAny();

    // Some HLS streams populate inband subtitle tracks after open; re-enforce selection.
    unawaited(Future<void>.delayed(
      const Duration(milliseconds: 350),
      _selectOnlyExternalSubtitleIfPossible,
    ));

    // On desktop, re-apply external subtitles after a short delay to avoid
    // cases where mpv isn't ready on first attach (prevents needing a toggle).
    if (!_isIOS) {
      unawaited(Future<void>.delayed(
        const Duration(milliseconds: 700),
        () => _applyExternalSubtitleIfAny(force: true),
      ));
    }

    if (!_alive) return;

    // Reset auto-skip flags for a fresh media open (quality change / next episode).
    _openingSkipped = false;
    _endingSkipped = false;
    _autoSkipBlockedUntil = null;

    bool settleTimeoutFired = false;

    if (shouldWaitForHlsSettle) {
      // Wait for HLS to report a valid duration (no fallback on position ticks).
      final settle = Completer<void>();
      late final StreamSubscription subDur;

      final timeout = Future<void>.delayed(const Duration(seconds: 15), () {
        if (!settle.isCompleted) {
          settleTimeoutFired = true;
          settle.complete();
        }
      });

      _log('Waiting for HLS to settle (max 15s)...');
      subDur = _player.stream.duration.listen(
        (d) {
          if (!_alive) {
            if (!settle.isCompleted) settle.complete();
            subDur.cancel();
            return;
          }
          _log('HLS duration update: ${d.inSeconds}s');
          if (d > const Duration(seconds: 3)) {
            if (!settle.isCompleted) {
              _log(
                  'HLS settled with duration: ${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}');
              settle.complete();
            }
          }
        },
        onError: (error) {
          _log('ERROR in HLS duration stream: $error');
          if (!settle.isCompleted) settle.complete();
        },
        onDone: () {
          _log('HLS duration stream closed prematurely');
          if (!settle.isCompleted) settle.complete();
        },
      );

      await Future.any([settle.future, timeout]);
      await subDur.cancel();

      if (settleTimeoutFired) {
        _log(
            'HLS settle TIMEOUT (15s) - no valid duration reported, continuing anyway');
      }
    }

    if (!_alive) return;

    final settledDuration = _player.state.duration;
    final durationLooksUnusable = _shouldFallbackToProxy(settledDuration);

    if (_openedViaProxy &&
        allowOppositeRetry &&
        (settleTimeoutFired || durationLooksUnusable)) {
      _log(
        'openAt: proxy duration=${settledDuration.inSeconds}s seems unusable; reopening direct once',
      );
      await _openAt(
        originalUrl,
        position: position,
        play: play,
        originalUrl: originalUrl,
        openedViaProxy: false,
        allowOppositeRetry: false,
      );
      return;
    }

    if (!_openedViaProxy &&
        !_proxyFallbackAttempted &&
        allowOppositeRetry &&
        canProxyFallback &&
        shouldWaitForHlsSettle &&
        durationLooksUnusable) {
      _proxyFallbackAttempted = true;
      _log(
          'openAt: duration=${settledDuration.inSeconds}s seems truncated; reopening via proxy');

      // Ensure proxy is running before retry.
      final ready = await _ensureProxyReady(reason: 'openAt_fallback');
      if (ready) {
        try {
          final proxied = _proxy.playlistUrl(Uri.parse(originalUrl)).toString();
          await _openAt(
            proxied,
            position: position,
            play: play,
            originalUrl: originalUrl,
            openedViaProxy: true,
            allowOppositeRetry: false,
          );
          return;
        } catch (e) {
          _log('openAt: proxy fallback build failed: $e');
        }
      }
    }

    // Reset auto-skip flags for a fresh media open (quality change / next episode).
    _openingSkipped = false;
    _endingSkipped = false;

    // if (position > Duration.zero) {
    //   await _seekPlanned(position, reason: 'openAt_restore');
    //   await Future.delayed(const Duration(milliseconds: 60));
    //   await _seekPlanned(position, reason: 'openAt_restore_confirm');
    // }

    final tgt = _clampSeekAbsolute(position);
    if (tgt > Duration.zero) {
      await _seekPlanned(tgt, reason: 'openAt_restore');
    } else {
      // Some HLS sources occasionally open a new episode at a non-zero offset.
      // If no resume was requested, force a seek back to 0.
      final startedAt = _player.state.position;
      if (startedAt > PlayerTuning.openAtForceZeroIfStartedAfter) {
        await _seekPlanned(Duration.zero, reason: 'openAt_force_zero');
      }
    }

    // Ensure playback starts if requested (prevents stuck paused state on Windows).
    if (play && _alive) {
      try {
        if (!_player.state.playing) {
          await _playTracked(reason: 'open_at_play');
        }
      } catch (_) {}
    }
  }

  Future<void> _changeQuality(PlayerQuality label) async {
    // Some sources expose only a single HLS master URL (usually in url1080), where
    // variant selection is internal. In that case, do NOT claim 720/480 are
    // unavailable; instead, try to guide mpv via hls-bitrate (desktop) and keep
    // the user's selected label.
    final rawUrls = <String?>[
      widget.args.url1080,
      widget.args.url720,
      widget.args.url480,
    ]
        .whereType<String>()
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toList(growable: false);
    final distinctCount = rawUrls.toSet().length;

    if (distinctCount <= 1) {
      // Update UI label immediately.
      _currentQuality = label;
      _safeSetState(() {});

      // Reopen at the same position only if we have a playable URL.
      final baseUrl = (_chosenUrl?.trim().isNotEmpty == true)
          ? _chosenUrl!.trim()
          : (rawUrls.isNotEmpty ? rawUrls.first : null);
      if (baseUrl == null || baseUrl.isEmpty) return;
      final baseIsHls = _looksLikeHlsUrl(baseUrl);

      // For mpv (desktop NativePlayer), limit HLS bitrate to approximate the selection.
      if (_isDesktop && baseIsHls) {
        // mpv `hls-bitrate` accepts: no|min|max|<rate>.
        // If given a number, mpv picks the highest BANDWIDTH <= <rate>.
        // HLS BANDWIDTH values are typically in bits-per-second.
        //
        // Prefer dynamic caps by probing the master playlist when possible.
        String opt = switch (label) {
          PlayerQuality.p1080 => 'max',
          PlayerQuality.p720 => '3500000',
          PlayerQuality.p480 => '1600000',
        };

        try {
          final targetHeight = switch (label) {
            PlayerQuality.p1080 => 1080,
            PlayerQuality.p720 => 720,
            PlayerQuality.p480 => 480,
          };

          // Ensure proxy client exists.
          final ready = await _ensureProxyReady(reason: 'changeQuality_probe');
          if (ready) {
            final cap = await _proxy.suggestHlsBitrateCap(
              Uri.parse(baseUrl),
              targetHeight: targetHeight,
              headers: widget.args.httpHeaders,
            );

            if (cap != null && cap > 0) {
              if (label == PlayerQuality.p1080) {
                opt = 'max';
              } else {
                opt = cap.toString();
              }
            }
          }
        } catch (_) {
          // Keep fallback caps.
        }

        unawaited(_setMpv('hls-bitrate', opt));
      }

      final wasPlaying = _player.state.playing;
      final pos = _player.state.position;
      final transport = await _resolveOpenTransport(
        baseUrl,
        reason: 'changeQuality_master',
      );

      _proxyFallbackAttempted = false;
      _openedViaProxy = transport.openedViaProxy;

      // Only add fudge for mid-video resumes; keep small positions as-is
      final resume =
          pos.inSeconds > 5 ? pos + PlayerTuning.openAtResumeFudge : pos;
      await _openAt(
        transport.toOpen,
        position: resume,
        play: wasPlaying,
        originalUrl: baseUrl,
        openedViaProxy: _openedViaProxy,
        allowOppositeRetry: true,
      );

      if (_isDesktop) {
        await _setVolumeSafe(_desktopVolume);
      }
      if (_alive) {
        try {
          await _player.setRate(_speed);
        } catch (_) {}
      }

      return;
    }

    // Prefer the exact requested stream; if it's missing, fall back but inform the user.
    final String? exactUrl = switch (label) {
      PlayerQuality.p1080 => widget.args.url1080,
      PlayerQuality.p720 => widget.args.url720,
      PlayerQuality.p480 => widget.args.url480,
    };

    final String? url = (exactUrl != null && exactUrl.trim().isNotEmpty)
        ? exactUrl.trim()
        : pickUrlForQuality(
            quality: label,
            url1080: widget.args.url1080,
            url720: widget.args.url720,
            url480: widget.args.url480,
            log: _log,
            argsIdentity: widget.args,
          );

    if (url == null || url.isEmpty) {
      _showBanner('Quality not available');
      return;
    }

    // Display the actual quality we ended up opening.
    final effectiveQuality = (url == widget.args.url1080)
        ? PlayerQuality.p1080
        : (url == widget.args.url720)
            ? PlayerQuality.p720
            : PlayerQuality.p480;

    if (exactUrl == null || exactUrl.trim().isEmpty) {
      _showBanner(
          '${label.label} not available • Using ${effectiveQuality.label}');
    }

    // If URL did not change, just update the displayed label (so UI matches selection)
    // and avoid reopening.
    if (url == _chosenUrl) {
      _currentQuality = effectiveQuality;
      _safeSetState(() {});
      return;
    }

    final wasPlaying = _player.state.playing;
    final pos = _player.state.position;

    _chosenUrl = url;
    _currentQuality = effectiveQuality;
    final transport = await _resolveOpenTransport(
      url,
      reason: 'changeQuality',
    );

    _proxyFallbackAttempted = false;
    _openedViaProxy = transport.openedViaProxy;

    // Only add fudge for mid-video resumes; keep small positions as-is
    final resume =
        pos.inSeconds > 5 ? pos + PlayerTuning.openAtResumeFudge : pos;
    await _openAt(
      transport.toOpen,
      position: resume,
      play: wasPlaying,
      originalUrl: url,
      openedViaProxy: _openedViaProxy,
      allowOppositeRetry: true,
    );

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
    await _pauseTracked(reason: 'present_ios_native');

    final rawSubtitle = widget.args.subtitleUrl?.trim();
    final normalizedSubtitle = (rawSubtitle == null || rawSubtitle.isEmpty)
        ? null
        : (rawSubtitle.startsWith('//') ? 'https:$rawSubtitle' : rawSubtitle);

    final args = <String, dynamic>{
      // IMPORTANT: pass the ORIGINAL remote URL to native iOS player.
      'url': _chosenUrl!,
      'position': _player.state.position.inSeconds.toDouble(),
      'rate': _speed,
      'title': widget.args.title,
      'subtitlesEnabled': _subtitlesEnabled,
      'subtitleUrl': normalizedSubtitle,
      'headers': widget.args.httpHeaders,
      // Pass skip ranges so native player can auto-skip as well.
      'autoSkipOpening': _autoSkipOpening,
      'autoSkipEnding': _autoSkipEnding,
      'openingStart':
          _autoSkipOpening ? widget.args.openingStart?.toDouble() : null,
      'openingEnd': _autoSkipOpening ? widget.args.openingEnd?.toDouble() : null,
      'endingStart':
          _autoSkipEnding ? widget.args.endingStart?.toDouble() : null,
      'endingEnd': _autoSkipEnding ? widget.args.endingEnd?.toDouble() : null,
      'wasPlaying': wasPlaying,
    };

    try {
      _iosNativeActive = true;
      await _iosNativePlayer.invokeMethod<void>('present', args);
      // No further action here; callbacks will sync back on dismiss/completion.
    } on PlatformException catch (e) {
      _iosNativeActive = false;
      _log('iOS native player failed: ${e.code}: ${e.message}');
      final ctx = _activeControlsCtx(preferFullscreen: false);
      if (ctx != null && ctx.mounted) {
        await _enterMediaKitFullscreenFrom(
          ctx,
          state: _mediaKitVideoState,
          reason: 'ios_native_present_fail',
        );
      }
      if (wasPlaying && _alive) {
        await _playTracked(reason: 'ios_native_present_fail_resume');
      }
    }
  }

  // ---------- Auto-skip / next ----------

  void _maybeAutoSkip(Duration pos) {
    final dur = _player.state.duration;
    if (dur == Duration.zero) return;
    if (_reopeningGuard || _inQuarantine || _plannedSeek) return;

    // Respect temporary block (e.g., right after undo or iOS restore).
    if (_autoSkipBlockedUntil != null) {
      if (DateTime.now().isBefore(_autoSkipBlockedUntil!)) {
        return;
      }
      _autoSkipBlockedUntil = null;
    }

    final p = pos.inSeconds;

    // --- Opening skip ---
    if (_autoSkipOpening &&
        !_openingSkipped &&
        widget.args.openingStart != null &&
        widget.args.openingEnd != null) {
      // +1 sec to avoid re-trigger if landed exactly at start
      final s = widget.args.openingStart! + 1;
      final e = widget.args.openingEnd!;
      // Trigger ANYTIME while we are inside [s, e)
      if (p >= s && p < e) {
        _openingSkipped = true;
        _skipTo(
          Duration(seconds: s),
          Duration(seconds: e),
          banner: 'Skipped Opening',
          skipKind: _AutoSkipKind.opening,
        );
        return; // do not evaluate ED on the same tick
      }
    }

    // --- Ending skip ---
    if (_autoSkipEnding &&
        !_endingSkipped &&
        widget.args.endingStart != null &&
        widget.args.endingEnd != null) {
      final s = widget.args.endingStart! + 1;
      final e = widget.args.endingEnd!;
      // Trigger ANYTIME while we are inside [s, e)
      if (p >= s && p < e) {
        _endingSkipped = true;
        _skipTo(
          Duration(seconds: s),
          Duration(seconds: e),
          banner: 'Skipped Ending',
          skipKind: _AutoSkipKind.ending,
        );
        return;
      }
    }
  }

  Future<void> _skipTo(
    Duration from,
    Duration to, {
    required String banner,
    required _AutoSkipKind skipKind,
  }) async {
    _undoSeekFrom = _clampSeekAbsolute(from);
    _lastSkipKind = skipKind;
    _autoSkipBlockedUntil =
        DateTime.now().add(PlayerTuning.autoSkipBlockAfterSkip);
    await _seekPlanned(_clampSeekAbsolute(to), reason: 'auto_skip');
    _showBanner(banner, affectCursor: false);
    _hideCursorInstant();
  }

  Future<void> _undoSkip() async {
    if (_undoSeekFrom == null) return;
    await _seekPlanned(_clampSeekAbsolute(_undoSeekFrom!), reason: 'undo_skip');
    _undoSeekFrom = null;
    _autoSkipBlockedUntil =
        DateTime.now().add(PlayerTuning.autoSkipBlockAfterUndo);
    if (_lastSkipKind == _AutoSkipKind.opening) {
      _openingSkipped = true;
    } else if (_lastSkipKind == _AutoSkipKind.ending) {
      _endingSkipped = true;
    }
    _lastSkipKind = null;
  }

  Future<void> _closePlayerFromAppBar() async {
    if (!mounted || _navigatingAway) return;

    _navigatingAway = true;
    _hideCursorInstant();
    _autoSkipBlockedUntil = null;

    final fsCtx = _controlsCtxFullscreen;
    if (fsCtx != null && fsCtx.mounted) {
      try {
        await exitFullscreen(fsCtx);
      } catch (_) {}
    }
    _wasFullscreen = false;
    _removeFullscreenBannerOverlayIfAny();
    _controlsCtxFullscreen = null;
    await _exitNativeFullscreen();
    _removeCursorOverlayIfAny();

    _detachListeners();
    await _flushDesktopVolumeToPrefs(reason: 'appbar_close');

    if (!_isDisposed) {
      try {
        await _player.stop();
      } catch (_) {}
    }

    if (!mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    if (!navigator.mounted) return;

    var reachedPlayerRoute = false;
    navigator.popUntil((route) {
      final isPlayerRoute = route.settings.name == 'player';
      if (isPlayerRoute) reachedPlayerRoute = true;
      return isPlayerRoute;
    });

    if (!navigator.mounted) return;
    if (reachedPlayerRoute && navigator.canPop()) {
      navigator.pop();
    } else {
      await navigator.maybePop();
    }
  }

  Future<bool> _closePlayerAfterAutoNextFailure() async {
    if (!mounted) return false;

    _navigatingAway = true;
    _hideCursorInstant();
    _autoSkipBlockedUntil = null;

    // Force windowed mode before leaving player, even when onExitFullscreen
    // callbacks are suppressed by _navigatingAway.
    final fsCtx = _controlsCtxFullscreen;
    if (fsCtx != null && fsCtx.mounted) {
      try {
        await exitFullscreen(fsCtx);
      } catch (_) {}
    }
    _wasFullscreen = false;
    _removeFullscreenBannerOverlayIfAny();
    _controlsCtxFullscreen = null;
    await _exitNativeFullscreen();
    _removeCursorOverlayIfAny();

    _detachListeners();

    await _flushDesktopVolumeToPrefs(reason: 'auto_next_failure_close');

    if (!mounted) return false;

    Future<bool> tryCloseOn(
      NavigatorState navigator, {
      Route<dynamic>? targetRoute,
    }) async {
      if (!navigator.mounted) return false;

      bool reachedTarget = false;
      if (targetRoute != null) {
        navigator.popUntil((route) {
          final isTarget = identical(route, targetRoute);
          if (isTarget) reachedTarget = true;
          return isTarget;
        });
      } else {
        navigator.popUntil((route) {
          final isPlayerRoute = route.settings.name == 'player';
          if (isPlayerRoute) reachedTarget = true;
          return isPlayerRoute;
        });
      }

      if (!navigator.mounted) return false;

      if (reachedTarget && navigator.canPop()) {
        try {
          navigator.pop();
          return true;
        } catch (_) {}
      }

      return navigator.maybePop();
    }

    final currentRoute = ModalRoute.of(context);
    final ownerNavigator = currentRoute?.navigator;

    bool popped = false;
    if (ownerNavigator != null && currentRoute != null) {
      popped = await tryCloseOn(
        ownerNavigator,
        targetRoute: currentRoute,
      );
    }

    if (!popped && mounted) {
      popped = await tryCloseOn(Navigator.of(context, rootNavigator: true));
    }

    if (!popped && mounted) {
      _navigatingAway = false;
    }

    return popped;
  }

  Future<void> _openNextEpisode() async {
    if (_navigatingAway) return;
    _navigatingAway = true;
    var navigated = false;
    var closedOnFailure = false;
    _hideCursorInstant();
    _autoSkipBlockedUntil = null;
    _log('_openNextEpisode() called');

    final wasFs = _wasFullscreen;
    _log('_openNextEpisode(); wasFs=$wasFs');

    if (wasFs) {
      _log('exiting fullscreen (lib + native) before auto-next');
      bool exitedViaControls = false;
      final ctx = _controlsCtxFullscreen;
      if (ctx != null && ctx.mounted) {
        try {
          await exitFullscreen(ctx);
          exitedViaControls = true;
        } catch (_) {}
      }
      _wasFullscreen = false;
      // Avoid double native fullscreen toggles; onExitFullscreen already calls it.
      if (!exitedViaControls) {
        await _exitNativeFullscreen();
      }
      await Future.delayed(const Duration(milliseconds: 120));
    }

    try {
      _log('fetching next episode (modules-only)...');

      final moduleId = widget.args.moduleId;
      if (moduleId == null || moduleId.trim().isEmpty) {
        _log('modules: missing moduleId, cannot auto-next');
        closedOnFailure = await _closePlayerAfterAutoNextFailure();
        return;
      }

      // Resolve next episode through cached list when available, otherwise via JS.
      List<JsModuleEpisode> episodes;
      final cachedEpisodes = widget.args.moduleEpisodes;
      if (cachedEpisodes != null && cachedEpisodes.isNotEmpty) {
        episodes = cachedEpisodes;
      } else {
        Stopwatch? episodesSw;
        String? episodesLabel;
        if (kDebugMode) {
          episodesLabel = 'autoNext extractEpisodes module=$moduleId';
          debugPrint('[Perf] $episodesLabel start');
          episodesSw = Stopwatch()..start();
        }
        episodes = await _jsExec
            .extractEpisodes(moduleId, widget.args.url)
            .timeout(PlayerTuning.autoNextResolveTimeout);
        if (kDebugMode && episodesSw != null) {
          episodesSw.stop();
          debugPrint(
              '[Perf] $episodesLabel ${episodesSw.elapsedMilliseconds}ms');
        }
      }
      if (episodes.isEmpty) {
        _log('modules: extractEpisodes returned empty');
        closedOnFailure = await _closePlayerAfterAutoNextFailure();
        return;
      }

      JsModuleEpisode? next;
      // Try by exact ordinal match first, then by greater-than current.
      final idx = episodes.indexWhere((e) => e.number == widget.args.ordinal);
      if (idx >= 0 && idx + 1 < episodes.length) {
        next = episodes[idx + 1];
      } else {
        next = episodes.firstWhere(
          (e) => e.number > widget.args.ordinal,
          orElse: () => episodes.last,
        );
      }

      if (next.number == widget.args.ordinal) {
        _log('modules: no next episode found');
        closedOnFailure = await _closePlayerAfterAutoNextFailure();
        return;
      }

      final JsModuleEpisode nextEp = next;

      Stopwatch? streamsSw;
      String? streamsLabel;
      if (kDebugMode) {
        streamsLabel = 'autoNext extractStreams module=$moduleId';
        debugPrint('[Perf] $streamsLabel start');
        streamsSw = Stopwatch()..start();
      }
      final voiceover = widget.args.preferredStreamIsVoiceover == true
          ? widget.args.preferredStreamTitle
          : null;
      final selection = await _jsExec
          .extractStreams(moduleId, nextEp.href, voiceover: voiceover)
          .timeout(PlayerTuning.autoNextResolveTimeout);
      if (kDebugMode && streamsSw != null) {
        streamsSw.stop();
        debugPrint('[Perf] $streamsLabel ${streamsSw.elapsedMilliseconds}ms');
      }
      if (selection.streams.isEmpty) {
        _log('modules: extractStreams returned empty');
        closedOnFailure = await _closePlayerAfterAutoNextFailure();
        return;
      }

      // Pick stream by preferred title when provided.
      JsStreamCandidate picked = selection.streams.first;
      final want = widget.args.preferredStreamTitle?.trim();
      if (want != null && want.isNotEmpty) {
        final w = want.toLowerCase();
        for (final s in selection.streams) {
          final t = s.title.trim().toLowerCase();
          if (t == w || t.contains(w) || w.contains(t)) {
            picked = s;
            break;
          }
        }
      }

      String? norm(String? u) {
        final s = u?.trim();
        if (s == null || s.isEmpty) return null;
        return s.startsWith('//') ? 'https:$s' : s;
      }

      String? url480 = norm(picked.url480);
      String? url720 = norm(picked.url720);
      String? url1080 = norm(picked.url1080) ?? norm(picked.streamUrl);
      String? subtitleUrl = selection.subtitleUrl ?? picked.subtitleUrl;
      Map<String, String>? headers = picked.headers;

      // Fallback: if only a single stream URL exists, use it as 1080.
      if (url1080 == null) {
        final rawUrl = picked.streamUrl.trim();
        if (rawUrl.isNotEmpty) {
          url1080 = rawUrl.startsWith('//') ? 'https:$rawUrl' : rawUrl;
        }
      }

      if (url1080 == null && url720 == null && url480 == null) {
        _log('modules: no stream URLs after normalization');
        closedOnFailure = await _closePlayerAfterAutoNextFailure();
        return;
      }

      if (!mounted) return;

      // Ensure the latest user volume is persisted before rebuilding the page.
      await _flushDesktopVolumeToPrefs(reason: 'auto_next_modules');

      if (!mounted) return;

      navigated = true;
      _detachListeners();

      _autoIncDoneForThisEp = false;
      _autoIncGuardForOrdinal = null;

      final navigator = Navigator.of(context, rootNavigator: true);
      if (!navigator.mounted) return;

      // Close any fullscreen/overlay routes above the player, then close the player.
      navigator.popUntil((route) => route.settings.name == 'player');
      if (navigator.mounted) {
        navigator.pop();
      }

      // Wait for old player to fully dispose and clean up textures before creating new one
      _log('auto-next: waiting for cleanup delay...');
      await Future.delayed(const Duration(milliseconds: 500));
      _log('auto-next: cleanup delay done; pushing next episode');

      if (!navigator.mounted) return;
      _log('auto-next: navigator mounted, pushing route');
      navigator.push(
        NoSwipeBackMaterialPageRoute(
          settings: const RouteSettings(name: 'player'),
          builder: (_) => PlayerPage(
            args: PlayerArgs(
              id: widget.args.id,
              url: widget.args.url,
              ordinal: nextEp.number,
              title: widget.args.title,
              moduleId: moduleId,
              moduleEpisodes: widget.args.moduleEpisodes,
              preferredStreamTitle: widget.args.preferredStreamTitle,
              preferredStreamIsVoiceover:
                  widget.args.preferredStreamIsVoiceover,
              subtitleUrl: subtitleUrl,
              url480: url480,
              url720: url720,
              url1080: url1080,
              duration: nextEp.durationSeconds,
              openingStart: nextEp.openingStart,
              openingEnd: nextEp.openingEnd,
              endingStart: nextEp.endingStart,
              endingEnd: nextEp.endingEnd,
              httpHeaders: headers,
              startFromZero: true,
            ),
            item: widget.item,
            sync: widget.sync,
            animeVoice: widget.animeVoice,
            startupBannerText: (picked.title.trim().isNotEmpty)
                ? 'Now playing: Episode ${nextEp.number} • ${picked.title}'
                : 'Now playing: Episode ${nextEp.number}',
            startFullscreen: wasFs,
            startWithProxy: widget.startWithProxy,
          ),
        ),
      );
      _log('auto-next: push completed');
      _log('pushReplacement issued');
    } catch (e, st) {
      _log('failed to open next episode: $e\n$st');
      closedOnFailure = await _closePlayerAfterAutoNextFailure();
    } finally {
      if (!navigated && !closedOnFailure) {
        _navigatingAway = false;
      }
    }
  }

  // ---------- Banners ----------

  void _showBanner(String text,
      {Duration hideAfter = PlayerTuning.bannerHideAfter,
      bool affectCursor = true}) {
    if (_navigatingAway) return;
    _bannerTimer?.cancel();
    _bannerText = text;
    _bannerVisible = true;

    _bumpUiVisibility();

    // Only force cursor visible if requested.
    _cursorForceVisible.value = affectCursor;

    _safeSetState(() {});
    _syncFullscreenBannerOverlay();
    _bannerTimer = Timer(hideAfter, _hideBanner);
  }

  void _hideBanner() {
    if (!_bannerVisible) return;
    _bannerVisible = false;
    _undoSeekFrom = null;

    _cursorForceVisible.value = false;

    _safeSetState(() {});
    _removeFullscreenBannerOverlayIfAny();
    Future.delayed(const Duration(milliseconds: 1), _cursorHideController.kick);
  }

  // ---------- UI ----------

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openSeekStepDialog(BuildContext dialogContext) {
    // Popup menu closes after tap; open dialog on next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !dialogContext.mounted) return;

      const options = <int>[2, 5, 10, 15, 30, 60];
      final selected = await showDialog<int>(
        context: dialogContext,
        builder: (ctx) {
          return SimpleDialog(
            title: const Text('Seek step'),
            children: [
              for (final s in options)
                SimpleDialogOption(
                  onPressed: () => Navigator.of(ctx).pop(s),
                  child: Row(
                    children: [
                      if (_seekStepSeconds == s)
                        const Icon(Icons.check, size: 18)
                      else
                        const SizedBox(width: 18),
                      const SizedBox(width: 10),
                      Text('$s seconds'),
                    ],
                  ),
                ),
            ],
          );
        },
      );

      if (!mounted || selected == null) return;

      _seekStepSeconds = selected;
      _safeSetState(() {});
      unawaited(
        ref.read(playerPrefsProvider.notifier).setSeekStepSeconds(selected),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> buildActions(BuildContext actionContext) {
      return buildPlayerAppBarActions(
        context: actionContext,
        isIOS: _isIOS,
        onOpenIOSPlayer: _presentIOSNativePlayer,
        currentQuality: _currentQuality,
        speed: _speed,
        seekStepSeconds: _seekStepSeconds,
        autoSkipOpening: _autoSkipOpening,
        autoSkipEnding: _autoSkipEnding,
        autoNextEpisode: _autoNextEpisode,
        autoProgress: _autoProgress,
        subtitlesEnabled: _subtitlesEnabled,
        onSelectQuality: (q) async {
          _currentQuality = q;
          _safeSetState(() {});
          unawaited(
              ref.read(playerPrefsProvider.notifier).setPreferredQuality(q));
          _suppressPrefQualityReopen = true;
          try {
            await _changeQuality(q);
          } finally {
            _suppressPrefQualityReopen = false;
          }
        },
        onSelectSpeed: (r) async {
          unawaited(ref.read(playerPrefsProvider.notifier).setSpeed(r));
          if (_alive) {
            try {
              await _player.setRate(r);
            } catch (_) {}
          }
        },
        onOpenSeekStep: () => _openSeekStepDialog(actionContext),
        onToggleAutoSkipOpening: () {
          _autoSkipOpening = !_autoSkipOpening;
          unawaited(
            ref
                .read(playerPrefsProvider.notifier)
                .setAutoSkipOpening(_autoSkipOpening),
          );
          _safeSetState(() {});
        },
        onToggleAutoSkipEnding: () {
          _autoSkipEnding = !_autoSkipEnding;
          unawaited(
            ref
                .read(playerPrefsProvider.notifier)
                .setAutoSkipEnding(_autoSkipEnding),
          );
          _safeSetState(() {});
        },
        onToggleAutoNextEpisode: () {
          _autoNextEpisode = !_autoNextEpisode;
          unawaited(
            ref
                .read(playerPrefsProvider.notifier)
                .setAutoNextEpisode(_autoNextEpisode),
          );
          _safeSetState(() {});
        },
        onToggleAutoProgress: () {
          _autoProgress = !_autoProgress;
          unawaited(
            ref
                .read(playerPrefsProvider.notifier)
                .setAutoProgress(_autoProgress),
          );
          _safeSetState(() {});
        },
        onToggleSubtitles: () {
          _subtitlesEnabled = !_subtitlesEnabled;
          unawaited(
            ref
                .read(playerPrefsProvider.notifier)
                .setSubtitlesEnabled(_subtitlesEnabled),
          );
          if (_subtitlesEnabled) {
            unawaited(_setMpv('secondary-sid', 'no'));
            unawaited(_setMpv('secondary-sub-visibility', 'no'));
            unawaited(_setMpv('sub-visibility', 'yes'));
            unawaited(_applyExternalSubtitleIfAny(force: true));
          } else {
            unawaited(_setMpv('secondary-sid', 'no'));
            unawaited(_setMpv('secondary-sub-visibility', 'no'));
            unawaited(_setMpv('sub-visibility', 'no'));
            unawaited(_setMpv('sid', 'no'));
          }
          _safeSetState(() {});
        },
        onOpenSubtitleStyle: () {
          // Popups call onTap before the menu fully closes; schedule to next frame.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !actionContext.mounted) return;
            unawaited(
              showSubtitleStyleDialog(
                context: actionContext,
                ref: ref,
                isDesktop: _isDesktop,
              ),
            );
          });
        },
        animeVoice: widget.animeVoice,
      );
    }

    final banner = (_bannerVisible && !_isFullscreenBannerHostActive())
        ? _buildBannerWidget()
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
                return PlayerCursorAutoHideOverlay(
                  idle: PlayerTuning.cursorIdleHide,
                  forceVisible: force,
                  controller: _cursorHideController,
                  onPointerActivity: _handlePlayerPointerActivity,
                  onPointerEnter: _handlePlayerPointerActivity,
                  onPointerExit: _handlePlayerPointerExit,
                );
              },
            ),
          ),
        ],
      );
    }

    Widget buildOverlayAppBar() {
      return Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: ValueListenableBuilder<int>(
          valueListenable: _controlsOverlayRevision,
          builder: (actionContext, __, ___) {
            final actions = buildActions(actionContext);
            return ValueListenableBuilder<bool>(
              valueListenable: _uiVisibleNotifier,
              builder: (_, visible, __) {
                return IgnorePointer(
                  ignoring: !visible,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    opacity: visible ? 1.0 : 0.0,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.6),
                      child: SafeArea(
                        bottom: false,
                        child: SizedBox(
                          height: kToolbarHeight,
                          child: AppBar(
                            leading: IconButton(
                              tooltip: 'Back',
                              icon: const BackButtonIcon(),
                              onPressed: () {
                                unawaited(_closePlayerFromAppBar());
                              },
                            ),
                            automaticallyImplyLeading: false,
                            title: Text('Episode ${widget.args.ordinal}'),
                            backgroundColor: Colors.transparent,
                            foregroundColor: Colors.white,
                            centerTitle: false,
                            titleSpacing: 0,
                            actions: actions,
                            elevation: 0,
                            scrolledUnderElevation: 0,
                            primary: false,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      );
    }

    Widget buildPlayerStack() {
      final overlayAppBar = buildOverlayAppBar();

      Widget videoWidget = Video(
        controller: _video,
        // media_kit_video can render subtitles as a Flutter overlay.
        // On desktop (mpv backend), mpv renders subtitles itself, so the overlay can duplicate.
        subtitleViewConfiguration: SubtitleViewConfiguration(
          visible: !_isDesktop && _subtitlesEnabled,
        ),
        controls: (state) => ControlsCtxBridge(
          state: state,
          overlay: overlayAppBar,
          onPointerDown: _handleControlsPointerDown,
          onPointerMove: _handleControlsPointerMove,
          onPointerHover: _handleControlsPointerHover,
          onPointerEnter: _handleControlsPointerEnter,
          onPointerExit: _handleControlsPointerExit,
          onReady: (ctx, videoState) {
            if (_navigatingAway) return;
            _mediaKitVideoState = videoState;

            var fullscreen = false;
            try {
              fullscreen = videoState.isFullscreen();
            } catch (_) {
              try {
                fullscreen = isFullscreen(ctx);
              } catch (_) {}
            }
            if (fullscreen) {
              _controlsCtxFullscreen = ctx;
            } else {
              _controlsCtxNormal = ctx;
            }
            _syncFullscreenBannerOverlay();
            _log(
                'controls onReady; startFullscreen=${widget.startFullscreen}, handled=$_startFsHandled');

            if (_shouldStartMediaKitFullscreen && !_startFsHandled) {
              _startFsHandled = true;
              WidgetsBinding.instance.endOfFrame.then((_) async {
                if (!mounted || _navigatingAway) return;
                await _enterMediaKitFullscreenFrom(
                  null,
                  state: videoState,
                  reason: 'initial_controls_ready',
                );
              });
            }
          },
        ),
        onEnterFullscreen: () async {
          _lastFullscreenTransitionAt = DateTime.now();
          _lastFullscreenTransitionType = 'enter';
          _log('onEnterFullscreen() fired (lib)');
          _cancelMobileFullscreenReentry();
          _wasFullscreen = true;
          if (!mounted || _navigatingAway) return;

          // Delay native fullscreen to prevent race with texture cleanup
          await Future.delayed(PlayerTuning.nativeFullscreenDelay);
          if (!mounted || _navigatingAway) return;
          if (!_nativeFsActive) {
            await _enterNativeFullscreen();
          }

          // Insert cursor overlay on desktop while fullscreen is active.
          _insertCursorOverlayIfNeeded();
          _cursorHideController.kick();
          _syncFullscreenBannerOverlay();

          _log('native fullscreen requested from onEnterFullscreen()');
        },
        onExitFullscreen: () async {
          _lastFullscreenTransitionAt = DateTime.now();
          _lastFullscreenTransitionType = 'exit';
          _log('onExitFullscreen() fired (lib)');
          _removeFullscreenBannerOverlayIfAny();
          _controlsCtxFullscreen = null;
          if (_lockMobileMediaKitFullscreen && !_navigatingAway) {
            _wasFullscreen = true;
            _scheduleMobileFullscreenReentry();
            _log('mobile fullscreen exit blocked; reentry scheduled');
            return;
          }

          _wasFullscreen = false;
          if (!mounted || _navigatingAway) return;
          if (_nativeFsActive) {
            await _exitNativeFullscreen();
          }

          // Remove cursor overlay when leaving fullscreen.
          _removeCursorOverlayIfAny();

          _log('native fullscreen exit requested from onExitFullscreen()');
        },
      );

      if (_isMobile) {
        videoWidget = MaterialVideoControlsTheme(
          normal: const MaterialVideoControlsThemeData(
            bottomButtonBarMargin: EdgeInsets.only(
              left: 16.0,
              right: 8.0,
              bottom: 24.0,
            ),
            bottomButtonBar: [
              MaterialPositionIndicator(),
              Spacer(),
            ],
          ),
          fullscreen: const MaterialVideoControlsThemeData(
            bottomButtonBarMargin: EdgeInsets.only(
              left: 16.0,
              right: 8.0,
              bottom: 28.0,
            ),
            bottomButtonBar: [
              MaterialPositionIndicator(),
              Spacer(),
            ],
          ),
          child: videoWidget,
        );
      }

      if (_isDesktop) {
        final shortcuts = _desktopKeyboardShortcuts();
        videoWidget = MaterialDesktopVideoControlsTheme(
          normal: MaterialDesktopVideoControlsThemeData(
            keyboardShortcuts: shortcuts,
          ),
          fullscreen: MaterialDesktopVideoControlsThemeData(
            keyboardShortcuts: shortcuts,
          ),
          child: videoWidget,
        );
      }

      return Stack(
        fit: StackFit.expand,
        children: [
          // Use a tiny bridge to get a context INSIDE the controls subtree.
          videoWidget,
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
          try {
            await _player.stop();
          } catch (_) {}
        }

        _wasFullscreen = false;
        _removeFullscreenBannerOverlayIfAny();
        _controlsCtxFullscreen = null;
        await _exitNativeFullscreen();
        _removeCursorOverlayIfAny();

        if (didPop) return;
        if (!mounted || !navigator.mounted) return;

        navigator.maybePop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Padding(
          padding: _isMobile && !_wasFullscreen && !_lockMobileMediaKitFullscreen
              ? const EdgeInsets.only(bottom: 56, left: 24, right: 24)
              : EdgeInsets.zero,
          child: wrapDesktopCursorHider(
            buildPlayerStack(),
          ),
        ),
      ),
    );
  }
}
