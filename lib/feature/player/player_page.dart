import 'dart:async';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/collection/collection_provider.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
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
import 'package:animeshin/feature/player/subtitle_style_dialog.dart';
import 'package:animeshin/feature/player/player_config.dart';
import 'package:animeshin/feature/player/player_appbar_actions.dart';
import 'package:animeshin/feature/player/player_quality_helpers.dart';
import 'package:animeshin/feature/player/player_banner_overlay.dart';
import 'package:animeshin/feature/player/player_cursor_overlay.dart';
import 'package:animeshin/feature/player/player_controls_ctx_bridge.dart';

// watch types / data
import 'package:animeshin/feature/watch/watch_types.dart';
import 'package:animeshin/feature/player/player_support.dart';
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

class _PlayerPageState extends ConsumerState<PlayerPage> {
  // ---- Fake wrap-to-end heal tuning ----
  // Consider "near start" if previous position <= this value.
  final Duration _wrapNearStart = PlayerTuning.wrapNearStart;
  // Consider "near end" if current position >= (duration - this value).
  final Duration _wrapNearEnd = PlayerTuning.wrapNearEnd;
  // Consider it a big forward jump if delta >= this value.
  final Duration _wrapBigJump = PlayerTuning.wrapBigJump;
  // Retry cadence & count to firmly snap back to zero if backend keeps wrapping.
  final Duration _wrapHealRetryDelay = PlayerTuning.wrapHealRetryDelay;
  final int _wrapHealMaxRetries = PlayerTuning.wrapHealMaxRetries;

  // Internal guard for healing loop.
  bool _wrapHealing = false;
  int _wrapHealAttempts = 0;

  // Blocks local & remote progress updates during healing.
  DateTime? _progressSaveBlockedUntil;

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
  final _playback = const PlaybackStore();
  final JsModuleExecutor _jsExec = JsModuleExecutor();

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
  Timer? _uiHideTimer;

  // Quality
  String? _chosenUrl; // stores the ORIGINAL remote HLS URL (master or media)
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

  // Ensure our hotkeys are handled by Flutter (and not the underlying Video widget).
  late final FocusNode _hotkeysFocusNode;

  // --- Jump detection / logging-only ------------------------------------------

  Duration _lastPos = Duration.zero;
  bool _plannedSeek = false;
  // --- Auto-skip guard flags (Android-friendly) ---
  bool _openingSkipped = false;
  bool _endingSkipped = false;

  // Left for diagnostics (no corrective actions are taken).
  final bool _reopeningGuard = false;
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

  // Mirrors effective progress; updated locally after successful persist
  int? _knownProgress;

  // Prevents double increment for the same episode
  bool _autoIncDoneForThisEp = false;
  int? _autoIncGuardForOrdinal;

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
  /// Do NOT permanently mutate widget.item; provider will publish fresh Entry.
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

    tmp.progress = prev;
    if (err == null) _knownProgress = next;
    return err;
  }

  Future<void> _maybeAutoIncrementProgress(Duration pos) async {
    if (!_autoProgress) return;
    // Skip auto-increment while a temporary save block is active.
    if (_progressSaveBlockedUntil != null &&
        DateTime.now().isBefore(_progressSaveBlockedUntil!)) {
      return;
    }

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

    // Wait until the player reports either a valid duration or stable positions.
    final settle = Completer<void>();
    late final StreamSubscription subDur;
    late final StreamSubscription subPos;

    bool hasDuration = false;
    int posTicksOver500ms = 0;

    // Safety timeout — don't hang forever.
    final timeout =
        Future<void>.delayed(PlayerTuning.iosRestoreSettleTimeout, () {});

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
      if (p > PlayerTuning.iosRestorePosTickThreshold) {
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

    // Reset auto-skip flags for a fresh media open (quality change / next episode).
    _openingSkipped = false;
    _endingSkipped = false;

    // Block auto-skip for a short window so we don't immediately jump again.
    _autoSkipBlockedUntil =
        DateTime.now().add(PlayerTuning.iosAutoSkipBlockAfterRestore);

    final tgt = _clampSeekAbsolute(target);
    await _seekPlanned(tgt, reason: 'ios_dismiss_restore');
    if ((_player.state.position - tgt).abs() >
        PlayerTuning.openAtSeekConfirmTolerance) {
      await _seekPlanned(tgt, reason: 'ios_dismiss_restore_confirm');
    }

    // Re-apply rate (the native VC may have changed it).
    try {
      await _player.setRate(rate);
    } catch (_) {}

    // Resume only after we are at the right place.
    if (wasPlaying && _alive) {
      try {
        await _player.play();
      } catch (_) {}
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
            return PlayerCursorAutoHideOverlay(
              idle: PlayerTuning.cursorIdleHide,
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
      } catch (_) {}
    });
  }

  void _removeCursorOverlayIfAny() {
    _cursorOverlayEntry?.remove();
    _cursorOverlayEntry = null;
  }

  void _bumpUiVisibility() {
    if (_uiVisible == false) {
      _uiVisible = true;
      _safeSetState(() {});
    }

    _uiHideTimer?.cancel();
    _uiHideTimer = Timer(PlayerTuning.cursorIdleHide, () {
      if (!mounted || _navigatingAway) return;
      if (_uiVisible) {
        _uiVisible = false;
        _safeSetState(() {});
      }
    });
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
    _uiHideTimer?.cancel();
    _uiHideTimer = null;
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

  Future<dynamic> _getMpv(String property) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return null;
    try {
      final dyn = platform as dynamic;
      return await dyn.getProperty(property);
    } catch (e) {
      _log('getProperty("$property") failed: $e');
      return null;
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

    // --- Make A/V sync follow the display clock (VLC-like smoothness) ---
    unawaited(_setMpv(
        'video-sync', 'display-resample')); // reduce "chase" & teleports
    // Optional: if you see micro-judder, you can also try interpolation
    // unawaited(_setMpv('interpolation', 'yes'));
    // unawaited(_setMpv('tscale', 'oversample'));

    // --- Hardware decoding: safer choice across devices ---
    unawaited(_setMpv('hwdec', 'auto-safe')); // avoid brittle decoders

    // --- Stabilize timestamp probing for HLS/TS (helps missing PTS) ---
    unawaited(_setMpv('demuxer-lavf-analyzeduration', '10')); // seconds
    unawaited(_setMpv('demuxer-lavf-probesize', '${50 * 1024 * 1024}'));
    // Generate missing PTS if upstream is wobbly.
    unawaited(_setMpv('demuxer-lavf-o', 'fflags=+genpts'));

    // --- HTTP/HLS transport safety (you already set some; keep them consolidated) ---
    unawaited(_setMpv(
      'stream-lavf-o',
      [
        // Keep persistent connections to reduce mid-segment stalls
        'http_persistent=1',
        'reconnect=1',
        'reconnect_streamed=1',
        'reconnect_on_http_error=4xx,5xx',
        // Some CDNs play nicer when we avoid multi-range; mpv handles ranges anyway
        // 'multiple_requests=0', // optional; only if you see glide-skips
      ].join(':'),
    ));

    // --- Optional: tame decoder threading if you see sporadic drops on low cores ---
    // unawaited(_setMpv('vd-lavc-threads', '2'));
  }

  @override
  void initState() {
    super.initState();

    _hotkeysFocusNode = FocusNode(debugLabel: 'player_hotkeys');

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

  // Try to heal "underflow -> wrap-to-end" by snapping back to zero a few times.
  // This is robust against rapid repeated key presses that cause multiple wraps.
  void _maybeHealWrapToStart(Duration prev, Duration pos) {
    if (_plannedSeek) return;
    final d = _player.state.duration;
    if (d == Duration.zero) return;

    // Heuristic trigger: we were near the start, suddenly landed near the end,
    // and the jump was large enough to be suspicious.
    final nearStart = prev <= _wrapNearStart;
    final jumpedToTail = pos >= (d - _wrapNearEnd);
    final bigForward = (pos - prev) >= _wrapBigJump;

    if (!(nearStart && jumpedToTail && bigForward)) return;

    // Start a short "no-save" window while we heal.
    _progressSaveBlockedUntil =
        DateTime.now().add(PlayerTuning.wrapHealSaveBlockWindow);

    if (_wrapHealing) {
      // Already healing — just extend the block window and let the loop continue.
      return;
    }

    _wrapHealing = true;
    _wrapHealAttempts = 0;

    // Inner function to retry snap-to-zero until it sticks or attempts are exhausted.
    void kick() {
      if (!_alive) {
        _wrapHealing = false;
        return;
      }
      _wrapHealAttempts++;

      // Planned seek so jump-detector won't flag it.
      unawaited(_seekPlanned(Duration.zero, reason: 'heal_underflow_wrap'));

      // Schedule a check after a short delay.
      Timer(_wrapHealRetryDelay, () {
        if (!_alive) {
          _wrapHealing = false;
          return;
        }
        final dNow = _player.state.duration;
        final pNow = _player.state.position;
        final stillAtTail =
            dNow > Duration.zero && pNow >= (dNow - _wrapNearEnd);

        if (stillAtTail && _wrapHealAttempts < _wrapHealMaxRetries) {
          // Try again.
          kick();
        } else {
          // Done (either healed or gave up); leave the no-save window to expire naturally.
          _wrapHealing = false;
        }
      });
    }

    // Fire the first attempt immediately.
    kick();
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
  void dispose() {
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

    _hotkeysFocusNode.dispose();

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
    final toOpen = _proxyReady && widget.startWithProxy
        ? _proxy.playlistUrl(Uri.parse(_chosenUrl!)).toString()
        : _chosenUrl!;

    await _openAt(
      toOpen,
      // We still perform a normal seek — progress bar remains absolute.
      position: await _restoreSavedPosition(),
      play: true,
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
      // mpv volume is 0..100.0; store as-is.
      _desktopVolume = v;
      _safeSetState(() {}); // update UI if you later show it
      _volumePersistDebounce?.cancel();
      _volumePersistDebounce = Timer(PlayerTuning.volumePersistDebounce, () {
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

          _log('! unexpected jump detected: +${diff.inMilliseconds}ms '
              '(prev=$prev → now=$pos, bigLeap=$bigLeap, burst=$burst)');

          // IMPORTANT: No corrective actions here (logging-only requirement).
        }
      }

      // DO NOT force setVolume here. It causes fighting with user changes.
      _maybeAutoSkip(pos);

      _maybeHealWrapToStart(prev, pos);

      // Try to bump AniList progress when near the ending / tail of the episode
      if (_autoProgress) {
        unawaited(_maybeAutoIncrementProgress(pos));
      }

      _safeSetState(() {});
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

    if (widget.startupBannerText?.isNotEmpty == true) {
      _showBanner(widget.startupBannerText!, affectCursor: false);
    }
  }

  // ---------- Persistence ----------

  Future<Duration> _restoreSavedPosition() async {
    final entry = await _playback.readEntry(
      widget.animeVoice,
      widget.args.id,
      widget.args.ordinal,
    );
    final saved = entry?.seconds ?? 0;

    // If user never watched (or only a tiny accidental start), treat as new episode.
    // This keeps new episodes starting from 0:00 while still resuming when user
    // intentionally stopped mid-episode.
    if (saved <= 15) return Duration.zero;

    // If progress is very small and was last watched a long time ago, treat it as
    // a fresh start. This avoids "old" accidental progress forcing a resume.
    // Defaults: stale after 30 days, and "small" means < 3 minutes.
    final lastWatchedEpochMs = entry?.lastWatchedEpochMs;
    if (lastWatchedEpochMs != null && saved < 180) {
      final last = DateTime.fromMillisecondsSinceEpoch(lastWatchedEpochMs);
      final age = DateTime.now().difference(last);
      if (age >= const Duration(days: 30)) return Duration.zero;
    }
    return Duration(seconds: saved);
  }

  Future<void> _saveProgress({bool clearIfCompleted = false}) async {
    if (_navigatingAway) return;

    // Do not persist while a temporary "heal" block is active.
    if (_progressSaveBlockedUntil != null &&
        DateTime.now().isBefore(_progressSaveBlockedUntil!)) {
      return;
    }

    final pos = _player.state.position;
    final dur = _player.state.duration;
    if (dur.inSeconds <= 0) return;

    final isCompleted = pos.inMilliseconds >= (dur.inMilliseconds * 0.98);
    if (clearIfCompleted || isCompleted) {
      await _playback.clearEpisode(
          widget.animeVoice, widget.args.id, widget.args.ordinal);
    } else {
      await _playback.saveEntry(
        widget.animeVoice,
        widget.args.id,
        widget.args.ordinal,
        seconds: pos.inSeconds,
      );
    }
  }

  // ---------- Media helpers ----------

  /// Wrapper that marks an intentional seek so our jump-detector won't flag it.
  Future<void> _seekPlanned(Duration to, {String? reason}) async {
    if (!_alive) return; // bail if page is leaving/disposed

    // Reset auto-skip flags for a fresh media open (quality change / next episode).
    _openingSkipped = false;
    _endingSkipped = false;

    // Clamp the requested position.
    final tgt = _clampSeekAbsolute(to);

    _plannedSeek = true;
    try {
      await _player.seek(tgt);
      _log('seek(planned) to=$tgt reason=${reason ?? "n/a"}');
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
      await _player.open(
        Media(
          url,
          httpHeaders: headers,
        ),
        play: play,
      );
    } catch (e) {
      _log('open failed (not alive?): $e');
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

    // Robust HLS settle: wait for either a valid duration OR first stable positions.
    final settle = Completer<void>();
    late final StreamSubscription subDur;
    late final StreamSubscription subPos;

    final timeout =
        Future<void>.delayed(PlayerTuning.openAtSettleTimeout, () {});
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
        subPos.cancel();
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
      if ((_player.state.position - tgt).abs() >
          PlayerTuning.openAtSeekConfirmTolerance) {
        await _seekPlanned(tgt, reason: 'openAt_restore_confirm');
      }
    } else {
      // Some HLS sources occasionally open a new episode at a non-zero offset.
      // If no resume was requested, force a seek back to 0.
      final startedAt = _player.state.position;
      if (startedAt > PlayerTuning.openAtForceZeroIfStartedAfter) {
        await _seekPlanned(Duration.zero, reason: 'openAt_force_zero');
        if (_player.state.position > PlayerTuning.openAtSeekConfirmTolerance) {
          await _seekPlanned(Duration.zero,
              reason: 'openAt_force_zero_confirm');
        }
      }
    }

    // Ensure playback starts if requested (prevents stuck paused state on Windows).
    if (play && _alive) {
      try {
        if (!_player.state.playing) {
          await _player.play();
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

      // For mpv (desktop NativePlayer), limit HLS bitrate to approximate the selection.
      if (_isDesktop) {
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
          final baseUrl = (_chosenUrl?.trim().isNotEmpty == true)
              ? _chosenUrl!.trim()
              : (rawUrls.isNotEmpty ? rawUrls.first : null);
          if (baseUrl != null && baseUrl.isNotEmpty) {
            final targetHeight = switch (label) {
              PlayerQuality.p1080 => 1080,
              PlayerQuality.p720 => 720,
              PlayerQuality.p480 => 480,
            };

            // Ensure proxy client exists.
            if (!_proxyReady) {
              try {
                await _proxy.start();
                _proxyReady = true;
              } catch (_) {}
            }

            if (_proxyReady) {
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
          }
        } catch (_) {
          // Keep fallback caps.
        }

        unawaited(_setMpv('hls-bitrate', opt));
      }

      // Reopen at the same position only if we have a playable URL.
      final baseUrl = (_chosenUrl?.trim().isNotEmpty == true)
          ? _chosenUrl!.trim()
          : (rawUrls.isNotEmpty ? rawUrls.first : null);
      if (baseUrl == null || baseUrl.isEmpty) return;

      final wasPlaying = _player.state.playing;
      final pos = _player.state.position;

      // Ensure proxy is running
      if (!_proxyReady) {
        try {
          await _proxy.start();
          _proxyReady = true;
        } catch (e) {
          _log('proxy start failed in changeQuality(master): $e');
        }
      }

      final toOpen = _proxyReady && widget.startWithProxy
          ? _proxy.playlistUrl(Uri.parse(baseUrl)).toString()
          : baseUrl;

      final resume = pos + PlayerTuning.openAtResumeFudge;
      await _openAt(toOpen, position: resume, play: wasPlaying);

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

    // Ensure proxy is running
    if (!_proxyReady) {
      try {
        await _proxy.start();
        _proxyReady = true;
      } catch (e) {
        _log('proxy start failed in changeQuality: $e');
      }
    }

    final toOpen = _proxyReady && widget.startWithProxy
        ? _proxy.playlistUrl(Uri.parse(url)).toString()
        : url;

    final resume = pos + PlayerTuning.openAtResumeFudge;
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
      'openingStart': widget.args.openingStart?.toDouble(),
      'openingEnd': widget.args.openingEnd?.toDouble(),
      'endingStart': widget.args.endingStart?.toDouble(),
      'endingEnd': widget.args.endingEnd?.toDouble(),
      'wasPlaying': wasPlaying,
    };

    try {
      _iosNativeActive = true;
      await _iosNativePlayer.invokeMethod<void>('present', args);
      // No further action here; callbacks will sync back on dismiss/completion.
    } on PlatformException catch (e) {
      _iosNativeActive = false;
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
    if (_reopeningGuard || _inQuarantine || _plannedSeek) return;

    // Respect temporary block (e.g., right after undo or iOS restore).
    if (_autoSkipBlockedUntil != null &&
        DateTime.now().isBefore(_autoSkipBlockedUntil!)) {
      // Disable skip penalty by clearing the block.
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
        _skipTo(Duration(seconds: s), Duration(seconds: e),
            banner: 'Skipped Opening');
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
        _skipTo(Duration(seconds: s), Duration(seconds: e),
            banner: 'Skipped Ending');
        return;
      }
    }
  }

  Future<void> _skipTo(Duration from, Duration to,
      {required String banner}) async {
    _undoSeekFrom = _clampSeekAbsolute(from);
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
    _openingSkipped = false;
    _endingSkipped = false;
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
      _log('fetching next episode (modules-only)...');

      final moduleId = widget.args.moduleId;
      if (moduleId == null || moduleId.trim().isEmpty) {
        _log('modules: missing moduleId, cannot auto-next');
        _showBanner('Next episode not supported');
        return;
      }

      // Resolve next episode through the JS module.
      final episodes = await _jsExec.extractEpisodes(moduleId, widget.args.url);
      if (episodes.isEmpty) {
        _log('modules: extractEpisodes returned empty');
        _showBanner('Next episode not available');
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
        _showBanner('Next episode not available');
        return;
      }

      final JsModuleEpisode nextEp = next;

      final selection = await _jsExec.extractStreams(moduleId, nextEp.href);
      if (selection.streams.isEmpty) {
        _log('modules: extractStreams returned empty');
        _showBanner('Next episode stream not available');
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
        _showBanner('Next episode stream not available');
        return;
      }

      if (!mounted) return;

      // Ensure the latest user volume is persisted before rebuilding the page.
      await _flushDesktopVolumeToPrefs(reason: 'auto_next_modules');

      if (!mounted) return;

      _navigatingAway = true;
      _detachListeners();

      _autoIncDoneForThisEp = false;
      _autoIncGuardForOrdinal = null;

      Navigator.of(context).pushReplacement(
        NoSwipeBackMaterialPageRoute(
          builder: (_) => PlayerPage(
            args: PlayerArgs(
              id: widget.args.id,
              url: widget.args.url,
              ordinal: nextEp.number,
              title: widget.args.title,
              moduleId: moduleId,
              preferredStreamTitle: widget.args.preferredStreamTitle,
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
      _log('pushReplacement issued');
    } catch (e, st) {
      _log('failed to open next episode: $e\n$st');
      _navigatingAway = false;
      _showBanner('Failed to open next episode');
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

  void _openSeekStepDialog() {
    // Popup menu closes after tap; open dialog on next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      const options = <int>[2, 5, 10, 15, 30, 60];
      final selected = await showDialog<int>(
        context: context,
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
    final actions = buildPlayerAppBarActions(
      context: context,
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
      onOpenSeekStep: _openSeekStepDialog,
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
          ref.read(playerPrefsProvider.notifier).setAutoProgress(_autoProgress),
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
          if (!mounted) return;
          unawaited(
            showSubtitleStyleDialog(
              context: context,
              ref: ref,
              isDesktop: _isDesktop,
            ),
          );
        });
      },
      animeVoice: widget.animeVoice,
      onSupportVoice: () => openSupport(widget.animeVoice, context),
    );

    final banner = _bannerVisible
        ? PlayerBannerOverlay(
            visible: _bannerVisible,
            text: _bannerText,
            showUndo: _undoSeekFrom != null,
            onUndo: _undoSkip,
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
                return PlayerCursorAutoHideOverlay(
                  idle: PlayerTuning.cursorIdleHide,
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
      final overlayAppBar = Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: IgnorePointer(
          ignoring: !_uiVisible,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            opacity: _uiVisible ? 1.0 : 0.0,
            child: Material(
              color: Colors.black.withValues(alpha: 0.6),
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: kToolbarHeight,
                  child: AppBar(
                    // title: Text(widget.args.title),
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
        ),
      );

      return Stack(
        fit: StackFit.expand,
        children: [
          // Use a tiny bridge to get a context INSIDE the controls subtree.
          Video(
            controller: _video,
            // media_kit_video can render subtitles as a Flutter overlay.
            // On desktop (mpv backend), mpv renders subtitles itself, so the overlay can duplicate.
            subtitleViewConfiguration: SubtitleViewConfiguration(
              visible: !_isDesktop && _subtitlesEnabled,
            ),
            controls: (state) => ControlsCtxBridge(
              state: state,
              onReady: (ctx) {
                if (_navigatingAway) return;
                _controlsCtx ??= ctx;
                _log(
                    'controls onReady; startFullscreen=${widget.startFullscreen}, handled=$_startFsHandled');

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
          overlayAppBar,
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

        if (didPop) return;
        if (!mounted || !navigator.mounted) return;

        navigator.maybePop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Padding(
          padding: _isMobile && !_wasFullscreen
              ? const EdgeInsets.only(bottom: 56, left: 24, right: 24)
              : EdgeInsets.zero,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) {
              _bumpUiVisibility();
              if (!_hotkeysFocusNode.hasFocus) {
                _hotkeysFocusNode.requestFocus();
              }
            },
            onPointerMove: (_) => _bumpUiVisibility(),
            onPointerHover: (_) => _bumpUiVisibility(),
            child: Focus(
              autofocus: true,
              focusNode: _hotkeysFocusNode,
              onKeyEvent: (_, event) {
                if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                  return KeyEventResult.ignored;
                }

                final key = event.logicalKey;

                if (key == LogicalKeyboardKey.space) {
                  unawaited(() async {
                    try {
                      if (_player.state.playing) {
                        await _player.pause();
                        _log('hotkey: pause');
                      } else {
                        await _player.play();
                        _log('hotkey: play');
                      }
                    } catch (_) {}
                  }());
                  return KeyEventResult.handled;
                }

                if (key == LogicalKeyboardKey.keyF) {
                  if (_isIOS) return KeyEventResult.handled;
                  final c = _controlsCtx;
                  if (c == null || !c.mounted) return KeyEventResult.handled;
                  unawaited(() async {
                    try {
                      if (!isFullscreen(c)) {
                        await enterFullscreen(c);
                        _wasFullscreen = true;
                        await _enterNativeFullscreen();
                        _insertCursorOverlayIfNeeded();
                        _cursorHideController.kick();
                        _log('hotkey: enter fullscreen');
                      } else {
                        await exitFullscreen(c);
                        _wasFullscreen = false;
                        await _exitNativeFullscreen();
                        _removeCursorOverlayIfAny();
                        _log('hotkey: exit fullscreen');
                      }
                    } catch (_) {}
                  }());
                  return KeyEventResult.handled;
                }

                if (key == LogicalKeyboardKey.escape) {
                  if (_isIOS) return KeyEventResult.handled;
                  final c = _controlsCtx;
                  if (c == null || !c.mounted) return KeyEventResult.handled;
                  unawaited(() async {
                    try {
                      if (isFullscreen(c)) {
                        await exitFullscreen(c);
                        _wasFullscreen = false;
                        await _exitNativeFullscreen();
                        _removeCursorOverlayIfAny();
                        _log('hotkey: escape fullscreen');
                      }
                    } catch (_) {}
                  }());
                  return KeyEventResult.handled;
                }

                if (key == LogicalKeyboardKey.arrowLeft) {
                  final step = _seekStepSeconds;
                  if (step <= 0) return KeyEventResult.handled;
                  unawaited(
                    _seekPlanned(
                      _player.state.position - Duration(seconds: step),
                      reason: 'key_seek_left',
                    ),
                  );
                  return KeyEventResult.handled;
                }

                if (key == LogicalKeyboardKey.arrowRight) {
                  final step = _seekStepSeconds;
                  if (step <= 0) return KeyEventResult.handled;
                  unawaited(
                    _seekPlanned(
                      _player.state.position + Duration(seconds: step),
                      reason: 'key_seek_right',
                    ),
                  );
                  return KeyEventResult.handled;
                }

                return KeyEventResult.ignored;
              },
              child: wrapDesktopCursorHider(
                buildPlayerStack(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
