import 'dart:async';
import 'package:flutter/foundation.dart';

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
import 'package:animeshin/repository/aniliberty/aniliberty_repository.dart';

// Shikimori repositories (primary source for Russian titles)
import 'package:animeshin/repository/shikimori/shikimori_gql_repository.dart';
import 'package:animeshin/repository/shikimori/shikimori_rest_repository.dart';

final collectionProvider = AsyncNotifierProvider.autoDispose
    .family<CollectionNotifier, Collection, CollectionTag>(
  (arg) => CollectionNotifier(arg),
);

class CollectionNotifier extends AsyncNotifier<Collection> {
  CollectionNotifier(this.arg);

  final CollectionTag arg;

  var _sort = EntrySort.title;

  @override
  FutureOr<Collection> build() async {
    final index = switch (state.asData?.value) {
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

    // Light AniLiberty enrichment: fill alias/id/last episode for dub indicator.
    // Only run when the indicator is enabled to avoid unnecessary requests.
    if (options.anilibriaEpDub) {
      await _enrichAniLibertyMeta(data);
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
      final collection = state.asData?.value;
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
        entry.anilibriaId = oldEntry.anilibriaId;
        entry.titles
          ..clear()
          ..addAll(oldEntry.titles);

        entry.titleEnglish = oldEntry.titleEnglish;
        entry.titleRomaji = oldEntry.titleRomaji;
        entry.titleNative = oldEntry.titleNative;
        entry.titleRussian = oldEntry.titleRussian;
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

  /// Optional AniLiberty enrichment to restore dub indicator data.
  Future<void> _enrichAniLibertyMeta(Map<String, dynamic> data) async {
    String? canonicalAlias(dynamic raw, Map<String, dynamic> media) {
      final s = raw?.toString().trim();
      if (s != null && s.isNotEmpty) return toKebabCase(s);

      // Fallback: derive from romaji/english if explicit alias is absent.
      final romaji = media['title']?['romaji']?.toString();
      if (romaji != null && romaji.trim().isNotEmpty) {
        final c = toKebabCase(romaji);
        if (c.isNotEmpty) return c;
      }

      final english = media['title']?['english']?.toString();
      if (english != null && english.trim().isNotEmpty) {
        final c = toKebabCase(english);
        if (c.isNotEmpty) return c;
      }

      return null;
    }

    // Collect entries that declare an AniLiberty alias (or derived fallback).
    final aliasToEntry = <String, Map<String, dynamic>>{};
    for (final l in data['MediaListCollection']['lists']) {
      for (final e in l['entries']) {
        final media = (e['media'] as Map<String, dynamic>);
        final aliasDyn = media['anilibriaAlias'] ?? e['anilibriaAlias'];
        final alias = canonicalAlias(aliasDyn, media);
        if (alias != null && alias.isNotEmpty) {
          aliasToEntry[alias] = e;
        }
      }
    }

    if (aliasToEntry.isEmpty) {
      debugPrint('[AniLiberty] No aliases found for dub indicator');
      return;
    }

    final repo = AnilibertyRepository();

    Map<String, dynamic>? pickFirstMapValue(Map<dynamic, dynamic>? obj, List<String> keys) {
      if (obj == null) return null;
      for (final k in keys) {
        final v = obj[k];
        if (v != null) return {k: v};
      }
      return null;
    }

    int? parseInt(dynamic v) {
      if (v is int) return v;
      if (v is String) {
        return int.tryParse(v);
      }
      return null;
    }

    int? maxOrdinalFromEpisodes(dynamic episodes) {
      if (episodes is! List) return null;
      int max = 0;
      for (final e in episodes) {
        if (e is Map) {
          final ord = parseInt(e['ordinal']);
          if (ord != null && ord > max) max = ord;
        }
      }
      return max > 0 ? max : null;
    }

    try {
      debugPrint('[AniLiberty] Enriching ${aliasToEntry.length} entries');
      // Batch fetch by aliases; tolerate failures quietly.
      final res = await repo.fetchListByAliases(aliases: aliasToEntry.keys.toList());
      final items = res['data'];
      if (items is! List) return;

      for (final item in items) {
        if (item is! Map) continue;

        // Normalize alias lookup; API may expose 'alias' or 'code'.
        final alias = canonicalAlias(item['alias'] ?? item['code'], item as Map<String, dynamic>);
        if (alias == null || alias.isEmpty) continue;

        final entry = aliasToEntry[alias];
        if (entry == null) continue;

        // Extract AniLiberty id and last episode with forgiving key set.
        final int? alId = parseInt(
          pickFirstMapValue(item, const ['id', 'anilibria_id', 'aniliberty_id'])?.values.first,
        );

        int? lastEp = parseInt(
          pickFirstMapValue(item, const [
            'lastEpisode',
            'last_episode',
            'last_ep',
            'episodes',
            'episodesTotal',
            'episodes_total',
          ])?.values.first,
        );

        lastEp ??= maxOrdinalFromEpisodes(item['episodes']);

        if (alId != null) {
          entry['media']['anilibriaId'] = alId;
        }
        if (lastEp != null) {
          entry['media']['anilibriaLastEpisode'] = lastEp;
        }
        debugPrint(
          '[AniLiberty] alias=$alias id=${alId ?? 0} lastEp=${lastEp ?? 0}',
        );
      }
    } catch (_) {
      // Swallow enrichment errors; keep core collection load unaffected.
      debugPrint('[AniLiberty] Enrichment failed');
    }
  }
}