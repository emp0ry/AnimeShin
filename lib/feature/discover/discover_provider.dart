import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/extension/future_extension.dart';
import 'package:animeshin/feature/character/character_item_model.dart';
import 'package:animeshin/feature/discover/discover_enrichment_controller.dart';
import 'package:animeshin/feature/discover/discover_filter_model.dart';
import 'package:animeshin/feature/discover/discover_filter_provider.dart';
import 'package:animeshin/feature/discover/discover_model.dart';
import 'package:animeshin/feature/discover/discover_search_fallback.dart';
import 'package:animeshin/feature/review/review_models.dart';
import 'package:animeshin/feature/staff/staff_item_model.dart';
import 'package:animeshin/feature/studio/studio_item_model.dart';
import 'package:animeshin/feature/user/user_item_model.dart';
import 'package:animeshin/feature/viewer/persistence_model.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/feature/viewer/repository_provider.dart';
import 'package:animeshin/repository/shikimori/shikimori_gql_repository.dart';
import 'package:animeshin/repository/shikimori/shikimori_rest_repository.dart';
import 'package:animeshin/util/graphql.dart';
import 'package:animeshin/util/paged.dart';
import 'package:animeshin/util/text_utils.dart';

final discoverProvider = AsyncNotifierProvider<DiscoverNotifier, DiscoverItems>(
  DiscoverNotifier.new,
);

class DiscoverNotifier extends AsyncNotifier<DiscoverItems> {
  late DiscoverFilter filter;

  final _enrichmentController = DiscoverTitleEnrichmentController();

  static bool _hasCyrillic(String s) => RegExp(r'[\u0400-\u04FF]').hasMatch(s);

  // Very small RU->LAT transliteration to help sources/APIs that only match latin.
  static String _ruToLat(String s) {
    const m = <String, String>{
      'а': 'a',
      'б': 'b',
      'в': 'v',
      'г': 'g',
      'д': 'd',
      'е': 'e',
      'ё': 'yo',
      'ж': 'zh',
      'з': 'z',
      'и': 'i',
      'й': 'y',
      'к': 'k',
      'л': 'l',
      'м': 'm',
      'н': 'n',
      'о': 'o',
      'п': 'p',
      'р': 'r',
      'с': 's',
      'т': 't',
      'у': 'u',
      'ф': 'f',
      'х': 'kh',
      'ц': 'ts',
      'ч': 'ch',
      'ш': 'sh',
      'щ': 'shch',
      'ъ': '',
      'ы': 'y',
      'ь': '',
      'э': 'e',
      'ю': 'yu',
      'я': 'ya',
    };

    final sb = StringBuffer();
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      final lower = ch.toLowerCase();
      final repl = m[lower];
      if (repl == null) {
        sb.write(ch);
        continue;
      }
      if (ch != lower && repl.isNotEmpty) {
        sb.write(repl[0].toUpperCase());
        sb.write(repl.substring(1));
      } else {
        sb.write(repl);
      }
    }
    return sb.toString();
  }

  static String _stripSeasonSuffix(String s) {
    var t = s.trim();
    t = t.replaceAll(
      RegExp(
        r'\s*[:\-–—]?\s*(?:season\s*\d+|s\s*\d+)\s*$',
        caseSensitive: false,
      ),
      '',
    );
    t = t.replaceAll(
      RegExp(
        r'\s*[:\-–—]?\s*\d+(?:st|nd|rd|th)?\s*season\s*$',
        caseSensitive: false,
      ),
      '',
    );
    t = t.replaceAll(
      RegExp(
        r'\s*[:\-–—]?\s*(?:сезон\s*\d+|\d+\s*сезон)\s*$',
        caseSensitive: false,
      ),
      '',
    );
    return t.trim();
  }

  static double _bestTitleScore(String query, DiscoverMediaItem item) {
    final q = query.trim();
    if (q.isEmpty) return 0.0;

    var best = fuzzyMatchScore(q, item.name);

    void apply(String? value) {
      if (value == null || value.trim().isEmpty) return;
      final score = fuzzyMatchScore(q, value);
      if (score > best) best = score;
    }

    apply(item.titleEnglish);
    apply(item.titleRomaji);
    apply(item.titleNative);
    apply(item.titleRussian);
    apply(item.titleShikimoriRomaji);

    for (final s in item.synonyms) {
      final sc = fuzzyMatchScore(q, s);
      if (sc > best) best = sc;
    }
    return best;
  }

  @override
  FutureOr<DiscoverItems> build() {
    filter = ref.watch(discoverFilterProvider);
    ref.listen<bool>(
      persistenceProvider.select((s) => s.options.ruTitle),
      (previous, next) {
        if (previous == next) return;

        final epoch = _enrichmentController.beginEpoch();
        if (!next) return;

        final current = state.asData?.value;
        if (current is DiscoverAnimeItems) {
          _scheduleTitleEnrichment(
            ofAnime: true,
            items: current.pages.items,
            requestEpoch: epoch,
          );
          return;
        }
        if (current is DiscoverMangaItems) {
          _scheduleTitleEnrichment(
            ofAnime: false,
            items: current.pages.items,
            requestEpoch: epoch,
          );
        }
      },
    );

    final requestEpoch = _enrichmentController.beginEpoch();

    return switch (filter.type) {
      DiscoverType.anime => _fetchAnime(
          const DiscoverAnimeItems(),
          requestEpoch: requestEpoch,
        ),
      DiscoverType.manga => _fetchManga(
          const DiscoverMangaItems(),
          requestEpoch: requestEpoch,
        ),
      DiscoverType.character =>
        _fetchCharacters(const DiscoverCharacterItems()),
      DiscoverType.staff => _fetchStaff(const DiscoverStaffItems()),
      DiscoverType.studio => _fetchStudios(const DiscoverStudioItems()),
      DiscoverType.user => _fetchUsers(const DiscoverUserItems()),
      DiscoverType.review => _fetchReviews(const DiscoverReviewItems()),
      DiscoverType.recommendation =>
        _fetchRecommendations(const DiscoverRecommendationItems()),
    };
  }

  Future<void> fetch() async {
    final oldValue = state.asData?.value;
    final requestEpoch = _enrichmentController.beginEpoch();

    state = await AsyncValue.guard(() => switch (filter.type) {
          DiscoverType.anime => _fetchAnime(
              (oldValue is DiscoverAnimeItems)
                  ? oldValue
                  : const DiscoverAnimeItems(),
              requestEpoch: requestEpoch,
            ),
          DiscoverType.manga => _fetchManga(
              (oldValue is DiscoverMangaItems)
                  ? oldValue
                  : const DiscoverMangaItems(),
              requestEpoch: requestEpoch,
            ),
          DiscoverType.character => _fetchCharacters(
              (oldValue is DiscoverCharacterItems)
                  ? oldValue
                  : const DiscoverCharacterItems(),
            ),
          DiscoverType.staff => _fetchStaff(
              (oldValue is DiscoverStaffItems)
                  ? oldValue
                  : const DiscoverStaffItems(),
            ),
          DiscoverType.studio => _fetchStudios(
              (oldValue is DiscoverStudioItems)
                  ? oldValue
                  : const DiscoverStudioItems(),
            ),
          DiscoverType.user => _fetchUsers(
              (oldValue is DiscoverUserItems)
                  ? oldValue
                  : const DiscoverUserItems(),
            ),
          DiscoverType.review => _fetchReviews(
              (oldValue is DiscoverReviewItems)
                  ? oldValue
                  : const DiscoverReviewItems(),
            ),
          DiscoverType.recommendation => _fetchRecommendations(
              (oldValue is DiscoverRecommendationItems)
                  ? oldValue
                  : const DiscoverRecommendationItems(),
            ),
        });
  }

  Future<DiscoverItems> _fetchAnime(
    DiscoverAnimeItems oldValue, {
    required int requestEpoch,
  }) async {
    Future<Map<String, dynamic>> req(String? search) => ref
        .read(repositoryProvider)
        .request(
          GqlQuery.mediaPage,
          {
            'page': oldValue.pages.next,
            'type': 'ANIME',
            if (search != null && search.trim().isNotEmpty) ...{
              'search': search,
              ...filter.mediaFilter.toGraphQlVariables(ofAnime: true)
                ..['sort'] = 'SEARCH_MATCH',
            } else
              ...filter.mediaFilter.toGraphQlVariables(ofAnime: true),
          },
        );

    final originalSearch = filter.search.trim();
    final imageQuality = ref.read(persistenceProvider).options.imageQuality;

    var data = await req(originalSearch.isEmpty ? null : originalSearch);
    final fallback = await _runSearchFallback(
      page: oldValue.pages.next,
      originalSearch: originalSearch,
      initialData: data,
      imageQuality: imageQuality,
      ofAnime: true,
      request: req,
    );
    data = fallback.result;

    if (fallback.chosenCandidate != null) {
      final source =
          fallback.usedShikimoriCandidate ? 'shikimori' : 'local-variant';
      _debugFallbackLog('resolved using $source "${fallback.chosenCandidate}"');
    }

    final items = _readMediaItems(data, imageQuality);
    if (originalSearch.isNotEmpty && items.isNotEmpty) {
      final ranked = [
        for (final it in items)
          it.copyWith(searchMatch: _bestTitleScore(originalSearch, it)),
      ]..sort((a, b) => (b.searchMatch ?? 0).compareTo(a.searchMatch ?? 0));
      items
        ..clear()
        ..addAll(ranked);
    }

    final result = DiscoverAnimeItems(
      oldValue.pages.withNext(
        items,
        data['Page']?['pageInfo']?['hasNextPage'] ?? false,
      ),
    );
    _scheduleTitleEnrichment(
      ofAnime: true,
      items: result.pages.items,
      requestEpoch: requestEpoch,
    );

    return result;
  }

  Future<DiscoverItems> _fetchManga(
    DiscoverMangaItems oldValue, {
    required int requestEpoch,
  }) async {
    Future<Map<String, dynamic>> req(String? search) => ref
        .read(repositoryProvider)
        .request(
          GqlQuery.mediaPage,
          {
            'page': oldValue.pages.next,
            'type': 'MANGA',
            if (search != null && search.trim().isNotEmpty) ...{
              'search': search,
              ...filter.mediaFilter.toGraphQlVariables(ofAnime: false)
                ..['sort'] = 'SEARCH_MATCH',
            } else
              ...filter.mediaFilter.toGraphQlVariables(ofAnime: false),
          },
        );

    final originalSearch = filter.search.trim();
    final imageQuality = ref.read(persistenceProvider).options.imageQuality;

    var data = await req(originalSearch.isEmpty ? null : originalSearch);
    final fallback = await _runSearchFallback(
      page: oldValue.pages.next,
      originalSearch: originalSearch,
      initialData: data,
      imageQuality: imageQuality,
      ofAnime: false,
      request: req,
    );
    data = fallback.result;

    if (fallback.chosenCandidate != null) {
      final source =
          fallback.usedShikimoriCandidate ? 'shikimori' : 'local-variant';
      _debugFallbackLog('resolved using $source "${fallback.chosenCandidate}"');
    }

    final items = _readMediaItems(data, imageQuality);
    if (originalSearch.isNotEmpty && items.isNotEmpty) {
      final ranked = [
        for (final it in items)
          it.copyWith(searchMatch: _bestTitleScore(originalSearch, it)),
      ]..sort((a, b) => (b.searchMatch ?? 0).compareTo(a.searchMatch ?? 0));
      items
        ..clear()
        ..addAll(ranked);
    }

    final result = DiscoverMangaItems(
      oldValue.pages.withNext(
        items,
        data['Page']?['pageInfo']?['hasNextPage'] ?? false,
      ),
    );
    _scheduleTitleEnrichment(
      ofAnime: false,
      items: result.pages.items,
      requestEpoch: requestEpoch,
    );

    return result;
  }

  Future<DiscoverSearchFallbackOutcome<Map<String, dynamic>>> _runSearchFallback({
    required int page,
    required String originalSearch,
    required Map<String, dynamic> initialData,
    required ImageQuality imageQuality,
    required bool ofAnime,
    required Future<Map<String, dynamic>> Function(String query) request,
  }) {
    return runDiscoverSearchFallback<Map<String, dynamic>>(
      page: page,
      originalQuery: originalSearch,
      initialResult: initialData,
      isEmpty: (value) => _readMediaItems(value, imageQuality).isEmpty,
      retry: request,
      localVariants: _buildLocalSearchVariants(originalSearch),
      shikimoriCandidates: (query) async {
        final repo = ShikimoriRestRepository();
        try {
          return repo.searchTitleCandidates(
            query,
            ofAnime: ofAnime,
            limit: 5,
          );
        } finally {
          repo.dispose();
        }
      },
      maxShikimoriCandidates: 5,
      debugLog: _debugFallbackLog,
    );
  }

  List<String> _buildLocalSearchVariants(String originalSearch) {
    final variants = <String>[];

    void add(String v) {
      final t = v.trim();
      if (t.isEmpty || variants.contains(t)) return;
      variants.add(t);
    }

    add(_stripSeasonSuffix(originalSearch));
    if (_hasCyrillic(originalSearch)) {
      add(_ruToLat(originalSearch));
      add(_ruToLat(_stripSeasonSuffix(originalSearch)));
    }

    return variants;
  }

  List<DiscoverMediaItem> _readMediaItems(
    Map<String, dynamic> data,
    ImageQuality imageQuality,
  ) {
    final mediaList = data['Page']?['media'];
    if (mediaList is! List) return <DiscoverMediaItem>[];

    return [
      for (final media in mediaList)
        if (media is Map<String, dynamic>) DiscoverMediaItem(media, imageQuality),
    ];
  }

  void _debugFallbackLog(String message) {
    if (!kDebugMode) return;
    debugPrint('[DiscoverFallback] $message');
  }

  void _scheduleTitleEnrichment({
    required bool ofAnime,
    required List<DiscoverMediaItem> items,
    required int requestEpoch,
  }) {
    final showRu = ref.read(persistenceProvider).options.ruTitle;
    if (!showRu) return;

    final malIds = <int>{
      for (final item in items)
        if (item.malId != null &&
            item.malId! > 0 &&
            _isMissingRuData(item))
          item.malId!,
    };
    if (malIds.isEmpty) return;

    unawaited(
      _enrichTitlesInBackground(
        malIds: malIds.toList(),
        ofAnime: ofAnime,
        requestEpoch: requestEpoch,
      ),
    );
  }

  bool _isMissingRuData(DiscoverMediaItem item) {
    final ru = _normalizeTitle(item.titleRussian);
    final shiki = _normalizeTitle(item.titleShikimoriRomaji);
    return ru == null && shiki == null;
  }

  Future<void> _enrichTitlesInBackground({
    required List<int> malIds,
    required bool ofAnime,
    required int requestEpoch,
  }) async {
    await Future<void>.delayed(Duration.zero);
    if (!_enrichmentController.isCurrent(requestEpoch)) return;

    final resolved = await _enrichmentController.resolve(
      malIds,
      fetchMissing: (missing) async {
        final repo = ShikimoriGqlRepository();
        try {
          final fetched = await repo.fetchByMalIdsBatch(
            missing,
            ofAnime: ofAnime,
          );
          return {
            for (final malId in missing)
              malId: (
                russian: _normalizeTitle(fetched[malId]?['russian']),
                shikimoriRomaji: _normalizeTitle(fetched[malId]?['name']),
              ),
          };
        } finally {
          repo.dispose();
        }
      },
    );
    if (!_enrichmentController.isCurrent(requestEpoch)) return;

    _patchCurrentMediaTitles(
      ofAnime: ofAnime,
      resolvedByMalId: resolved,
    );
  }

  void _patchCurrentMediaTitles({
    required bool ofAnime,
    required Map<int, DiscoverRuTitleInfo> resolvedByMalId,
  }) {
    final current = state.asData?.value;
    if (current == null || resolvedByMalId.isEmpty) return;

    if (ofAnime && current is DiscoverAnimeItems) {
      final patched = _applyResolvedTitles(
        current.pages.items,
        resolvedByMalId,
      );
      if (!patched.didChange) return;

      state = AsyncValue.data(
        DiscoverAnimeItems(
          Paged<DiscoverMediaItem>(
            items: patched.items,
            hasNext: current.pages.hasNext,
            next: current.pages.next,
          ),
        ),
      );
      return;
    }

    if (!ofAnime && current is DiscoverMangaItems) {
      final patched = _applyResolvedTitles(
        current.pages.items,
        resolvedByMalId,
      );
      if (!patched.didChange) return;

      state = AsyncValue.data(
        DiscoverMangaItems(
          Paged<DiscoverMediaItem>(
            items: patched.items,
            hasNext: current.pages.hasNext,
            next: current.pages.next,
          ),
        ),
      );
    }
  }

  ({List<DiscoverMediaItem> items, bool didChange}) _applyResolvedTitles(
    List<DiscoverMediaItem> items,
    Map<int, DiscoverRuTitleInfo> resolvedByMalId,
  ) {
    var didChange = false;
    final patched = <DiscoverMediaItem>[];

    for (final item in items) {
      final malId = item.malId;
      final resolved = malId == null ? null : resolvedByMalId[malId];
      if (resolved == null) {
        patched.add(item);
        continue;
      }

      final nextRussian =
          _normalizeTitle(resolved.russian) ?? item.titleRussian;
      final nextShikimori =
          _normalizeTitle(resolved.shikimoriRomaji) ??
              item.titleShikimoriRomaji;

      if (nextRussian == item.titleRussian &&
          nextShikimori == item.titleShikimoriRomaji) {
        patched.add(item);
        continue;
      }

      didChange = true;
      patched.add(
        item.copyWith(
          titleRussian: (nextRussian,),
          titleShikimoriRomaji: (nextShikimori,),
        ),
      );
    }

    return (items: patched, didChange: didChange);
  }

  String? _normalizeTitle(dynamic value) {
    final t = value?.toString().trim();
    if (t == null || t.isEmpty) return null;
    return t;
  }

  Future<DiscoverItems> _fetchCharacters(
    DiscoverCharacterItems oldValue,
  ) async {
    final data = await ref.read(repositoryProvider).request(
      GqlQuery.characterPage,
      {
        'page': oldValue.pages.next,
        if (filter.search.isNotEmpty) 'search': filter.search,
        if (filter.hasBirthday) 'isBirthday': true,
      },
    );

    final items = <CharacterItem>[];
    for (final c in data['Page']['characters']) {
      items.add(CharacterItem(c));
    }

    return DiscoverCharacterItems(oldValue.pages.withNext(
      items,
      data['Page']['pageInfo']['hasNextPage'] ?? false,
    ));
  }

  Future<DiscoverItems> _fetchStaff(DiscoverStaffItems oldValue) async {
    final data = await ref.read(repositoryProvider).request(
      GqlQuery.staffPage,
      {
        'page': oldValue.pages.next,
        if (filter.search.isNotEmpty) 'search': filter.search,
        if (filter.hasBirthday) 'isBirthday': true,
      },
    );

    final items = <StaffItem>[];
    for (final s in data['Page']['staff']) {
      items.add(StaffItem(s));
    }

    return DiscoverStaffItems(oldValue.pages.withNext(
      items,
      data['Page']['pageInfo']['hasNextPage'] ?? false,
    ));
  }

  Future<DiscoverItems> _fetchStudios(DiscoverStudioItems oldValue) async {
    final data = await ref.read(repositoryProvider).request(
      GqlQuery.studioPage,
      {
        'page': oldValue.pages.next,
        if (filter.search.isNotEmpty) 'search': filter.search,
      },
    );

    final items = <StudioItem>[];
    for (final s in data['Page']['studios']) {
      items.add(StudioItem(s));
    }

    return DiscoverStudioItems(oldValue.pages.withNext(
      items,
      data['Page']['pageInfo']['hasNextPage'] ?? false,
    ));
  }

  Future<DiscoverItems> _fetchUsers(DiscoverUserItems oldValue) async {
    final data = await ref.read(repositoryProvider).request(
      GqlQuery.userPage,
      {
        'page': oldValue.pages.next,
        if (filter.search.isNotEmpty) 'search': filter.search,
      },
    );

    final items = <UserItem>[];
    for (final u in data['Page']['users']) {
      items.add(UserItem(u));
    }

    return DiscoverUserItems(oldValue.pages.withNext(
      items,
      data['Page']['pageInfo']['hasNextPage'] ?? false,
    ));
  }

  Future<DiscoverItems> _fetchReviews(DiscoverReviewItems oldValue) async {
    final data = await ref.read(repositoryProvider).request(
      GqlQuery.reviewPage,
      {
        'page': oldValue.pages.next,
        'sort': filter.reviewsFilter.sort.value,
        if (filter.reviewsFilter.mediaType != null)
          'mediaType': filter.reviewsFilter.mediaType!.value,
      },
    );

    final items = <ReviewItem>[];
    for (final r in data['Page']['reviews']) {
      items.add(ReviewItem(r));
    }

    return DiscoverReviewItems(oldValue.pages.withNext(
      items,
      data['Page']['pageInfo']['hasNextPage'] ?? false,
    ));
  }

  Future<DiscoverItems> _fetchRecommendations(
    DiscoverRecommendationItems oldValue,
  ) async {
    final data = await ref.read(repositoryProvider).request(
      GqlQuery.recommendationsPage,
      {
        'page': oldValue.pages.next,
        'sort': filter.recommendationsFilter.sort.value,
        if (filter.recommendationsFilter.inLists != null)
          'onList': filter.recommendationsFilter.inLists,
      },
    );

    final imageQuality = ref.read(persistenceProvider).options.imageQuality;

    final items = <DiscoverRecommendationItem>[];
    for (final r in data['Page']['recommendations']) {
      items.add(DiscoverRecommendationItem(r, imageQuality));
    }

    return DiscoverRecommendationItems(oldValue.pages.withNext(
      items,
      data['Page']['pageInfo']['hasNextPage'] ?? false,
    ));
  }

  Future<Object?> rateRecommendation(
    int mediaId,
    int recommendedMediaId,
    bool? rating,
  ) {
    return ref.read(repositoryProvider).request(
      GqlMutation.rateRecommendation,
      {
        'id': mediaId,
        'recommendedId': recommendedMediaId,
        'rating': rating == null
            ? 'NO_RATING'
            : rating
                ? 'RATE_UP'
                : 'RATE_DOWN',
      },
    ).getErrorOrNull();
  }
}
