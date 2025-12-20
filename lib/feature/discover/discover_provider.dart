import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/extension/future_extension.dart';
import 'package:animeshin/feature/character/character_item_model.dart';
import 'package:animeshin/feature/discover/discover_filter_model.dart';
import 'package:animeshin/feature/staff/staff_item_model.dart';
import 'package:animeshin/feature/studio/studio_item_model.dart';
import 'package:animeshin/feature/user/user_item_model.dart';
import 'package:animeshin/feature/discover/discover_filter_provider.dart';
import 'package:animeshin/feature/discover/discover_model.dart';
import 'package:animeshin/feature/review/review_models.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/feature/viewer/repository_provider.dart';
import 'package:animeshin/util/graphql.dart';
import 'package:animeshin/util/text_utils.dart';

final discoverProvider = AsyncNotifierProvider<DiscoverNotifier, DiscoverItems>(
  DiscoverNotifier.new,
);

class DiscoverNotifier extends AsyncNotifier<DiscoverItems> {
  late DiscoverFilter filter;

  static bool _hasCyrillic(String s) => RegExp(r'[\u0400-\u04FF]').hasMatch(s);

  // Very small RU->LAT transliteration to help sources/APIs that only match latin.
  static String _ruToLat(String s) {
    const m = <String, String>{
      'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'yo',
      'ж': 'zh', 'з': 'z', 'и': 'i', 'й': 'y', 'к': 'k', 'л': 'l', 'м': 'm',
      'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u',
      'ф': 'f', 'х': 'kh', 'ц': 'ts', 'ч': 'ch', 'ш': 'sh', 'щ': 'shch',
      'ъ': '', 'ы': 'y', 'ь': '', 'э': 'e', 'ю': 'yu', 'я': 'ya',
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
      // Preserve basic casing.
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
      RegExp(r'\s*[:\-–—]?\s*(?:season\s*\d+|s\s*\d+)\s*$', caseSensitive: false),
      '',
    );
    t = t.replaceAll(
      RegExp(r'\s*[:\-–—]?\s*\d+(?:st|nd|rd|th)?\s*season\s*$', caseSensitive: false),
      '',
    );
    t = t.replaceAll(
      RegExp(r'\s*[:\-–—]?\s*(?:сезон\s*\d+|\d+\s*сезон)\s*$', caseSensitive: false),
      '',
    );
    return t.trim();
  }

  static double _bestTitleScore(String query, DiscoverMediaItem item) {
    final q = query.trim();
    if (q.isEmpty) return 0.0;
    var best = fuzzyMatchScore(q, item.name);
    if (item.titleEnglish != null) {
      best = best < (fuzzyMatchScore(q, item.titleEnglish!))
          ? fuzzyMatchScore(q, item.titleEnglish!)
          : best;
    }
    if (item.titleRomaji != null) {
      best = best < (fuzzyMatchScore(q, item.titleRomaji!))
          ? fuzzyMatchScore(q, item.titleRomaji!)
          : best;
    }
    if (item.titleNative != null) {
      best = best < (fuzzyMatchScore(q, item.titleNative!))
          ? fuzzyMatchScore(q, item.titleNative!)
          : best;
    }
    for (final s in item.synonyms) {
      final sc = fuzzyMatchScore(q, s);
      if (sc > best) best = sc;
    }
    return best;
  }

  @override
  FutureOr<DiscoverItems> build() {
    filter = ref.watch(discoverFilterProvider);
    return switch (filter.type) {
      DiscoverType.anime => _fetchAnime(const DiscoverAnimeItems()),
      DiscoverType.manga => _fetchManga(const DiscoverMangaItems()),
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
    final oldValue = state.valueOrNull;
    state = await AsyncValue.guard(() => switch (filter.type) {
          DiscoverType.anime => _fetchAnime(
              (oldValue is DiscoverAnimeItems)
                  ? oldValue
                  : const DiscoverAnimeItems(),
            ),
          DiscoverType.manga => _fetchManga(
              (oldValue is DiscoverMangaItems)
                  ? oldValue
                  : const DiscoverMangaItems(),
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

  Future<DiscoverItems> _fetchAnime(DiscoverAnimeItems oldValue) async {
    Future<Map<String, dynamic>> req(String? search) => ref.read(repositoryProvider).request(
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
    var data = await req(originalSearch.isEmpty ? null : originalSearch);

    final imageQuality = ref.read(persistenceProvider).options.imageQuality;

    final items = <DiscoverMediaItem>[];
    for (final m in data['Page']['media']) {
      items.add(DiscoverMediaItem(m, imageQuality));
    }

    // If AniList returns nothing for some scripts (often Cyrillic), retry on first page.
    if (items.isEmpty && oldValue.pages.next == 1 && originalSearch.isNotEmpty) {
      final variants = <String>[];
      void add(String v) {
        final t = v.trim();
        if (t.isEmpty) return;
        if (!variants.contains(t)) variants.add(t);
      }

      add(_stripSeasonSuffix(originalSearch));
      if (_hasCyrillic(originalSearch)) {
        add(_ruToLat(originalSearch));
        add(_ruToLat(_stripSeasonSuffix(originalSearch)));
      }

      for (final v in variants) {
        if (v == originalSearch) continue;
        data = await req(v);
        items
          ..clear()
          ..addAll([
            for (final m in data['Page']['media'])
              DiscoverMediaItem(m, imageQuality),
          ]);
        if (items.isNotEmpty) break;
      }
    }

    // Local multilingual ranking.
    if (originalSearch.isNotEmpty && items.isNotEmpty) {
      final ranked = [
        for (final it in items)
          it.copyWith(searchMatch: _bestTitleScore(originalSearch, it)),
      ]
        ..sort((a, b) => (b.searchMatch ?? 0).compareTo(a.searchMatch ?? 0));
      items
        ..clear()
        ..addAll(ranked);
    }

    return DiscoverAnimeItems(oldValue.pages.withNext(
      items,
      data['Page']['pageInfo']['hasNextPage'] ?? false,
    ));
  }

  Future<DiscoverItems> _fetchManga(DiscoverMangaItems oldValue) async {
    Future<Map<String, dynamic>> req(String? search) => ref.read(repositoryProvider).request(
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
    var data = await req(originalSearch.isEmpty ? null : originalSearch);

    final imageQuality = ref.read(persistenceProvider).options.imageQuality;

    final items = <DiscoverMediaItem>[];
    for (final m in data['Page']['media']) {
      items.add(DiscoverMediaItem(m, imageQuality));
    }

    if (items.isEmpty && oldValue.pages.next == 1 && originalSearch.isNotEmpty) {
      final variants = <String>[];
      void add(String v) {
        final t = v.trim();
        if (t.isEmpty) return;
        if (!variants.contains(t)) variants.add(t);
      }
      add(_stripSeasonSuffix(originalSearch));
      if (_hasCyrillic(originalSearch)) {
        add(_ruToLat(originalSearch));
        add(_ruToLat(_stripSeasonSuffix(originalSearch)));
      }
      for (final v in variants) {
        if (v == originalSearch) continue;
        data = await req(v);
        items
          ..clear()
          ..addAll([
            for (final m in data['Page']['media'])
              DiscoverMediaItem(m, imageQuality),
          ]);
        if (items.isNotEmpty) break;
      }
    }

    if (originalSearch.isNotEmpty && items.isNotEmpty) {
      final ranked = [
        for (final it in items)
          it.copyWith(searchMatch: _bestTitleScore(originalSearch, it)),
      ]
        ..sort((a, b) => (b.searchMatch ?? 0).compareTo(a.searchMatch ?? 0));
      items
        ..clear()
        ..addAll(ranked);
    }

    return DiscoverMangaItems(oldValue.pages.withNext(
      items,
      data['Page']['pageInfo']['hasNextPage'] ?? false,
    ));
  }

  Future<DiscoverItems> _fetchCharacters(
      DiscoverCharacterItems oldValue) async {
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
