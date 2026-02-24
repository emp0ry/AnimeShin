enum AudioRecoveryDecision {
  none,
  detectDrop,
  reselectAid,
}

class AudioStateSnapshot {
  const AudioStateSnapshot({
    required this.playing,
    required this.buffering,
    required this.volume,
    required this.muted,
    required this.audioTrackCount,
    required this.selectedAid,
    required this.audioBitrate,
  });

  final bool playing;
  final bool buffering;
  final double volume;
  final bool muted;
  final int audioTrackCount;
  final String? selectedAid;
  final double? audioBitrate;

  bool get _hasMissingAid {
    final aid = selectedAid?.trim();
    if (aid == null || aid.isEmpty) return true;
    return aid.toLowerCase() == 'no';
  }

  bool get _hasZeroAudioBitrate {
    final bitrate = audioBitrate;
    if (bitrate == null) return false;
    return bitrate <= 0;
  }

  bool get isDropCandidate {
    return playing &&
        !buffering &&
        volume > 0 &&
        !muted &&
        audioTrackCount > 0 &&
        (_hasMissingAid || _hasZeroAudioBitrate);
  }
}

class AudioDropDetector {
  AudioDropDetector({
    required this.confirmWindow,
    required this.cooldown,
  });

  final Duration confirmWindow;
  final Duration cooldown;

  DateTime? _dropCandidateSince;
  DateTime? _cooldownUntil;
  bool _dropSignaled = false;

  bool isInCooldown([DateTime? now]) {
    final until = _cooldownUntil;
    if (until == null) return false;
    return (now ?? DateTime.now()).isBefore(until);
  }

  void reset() {
    _dropCandidateSince = null;
    _cooldownUntil = null;
    _dropSignaled = false;
  }

  AudioRecoveryDecision evaluate(
    AudioStateSnapshot snapshot, {
    DateTime? now,
  }) {
    final ts = now ?? DateTime.now();

    if (!snapshot.isDropCandidate) {
      _dropCandidateSince = null;
      _dropSignaled = false;
      return AudioRecoveryDecision.none;
    }

    if (isInCooldown(ts)) {
      return AudioRecoveryDecision.none;
    }

    final since = _dropCandidateSince;
    if (since == null) {
      _dropCandidateSince = ts;
      _dropSignaled = true;
      return AudioRecoveryDecision.detectDrop;
    }

    if (!_dropSignaled) {
      _dropSignaled = true;
      return AudioRecoveryDecision.detectDrop;
    }

    if (ts.difference(since) >= confirmWindow) {
      _dropCandidateSince = null;
      _dropSignaled = false;
      _cooldownUntil = ts.add(cooldown);
      return AudioRecoveryDecision.reselectAid;
    }

    return AudioRecoveryDecision.none;
  }
}
