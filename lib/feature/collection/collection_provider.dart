import 'dart:async';

import 'package:animeshin/repository/anilibria/anilibria_repository.dart';
import 'package:animeshin/extension/iterable_extension.dart';
import 'package:animeshin/util/notification_system.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/extension/date_time_extension.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/home/home_provider.dart';
import 'package:animeshin/feature/media/media_models.dart';
import 'package:animeshin/feature/viewer/repository_provider.dart';
import 'package:animeshin/util/graphql.dart';

// Shikimori repositories (primary source for Russian titles)
import 'package:animeshin/repository/shikimori/shikimori_gql_repository.dart';
import 'package:animeshin/repository/shikimori/shikimori_rest_repository.dart';

final collectionProvider = AsyncNotifierProvider.autoDispose
    .family<CollectionNotifier, Collection, CollectionTag>(
  CollectionNotifier.new,
);

class CollectionNotifier
    extends AutoDisposeFamilyAsyncNotifier<Collection, CollectionTag> {
  var _sort = EntrySort.title;

  @override
  FutureOr<Collection> build(arg) async {
    final index = switch (state.valueOrNull) {
      FullCollection c => c.index,
      _ => 0,
    };

    final viewerId = ref.watch(viewerIdProvider);

    final isFull = arg.userId != viewerId ||
        ref.watch(homeProvider.select(
          (s) => arg.ofAnime
              ? s.didExpandAnimeCollection
              : s.didExpandMangaCollection,
        ));

    final data = await ref.read(repositoryProvider).request(
      GqlQuery.collection,
      {
        'userId': arg.userId,
        'type': arg.ofAnime ? 'ANIME' : 'MANGA',
        if (!isFull) 'status_in': ['CURRENT', 'REPEATING'],
      },
    );

    final options = ref.watch(persistenceProvider.select((s) => s.options));
    for (final l in data['MediaListCollection']['lists']) {
      for (final e in l['entries']) {
        e['ruTitleState'] = options.ruTitle;
        e['anilibriaEpDubState'] = options.anilibriaEpDub;
        e['anilibriaWatchState'] = options.anilibriaWatch;
      }
    }
    // ---------- STEP A: Fill Russian titles from Shikimori ----------
    // Strategy:
    // 1) If media has idMal -> batch GraphQL with ids string (limit=50) and map by myanimelistId.
    // 2) If no idMal -> fallback to REST search by romaji/english (limited concurrency).
    await _enrichRussianTitlesFromShikimori(
      data,
      ofAnime: arg.ofAnime,
    );

    // ---------- STEP B: Latest episode from Anilibria ONLY ----------
    // We do not change title.russian here; we only set media.anilibriaLastEpisode
    // from episodes.last.ordinal if available (anime only).
    if (arg.ofAnime) {
      await _enrichLatestEpisodeFromAnilibria(data);
    }

    final imageQuality = ref.read(persistenceProvider).options.imageQuality;

    final collection = isFull
        ? FullCollection(
            data['MediaListCollection'],
            arg.ofAnime,
            index,
            imageQuality,
          )
        : PreviewCollection(data['MediaListCollection'], imageQuality);
    collection.sort(_sort);

    if (options.scheduleNotification) {
      await NotificationSystem.scheduleNotificationsForAll(collection.list.entries);
    }
    else {
      await NotificationSystem.cancelAllScheduledNotifications();
    }

    return collection;
  }

  // --- Internal helpers ------------------------------------------------------

  /// Simple concurrency limiter (no Future.isCompleted required).
  Future<void> _forEachLimited<T>(
    Iterable<T> items, {
    required int maxConcurrent,
    required Future<void> Function(T) action,
  }) async {
    final inflight = <Future<void>>[];
    for (final item in items) {
      final f = action(item);
      inflight.add(f);
      f.whenComplete(() => inflight.remove(f));
      if (inflight.length >= maxConcurrent) {
        await Future.any(inflight);
      }
    }
    await Future.wait(inflight);
  }

  /// Primary: Shikimori → set title.russian.
  Future<void> _enrichRussianTitlesFromShikimori(
    Map<String, dynamic> data, {
    required bool ofAnime,
  }) async {
    final malToEntry = <int, Map<String, dynamic>>{};
    final entriesNeedingSearch = <Map<String, dynamic>>[];

    // Collect entries:
    // - skip if already have russian title
    // - split by presence of idMal (GQL batch) vs no idMal (REST fallback)
    for (final l in data['MediaListCollection']['lists']) {
      for (final e in l['entries']) {
        final titles = e['media']['title'] as Map<String, dynamic>;
        final hasRu = (titles['russian'] != null &&
            titles['russian'].toString().trim().isNotEmpty);
        if (hasRu) continue;

        final malId = e['media']['idMal'];
        if (malId is int && malId > 0) {
          malToEntry[malId] = e;
        } else {
          entriesNeedingSearch.add(e);
        }
      }
    }

    // 1) Batch by malId via Shikimori GQL (limit=50)
    if (malToEntry.isNotEmpty) {
      final shikiGql = ShikimoriGqlRepository();
      final malIds = malToEntry.keys.toList();
      final byMal = await shikiGql.fetchByMalIdsBatch(
        malIds,
        ofAnime: ofAnime,
        chunkSize: 50, // Shikimori GQL max is 50 per your note
      );

      byMal.forEach((mal, obj) {
        // Prefer 'russian', fallback to 'name'
        final ru = (obj['russian'] ?? obj['name'])?.toString();
        String? url = obj['url']?.toString();

        if (url != null && url.isNotEmpty && !url.startsWith('http')) {
          // Ensure absolute URL if API returned a relative path
          url = 'https://shikimori.one$url';
        }

        if (ru != null && ru.trim().isNotEmpty) {
          final entry = malToEntry[mal]!;
          entry['media']['title']['russian'] = ru;
          if (url != null && url.isNotEmpty) {
            entry['media']['shikimoriUrl'] = url;
          }
        }
      });
    }

    // 2) REST fallback for items without malId
    if (entriesNeedingSearch.isNotEmpty) {
      final shikiRest = ShikimoriRestRepository();

      await _forEachLimited<Map<String, dynamic>>(
        entriesNeedingSearch,
        maxConcurrent: 6, // keep it modest to avoid rate limits
        action: (e) async {
          final titles = e['media']['title'] as Map<String, dynamic>;
          final romaji = (titles['romaji'] ?? '').toString();
          final english = (titles['english'] ?? '').toString();

          // Try romaji first, then english
          final first = await shikiRest.searchRussianAndUrl(
            romaji,
            ofAnime: ofAnime,
          );
          final result = (first.ru != null && first.ru!.trim().isNotEmpty)
              ? first
              : await shikiRest.searchRussianAndUrl(
                  english,
                  ofAnime: ofAnime,
                );

          if (result.ru != null && result.ru!.trim().isNotEmpty) {
            e['media']['title']['russian'] = result.ru;
            if (result.url != null && result.url!.isNotEmpty) {
              e['media']['shikimoriUrl'] = result.url;
            }
          }
        },
      );
    }
  }

  /// Secondary: Anilibria → set media.anilibriaLastEpisode using episodes.last.ordinal.
  /// Russian titles are NOT touched here.
  ///
  /// Now we build alias candidates from:
  ///  - AniList romaji (kebab-case)
  ///  - Fallback: slug derived from e.media.shikimoriUrl
  Future<void> _enrichLatestEpisodeFromAnilibria(
    Map<String, dynamic> data,
  ) async {
    final anilibriaRepo = AnilibriaRepository();

    // Collect unique aliases to batch-request; also remember which entry each alias belongs to
    final aliases = <String>{};
    final entriesByAlias = <String, Map<String, dynamic>>{};

    for (final l in data['MediaListCollection']['lists']) {
      for (final e in l['entries']) {
        final media = e['media'] as Map<String, dynamic>;
        final titleMap = (media['title'] as Map<String, dynamic>?) ?? const {};

        // 1) romaji -> kebab-case
        final romaji = (titleMap['romaji'] ?? '').toString().trim();
        if (romaji.isNotEmpty) {
          final alias = toKebabCase(romaji);
          if (alias.isNotEmpty) {
            aliases.add(alias);
            // keep first mapping (alias collisions are rare but possible)
            entriesByAlias.putIfAbsent(alias, () => e);
          }
        }

        // 2) fallback from shikimoriUrl slug
        final shikiUrl = (media['shikimoriUrl'] ?? '').toString().trim();
        if (shikiUrl.isNotEmpty) {
          final slug = slugFromShikiUrl(shikiUrl);
          if (slug.isNotEmpty) {
            aliases.add(slug);
            entriesByAlias.putIfAbsent(slug, () => e);
          }
        }
      }
    }

    if (aliases.isEmpty) return;

    // Fetch all aliases in batches (repo already splits by limit internally)
    final anilibriaData = await anilibriaRepo.fetchListByAliases(
      aliases: aliases.toList(),
      include: const ['episodes', 'alias'],
      exclude: const [
        // keep payload small
        'name',
        'episodes.id',
        'episodes.name',
        'episodes.opening',
        'episodes.ending',
        'episodes.preview',
        'episodes.hls_480',
        'episodes.hls_720',
        'episodes.hls_1080',
        'episodes.duration',
        'episodes.rutube_id',
        'episodes.youtube_id',
        'episodes.updated_at',
        'episodes.sort_order',
        'episodes.release_id',
        'episodes.name_english',
      ],
    );

    // Index Anilibria results by alias
    final dataList = (anilibriaData['data'] as List<dynamic>?) ?? const [];
    final anilibriaByAlias = <String, dynamic>{};
    for (final item in dataList) {
      if (item is Map && item['alias'] is String) {
        anilibriaByAlias[item['alias'] as String] = item;
      }
    }

    // For each entry, try romaji-alias first, then slug alias, set last episode ordinal if found
    for (final l in data['MediaListCollection']['lists']) {
      for (final e in l['entries']) {
        final media = e['media'] as Map<String, dynamic>;
        final titleMap = (media['title'] as Map<String, dynamic>?) ?? const {};

        final romaji = (titleMap['romaji'] ?? '').toString().trim();
        final romajiAlias = romaji.isNotEmpty ? toKebabCase(romaji) : '';

        final shikiUrl = (media['shikimoriUrl'] ?? '').toString().trim();
        final slugAlias = shikiUrl.isNotEmpty ? slugFromShikiUrl(shikiUrl) : '';

        // Try candidates in order
        for (final alias in <String>[romajiAlias, slugAlias]) {
          if (alias.isEmpty) continue;
          final aniItem = anilibriaByAlias[alias];
          if (aniItem == null) continue;

          if (aniItem['alias'].toString().isNotEmpty) {
            media['anilibriaAlias'] = aniItem['alias'];
          }

          final episodes = aniItem['episodes'] as List<dynamic>?;
          if (episodes != null && episodes.isNotEmpty) {
            final ordinal = (episodes.last is Map)
                ? (episodes.last['ordinal'] as num?)?.toInt()
                : null;
            if (ordinal != null) {
              media['anilibriaLastEpisode'] = ordinal;
              break; // stop after first successful alias
            }
          }
        }
      }
    }
  }

  void ensureSorted(EntrySort sort, EntrySort previewSort) {
    _updateState((collection) {
      final selectedSort = switch (collection) {
        FullCollection _ => sort,
        PreviewCollection _ => previewSort,
      };

      if (_sort == selectedSort) return;
      _sort = selectedSort;

      collection.sort(selectedSort);
      return null;
    });
  }

  void changeIndex(int newIndex) => _updateState(
        (collection) => switch (collection) {
          FullCollection _ => collection.withIndex(newIndex),
          PreviewCollection _ => collection,
        },
      );

  void removeEntry(int mediaId) {
    _updateState(
      (collection) => switch (collection) {
        PreviewCollection c => c..list.removeByMediaId(mediaId),
        FullCollection c => _withRemovedEmptyLists(
            c..lists.forEach((list) => list.removeByMediaId(mediaId)),
          ),
      },
    );
  }

  /// There is an api bug in entry updating,
  /// which prevents tag data from being returned.
  /// This is why [saveEntry] additionally fetches the updated entry.
  Future<void> saveEntry(int mediaId, ListStatus? oldStatus) async {
    try {
      var data = await ref.read(repositoryProvider).request(
        GqlQuery.listEntry,
        {'userId': arg.userId, 'mediaId': mediaId},
      );
      data = data['MediaList'];

      Entry? oldEntry;
      final collection = state.valueOrNull;
      if (collection is FullCollection) {
        for (final list in collection.lists) {
          oldEntry = list.entries.firstWhereOrNull((e) => e.mediaId == mediaId);
          if (oldEntry != null) break;
        }
      } else if (collection is PreviewCollection) {
        oldEntry = collection.list.entries.firstWhereOrNull((e) => e.mediaId == mediaId);
      }

      final entry = Entry(
        data,
        ref.read(persistenceProvider).options.imageQuality,
      );

      final options = ref.watch(persistenceProvider.select((s) => s.options));
      // These fields are UI switches, we must re-apply them manually here
      entry.ruTitleState = options.ruTitle;
      entry.anilibriaEpDubState = options.anilibriaEpDub;
      entry.anilibriaWatchState = options.anilibriaWatch;

      if (oldEntry != null) {
        entry.shikimoriUrl = oldEntry.shikimoriUrl;
        entry.lastAniLibriaEpisode = oldEntry.lastAniLibriaEpisode;
        entry.anilibriaAlias = oldEntry.anilibriaAlias;
        entry.titles
          ..clear()
          ..addAll(oldEntry.titles);
      }

      if (options.scheduleNotification) {
        await NotificationSystem.scheduleNotificationForEntry(entry);
      }
      else {
        await NotificationSystem.cancelAllScheduledNotifications();
      }

      _updateState(
        (collection) => switch (collection) {
          FullCollection _ => _saveEntryInFullCollection(
              collection,
              entry,
              oldStatus,
              data,
            ),
          PreviewCollection _ => _saveEntryInPreviewCollection(
              collection,
              entry,
              oldStatus,
              entry.listStatus,
            ),
        },
      );
    } catch (_) {}
  }

  /// An alternative to [saveEntry],
  /// that only updates the progress and potentially, the list status.
  /// When incrementing to last episode, [saveEntry] should be called instead.
  Future<String?> saveEntryProgress(
    Entry oldEntry,
    bool setAsCurrent,
  ) async {
    try {
      await ref.read(repositoryProvider).request(
        GqlMutation.updateProgress,
        {
          'mediaId': oldEntry.mediaId,
          'progress': oldEntry.progress,
          if (setAsCurrent) ...{
            'status': ListStatus.current.value,
            if (oldEntry.watchStart == null)
              'startedAt': DateTime.now().fuzzyDate,
          },
        },
      );

      await saveEntry(oldEntry.mediaId, oldEntry.listStatus);

      return null;
    } catch (e) {
      return e.toString();
    }
  }

  FullCollection _saveEntryInFullCollection(
    FullCollection collection,
    Entry entry,
    ListStatus? oldStatus,
    Map<String, dynamic> data,
  ) {
    final hiddenFromStatusLists = data['hiddenFromStatusLists'] ?? false;
    final customListItems = data['customLists'] ?? const <String, dynamic>{};
    final customLists = customListItems.entries
        .where((e) => e.value == true)
        .map((e) => e.key.toLowerCase())
        .toList();

    for (final list in collection.lists) {
      if (list.status != null) {
        if (list.status == oldStatus) {
          if (list.status == entry.listStatus) {
            if (hiddenFromStatusLists) {
              list.removeByMediaId(entry.mediaId);
              continue;
            }

            if (!list.setByMediaId(entry)) {
              list.insertSorted(entry, _sort);
            }

            continue;
          }

          list.removeByMediaId(entry.mediaId);
          continue;
        }

        if (list.status == entry.listStatus) {
          list.insertSorted(entry, _sort);
        }

        continue;
      }

      if (customLists.contains(list.name.toLowerCase())) {
        if (!list.setByMediaId(entry)) {
          list.insertSorted(entry, _sort);
        }

        continue;
      }

      list.removeByMediaId(entry.mediaId);
    }

    return _withRemovedEmptyLists(collection);
  }

  PreviewCollection _saveEntryInPreviewCollection(
    PreviewCollection collection,
    Entry entry,
    ListStatus? oldStatus,
    ListStatus? newStatus,
  ) {
    if (newStatus == ListStatus.current || newStatus == ListStatus.repeating) {
      if (oldStatus == ListStatus.current ||
          oldStatus == ListStatus.repeating) {
        collection.list.setByMediaId(entry);
        return collection;
      }

      collection.list.insertSorted(entry, _sort);
      return collection;
    }

    collection.list.removeByMediaId(entry.mediaId);
    return collection;
  }

  FullCollection _withRemovedEmptyLists(FullCollection collection) {
    final lists = collection.lists;
    int index = collection.index;

    for (int i = 0; i < lists.length; i++) {
      if (lists[i].entries.isEmpty) {
        if (i <= index && index != 0) index--;
        lists.removeAt(i--);
      }
    }

    return collection.withIndex(index);
  }

  void _updateState(Collection? Function(Collection) mutator) {
    if (!state.hasValue) return;
    final result = mutator(state.value!);
    if (result != null) state = AsyncValue.data(result);
  }
}
