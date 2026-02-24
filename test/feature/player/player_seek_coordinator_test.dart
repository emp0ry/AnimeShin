import 'package:animeshin/feature/player/player_seek_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SeekCoordinator', () {
    SeekCoordinator createCoordinator() {
      return SeekCoordinator(
        coalesceWindow: const Duration(milliseconds: 140),
        duplicateTolerance: const Duration(milliseconds: 350),
      );
    }

    SeekRequest request(
      int seconds,
      DateTime ts, {
      String reason = 'test',
    }) {
      return SeekRequest(
        target: Duration(seconds: seconds),
        reason: reason,
        timestamp: ts,
      );
    }

    test('coalesces burst seeks and keeps only the latest pending request', () {
      final coordinator = createCoordinator();
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);

      final first = request(10, t0, reason: 'first');
      final second = request(25, t0.add(const Duration(milliseconds: 20)),
          reason: 'second');
      final third = request(
        40,
        t0.add(const Duration(milliseconds: 35)),
        reason: 'third',
      );

      final firstDecision = coordinator.enqueue(first, now: t0);
      expect(firstDecision.decision, SeekDecision.executeNow);

      coordinator.markSeekStarted(first, now: t0);
      coordinator.markSeekFinished(
        executedTarget: first.target,
        now: t0.add(const Duration(milliseconds: 10)),
      );

      final secondDecision = coordinator.enqueue(
        second,
        now: t0.add(const Duration(milliseconds: 20)),
      );
      expect(secondDecision.decision, SeekDecision.queueLatest);
      expect(secondDecision.replacedPending, isFalse);

      final thirdDecision = coordinator.enqueue(
        third,
        now: t0.add(const Duration(milliseconds: 35)),
      );
      expect(thirdDecision.decision, SeekDecision.queueLatest);
      expect(thirdDecision.replacedPending, isTrue);

      final notReady = coordinator.takeReadyPending(
        now: t0.add(const Duration(milliseconds: 100)),
      );
      expect(notReady, isNull);

      final ready = coordinator.takeReadyPending(
        now: t0.add(const Duration(milliseconds: 220)),
      );
      expect(ready, isNotNull);
      expect(ready!.target, third.target);
      expect(coordinator.hasPending, isFalse);
    });

    test('replaces pending seek with latest while seek is in-flight', () {
      final coordinator = createCoordinator();
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);

      final active = request(30, t0, reason: 'active');
      final pendingA = request(
        60,
        t0.add(const Duration(milliseconds: 40)),
        reason: 'pending_a',
      );
      final pendingB = request(
        90,
        t0.add(const Duration(milliseconds: 55)),
        reason: 'pending_b',
      );

      expect(
        coordinator.enqueue(active, now: t0).decision,
        SeekDecision.executeNow,
      );
      coordinator.markSeekStarted(active, now: t0);

      final queuedA = coordinator.enqueue(
        pendingA,
        now: t0.add(const Duration(milliseconds: 40)),
      );
      expect(queuedA.decision, SeekDecision.queueLatest);
      expect(queuedA.replacedPending, isFalse);

      final queuedB = coordinator.enqueue(
        pendingB,
        now: t0.add(const Duration(milliseconds: 55)),
      );
      expect(queuedB.decision, SeekDecision.queueLatest);
      expect(queuedB.replacedPending, isTrue);

      coordinator.markSeekFinished(
        executedTarget: active.target,
        now: t0.add(const Duration(milliseconds: 150)),
      );

      final ready = coordinator.takeReadyPending(
        now: t0.add(const Duration(milliseconds: 220)),
      );
      expect(ready, isNotNull);
      expect(ready!.target, pendingB.target);
    });

    test('verify mismatch correction is capped to one attempt', () {
      final coordinator = createCoordinator();
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final first = request(120, t0, reason: 'verify');

      expect(coordinator.enqueue(first, now: t0).decision,
          SeekDecision.executeNow);
      coordinator.markSeekStarted(first, now: t0);
      coordinator.markSeekFinished(
        executedTarget: first.target,
        now: t0.add(const Duration(milliseconds: 20)),
      );

      final shouldCorrect = coordinator.shouldCorrectMismatch(
        currentPosition: const Duration(seconds: 110),
        retryThreshold: const Duration(seconds: 2),
        maxCorrection: 1,
      );
      expect(shouldCorrect, isTrue);

      coordinator.noteCorrectionApplied();

      final blockedAfterFirst = coordinator.shouldCorrectMismatch(
        currentPosition: const Duration(seconds: 109),
        retryThreshold: const Duration(seconds: 2),
        maxCorrection: 1,
      );
      expect(blockedAfterFirst, isFalse);
    });

    test('drops duplicate seek target within tolerance', () {
      final coordinator = createCoordinator();
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final first = request(50, t0, reason: 'first');

      expect(
        coordinator.enqueue(first, now: t0).decision,
        SeekDecision.executeNow,
      );
      coordinator.markSeekStarted(first, now: t0);

      final duplicate = coordinator.enqueue(
        SeekRequest(
          target: const Duration(seconds: 50, milliseconds: 200),
          reason: 'dup',
          timestamp: t0.add(const Duration(milliseconds: 30)),
        ),
        now: t0.add(const Duration(milliseconds: 30)),
      );

      expect(duplicate.decision, SeekDecision.dropDuplicate);
      expect(coordinator.hasPending, isFalse);
    });
  });
}
