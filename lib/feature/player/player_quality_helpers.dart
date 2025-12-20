import 'package:animeshin/feature/player/player_config.dart';

bool _isPresentUrl(String? s) {
  final v = s?.trim();
  return v != null && v.isNotEmpty && v.toLowerCase() != 'null';
}

/// Picks the best available URL given a preferred [quality] and fallback order.
///
/// Returns `null` if all candidate URLs are absent.
String? pickUrlForQuality({
  required PlayerQuality quality,
  required String? url1080,
  required String? url720,
  required String? url480,
  void Function(String message)? log,
  Object? argsIdentity,
}) {
  late final List<String?> candidates;
  switch (quality) {
    case PlayerQuality.p1080:
      candidates = [url1080, url720, url480];
    case PlayerQuality.p720:
      candidates = [url720, url480, url1080];
    case PlayerQuality.p480:
      candidates = [url480, url720, url1080];
  }

  for (final c in candidates) {
    if (_isPresentUrl(c)) {
      final chosen = c!.trim();
      log?.call('[pickUrl] quality="${quality.label}" chose: $chosen');
      return chosen;
    }
  }

  log?.call(
    '[pickUrl] RETURN NULL. quality="${quality.label}" '
    'args#${argsIdentity == null ? 'null' : identityHashCode(argsIdentity)} '
    '1080="$url1080" 720="$url720" 480="$url480"',
  );
  return null;
}

/// Picks the initial playback quality and the URL to open.
///
/// If a URL is picked, it's returned in [chosenUrl].
({PlayerQuality quality, String? chosenUrl}) pickInitialQualityAndUrl({
  required PlayerQuality preferredQuality,
  required String? url1080,
  required String? url720,
  required String? url480,
  void Function(String message)? log,
  Object? argsIdentity,
}) {
  final url = pickUrlForQuality(
    quality: preferredQuality,
    url1080: url1080,
    url720: url720,
    url480: url480,
    log: log,
    argsIdentity: argsIdentity,
  );
  return (quality: preferredQuality, chosenUrl: url);
}
