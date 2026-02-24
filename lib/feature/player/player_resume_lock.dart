class ResumeAnchorSnapshot {
  const ResumeAnchorSnapshot({
    required this.anchorPosition,
    required this.pausedAt,
    required this.resumedAt,
    required this.pauseDuration,
  });

  final Duration anchorPosition;
  final DateTime pausedAt;
  final DateTime resumedAt;
  final Duration pauseDuration;
}

enum ResumeAnchorDecision {
  none,
  applyAnchor,
  correctOnce,
}

class ResumeLockController {
  ResumeLockController({
    required this.applyAfterPause,
    required this.mismatchThreshold,
    required this.maxCorrection,
  });

  final Duration applyAfterPause;
  final Duration mismatchThreshold;
  final int maxCorrection;

  DateTime? _pausedAt;
  Duration? _anchorPosition;
  int _correctionAttempts = 0;
  bool _resumeAnchorApplied = false;

  DateTime? get pausedAt => _pausedAt;
  Duration? get anchorPosition => _anchorPosition;
  int get correctionAttempts => _correctionAttempts;
  bool get resumeAnchorApplied => _resumeAnchorApplied;

  void markPaused({
    required Duration anchorPosition,
    DateTime? now,
  }) {
    _pausedAt = now ?? DateTime.now();
    _anchorPosition = anchorPosition;
    _correctionAttempts = 0;
    _resumeAnchorApplied = false;
  }

  ResumeAnchorSnapshot? snapshotOnResume({DateTime? now}) {
    final pausedAt = _pausedAt;
    final anchor = _anchorPosition;
    if (pausedAt == null || anchor == null) return null;
    final resumedAt = now ?? DateTime.now();
    return ResumeAnchorSnapshot(
      anchorPosition: anchor,
      pausedAt: pausedAt,
      resumedAt: resumedAt,
      pauseDuration: resumedAt.difference(pausedAt),
    );
  }

  ResumeAnchorDecision decideOnResume(ResumeAnchorSnapshot snapshot) {
    _correctionAttempts = 0;
    if (snapshot.pauseDuration >= applyAfterPause) {
      _resumeAnchorApplied = true;
      return ResumeAnchorDecision.applyAnchor;
    }
    _resumeAnchorApplied = false;
    return ResumeAnchorDecision.none;
  }

  ResumeAnchorDecision decideCorrection({
    required Duration currentPosition,
    required bool buffering,
  }) {
    if (buffering || !_resumeAnchorApplied) return ResumeAnchorDecision.none;
    final anchor = _anchorPosition;
    if (anchor == null) return ResumeAnchorDecision.none;
    if (_correctionAttempts >= maxCorrection) return ResumeAnchorDecision.none;

    final drift = (currentPosition - anchor).abs();
    if (drift > mismatchThreshold) {
      _correctionAttempts++;
      return ResumeAnchorDecision.correctOnce;
    }
    return ResumeAnchorDecision.none;
  }

  void clearResumeContext() {
    _pausedAt = null;
    _resumeAnchorApplied = false;
    _correctionAttempts = 0;
  }

  void reset() {
    _pausedAt = null;
    _anchorPosition = null;
    _correctionAttempts = 0;
    _resumeAnchorApplied = false;
  }
}
