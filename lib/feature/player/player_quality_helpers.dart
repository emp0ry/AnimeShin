import 'package:animeshin/feature/player/player_config.dart';

enum StreamUrlKind {
  hls,
  directFile,
  unknown,
}

const Set<String> _hlsExtensions = <String>{'.m3u8', '.m3u'};
const Set<String> _directFileExtensions = <String>{
  '.mp4',
  '.mkv',
  '.webm',
  '.mov',
  '.m4v',
  '.avi',
  '.flv',
  '.mp3',
  '.aac',
  '.m4a',
  '.ogg',
  '.oga',
  '.wav',
  '.flac',
};

bool _isPresentUrl(String? s) {
  final v = s?.trim();
  return v != null && v.isNotEmpty && v.toLowerCase() != 'null';
}

String _safeDecode(String value) {
  try {
    return Uri.decodeFull(value);
  } catch (_) {
    return value;
  }
}

bool _containsExtension(Iterable<String> values, Set<String> extensions) {
  for (final value in values) {
    final lowered = _safeDecode(value).toLowerCase();
    for (final ext in extensions) {
      final pattern = RegExp('${RegExp.escape(ext)}(?:\$|[/?#&])');
      if (pattern.hasMatch(lowered)) return true;
    }
  }
  return false;
}

/// Classifies URL shape to choose playback transport policy.
StreamUrlKind classifyStreamUrl(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return StreamUrlKind.unknown;

  final probes = <String>[raw];
  try {
    final uri = Uri.parse(raw);
    if (uri.path.isNotEmpty) probes.add(uri.path);
    if (uri.fragment.isNotEmpty) probes.add(uri.fragment);
    if (uri.query.isNotEmpty) probes.add(uri.query);
    for (final values in uri.queryParametersAll.values) {
      for (final v in values) {
        if (v.trim().isNotEmpty) probes.add(v);
      }
    }
  } catch (_) {
    // Keep raw probe only.
  }

  if (_containsExtension(probes, _hlsExtensions)) return StreamUrlKind.hls;
  if (_containsExtension(probes, _directFileExtensions)) {
    return StreamUrlKind.directFile;
  }
  return StreamUrlKind.unknown;
}

bool shouldStartWithProxy({
  required bool startWithProxy,
  required String url,
}) {
  if (!startWithProxy) return false;
  return classifyStreamUrl(url) == StreamUrlKind.hls;
}

bool shouldAllowProxyFallback({
  required bool startWithProxy,
  required String url,
}) {
  if (!startWithProxy) return false;
  return classifyStreamUrl(url) != StreamUrlKind.directFile;
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
