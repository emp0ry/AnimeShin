import 'package:animeshin/feature/player/local_hls_proxy.dart';
import 'package:animeshin/feature/player/player_transport_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlayerTransportCorrelator', () {
    test('correlates jump with the latest recent segment error', () {
      final correlator = PlayerTransportCorrelator(
        correlationWindow: const Duration(seconds: 8),
      );
      final failTs = DateTime.utc(2026, 1, 1, 12, 0, 0);

      correlator.registerProxyEvent(
        HlsProxyEvent(
          type: HlsProxyEventType.segmentFail,
          timestamp: failTs,
          traceId: 'trace-a',
          requestId: 77,
          segmentUrlHash: 'deadbeef',
          retry: 1,
          statusCode: 502,
          errorType: 'timeout',
        ),
      );

      final hit = correlator.correlateJump(
        failTs.add(const Duration(milliseconds: 1750)),
      );
      expect(hit.requestId, 77);
      expect(hit.age, const Duration(milliseconds: 1750));
    });

    test('returns empty correlation outside the time window', () {
      final correlator = PlayerTransportCorrelator(
        correlationWindow: const Duration(seconds: 3),
      );
      final failTs = DateTime.utc(2026, 1, 1, 12, 0, 0);

      correlator.registerProxyEvent(
        HlsProxyEvent(
          type: HlsProxyEventType.segmentFail,
          timestamp: failTs,
          traceId: 'trace-b',
          requestId: 101,
          segmentUrlHash: 'abc12345',
          retry: 0,
          statusCode: 504,
          errorType: 'timeout',
        ),
      );

      final miss = correlator.correlateJump(
        failTs.add(const Duration(seconds: 12)),
      );
      expect(miss.requestId, isNull);
      expect(miss.age, isNull);
    });

    test('formats audio transport event in debug line', () {
      final event = PlayerTransportEvent(
        timestamp: DateTime.utc(2026, 1, 1, 12, 0, 0),
        traceId: 'trace-audio',
        type: PlayerTransportEventType.audioDropDetected,
        position: const Duration(minutes: 7, seconds: 3),
        note: 'reason=watchdog aid=no',
      );

      final line = event.toDebugLine();
      expect(line, contains('trace=trace-audio'));
      expect(line, contains('type=audioDropDetected'));
      expect(line, contains('note="reason=watchdog aid=no"'));
    });

    test('formats new seek/cache transport event types', () {
      const types = <PlayerTransportEventType>[
        PlayerTransportEventType.seekQueued,
        PlayerTransportEventType.seekCoalesced,
        PlayerTransportEventType.seekVerify,
        PlayerTransportEventType.seekMismatch,
        PlayerTransportEventType.resumeAnchorStart,
        PlayerTransportEventType.resumeAnchorVerify,
        PlayerTransportEventType.resumeAnchorMismatch,
        PlayerTransportEventType.resumeAnchorEnd,
        PlayerTransportEventType.cacheReset,
      ];

      for (final type in types) {
        final event = PlayerTransportEvent(
          timestamp: DateTime.utc(2026, 1, 1, 12, 0, 0),
          traceId: 'trace-seek',
          type: type,
          position: const Duration(seconds: 11),
          targetPosition: const Duration(seconds: 13),
          note: 'note=$type',
        );
        final line = event.toDebugLine();
        expect(line, contains('trace=trace-seek'));
        expect(line, contains('type=${type.name}'));
      }
    });
  });
}
