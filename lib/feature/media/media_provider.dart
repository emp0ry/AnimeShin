import 'dart:async';

import 'package:animeshin/repository/anilibria/anilibria_repository.dart';
import 'package:animeshin/repository/shikimori/shikimori_rest_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/extension/future_extension.dart';
import 'package:animeshin/extension/iterable_extension.dart';
import 'package:animeshin/extension/string_extension.dart';
import 'package:animeshin/feature/edit/edit_model.dart';
import 'package:animeshin/feature/forum/forum_model.dart';
import 'package:animeshin/feature/media/media_models.dart';
import 'package:animeshin/feature/settings/settings_provider.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/feature/viewer/repository_provider.dart';
import 'package:animeshin/util/graphql.dart';
import 'package:animeshin/util/paged.dart';

final mediaProvider =
    AsyncNotifierProvider.autoDispose.family<MediaNotifier, Media, int>(
  MediaNotifier.new,
);

final mediaConnectionsProvider = AsyncNotifierProvider.autoDispose
    .family<MediaRelationsNotifier, MediaConnections, int>(
  MediaRelationsNotifier.new,
);

final mediaThreadsProvider =
    AsyncNotifierProvider.family<MediaThreadsNotifier, Paged<ThreadItem>, int>(
  MediaThreadsNotifier.new,
);

final mediaFollowingProvider = AsyncNotifierProvider.family<
    MediaFollowingNotifier, Paged<MediaFollowing>, int>(
  MediaFollowingNotifier.new,
);

class MediaNotifier extends AutoDisposeFamilyAsyncNotifier<Media, int> {
  @override
  FutureOr<Media> build(int arg) async {
    var data = await ref
        .read(repositoryProvider)
        .request(GqlQuery.media, {'id': arg, 'withInfo': true});
    data = data['Media'];

    final imageQuality = ref.read(persistenceProvider).options.imageQuality;

    // AniList returns 'ANIME' or 'MANGA'
    final ofAnime = data['type'] == 'ANIME';

    // Try to enrich data with Shikimori russian title + absolute url
    final idMal = data['idMal'];
    if (idMal != null && idMal is int) {
    try {
      final shikiRepo = ShikimoriRestRepository();

      // Fetch Shikimori item by MAL id
      final shikiData = await shikiRepo.fetchByMalId(idMal, ofAnime: ofAnime);
      if (shikiData != null) {
        // 1) Fill russian title when available
        final ru = shikiData['russian']?.toString().trim();
        if (ru != null && ru.isNotEmpty) {
          (data['title'] as Map<String, dynamic>)['russian'] = ru;
        }

        // 2) Normalize URL to absolute (API returns /animes/... or /mangas/...)
        final u = shikiData['url']?.toString().trim();
        if (u != null && u.isNotEmpty) {
          data['shikimoriUrl'] = u.startsWith('http') ? u : 'https://shikimori.one$u';

          // 3) If ANIME: try to find matching Anilibria release by alias
          if (ofAnime) {
            final anilibriaRepo = AnilibriaRepository();

            // Collect candidate aliases in order of confidence (use a Set to avoid duplicates)
            final aliases = <String>{};

            // Prefer AniList romaji -> kebab-case
            final titles = data['title'] as Map<String, dynamic>?;
            final romaji = (titles?['romaji'] ?? '').toString().trim();
            if (romaji.isNotEmpty) {
              aliases.add(toKebabCase(romaji));
            }

            // Fallback: slug derived from Shikimori URL
            final slug = slugFromShikiUrl(u);
            if (slug.isNotEmpty) {
              aliases.add(slug);
            }

            // Try aliases one by one until we find a matching Anilibria release
            for (final alias in aliases) {
              if (alias.isEmpty) continue;

              final ani = await anilibriaRepo.fetchByAlias(
                alias: alias,
                include: const ['alias', 'episodes.ordinal'],
              );

              // If Anilibria returns an alias, consider it a match
              final aniAlias = (ani?['alias'] as String?)?.trim();
              if (aniAlias != null && aniAlias.isNotEmpty) {
                data['anilibriaUrl'] = 'https://anilibria.top/anime/releases/release/$alias';

                final eps = ani?['episodes'];
                if (eps is List && eps.isNotEmpty) {
                  final last = eps.last;
                  if (last is Map && last['ordinal'] is int) {
                    data['anilibriaLastEpisode'] = last['ordinal'];
                  }
                }

                break; // stop after first successful match
              }
            }
          }
        }
      }
    } catch (_) {}
    }

    // Existing AniList mapping
    final relatedMedia = <RelatedMedia>[];
    for (final relation in data['relations']['edges']) {
      if (relation['node'] != null) {
        relatedMedia.add(RelatedMedia(relation, imageQuality));
      }
    }

    final settings = await ref.watch(
      settingsProvider.selectAsync((settings) => settings),
    );

    return Media(
      EntryEdit(data, settings, false),
      MediaInfo(data, imageQuality),
      MediaStats(data),
      relatedMedia,
    );
  }

  Future<Object?> toggleFavorite() {
    final value = state.valueOrNull;
    if (value == null) return Future.value('User not yet loaded');

    final typeKey = value.info.isAnime ? 'anime' : 'manga';
    return ref.read(repositoryProvider).request(
      GqlMutation.toggleFavorite,
      {typeKey: arg},
    ).getErrorOrNull();
  }
}

class MediaRelationsNotifier
    extends AutoDisposeFamilyAsyncNotifier<MediaConnections, int> {
  @override
  FutureOr<MediaConnections> build(arg) =>
      _fetch(const MediaConnections(), null);

  Future<void> fetch(MediaTab tab) async {
    final oldState = state.valueOrNull ?? const MediaConnections();
    state = switch (tab) {
      MediaTab.info ||
      MediaTab.relations ||
      MediaTab.threads ||
      MediaTab.following ||
      MediaTab.statistics =>
        state,
      MediaTab.characters => oldState.characters.hasNext
          ? await AsyncValue.guard(() => _fetch(oldState, tab))
          : state,
      MediaTab.staff => oldState.staff.hasNext
          ? await AsyncValue.guard(() => _fetch(oldState, tab))
          : state,
      MediaTab.reviews => oldState.reviews.hasNext
          ? await AsyncValue.guard(() => _fetch(oldState, tab))
          : state,
      MediaTab.recommendations => oldState.recommendations.hasNext
          ? await AsyncValue.guard(() => _fetch(oldState, tab))
          : state,
    };
  }

  Future<MediaConnections> _fetch(
      MediaConnections oldState, MediaTab? tab) async {
    final variables = <String, dynamic>{'id': arg};
    if (tab == null) {
      variables['withRecommendations'] = true;
      variables['withCharacters'] = true;
      variables['withStaff'] = true;
      variables['withReviews'] = true;
    } else if (tab == MediaTab.recommendations) {
      variables['withRecommendations'] = true;
      variables['page'] = oldState.recommendations.next;
    } else if (tab == MediaTab.characters) {
      variables['withCharacters'] = true;
      variables['page'] = oldState.characters.next;
    } else if (tab == MediaTab.staff) {
      variables['withStaff'] = true;
      variables['page'] = oldState.staff.next;
    } else if (tab == MediaTab.reviews) {
      variables['withReviews'] = true;
      variables['page'] = oldState.reviews.next;
    }

    var data = await ref.read(repositoryProvider).request(
          GqlQuery.media,
          variables,
        );
    data = data['Media'];

    final imageQuality = ref.read(persistenceProvider).options.imageQuality;

    var characters = oldState.characters;
    var staff = oldState.staff;
    var reviews = oldState.reviews;
    var recommendations = oldState.recommendations;
    var languageToVoiceActors = [...oldState.languageToVoiceActors];
    var selectedLanguage = oldState.selectedLanguage;

    if (tab == null || tab == MediaTab.characters) {
      final map = data['characters'];
      final items = <MediaRelatedItem>[];
      for (final c in map['edges']) {
        final role = StringExtension.tryNoScreamingSnakeCase(c['role']);
        items.add(MediaRelatedItem(c['node'], role));

        if (c['voiceActors'] == null) continue;

        for (final va in c['voiceActors']) {
          final l = StringExtension.tryNoScreamingSnakeCase(va['languageV2']);
          if (l == null) continue;

          var languageMapping = languageToVoiceActors.firstWhereOrNull(
            (lm) => lm.language == l,
          );

          if (languageMapping == null) {
            languageMapping = (language: l, voiceActors: {});
            languageToVoiceActors.add(languageMapping);
          }

          final characterVoiceActors = languageMapping.voiceActors.putIfAbsent(
            items.last.id,
            () => [],
          );

          characterVoiceActors.add(MediaRelatedItem(va, l));
        }
      }

      languageToVoiceActors.sort((a, b) {
        if (a.language == 'Japanese') return -1;
        if (b.language == 'Japanese') return 1;
        return a.language.compareTo(b.language);
      });

      characters = characters.withNext(
        items,
        map['pageInfo']['hasNextPage'] ?? false,
      );
    }

    if (tab == null || tab == MediaTab.staff) {
      final map = data['staff'];
      final items = <MediaRelatedItem>[];
      for (final s in map['edges']) {
        items.add(MediaRelatedItem(s['node'], s['role']));
      }

      staff = staff.withNext(items, map['pageInfo']['hasNextPage'] ?? false);
    }

    if (tab == null || tab == MediaTab.reviews) {
      final map = data['reviews'];
      final items = <RelatedReview>[];
      for (final r in map['nodes']) {
        final item = RelatedReview.maybe(r);
        if (item != null) items.add(item);
      }

      reviews = reviews.withNext(
        items,
        map['pageInfo']['hasNextPage'] ?? false,
      );
    }

    if (tab == null || tab == MediaTab.recommendations) {
      final map = data['recommendations'];
      final items = <Recommendation>[];
      for (final r in map['nodes']) {
        if (r['mediaRecommendation'] != null) {
          items.add(Recommendation(r, imageQuality));
        }
      }

      recommendations = recommendations.withNext(
        items,
        map['pageInfo']['hasNextPage'] ?? false,
      );
    }

    return oldState.copyWith(
      recommendations: recommendations,
      characters: characters,
      staff: staff,
      reviews: reviews,
      languageToVoiceActors: languageToVoiceActors,
      selectedLanguage: selectedLanguage,
    );
  }

  void changeLanguage(int selectedLanguage) => state.whenData(
        (data) {
          if (selectedLanguage >= data.languageToVoiceActors.length) return;

          state = AsyncValue.data(MediaConnections(
            recommendations: data.recommendations,
            characters: data.characters,
            staff: data.staff,
            reviews: data.reviews,
            languageToVoiceActors: data.languageToVoiceActors,
            selectedLanguage: selectedLanguage,
          ));
        },
      );

  Future<Object?> rateRecommendation(int recId, bool? rating) {
    return ref.read(repositoryProvider).request(
      GqlMutation.rateRecommendation,
      {
        'id': arg,
        'recommendedId': recId,
        'rating': rating == null
            ? 'NO_RATING'
            : rating
                ? 'RATE_UP'
                : 'RATE_DOWN',
      },
    ).getErrorOrNull();
  }
}

class MediaThreadsNotifier extends FamilyAsyncNotifier<Paged<ThreadItem>, int> {
  @override
  FutureOr<Paged<ThreadItem>> build(arg) => _fetch(const Paged());

  Future<void> fetch() async {
    final oldState = state.valueOrNull ?? const Paged();
    if (!oldState.hasNext) return;
    state = await AsyncValue.guard(() => _fetch(oldState));
  }

  Future<Paged<ThreadItem>> _fetch(Paged<ThreadItem> oldState) async {
    final data = await ref.read(repositoryProvider).request(
      GqlQuery.threadPage,
      {'mediaId': arg, 'page': oldState.next, 'sort': 'ID_DESC'},
    );

    final items = <ThreadItem>[];
    for (final t in data['Page']['threads']) {
      items.add(ThreadItem(t));
    }

    return oldState.withNext(
      items,
      data['Page']['pageInfo']['hasNextPage'] ?? false,
    );
  }
}

class MediaFollowingNotifier
    extends FamilyAsyncNotifier<Paged<MediaFollowing>, int> {
  @override
  FutureOr<Paged<MediaFollowing>> build(arg) => _fetch(const Paged());

  Future<void> fetch() async {
    final oldState = state.valueOrNull ?? const Paged();
    if (!oldState.hasNext) return;
    state = await AsyncValue.guard(() => _fetch(oldState));
  }

  Future<Paged<MediaFollowing>> _fetch(Paged<MediaFollowing> oldState) async {
    final data = await ref.read(repositoryProvider).request(
      GqlQuery.mediaFollowing,
      {'mediaId': arg, 'page': oldState.next},
    );

    final items = <MediaFollowing>[];
    for (final f in data['Page']['mediaList']) {
      items.add(MediaFollowing(f));
    }

    return oldState.withNext(
      items,
      data['Page']['pageInfo']['hasNextPage'] ?? false,
    );
  }
}
