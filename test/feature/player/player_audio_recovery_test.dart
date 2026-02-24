import 'package:animeshin/feature/player/player_audio_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudioDropDetector', () {
    AudioDropDetector createDetector() {
      return AudioDropDetector(
        confirmWindow: const Duration(seconds: 4),
        cooldown: const Duration(seconds: 12),
      );
    }

    AudioStateSnapshot snapshot({
      required bool playing,
      required bool buffering,
      required double volume,
      required bool muted,
      required int tracks,
      required String? aid,
      required double? bitrate,
    }) {
      return AudioStateSnapshot(
        playing: playing,
        buffering: buffering,
        volume: volume,
        muted: muted,
        audioTrackCount: tracks,
        selectedAid: aid,
        audioBitrate: bitrate,
      );
    }

    test('does not detect drop while buffering', () {
      final detector = createDetector();
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);

      final decision = detector.evaluate(
        snapshot(
          playing: true,
          buffering: true,
          volume: 100,
          muted: false,
          tracks: 1,
          aid: 'no',
          bitrate: 0,
        ),
        now: t0,
      );

      expect(decision, AudioRecoveryDecision.none);
    });

    test('confirms drop only after confirmation window', () {
      final detector = createDetector();
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final badState = snapshot(
        playing: true,
        buffering: false,
        volume: 90,
        muted: false,
        tracks: 2,
        aid: 'no',
        bitrate: 0,
      );

      expect(
        detector.evaluate(badState, now: t0),
        AudioRecoveryDecision.detectDrop,
      );
      expect(
        detector.evaluate(
          badState,
          now: t0.add(const Duration(seconds: 2)),
        ),
        AudioRecoveryDecision.none,
      );
      expect(
        detector.evaluate(
          badState,
          now: t0.add(const Duration(seconds: 4)),
        ),
        AudioRecoveryDecision.reselectAid,
      );
    });

    test('cooldown blocks repeated recovery attempts', () {
      final detector = createDetector();
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final badState = snapshot(
        playing: true,
        buffering: false,
        volume: 85,
        muted: false,
        tracks: 1,
        aid: 'no',
        bitrate: 0,
      );

      expect(
        detector.evaluate(badState, now: t0),
        AudioRecoveryDecision.detectDrop,
      );
      expect(
        detector.evaluate(
          badState,
          now: t0.add(const Duration(seconds: 4)),
        ),
        AudioRecoveryDecision.reselectAid,
      );

      expect(
        detector.evaluate(
          badState,
          now: t0.add(const Duration(seconds: 5)),
        ),
        AudioRecoveryDecision.none,
      );
      expect(
        detector.evaluate(
          badState,
          now: t0.add(const Duration(seconds: 16)),
        ),
        AudioRecoveryDecision.detectDrop,
      );
    });

    test('does not trigger when selected aid is healthy', () {
      final detector = createDetector();
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);

      final decision = detector.evaluate(
        snapshot(
          playing: true,
          buffering: false,
          volume: 100,
          muted: false,
          tracks: 2,
          aid: '2',
          bitrate: 128000,
        ),
        now: t0,
      );

      expect(decision, AudioRecoveryDecision.none);
    });

    test('works with null audio bitrate without crashing', () {
      final detector = createDetector();
      final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final badState = snapshot(
        playing: true,
        buffering: false,
        volume: 80,
        muted: false,
        tracks: 1,
        aid: 'no',
        bitrate: null,
      );

      expect(
        detector.evaluate(badState, now: t0),
        AudioRecoveryDecision.detectDrop,
      );
      expect(
        detector.evaluate(
          badState,
          now: t0.add(const Duration(seconds: 4)),
        ),
        AudioRecoveryDecision.reselectAid,
      );
    });
  });
}
