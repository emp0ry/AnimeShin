// Loads a FULL AniList collection strictly for export (no UI previews).
// Uses your existing Repository/GQL and constructs a FullCollection.
// Sorting is delegated to AniList: ADDED_TIME_DESC (i.e., "Last Added" first).

import 'package:animeshin/feature/viewer/persistence_model.dart';
import 'package:animeshin/repository/shikimori/shikimori_gql_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/feature/viewer/repository_provider.dart';
import 'package:animeshin/util/graphql.dart'; // for GqlQuery.collection

/// Fetch FullCollection for export (anime or manga depending on [ofAnime]).
/// - No 'status_in' filter; we want ALL lists/entries.
/// - Server-side sort: ADDED_TIME_DESC to match AniList "Last Added".
Future<FullCollection> fetchFullCollectionForExport({
  required Ref ref,
  required int userId,
  required bool ofAnime,
  required bool isShikimori,
  int listIndex = 0,
}) async {
  // Reuse repository and image quality from the app
  final repo = ref.read(repositoryProvider);
  final ImageQuality imageQuality =
      ref.read(persistenceProvider).options.imageQuality;

  // IMPORTANT:
  // - Do NOT pass 'status_in' → we need the full collection (no preview cut).
  // - Pass 'sort': ['ADDED_TIME_DESC'] → server returns "Last Added" first.
  final data = await repo.request(
    GqlQuery.collection,
    {
      'userId': userId,
      'type': ofAnime ? 'ANIME' : 'MANGA',
      'sort': ['ADDED_TIME_DESC'],
    },
  );

  if (isShikimori) {
    await addShikimoriToCollection(data, ofAnime);
  }

  // Build FullCollection from raw AniList response
  final full = FullCollection(
    data['MediaListCollection'],
    ofAnime,
    listIndex,
    imageQuality,
  );

  debugPrintByStatus(full, isShikimori);

  // Do NOT resort client-side; keep server order (Last Added)
  return full;
}

Future<void> addShikimoriToCollection(Map<String, dynamic> data, bool ofAnime) async {
  final malToEntry = <int, Map<String, dynamic>>{};
  final entriesNeedingSearch = <Map<String, dynamic>>[];

  // Collect entries:
  for (final l in data['MediaListCollection']['lists']) {
    for (final e in l['entries']) {
      final titles = e['media']['title'] as Map<String, dynamic>;
      final hasRu = (titles['russian'] != null &&
          titles['russian'].toString().trim().isNotEmpty);
      final hasShikiRomaji = (titles['shikimoriRomaji'] != null &&
        titles['shikimoriRomaji'].toString().trim().isNotEmpty);
      if (hasRu) continue;
      if (hasShikiRomaji) continue;

      final malId = e['media']['idMal'];
      if (malId is int && malId > 0) {
        malToEntry[malId] = e;
      } else {
        debugPrint('entriesNeedingSearch: ${e['media']['title']}');
        entriesNeedingSearch.add(e);
      }
    }
  }

  // Batch by malId via Shikimori GQL (limit=50)
  if (malToEntry.isNotEmpty) {
    final shikiGql = ShikimoriGqlRepository();
    final malIds = malToEntry.keys.toList();
    final byMal = await shikiGql.fetchByMalIdsBatch(
      malIds,
      ofAnime: ofAnime,
      chunkSize: 50, // Shikimori GQL max is 50 per your note
    );

    byMal.forEach((mal, obj) {
      final russian = obj['russian']?.toString();
      final name = obj['name']?.toString();

      final entry = malToEntry[mal]!;

      if (russian != null && russian.trim().isNotEmpty) {
        entry['media']['title']['russian'] = russian;
      }
      if (name != null && name.trim().isNotEmpty) {
        entry['media']['title']['shikimoriRomaji'] = name;
      }
    });
  }
}

// Debug: group across ALL lists if it's a FullCollection
void debugPrintByStatus(Collection collection, bool isShikimori) {
  // collect entries from all lists
  final Iterable<Entry> allEntries = switch (collection) {
    FullCollection c => c.lists.expand((l) => l.entries),
    PreviewCollection c => c.list.entries, // на всякий
  };

  // group by enum name: current, repeating, completed, paused, planning, dropped
  final groups = <String, List<Entry>>{};
  for (final e in allEntries) {
    final key = e.listStatus?.name ?? 'unknown';
    groups.putIfAbsent(key, () => []).add(e);
  }

  void printGroup(String key, String label) {
    final list = groups[key] ?? const <Entry>[];
    debugPrint('\n=== $label (${list.length}) ===');
    for (final e in list.reversed) {
      if (isShikimori) {
        debugPrint(' ${e.titleRussian}');
      } else {
        debugPrint(' ${e.titles.first}');
      }
    }
  }

  printGroup('current',   'Watching');
  printGroup('repeating', 'Rewatching');
  printGroup('completed', 'Completed');
  printGroup('paused',    'Paused');
  printGroup('dropped',   'Dropped');
  printGroup('planning',  'Planned');
}