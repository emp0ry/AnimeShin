import 'package:animeshin/feature/player/local_hls_proxy.dart';

enum PlayerTransportEventType {
  seekStart,
  seekEnd,
  bufferingStart,
  bufferingEnd,
  unexpectedJump,
  proxyEvent,
}

class PlayerTransportEvent {
  const PlayerTransportEvent({
    required this.timestamp,
    required this.traceId,
    required this.type,
    this.position,
    this.targetPosition,
    this.note,
    this.relatedProxyRequestId,
    this.relatedProxyAge,
  });

  final DateTime timestamp;
  final String traceId;
  final PlayerTransportEventType type;
  final Duration? position;
  final Duration? targetPosition;
  final String? note;
  final int? relatedProxyRequestId;
  final Duration? relatedProxyAge;

  String toDebugLine() {
    final b = StringBuffer();
    b.write('trace=$traceId ');
    b.write('type=${type.name}');
    if (position != null) {
      b.write(' pos=${_fmt(position!)}');
    }
    if (targetPosition != null) {
      b.write(' target=${_fmt(targetPosition!)}');
    }
    if (relatedProxyRequestId != null) {
      b.write(' relatedReq=$relatedProxyRequestId');
    }
    if (relatedProxyAge != null) {
      b.write(' relatedAgeMs=${relatedProxyAge!.inMilliseconds}');
    }
    if (note != null && note!.isNotEmpty) {
      b.write(' note="$note"');
    }
    return b.toString();
  }

  static String _fmt(Duration d) {
    final totalMs = d.inMilliseconds;
    final sign = totalMs < 0 ? '-' : '';
    final absMs = totalMs.abs();
    final h = absMs ~/ 3600000;
    final m = (absMs ~/ 60000) % 60;
    final s = (absMs ~/ 1000) % 60;
    final ms = absMs % 1000;
    return '$sign${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}.'
        '${ms.toString().padLeft(3, '0')}';
  }
}

class PlayerTransportCorrelator {
  PlayerTransportCorrelator({
    required this.correlationWindow,
  });

  final Duration correlationWindow;
  HlsProxyEvent? _lastSegmentError;

  void registerProxyEvent(HlsProxyEvent event) {
    if (event.type == HlsProxyEventType.segmentFail ||
        event.type == HlsProxyEventType.segmentRetry) {
      _lastSegmentError = event;
    }
  }

  ({int? requestId, Duration? age}) correlateJump(DateTime timestamp) {
    final last = _lastSegmentError;
    if (last == null) {
      return (requestId: null, age: null);
    }
    final age = timestamp.difference(last.timestamp);
    if (age.isNegative || age > correlationWindow) {
      return (requestId: null, age: null);
    }
    return (requestId: last.requestId, age: age);
  }
}
