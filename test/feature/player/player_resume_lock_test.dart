import 'package:animeshin/feature/player/player_resume_lock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ResumeLockController', () {
    ResumeLockController createController() {
      return ResumeLockController(
        applyAfterPause: const Duration(seconds: 20),
        mismatchThreshold: const Duration(seconds: 2),
        maxCorrection: 1,
      );
    }

    test('does not apply anchor lock on short pause', () {
      final controller = createController();
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);
      controller.markPaused(
        anchorPosition: const Duration(minutes: 7, seconds: 5),
        now: t0,
      );

      final snapshot = controller.snapshotOnResume(
        now: t0.add(const Duration(seconds: 10)),
      );
      expect(snapshot, isNotNull);
      final decision = controller.decideOnResume(snapshot!);
      expect(decision, ResumeAnchorDecision.none);
    });

    test('applies anchor lock on long pause', () {
      final controller = createController();
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);
      controller.markPaused(
        anchorPosition: const Duration(minutes: 7, seconds: 5),
        now: t0,
      );

      final snapshot = controller.snapshotOnResume(
        now: t0.add(const Duration(seconds: 35)),
      );
      expect(snapshot, isNotNull);
      final decision = controller.decideOnResume(snapshot!);
      expect(decision, ResumeAnchorDecision.applyAnchor);
    });

    test('does one correction on mismatch over threshold', () {
      final controller = createController();
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);
      controller.markPaused(
        anchorPosition: const Duration(minutes: 10),
        now: t0,
      );
      final snapshot = controller.snapshotOnResume(
        now: t0.add(const Duration(seconds: 30)),
      );
      expect(controller.decideOnResume(snapshot!),
          ResumeAnchorDecision.applyAnchor);

      final correction = controller.decideCorrection(
        currentPosition: const Duration(minutes: 10, seconds: 4),
        buffering: false,
      );
      expect(correction, ResumeAnchorDecision.correctOnce);
    });

    test('blocks second mismatch correction after max correction', () {
      final controller = createController();
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);
      controller.markPaused(
        anchorPosition: const Duration(minutes: 3),
        now: t0,
      );
      final snapshot = controller.snapshotOnResume(
        now: t0.add(const Duration(seconds: 45)),
      );
      expect(controller.decideOnResume(snapshot!),
          ResumeAnchorDecision.applyAnchor);

      expect(
        controller.decideCorrection(
          currentPosition: const Duration(minutes: 3, seconds: 5),
          buffering: false,
        ),
        ResumeAnchorDecision.correctOnce,
      );
      expect(
        controller.decideCorrection(
          currentPosition: const Duration(minutes: 3, seconds: 6),
          buffering: false,
        ),
        ResumeAnchorDecision.none,
      );
    });

    test('does not correct while buffering', () {
      final controller = createController();
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);
      controller.markPaused(
        anchorPosition: const Duration(minutes: 5),
        now: t0,
      );
      final snapshot = controller.snapshotOnResume(
        now: t0.add(const Duration(seconds: 25)),
      );
      expect(controller.decideOnResume(snapshot!),
          ResumeAnchorDecision.applyAnchor);

      final correction = controller.decideCorrection(
        currentPosition: const Duration(minutes: 5, seconds: 5),
        buffering: true,
      );
      expect(correction, ResumeAnchorDecision.none);
    });
  });
}
