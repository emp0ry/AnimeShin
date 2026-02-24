class SeekRequest {
  const SeekRequest({
    required this.target,
    required this.reason,
    required this.timestamp,
  });

  final Duration target;
  final String? reason;
  final DateTime timestamp;
}

enum SeekDecision {
  executeNow,
  queueLatest,
  dropDuplicate,
}

class SeekCoordinator {
  SeekCoordinator({
    required this.coalesceWindow,
    required this.duplicateTolerance,
  });

  final Duration coalesceWindow;
  final Duration duplicateTolerance;

  bool _inFlight = false;
  SeekRequest? _pending;
  DateTime? _pendingReadyAt;
  DateTime? _lastDecisionAt;
  Duration? _activeTarget;
  Duration? _lastExecutedTarget;
  int _correctionAttempts = 0;

  bool get inFlight => _inFlight;

  bool get hasPending => _pending != null;

  SeekRequest? get pendingRequest => _pending;

  Duration? get lastExecutedTarget => _lastExecutedTarget;

  ({SeekDecision decision, bool replacedPending}) enqueue(
    SeekRequest request, {
    DateTime? now,
  }) {
    final ts = now ?? DateTime.now();

    final duplicateWithActive = _isClose(request.target, _activeTarget);
    final duplicateWithPending = _isClose(request.target, _pending?.target);
    if (duplicateWithActive || duplicateWithPending) {
      return (decision: SeekDecision.dropDuplicate, replacedPending: false);
    }

    final insideCoalesceWindow = _lastDecisionAt != null &&
        ts.difference(_lastDecisionAt!) < coalesceWindow;

    if (_inFlight || insideCoalesceWindow) {
      final replacedPending = _pending != null;
      _pending = request;
      _pendingReadyAt = ts.add(coalesceWindow);
      _lastDecisionAt = ts;
      return (
        decision: SeekDecision.queueLatest,
        replacedPending: replacedPending,
      );
    }

    _lastDecisionAt = ts;
    return (decision: SeekDecision.executeNow, replacedPending: false);
  }

  void markSeekStarted(SeekRequest request, {DateTime? now}) {
    _inFlight = true;
    _activeTarget = request.target;
    _lastDecisionAt = now ?? DateTime.now();
    _correctionAttempts = 0;
  }

  void markSeekFinished({
    required Duration executedTarget,
    DateTime? now,
  }) {
    _inFlight = false;
    _activeTarget = null;
    _lastExecutedTarget = executedTarget;
    _lastDecisionAt = now ?? DateTime.now();
  }

  SeekRequest? takeReadyPending({DateTime? now}) {
    final pending = _pending;
    if (pending == null) return null;
    final ts = now ?? DateTime.now();
    final readyAt = _pendingReadyAt;
    if (readyAt != null && ts.isBefore(readyAt)) return null;

    _pending = null;
    _pendingReadyAt = null;
    return pending;
  }

  Duration? delayUntilPendingReady({DateTime? now}) {
    final readyAt = _pendingReadyAt;
    if (_pending == null || readyAt == null) return null;
    final delay = readyAt.difference(now ?? DateTime.now());
    if (delay.isNegative) return Duration.zero;
    return delay;
  }

  bool shouldCorrectMismatch({
    required Duration currentPosition,
    required Duration retryThreshold,
    required int maxCorrection,
  }) {
    final target = _lastExecutedTarget;
    if (target == null) return false;
    if (_correctionAttempts >= maxCorrection) return false;
    final delta = (currentPosition - target).abs();
    return delta >= retryThreshold;
  }

  void noteCorrectionApplied() {
    _correctionAttempts++;
  }

  void reset() {
    _inFlight = false;
    _pending = null;
    _pendingReadyAt = null;
    _lastDecisionAt = null;
    _activeTarget = null;
    _lastExecutedTarget = null;
    _correctionAttempts = 0;
  }

  bool _isClose(Duration a, Duration? b) {
    if (b == null) return false;
    return (a - b).abs() <= duplicateTolerance;
  }
}
