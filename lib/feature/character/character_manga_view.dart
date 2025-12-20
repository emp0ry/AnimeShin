import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:animeshin/feature/character/character_model.dart';
import 'package:animeshin/util/routes.dart';
import 'package:animeshin/widget/grid/mono_relation_grid.dart';
import 'package:animeshin/widget/paged_view.dart';
import 'package:animeshin/feature/character/character_provider.dart';

class CharacterMangaSubview extends StatelessWidget {
  const CharacterMangaSubview({required this.id, required this.scrollCtrl});

  final int id;
  final ScrollController scrollCtrl;

  @override
  Widget build(BuildContext context) {
    return PagedView<CharacterRelatedItem>(
      scrollCtrl: scrollCtrl,
      onRefresh: (invalidate) => invalidate(characterMediaProvider(id)),
      provider: characterMediaProvider(id).select(
        (s) => s.unwrapPrevious().whenData((data) => data.manga),
      ),
      onData: (data) => MonoRelationGrid(
        items: data.items,
        onTap: (item) => context.push(
          Routes.media(item.tileId, item.tileImageUrl),
        ),
      ),
    );
  }
}
