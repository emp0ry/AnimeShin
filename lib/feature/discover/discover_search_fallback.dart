class DiscoverSearchFallbackOutcome<T> {
  const DiscoverSearchFallbackOutcome({
    required this.result,
    required this.usedShikimoriCandidate,
    required this.chosenCandidate,
  });

  final T result;
  final bool usedShikimoriCandidate;
  final String? chosenCandidate;
}

Future<DiscoverSearchFallbackOutcome<T>> runDiscoverSearchFallback<T>({
  required int page,
  required String originalQuery,
  required T initialResult,
  required bool Function(T value) isEmpty,
  required Future<T> Function(String query) retry,
  required Iterable<String> localVariants,
  required Future<List<String>> Function(String query) shikimoriCandidates,
  int maxShikimoriCandidates = 5,
  void Function(String message)? debugLog,
}) async {
  final query = originalQuery.trim();
  if (page != 1 || query.isEmpty || !isEmpty(initialResult)) {
    return DiscoverSearchFallbackOutcome<T>(
      result: initialResult,
      usedShikimoriCandidate: false,
      chosenCandidate: null,
    );
  }

  debugLog?.call('fallback triggered for "$query"');

  var latest = initialResult;
  final seen = <String>{query.toLowerCase()};

  String? normalize(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final key = t.toLowerCase();
    if (!seen.add(key)) return null;
    return t;
  }

  for (final variant in localVariants) {
    final candidate = normalize(variant);
    if (candidate == null) continue;

    debugLog?.call('retry AniList with local candidate "$candidate"');
    latest = await retry(candidate);
    if (!isEmpty(latest)) {
      return DiscoverSearchFallbackOutcome<T>(
        result: latest,
        usedShikimoriCandidate: false,
        chosenCandidate: candidate,
      );
    }
  }

  final shiki = await shikimoriCandidates(query);
  for (final candidateRaw in shiki.take(maxShikimoriCandidates)) {
    final candidate = normalize(candidateRaw);
    if (candidate == null) continue;

    debugLog?.call('retry AniList with Shikimori candidate "$candidate"');
    latest = await retry(candidate);
    if (!isEmpty(latest)) {
      return DiscoverSearchFallbackOutcome<T>(
        result: latest,
        usedShikimoriCandidate: true,
        chosenCandidate: candidate,
      );
    }
  }

  return DiscoverSearchFallbackOutcome<T>(
    result: latest,
    usedShikimoriCandidate: false,
    chosenCandidate: null,
  );
}
