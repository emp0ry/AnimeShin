// Shikimori JSON payload models + result container (filename + bytes).

import 'dart:typed_data';

class ShikiAnimeItem {
  ShikiAnimeItem({
    required this.targetTitle,
    required this.targetTitleRu,
    required this.targetId,
    required this.score,      // 0..10 int
    required this.status,     // watching/completed/on_hold/dropped/planned/rewatching
    required this.rewatches,  // number of rewatches
    required this.episodes,   // watched episodes (progress)
    required this.text,       // user comments
  });

  final String targetTitle;
  final String? targetTitleRu;
  final int targetId;
  final int score;
  final String status;
  final int rewatches;
  final int episodes;
  final String? text;
}

class ShikiMangaItem {
  ShikiMangaItem({
    required this.targetTitle,
    required this.targetTitleRu,
    required this.targetId,
    required this.score,     // 0..10 int
    required this.status,    // reading/completed/on_hold/dropped/planned/rereading
    required this.rewatches, // number of rereads
    required this.volumes,   // read volumes (0 if unknown)
    required this.chapters,  // read chapters (progress)
    required this.text,      // user comments
  });

  final String targetTitle;
  final String? targetTitleRu;
  final int targetId;
  final int score;
  final String status;
  final int rewatches;
  final int volumes;
  final int chapters;
  final String? text;
}

class ShikiJsonPayload {
  ShikiJsonPayload({required this.filename, required this.bytes});
  final String filename;
  final Uint8List bytes;
}
