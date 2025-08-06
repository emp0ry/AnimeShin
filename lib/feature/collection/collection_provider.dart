import 'dart:async';

import 'package:animeshin/anilibria/anilibria_repository.dart';
import 'package:animeshin/extension/iterable_extension.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/extension/date_time_extension.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/home/home_provider.dart';
import 'package:animeshin/feature/media/media_models.dart';
import 'package:animeshin/feature/viewer/repository_provider.dart';
import 'package:animeshin/util/graphql.dart';
import 'package:animeshin/util/background_handler.dart';

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

    String toKebabCase(String input) => input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');

    final anilibriaRepo = AnilibriaRepository();

    final List<String> aliases = [];
    final Map<String, Map<String, dynamic>> entriesByAlias = {};
    for (final l in data['MediaListCollection']['lists']) {
      for (final e in l['entries']) {
        final alias = toKebabCase(e['media']['title']['romaji']);
        aliases.add(alias);
        entriesByAlias[alias] = e;
      }
    }

    final anilibriaData = await anilibriaRepo.fetchListByAliases(
      aliases: aliases,
      include: ['name', 'episodes', 'alias'],
      exclude: [
        'name.english',
        'name.alternative',
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
        'episodes.name_english'
      ],
    );

    // final result = await anilibriaRepo.searchAliasByEnglishTitle(englishTitle: data['MediaListCollection']['lists'][0]['entries'][10]['media']['title']['english'], include: ['name', 'alias']);
    // print('english ${data['MediaListCollection']['lists'][0]['entries'][10]['media']['title']['english']} result: $result');

    final dataList = anilibriaData['data'] as List<dynamic>;
    final Map<String, dynamic> anilibriaByAlias = {};
    for (final item in dataList) {
      if (item['alias'] != null) {
        anilibriaByAlias[item['alias']] = item;
      }
    }

    for (final l in data['MediaListCollection']['lists']) {
      for (final e in l['entries']) {
        // if (e['media']['title']['english'] == "Dr. STONE New World") {
        //   // print('Rascal Does Not Dream of Santa Claus found');
        //   // final result = await anilibriaRepo.searchAliasByEnglishTitle(englishTitle: e['media']['title']['romaji'], include: ['name', 'alias']);
        //   // print('Rascal Does Not Dream of Santa Claus result: $result');
        //   print(e['media']['title']);
        // }
        final entryAlias = toKebabCase(e['media']['title']['romaji']);
        final aniItem = anilibriaByAlias[entryAlias];
        if (aniItem != null) {
          final ruTitle = aniItem['name']?['main'];
          final episodes = aniItem['episodes'] as List<dynamic>?;
          if (ruTitle != null) e['media']['title']['russian'] = ruTitle;
          if (episodes != null && episodes.isNotEmpty) {
            e['media']['anilibriaLastEpisode'] = episodes.last['ordinal'];
          }
        }
      }
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

    return collection;
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

      if (oldEntry != null) {
        entry.ruTitle = oldEntry.ruTitle;
        entry.ruLastEpisode = oldEntry.ruLastEpisode;
      }

      try {
        if ((entry.listStatus == ListStatus.current || entry.listStatus == ListStatus.planning) &&
            entry.airingAt != null &&
            entry.nextEpisode != null) {
          await BackgroundHandler.scheduleEpisodeNotification(
            entry.airingAt!,
            entry.titles[0],
            entry.nextEpisode!,
            entry.imageUrl,
          );
        } else {
          await BackgroundHandler.cancelEpisodeNotification(entry.titles[0], entry.nextEpisode ?? 1);
        }
      } catch (_) {}

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
