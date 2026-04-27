// Player-specific enums & tuning constants.
//
// Goal: reduce hard-coded strings/magic numbers in `player_page.dart` so future
// features are easier to add and safer to refactor.

enum PlayerQuality {
  p1080,
  p720,
  p480;

  String get label => switch (this) {
        PlayerQuality.p1080 => '1080p',
        PlayerQuality.p720 => '720p',
        PlayerQuality.p480 => '480p',
      };

  static const List<PlayerQuality> menuOrder = [
    PlayerQuality.p1080,
    PlayerQuality.p720,
    PlayerQuality.p480,
  ];

  static PlayerQuality fromLabel(String? value) {
    final v = (value ?? '').trim().toLowerCase();
    return switch (v) {
      '1080p' => PlayerQuality.p1080,
      '720p' => PlayerQuality.p720,
      '480p' => PlayerQuality.p480,
      _ => PlayerQuality.p1080,
    };
  }
}

class PlayerTuning {
  const PlayerTuning._();

  // UI
  static const Duration bannerHideAfter = Duration(seconds: 5);
  static const Duration cursorIdleHide = Duration(seconds: 3);

  // Autosave
  static const Duration autosavePeriod = Duration(seconds: 5);
  static const Duration volumePersistDebounce = Duration(milliseconds: 300);

  // iOS restore
  static const Duration iosRestoreSettleTimeout = Duration(seconds: 8);
  static const Duration iosAutoSkipBlockAfterRestore = Duration(seconds: 3);
  static const Duration iosRestorePosTickThreshold =
      Duration(milliseconds: 500);

  // Open+seek settle
  static const Duration openAtSettleTimeout = Duration(seconds: 12);
  static const Duration openAtSeekConfirmTolerance =
      Duration(milliseconds: 250);
  static const Duration openAtResumeFudge = Duration(milliseconds: 300);
  static const Duration openAtForceZeroIfStartedAfter = Duration(seconds: 2);
  static const Duration seekCoalesceWindow = Duration(milliseconds: 140);
  static const Duration seekVerifyDelay = Duration(milliseconds: 220);
  static const Duration seekVerifyTolerance = Duration(milliseconds: 350);
  static const Duration seekMismatchRetryThreshold = Duration(seconds: 2);
  static const int seekMismatchMaxCorrection = 1;
  static const Duration longPauseBufferResetAfter = Duration(minutes: 8);
  static const String mpvVideoSyncMode = 'audio';
  static const bool resumeAnchorEnabled = true;
  static const Duration resumeAnchorApplyAfterPause = Duration(seconds: 20);
  static const Duration resumeAnchorVerifyDelay = Duration(milliseconds: 260);
  static const Duration resumeAnchorSecondVerifyDelay =
      Duration(milliseconds: 1300);
  static const Duration resumeAnchorDriftTolerance =
      Duration(milliseconds: 450);
  static const Duration resumeAnchorMismatchThreshold = Duration(seconds: 2);
  static const int resumeAnchorMaxCorrection = 1;

  // Jump detection
  static const Duration jumpLogThreshold = Duration(milliseconds: 3500);
  static const Duration jumpQuarantineWindow = Duration(seconds: 2);
  static const Duration jumpBigLeap = Duration(seconds: 30);

  // Auto-skip
  static const Duration autoSkipBlockAfterSkip = Duration(seconds: 2);
  static const Duration autoSkipBlockAfterUndo = Duration(seconds: 10);

  // HLS proxy diagnostics & retries
  static const Duration hlsSegmentTimeout = Duration(seconds: 8);
  static const int hlsSegmentMaxRetries = 3;
  static const int hlsRetryBackoffBaseMs = 140;
  static const bool hlsShortReadRetryEnabled = true;
  static const Duration hlsJumpCorrelationWindow = Duration(seconds: 8);
  static const bool hlsUpstreamPersistentConnections = true;
  static const bool mpvHlsPersistentConnection = true;
  static const Duration hlsUpstreamIdleResetAfter = Duration(seconds: 45);

  // Audio drop watchdog & recovery
  static const bool audioDropWatchEnabled = true;
  static const Duration audioHealthPollInterval = Duration(seconds: 1);
  static const Duration audioWatchdogPausedPollInterval = Duration(seconds: 20);
  static const Duration audioDropConfirmWindow = Duration(seconds: 4);
  static const Duration audioReselectCooldown = Duration(seconds: 12);
  static const Duration audioReselectSettleDelay = Duration(milliseconds: 120);

  // Fullscreen/native timing
  static const Duration nativeFullscreenDelay = Duration(milliseconds: 150);
  static const Duration mobileFullscreenReentryDelay =
      Duration(milliseconds: 250);
  static const int mobileFullscreenReentryMaxAttempts = 12;
  static const double playerUiProtectedBottomArea = 96.0;
  static const double playerUiProtectedCenterAreaWidth = 104.0;
  static const double playerUiProtectedCenterAreaHeight = 104.0;

  // Auto-next module resolution timeout
  static const Duration autoNextResolveTimeout = Duration(seconds: 15);

  // Desktop mpv buffering (bytes)
  static const int windowsBufferBytes = 128 * 1024 * 1024;
  static const int otherBufferBytes = 64 * 1024 * 1024;

  // Windows fallback switch:
  // keep hardware rendering as default; allow forcing software if needed.
  static const bool windowsForceSoftwareVideoOutput = false;

  // Speed menu
  static const List<double> speedMenu = [
    0.25,
    0.5,
    0.75,
    1,
    1.25,
    1.5,
    1.75,
    2,
    2.25,
    2.5,
  ];
}
