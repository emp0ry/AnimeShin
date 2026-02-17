typedef DiscoverRuTitleInfo = ({String? russian, String? shikimoriRomaji});

class DiscoverTitleEnrichmentController {
  final Map<int, DiscoverRuTitleInfo> _cache = <int, DiscoverRuTitleInfo>{};
  int _epoch = 0;

  int beginEpoch() => ++_epoch;

  bool isCurrent(int epoch) => epoch == _epoch;

  Future<Map<int, DiscoverRuTitleInfo>> resolve(
    Iterable<int> malIds, {
    required Future<Map<int, DiscoverRuTitleInfo>> Function(List<int> missing)
        fetchMissing,
  }) async {
    final deduped = <int>{...malIds.where((id) => id > 0)};
    if (deduped.isEmpty) return const <int, DiscoverRuTitleInfo>{};

    final resolved = <int, DiscoverRuTitleInfo>{};
    final missing = <int>[];

    for (final malId in deduped) {
      final cached = _cache[malId];
      if (cached != null) {
        resolved[malId] = cached;
      } else {
        missing.add(malId);
      }
    }

    if (missing.isNotEmpty) {
      final fetched = await fetchMissing(missing);
      for (final malId in missing) {
        final entry = fetched[malId] ??
            (russian: null, shikimoriRomaji: null);
        _cache[malId] = entry;
        resolved[malId] = entry;
      }
    }

    return resolved;
  }
}
