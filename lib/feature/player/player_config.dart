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
  static const bool hlsUpstreamPersistentConnections = false;
  static const bool mpvHlsPersistentConnection = false;

  // Fullscreen/native timing
  static const Duration nativeFullscreenDelay = Duration(milliseconds: 150);

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
