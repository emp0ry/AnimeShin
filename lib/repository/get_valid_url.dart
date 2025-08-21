import 'dart:io';

/// Picks the first reachable API base URL in the given order.
/// "Reachable" means: TCP + HTTP exchange succeed (any status code).
/// You can optionally probe a specific path and/or validate the response.
///
/// Example:
///   final base = await pickApiBaseUrl(
///     ['https://api1.example.com', 'https://api2.example.com', 'https://api3.example.com'],
///     probePath: '/health',
///     timeout: const Duration(seconds: 2),
///   );
Future<String?> pickApiBaseUrl(
  List<String> bases, {
  String? probePath,
  Duration timeout = const Duration(seconds: 3),
  bool useGet = false,
  Future<bool> Function(HttpClientResponse resp)? validator,
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..badCertificateCallback = (cert, host, port) {
      // If you use self-signed certs in dev, allowlist here (or keep false for prod).
      return false;
    };

  try {
    for (final base in bases) {
      final ok = await _isReachable(
        client,
        base,
        probePath: probePath,
        timeout: timeout,
        useGet: useGet,
        validator: validator,
      );
      if (ok) return base;
    }
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<bool> _isReachable(
  HttpClient client,
  String base, {
  String? probePath,
  required Duration timeout,
  bool useGet = false,
  Future<bool> Function(HttpClientResponse resp)? validator,
}) async {
  try {
    // Build target URI (base + optional probe path)
    final baseUri = Uri.parse(base);
    final uri = (probePath == null || probePath.isEmpty)
        ? baseUri
        : baseUri.replace(
            path: _joinPath(baseUri.path, probePath),
          );

    // HEAD is cheaper; GET if your server doesn’t handle HEAD well or you need body
    final req = useGet ? await client.getUrl(uri) : await client.headUrl(uri);
    final resp = await req.close().timeout(timeout);

    // If a custom validator is provided, use it (e.g., check header/body)
    if (validator != null) {
      return await validator(resp);
    }

    // Any HTTP response means the host is up (including 3xx/4xx/5xx)
    return true;
  } catch (_) {
    // DNS, connect timeout, TLS failure, etc. → not reachable
    return false;
  }
}

String _joinPath(String a, String b) {
  if (a.endsWith('/')) a = a.substring(0, a.length - 1);
  if (!b.startsWith('/')) b = '/$b';
  return '$a$b';
}

/// Returns the first base whose probe responds with a "good" status code.
/// - Good = in [minOk..maxOk] OR explicitly listed in [okStatuses].
/// - If server rejects HEAD with 405, optionally retries with GET when
///   [fallbackGetOn405] is true.
Future<String?> pickApiBaseUrlGoodStatus(
  List<String> bases, {
  String? probePath,
  Duration timeout = const Duration(seconds: 3),
  bool useGet = false,
  bool fallbackGetOn405 = true,
  int minOk = 200,
  int maxOk = 299,
  Set<int>? okStatuses,
}) async {
  bool isGood(int code) {
    if (okStatuses != null && okStatuses.isNotEmpty) {
      return okStatuses.contains(code);
    }
    return code >= minOk && code <= maxOk;
  }

  final client = HttpClient()
    ..connectionTimeout = timeout
    ..badCertificateCallback = (cert, host, port) => false; // keep strict in prod

  try {
    for (final base in bases) {
      final ok = await _probeWithStatus(
        client,
        base,
        probePath: probePath,
        timeout: timeout,
        useGet: useGet,
        isGood: isGood,
        fallbackGetOn405: fallbackGetOn405,
      );
      if (ok) return base;
    }
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Internal probe that checks status code quality and optionally retries GET on 405.
Future<bool> _probeWithStatus(
  HttpClient client,
  String base, {
  String? probePath,
  required Duration timeout,
  required bool Function(int status) isGood,
  bool useGet = false,
  bool fallbackGetOn405 = true,
}) async {
  try {
    final baseUri = Uri.parse(base);
    final uri = (probePath == null || probePath.isEmpty)
        ? baseUri
        : baseUri.replace(path: _joinPath(baseUri.path, probePath));

    // First attempt: HEAD (or GET if explicitly requested)
    final firstReq = useGet ? await client.getUrl(uri) : await client.headUrl(uri);
    final firstResp = await firstReq.close().timeout(timeout);

    // If HEAD not allowed and we want to fallback, retry with GET once.
    if (!useGet && fallbackGetOn405 && firstResp.statusCode == HttpStatus.methodNotAllowed) {
      final getReq = await client.getUrl(uri);
      final getResp = await getReq.close().timeout(timeout);
      return isGood(getResp.statusCode);
    }

    return isGood(firstResp.statusCode);
  } catch (_) {
    return false;
  }
}