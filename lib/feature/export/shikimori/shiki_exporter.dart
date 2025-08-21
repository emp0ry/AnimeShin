// Exporter: builds pretty JSON + filename for Shikimori anime/manga lists.

import 'dart:convert';
import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:animeshin/feature/export/shikimori/shiki_models.dart';

enum ShikiListType { anime, manga }

class ShikiExporter {
  static ShikiJsonPayload build({
    required ShikiListType type,
    required List<ShikiAnimeItem> animes,
    required List<ShikiMangaItem> mangas,
    DateTime? now,
  }) {
    final dt = now ?? DateTime.now();
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(dt);

    late Uint8List bytes;
    late String filename;

    if (type == ShikiListType.anime) {
      final list = animes.map((e) => {
        'target_title': e.targetTitle,
        'target_title_ru': e.targetTitleRu,
        'target_id': e.targetId,
        'target_type': 'Anime',
        'score': e.score,
        'status': e.status,        // watching/completed/on_hold/dropped/planned/rewatching
        'rewatches': e.rewatches,
        'episodes': e.episodes,
        'text': e.text,
      }).toList();

      final jsonStr = const JsonEncoder.withIndent('  ').convert(list);
      bytes = Uint8List.fromList(utf8.encode(jsonStr));
      filename = 'shikimori_animes_$stamp.json';
    } else {
      final list = mangas.map((e) => {
        'target_title': e.targetTitle,
        'target_title_ru': e.targetTitleRu,
        'target_id': e.targetId,
        'target_type': 'Manga',
        'score': e.score,
        'status': e.status,        // reading/completed/on_hold/dropped/planned/rereading
        'rewatches': e.rewatches,
        'volumes': e.volumes,
        'chapters': e.chapters,
        'text': e.text,
      }).toList();

      final jsonStr = const JsonEncoder.withIndent('  ').convert(list);
      bytes = Uint8List.fromList(utf8.encode(jsonStr));
      filename = 'shikimori_mangas_$stamp.json';
    }

    return ShikiJsonPayload(filename: filename, bytes: bytes);
    }
}
