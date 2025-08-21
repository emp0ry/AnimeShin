// A Riverpod wrapper for fetchFullCollectionForExport so UI can await it easily.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/export/export_collection_loader.dart';

/// Args tuple for provider
typedef ExportArgs = ({int userId, bool ofAnime, int listIndex, bool isShikimori});

final exportFullCollectionProvider =
    FutureProvider.family<FullCollection, ExportArgs>((ref, args) async {
  return fetchFullCollectionForExport(
    ref: ref,
    userId: args.userId,
    ofAnime: args.ofAnime,
    listIndex: args.listIndex,
    isShikimori: args.isShikimori
  );
});
